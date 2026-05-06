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

// China Gate FPGA core - BG (scroll) tilemap renderer.
//
// Decodifica MAME chinagat tilelayout (16x16 4bpp, 64 byte/tile):
//   - planes 2,3 nei primi 0x20000 byte SDRAM region (a-13 + a-12)
//   - planes 0,1 negli 0x20000 byte successivi (a-15 + a-14)
//   - byte_idx (within half) = T*64 + 16*qf + pyf
//   - byte SDRAM = 4 pixel × 2 plane:
//     pixel x in 0..3 (left→right): bit_pos = 3 - x
//       p_lo = byte[bit_pos]      (plane 2 in lo half, plane 0 in hi half)
//       p_hi = byte[bit_pos + 4]  (plane 3 in lo half, plane 1 in hi half)
//
// HW v32 (con MRA "BG v1 swap halves") confermò che la prima half MRA US
// = byte_hi (planes 0,1) e seconda half = byte_lo (planes 2,3). Si swap dei
// "lo" / "hi" mantenendo MRA US standard.
//
// Tiles ROM in BRAM locale (256KB = 2 x 128KB). Caricato via ioctl_download.
// Zero contesa SDRAM, zero friccichio.
//
// Pipeline: heff/veff registered, lookahead +1 pixel, swap atomico su q_now_changed.

module jtcg_scroll (
    input  logic         rst,
    input  logic         clk,
    input  logic         pxl_cen,
    input  logic         hs,

    // ---- CPU bus (BG VRAM) ----
    input  logic [10:0]  cpu_vram_addr,
    input  logic [ 7:0]  cpu_vram_din,
    input  logic         cpu_vram_we,
    output logic [ 7:0]  cpu_vram_dout,

    // ---- video sync ----
    input  logic [ 8:0]  hdump,
    input  logic [ 8:0]  vdump,
    input  logic         LHBL,
    input  logic         LVBL,
    input  logic         flip_screen,
    input  logic [ 8:0]  scrollx,
    input  logic [ 8:0]  scrolly,

    // OSD offset
    input  logic signed [9:0]  osd_xoff,
    input  logic signed [9:0]  osd_yoff,

    // ---- Tiles ROM download (256KB stored locally in 2x BRAM 128KB) ----
    input  logic         tiles_dl_wr,
    input  logic [17:0]  tiles_dl_addr,    // byte offset 0..0x3FFFF
    input  logic [ 7:0]  tiles_dl_data,

    // ---- pixel out ----
    output logic [ 6:0]  bg_pxl              // {pal[2:0], pix[3:0]}
);

    // ------------------------------------------------------------------
    // BG VRAM (2K dual-port: CPU 8-bit + video 16-bit)
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
    // Effective coords + lookahead 1 pixel
    // ------------------------------------------------------------------
    logic [ 8:0] heff, veff, heff_la;

    always @(posedge clk) begin
        if (rst) begin
            heff <= 0;
            veff <= 0;
        end else if (pxl_cen) begin
            heff <= (hdump ^ {1'b0, {8{flip_screen}}}) + scrollx + osd_xoff[8:0];
            veff <= (vdump ^ {1'b0, {8{flip_screen}}}) + scrolly + osd_yoff[8:0];
        end
    end

    assign heff_la = heff + 9'd1;

    // Coords del pixel attualmente in screen (per pixel decoder)
    wire [3:0] px_now      = heff[3:0];
    wire [1:0] q_now       = px_now[3:2];
    wire [1:0] px_in_q_now = px_now[1:0];

    // Coords lookahead per VRAM/ROM lookup
    wire [4:0] tile_col_la = heff_la[8:4];
    wire [4:0] tile_row    = veff[8:4];
    wire [3:0] py          = veff[3:0];
    wire [1:0] q_la        = heff_la[3:2];

    // PCB permutation: linear (row[4:0], col[4:0]) → pcb (row[4], col[4], row[3:0], col[3:0])
    wire [9:0] vid_addr = {tile_row[4], tile_col_la[4], tile_row[3:0], tile_col_la[3:0]};
    logic [15:0] vid_word_data;

    jtframe_dual_ram16 #(.AW(10)) u_bg_vram (
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

    // Pipeline q_la/py per BRAM VRAM latency (1 ciclo)
    logic [1:0] q_la_d;
    logic [3:0] py_d;
    always @(posedge clk) begin
        q_la_d <= q_la;
        py_d   <= py;
    end

    // Tile attrs (validi 1 ciclo dopo heff_la)
    wire [10:0] tile_code  = {vid_word_data[10:8], vid_word_data[7:0]};
    wire [ 2:0] tile_color =  vid_word_data[13:11];
    wire        tile_xflip =  vid_word_data[14];
    wire        tile_yflip =  vid_word_data[15];

    wire [3:0] pyf = py_d   ^ {4{tile_yflip}};
    wire [1:0] qf  = q_la_d ^ {2{tile_xflip}};

    // byte_idx within half ROM (17 bit): T(11) << 6 | qf(2) << 4 | pyf(4)
    wire [16:0] byte_idx_la = {tile_code, qf, pyf};

    // ------------------------------------------------------------------
    // Tiles ROM in BRAM locale (256KB = 2 x 128KB)
    // tiles_dl_addr[17] = 0 → lo half (planes 2,3 according to MAME, ma con
    //   v32 confermato che è byte_HI nel decoder)
    // tiles_dl_addr[17] = 1 → hi half (byte_LO nel decoder)
    // ------------------------------------------------------------------
    (* ramstyle = "M10K,no_rw_check" *) logic [7:0] tiles_rom_lo [0:131071]; // hi half MAME = byte_lo
    (* ramstyle = "M10K,no_rw_check" *) logic [7:0] tiles_rom_hi [0:131071]; // lo half MAME = byte_hi

    always @(posedge clk) begin
        if (tiles_dl_wr) begin
            // dl_addr[17]=0 → MAME prima half → byte_hi nel decoder
            // dl_addr[17]=1 → MAME seconda half → byte_lo nel decoder
            if (tiles_dl_addr[17] == 1'b0)
                tiles_rom_hi[tiles_dl_addr[16:0]] <= tiles_dl_data;
            else
                tiles_rom_lo[tiles_dl_addr[16:0]] <= tiles_dl_data;
        end
    end

    logic [7:0] nxt_byte_lo, nxt_byte_hi;
    always @(posedge clk) begin
        nxt_byte_lo <= tiles_rom_lo[byte_idx_la];
        nxt_byte_hi <= tiles_rom_hi[byte_idx_la];
    end

    // Pipeline color/xflip allineati a nxt_byte_* (1 ciclo dopo BRAM VRAM)
    logic [2:0] nxt_color;
    logic       nxt_xflip;
    always @(posedge clk) begin
        nxt_color <= tile_color;
        nxt_xflip <= tile_xflip;
    end

    // ------------------------------------------------------------------
    // Atomic swap nxt → cur al CAMBIO q_la (= cambio della X-quad lookahead).
    // q_la cambia 1 pxl_cen PRIMA di q_now, quindi swap avviene al pxl_cen
    // dell'ultimo pixel della X-quad precedente. cur è già aggiornato
    // quando heff entra nella nuova X-quad → primo pixel corretto.
    // ------------------------------------------------------------------
    wire [1:0] q_la_screen = heff_la[3:2];
    logic [1:0] q_la_screen_d;
    wire q_la_changed = (q_la_screen != q_la_screen_d);
    always @(posedge clk) if (pxl_cen) q_la_screen_d <= q_la_screen;

    logic [7:0] cur_byte_lo, cur_byte_hi;
    logic [2:0] cur_color;
    logic       cur_xflip;

    always @(posedge clk) begin
        if (rst) begin
            cur_byte_lo <= 0;
            cur_byte_hi <= 0;
            cur_color   <= 0;
            cur_xflip   <= 0;
        end else if (pxl_cen && q_la_changed) begin
            cur_byte_lo <= nxt_byte_lo;
            cur_byte_hi <= nxt_byte_hi;
            cur_color   <= nxt_color;
            cur_xflip   <= nxt_xflip;
        end
    end

    // ------------------------------------------------------------------
    // Pixel decoding (perm 3210, BG-specifico)
    // ------------------------------------------------------------------
    // HW v48 conferma: tutti i tile BG escono specchiati X. Inverto bit_pos
    // default → con cur_xflip=0 ora pixel 0 = bit 0 (leftmost), match HW.
    wire [2:0] bit_pos_raw = {1'b0, ~px_in_q_now[1], ~px_in_q_now[0]};   // 3 - px_in_q
    wire [2:0] bit_pos = cur_xflip ? bit_pos_raw : {1'b0, px_in_q_now};

    wire p3 = cur_byte_lo[bit_pos + 3'd4];
    wire p2 = cur_byte_lo[bit_pos        ];
    wire p1 = cur_byte_hi[bit_pos + 3'd4];
    wire p0 = cur_byte_hi[bit_pos        ];
    wire [3:0] pen = {p3, p2, p1, p0};

    assign bg_pxl = (LHBL & LVBL) ? {cur_color, pen} : 7'h00;

endmodule
