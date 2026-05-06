// SPDX-License-Identifier: GPL-3.0-or-later
/*  This file is part of ChinaGate_MiSTer.

    ChinaGate_MiSTer is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    ChinaGate_MiSTer is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with ChinaGate_MiSTer.  If not, see <http://www.gnu.org/licenses/>.

    Author: Umberto Parisi (rmonic79)
    Version: 1.0
    Date: 2026

*/

// China Gate FPGA core - FG renderer + vtimer.
//
// Decodifica MAME chinagat charlayout (8x8 4bpp, 32 byte/char):
//   - 4 byte per row, byte_idx = T*32 + 8*qx + y (qx in 0..3, 2 pixel/byte)
//   - 1 byte SDRAM = 2 pixel x 4 plane (planes interleavati)
//   - pixel pari (left, subx=0):    pen = {b[7], b[5], b[3], b[1]}
//   - pixel dispari (right, subx=1): pen = {b[6], b[4], b[2], b[0]}
//
// Chars ROM in BRAM locale (128KB ~ 100 M10K). Caricata via ioctl_download.
// Zero contesa SDRAM, zero friccichio.
//
// Pipeline (3 stages, lookahead 2 pxl_cen per coprire latenza BRAM VRAM + ROM):
//   T:   heff(T)     → vid_addr_la(T) = heff(T)+2 mappato → BRAM VRAM
//   T+1: vid_word_data(T+1) → byte_idx_la(T+1) → BRAM chars
//   T+2: rom_byte(T+2) → pixel decode
//   subx/pal pipelinati di 2 cicli per allineare con rom_byte.

module jtcg_video (
    input  logic         rst,
    input  logic         clk,
    input  logic         pxl_cen,

    // ---- CPU bus (FG VRAM) ----
    input  logic [10:0]  cpu_vram_addr,
    input  logic [ 7:0]  cpu_vram_din,
    input  logic         cpu_vram_we,
    output logic [ 7:0]  cpu_vram_dout,

    input  logic         flip_screen,

    // OSD-driven X/Y offset (signed 10-bit, applicato a heff/veff)
    input  logic signed [9:0]  osd_xoff,
    input  logic signed [9:0]  osd_yoff,

    // ---- Chars ROM download (128KB stored locally in BRAM) ----
    input  logic         chars_dl_wr,
    input  logic [16:0]  chars_dl_addr,
    input  logic [ 7:0]  chars_dl_data,

    // ---- video timing outs ----
    output logic [ 8:0]  hdump,
    output logic [ 8:0]  vdump,
    output logic         LHBL,
    output logic         LVBL,
    output logic         HS,
    output logic         VS,

    output logic [ 7:0]  fg_pxl
);

    // ------------------------------------------------------------------
    // Video timer
    // ------------------------------------------------------------------
    logic [8:0] vrender, vrender1;
    logic       Hinit, Vinit;

    jtframe_vtimer #(
        .VB_START  (9'h0F7),
        .VB_END    (9'h007),
        .VCNT_END  (9'd271),
        .VS_START  (9'h106),
        .HS_START  (9'h1AE),
        .HB_START  (9'h184),
        .HJUMP     (1),
        .HB_END    (9'd4),
        .HINIT     (9'd255)
    ) u_vtimer (
        .clk     (clk),
        .pxl_cen (pxl_cen),
        .vdump   (vdump),
        .vrender (vrender),
        .vrender1(vrender1),
        .H       (hdump),
        .Hinit   (Hinit),
        .Vinit   (Vinit),
        .LHBL    (LHBL),
        .LVBL    (LVBL),
        .HS      (HS),
        .VS      (VS)
    );

    // ------------------------------------------------------------------
    // FG VRAM (2K dual-port: CPU 8-bit + video 16-bit)
    // ------------------------------------------------------------------
    logic [ 1:0] cpu_we_pair;
    logic [15:0] cpu_din_pair;
    logic [15:0] cpu_dout_pair;
    logic [ 9:0] cpu_word_addr;

    assign cpu_word_addr = cpu_vram_addr[10:1];
    assign cpu_we_pair   = cpu_vram_we ? (cpu_vram_addr[0] ? 2'b01 : 2'b10) : 2'b00;
    assign cpu_din_pair  = {cpu_vram_din, cpu_vram_din};
    assign cpu_vram_dout = cpu_vram_addr[0] ? cpu_dout_pair[ 7:0]
                                            : cpu_dout_pair[15:8];

    // ------------------------------------------------------------------
    // Effective coords + lookahead 2 pixel
    // ------------------------------------------------------------------
    logic [ 8:0] heff, veff, heff_la;

    always @(posedge clk) begin
        if (rst) begin
            heff <= 0;
            veff <= 0;
        end else if (pxl_cen) begin
            // FG ha offset X fisso -1 calibrato (HOFFSET hardcoded).
            // OSD osd_xoff resta sommato per fine-tuning extra.
            heff <= (hdump ^ {1'b0, {8{flip_screen}}}) - 9'd1 + osd_xoff[8:0];
            veff <= (vdump ^ {1'b0, {8{flip_screen}}}) + osd_yoff[8:0];
        end
    end

    // Lookahead di 1 pixel: nxt_byte sarà il byte del pixel SUCCESSIVO,
    // pronto per lo swap atomico su qx_now_changed.
    assign heff_la = heff + 9'd1;

    // Coords per VRAM lookup (lookahead)
    wire [4:0] tile_col_la = heff_la[7:3];
    wire [4:0] tile_row    = veff[7:3];
    wire [2:0] py          = veff[2:0];
    wire [1:0] qx_la       = heff_la[2:1];

    // VRAM lookup linear (no PCB permutation per FG)
    wire [9:0] vid_addr = {tile_row, tile_col_la};
    logic [15:0] vid_word_data;

    jtframe_dual_ram16 #(.AW(10)) u_fg_vram (
        .clk0   (clk),
        .data0  (cpu_din_pair),
        .addr0  (cpu_word_addr),
        .we0    (cpu_we_pair),
        .q0     (cpu_dout_pair),

        .clk1   (clk),
        .data1  (16'h0000),
        .addr1  (vid_addr),
        .we1    (2'b00),
        .q1     (vid_word_data)
    );

    // Pipeline qx_la/py per matchare BRAM VRAM (1 ciclo)
    logic [1:0] qx_la_d;
    logic [2:0] py_d;
    always @(posedge clk) begin
        qx_la_d <= qx_la;
        py_d    <= py;
    end

    // Tile attrs (validi 1 ciclo dopo heff_la)
    wire [11:0] tile_code = vid_word_data[11:0];
    wire [ 3:0] tile_pal  = vid_word_data[15:12];

    // byte_idx lookahead (1 ciclo dopo BRAM VRAM)
    wire [16:0] byte_idx_la = {tile_code, qx_la_d, py_d};

    // ------------------------------------------------------------------
    // Chars ROM in BRAM locale (128KB)
    // ------------------------------------------------------------------
    (* ramstyle = "M10K,no_rw_check" *) logic [7:0] chars_rom [0:131071];

    always @(posedge clk) begin
        if (chars_dl_wr) chars_rom[chars_dl_addr] <= chars_dl_data;
    end

    // Lettura BRAM in continuazione su byte_idx_la (lookahead +2 pixel).
    // Ritarda 1 ciclo per BRAM latency.
    logic [7:0] nxt_byte;
    always @(posedge clk) begin
        nxt_byte <= chars_rom[byte_idx_la];
    end

    // Pipeline tile_pal allineato a nxt_byte (1 ciclo dopo BRAM VRAM)
    logic [3:0] nxt_pal;
    always @(posedge clk) nxt_pal <= tile_pal;

    // ------------------------------------------------------------------
    // Atomic swap nxt → cur su cambio X-quad on screen
    // ------------------------------------------------------------------
    wire [2:0] px_now   = heff[2:0];
    wire [1:0] qx_now   = px_now[2:1];
    wire       subx_now = px_now[0];

    logic [1:0] qx_now_d;
    wire qx_now_changed = (qx_now != qx_now_d);
    always @(posedge clk) if (pxl_cen) qx_now_d <= qx_now;

    logic [7:0] cur_byte;
    logic [3:0] cur_pal;

    always @(posedge clk) begin
        if (rst) begin
            cur_byte <= 0;
            cur_pal  <= 0;
        end else if (pxl_cen && qx_now_changed) begin
            cur_byte <= nxt_byte;
            cur_pal  <= nxt_pal;
        end
    end

    // ------------------------------------------------------------------
    // Pixel decoder
    // ------------------------------------------------------------------
    wire [3:0] pen_left  = {cur_byte[7], cur_byte[5], cur_byte[3], cur_byte[1]};
    wire [3:0] pen_right = {cur_byte[6], cur_byte[4], cur_byte[2], cur_byte[0]};
    wire [3:0] pen = subx_now ? pen_right : pen_left;

    assign fg_pxl = (LHBL & LVBL) ? {cur_pal, pen} : 8'h00;

endmodule
