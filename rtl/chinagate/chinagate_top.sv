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

// China Gate FPGA core - top-level integration.
//
// Connects:
//   - jtcg_main + jtcg_sub + jtcg_shared_ram   (CPU subsystem)
//   - jtcg_video (FG) + jtcg_scroll (BG) + jtcg_obj (sprites)
//   - jtcg_colmix (palette + priority)
//
// Audio is stubbed: snd_latch goes nowhere. snd_irq pulse from main is
// observable on the top output for debug only. The Z80 + YM2151 + OKI M6295
// will be wired up in a later step.
//
// ROM ports are exposed at the top so the testbench (or, in synth, the
// MiSTer SDRAM controller via jtframe_rom_Nslots + jtframe_sdram) can supply
// data. Each port has the standard {addr, data, cs, ok} 4-wire contract.
// In sim ok is held high; in synth jtframe_romrq drives it.

module chinagate_top (
    input  logic         clk,             // system clock (>= 24 MHz)
    input  logic         pxl_cen,         // 6 MHz pixel enable
    input  logic         cpu_cen,         // 6 MHz cpu pin clock (drives sys6809 cen)
    input  logic         rst,

    // ---- inputs (cabinet / dsw) ----
    input  logic [ 2:0]  coin_n,
    input  logic [ 7:0]  p1_n,
    input  logic [ 7:0]  p2_n,
    input  logic [ 7:0]  dsw1,
    input  logic [ 7:0]  dsw2,

    // ---- OSD offsets (signed, per layer X/Y) ----
    input  logic signed [9:0]  osd_bg_xoff,
    input  logic signed [9:0]  osd_bg_yoff,
    input  logic signed [9:0]  osd_fg_xoff,
    input  logic signed [9:0]  osd_fg_yoff,
    input  logic signed [9:0]  osd_spr_xoff,
    input  logic signed [9:0]  osd_spr_yoff,

    // ==================================================================
    // ROM ports (driven externally)
    // ==================================================================

    // Main CPU ROM (composite byte address into the 128KB image):
    //   byte [0x00000..0x17FFF) = banked area (bank N at [N*0x4000])
    //   byte [0x18000..0x1FFFF) = fixed area (CPU $8000-$FFFF)
    output logic [16:0]  main_rom_byte_addr,
    input  logic [ 7:0]  main_rom_data,
    input  logic         main_rom_ok,

    // Sub CPU ROM (same scheme)
    output logic [16:0]  sub_rom_byte_addr,
    input  logic [ 7:0]  sub_rom_data,
    input  logic         sub_rom_ok,

    // FG (chars) ROM: stored in BRAM locally, loaded via ioctl_download
    input  logic         chars_dl_wr,
    input  logic [16:0]  chars_dl_addr,
    input  logic [ 7:0]  chars_dl_data,

    // BG (tiles) ROM: stored in BRAM locally (256KB), loaded via ioctl_download
    input  logic         tiles_dl_wr,
    input  logic [17:0]  tiles_dl_addr,
    input  logic [ 7:0]  tiles_dl_data,

    // Sprites ROM: 32-bit word, byte-level 19-bit -> word [18:2] = 17 bit
    output logic [18:1]  obj_rom_addr,
    input  logic [31:0]  obj_rom_data,
    input  logic         obj_rom_ok,
    output logic         obj_rom_cs,

    // ==================================================================
    // CPU bus stall (drive high to freeze CPUs while cache/SDRAM serves)
    // ==================================================================
    input  logic         main_bus_busy,
    input  logic         sub_bus_busy,

    // ==================================================================
    // Video output
    // ==================================================================
    output logic [ 8:0]  hdump,
    output logic [ 8:0]  vdump,
    output logic         LHBL,
    output logic         LVBL,
    output logic         HS,
    output logic         VS,
    output logic [ 3:0]  red,
    output logic [ 3:0]  green,
    output logic [ 3:0]  blue,

    // ==================================================================
    // Debug / audio stub
    // ==================================================================
    output logic [ 7:0]  snd_latch_dbg,
    output logic         snd_irq_dbg,
    output logic         video_enable_dbg,
    output logic         flip_screen_dbg,
    output logic [ 8:0]  scrollx_dbg,
    output logic [ 8:0]  scrolly_dbg,
    output logic [15:0]  main_pc_dbg,     // exposed via mc6809i RegData
    output logic [15:0]  sub_pc_dbg
);

    // ==================================================================
    // Forward-declared interrupt pulses (driven later from vtimer signals)
    // ==================================================================
    logic vbl_nmi_pulse, timer_firq_pulse;

    // ==================================================================
    // Shared RAM (8K dual-port)
    // ==================================================================
    logic [12:0] shared_main_addr, shared_sub_addr;
    logic [ 7:0] shared_main_din,  shared_sub_din;
    logic        shared_main_we,   shared_sub_we;
    logic [ 7:0] shared_main_dout, shared_sub_dout;

    jtcg_shared_ram u_shared (
        .clk    (clk),
        .a_addr (shared_main_addr),
        .a_din  (shared_main_din),
        .a_we   (shared_main_we),
        .a_dout (shared_main_dout),
        .b_addr (shared_sub_addr),
        .b_din  (shared_sub_din),
        .b_we   (shared_sub_we),
        .b_dout (shared_sub_dout)
    );

    // ==================================================================
    // Main CPU node
    // ==================================================================
    logic [15:0] main_addr;
    logic [ 7:0] main_dout;
    logic        main_we, main_oe;
    logic        main_ram_cs, main_cram_cs, main_vram_cs;
    logic        main_pal_lo_cs, main_pal_hi_cs, main_oram_cs;
    logic        main_rom_fix_cs, main_rom_bank_cs;

    logic [ 7:0] main_cram_dout, main_vram_dout;
    logic [ 7:0] main_pal_dout, main_oram_dout;
    logic [ 2:0] main_rom_bank;
    logic [ 8:0] main_scrollx, main_scrolly;
    logic        main_flip, main_video_en;
    logic [ 7:0] main_snd_latch;
    logic        main_snd_irq, main_sub_irq_set;

    // CPU-E-quadrature strobe used to gate ALL external memory writes.
    // This matches the jtframe_sys6809 internal RAM convention (ram_we =
    // ram_cs & ~RnW & cen_Q) and ensures cpu_dout is stable when latched.
    logic main_cen_q;
    wire  main_we_pulse = main_we & main_cen_q;

    assign shared_main_addr = main_addr[12:0];
    assign shared_main_din  = main_dout;
    assign shared_main_we   = main_ram_cs & main_we_pulse;

    // ----- per palette CPU mux on main side -----
    logic [ 7:0] main_pal_lo_dout, main_pal_hi_dout;
    always_comb begin
        if      (main_pal_lo_cs) main_pal_dout = main_pal_lo_dout;
        else if (main_pal_hi_cs) main_pal_dout = main_pal_hi_dout;
        else                     main_pal_dout = 8'hFF;
    end

    // OAM read-back to CPU (will be wired to sprite OAM dual-port)
    logic [ 7:0] main_oam_dout_int;
    assign main_oram_dout = main_oam_dout_int;

    jtcg_main u_main (
        .clk            (clk),
        .cen            (cpu_cen),
        .rst            (rst),
        .vbl_nmi_set    (vbl_nmi_pulse),
        .timer_firq_set (timer_firq_pulse),

        .cpu_addr       (main_addr),
        .cpu_dout       (main_dout),
        .cpu_we         (main_we),
        .cpu_oe         (main_oe),

        .ram_cs         (main_ram_cs),
        .cram_cs        (main_cram_cs),
        .vram_cs        (main_vram_cs),
        .pal_lo_cs      (main_pal_lo_cs),
        .pal_hi_cs      (main_pal_hi_cs),
        .oram_cs        (main_oram_cs),
        .rom_fix_cs     (main_rom_fix_cs),
        .rom_bank_cs    (main_rom_bank_cs),

        .ram_dout       (shared_main_dout),
        .cram_dout      (main_cram_dout),
        .vram_dout      (main_vram_dout),
        .pal_dout       (main_pal_dout),
        .oram_dout      (main_oram_dout),
        .rom_fix_dout   (main_rom_data),    // shared single ROM data path
        .rom_bank_dout  (main_rom_data),

        .rom_bank       (main_rom_bank),
        .scrollx        (main_scrollx),
        .scrolly        (main_scrolly),
        .flip_screen    (main_flip),
        .video_enable   (main_video_en),
        .snd_latch      (main_snd_latch),
        .snd_irq        (main_snd_irq),
        .sub_irq_set    (main_sub_irq_set),

        .vblank_in      (~LVBL),         // active-high vblank to SYSTEM port
        .coin_n         (coin_n),
        .p1_n           (p1_n),
        .p2_n           (p2_n),
        .dsw1           (dsw1),
        .dsw2           (dsw2),

        .bus_busy       (main_bus_busy),

        .cpu_vma        (),
        .cpu_irq_ack    (),
        .cpu_cen_q      (main_cen_q)
    );

    // Compose the SDRAM byte address from the active CS:
    //   bank: byte = {bank[2:0], addr[13:0]}            in [0..0x17FFF]
    //   fix : byte = 17'h18000 | {2'b0, addr[14:0]}     in [0x18000..0x1FFFF]
    // Note: the ROM_CONTINUE-style image layout in cgate51.bin has the fix
    // area at file bytes [0x18000..0x1FFFF], so we can reach it by setting
    // bit 16 = 1 and bits 15:14 = 11 above the base.
    always_comb begin
        if (main_rom_fix_cs)
            main_rom_byte_addr = {2'b11, main_addr[14:0]};   // 0x18000 + a[14:0]
        else
            main_rom_byte_addr = {main_rom_bank, main_addr[13:0]};
    end

    // ==================================================================
    // Sub CPU node
    // ==================================================================
    logic [15:0] sub_addr;
    logic [ 7:0] sub_dout;
    logic        sub_we, sub_oe;
    logic        sub_ram_cs, sub_rom_fix_cs, sub_rom_bank_cs;
    logic [ 2:0] sub_rom_bank;

    logic sub_cen_q;
    wire  sub_we_pulse = sub_we & sub_cen_q;

    assign shared_sub_addr = sub_addr[12:0];
    assign shared_sub_din  = sub_dout;
    assign shared_sub_we   = sub_ram_cs & sub_we_pulse;

    jtcg_sub u_sub (
        .clk            (clk),
        .cen            (cpu_cen),
        .rst            (rst),
        .sub_irq_set    (main_sub_irq_set),

        .cpu_addr       (sub_addr),
        .cpu_dout       (sub_dout),
        .cpu_we         (sub_we),
        .cpu_oe         (sub_oe),

        .ram_cs         (sub_ram_cs),
        .rom_fix_cs     (sub_rom_fix_cs),
        .rom_bank_cs    (sub_rom_bank_cs),

        .ram_dout       (shared_sub_dout),
        .rom_fix_dout   (sub_rom_data),
        .rom_bank_dout  (sub_rom_data),

        .rom_bank       (sub_rom_bank),

        .bus_busy       (sub_bus_busy),

        .cpu_vma        (),
        .cpu_irq_ack    (),
        .cpu_cen_q      (sub_cen_q)
    );

    always_comb begin
        if (sub_rom_fix_cs)
            sub_rom_byte_addr = {2'b11, sub_addr[14:0]};
        else
            sub_rom_byte_addr = {sub_rom_bank, sub_addr[13:0]};
    end

    // ==================================================================
    // Video subsystem (FG + BG + sprites)
    // ==================================================================
    logic [ 7:0] fg_pxl;
    logic [ 6:0] bg_pxl;
    logic [ 7:0] obj_pxl;

    jtcg_video u_video (
        .rst           (rst),
        .clk           (clk),
        .pxl_cen       (pxl_cen),

        .cpu_vram_addr (main_addr[10:0]),
        .cpu_vram_din  (main_dout),
        .cpu_vram_we   (main_cram_cs & main_we_pulse),
        .cpu_vram_dout (main_cram_dout),
        .flip_screen   (main_flip),

        .osd_xoff      (osd_fg_xoff),
        .osd_yoff      (osd_fg_yoff),

        .chars_dl_wr   (chars_dl_wr),
        .chars_dl_addr (chars_dl_addr),
        .chars_dl_data (chars_dl_data),

        .hdump         (hdump),
        .vdump         (vdump),
        .LHBL          (LHBL),
        .LVBL          (LVBL),
        .HS            (HS),
        .VS            (VS),
        .fg_pxl        (fg_pxl)
    );

    jtcg_scroll u_scroll (
        .rst           (rst),
        .clk           (clk),
        .pxl_cen       (pxl_cen),
        .hs            (HS),

        .cpu_vram_addr (main_addr[10:0]),
        .cpu_vram_din  (main_dout),
        .cpu_vram_we   (main_vram_cs & main_we_pulse),
        .cpu_vram_dout (main_vram_dout),

        .hdump         (hdump),
        .vdump         (vdump),
        .LHBL          (LHBL),
        .LVBL          (LVBL),
        .flip_screen   (main_flip),
        .scrollx       (main_scrollx),
        .scrolly       (main_scrolly),

        .osd_xoff      (osd_bg_xoff),
        .osd_yoff      (osd_bg_yoff),

        .tiles_dl_wr   (tiles_dl_wr),
        .tiles_dl_addr (tiles_dl_addr),
        .tiles_dl_data (tiles_dl_data),

        .bg_pxl        (bg_pxl)
    );

    // ==================================================================
    // Sprite OAM (BRAM dual-port: CPU port + sprite engine port)
    // 384 byte effective, 512 byte addressed (9-bit addr)
    // ==================================================================
    logic [ 8:0] obj_oram_addr;
    logic [ 7:0] obj_oram_data;

    jtframe_dual_ram #(.AW(9), .DW(8)) u_oam (
        .clk0   (clk),
        .data0  (main_dout),
        .addr0  (main_addr[8:0]),
        .we0    (main_oram_cs & main_we_pulse),
        .q0     (main_oam_dout_int),

        .clk1   (clk),
        .data1  (8'h00),
        .addr1  (obj_oram_addr),
        .we1    (1'b0),
        .q1     (obj_oram_data)
    );

    jtcg_obj u_obj (
        .clk        (clk),
        .rst        (rst),
        .pxl_cen    (pxl_cen),
        .hdump      (hdump),
        .VPOS       (vdump[7:0]),
        .flip       (main_flip),
        .HBL        (~LHBL),
        .hs         (HS),
        .osd_xoff   (osd_spr_xoff),
        .osd_yoff   (osd_spr_yoff),
        .oram_addr  (obj_oram_addr),
        .oram_data  (obj_oram_data),
        .rom_addr   (obj_rom_addr),
        .rom_cs     (obj_rom_cs),
        .rom_data   (obj_rom_data),
        .rom_ok     (obj_rom_ok),
        .pxl        (obj_pxl)
    );

    // ==================================================================
    // Colmix / palette
    // ==================================================================
    jtcg_colmix u_colmix (
        .clk             (clk),
        .rst             (rst),
        .pxl_cen         (pxl_cen),

        .cpu_pal_addr    (main_addr[8:0]),
        .cpu_pal_din     (main_dout),
        .cpu_pal_lo_we   (main_pal_lo_cs & main_we_pulse),
        .cpu_pal_hi_we   (main_pal_hi_cs & main_we_pulse),
        .cpu_pal_lo_dout (main_pal_lo_dout),
        .cpu_pal_hi_dout (main_pal_hi_dout),

        .LHBL            (LHBL),
        .LVBL            (LVBL),
        .fg_pxl          (fg_pxl),
        .obj_pxl         (obj_pxl),
        .bg_pxl          (bg_pxl),

        .red             (red),
        .green           (green),
        .blue            (blue)
    );

    // ==================================================================
    // Interrupt pulses from vtimer
    // vbl_nmi: rising edge of LVBL going low (vcount entering blanking)
    // timer_firq: rising edge of vdump[3] (every 8 lines)
    // ==================================================================
    logic LVBL_d, vdump3_d;
    always_ff @(posedge clk) begin
        if (rst) begin
            LVBL_d           <= 1'b0;
            vdump3_d         <= 1'b0;
            vbl_nmi_pulse    <= 1'b0;
            timer_firq_pulse <= 1'b0;
        end else if (pxl_cen) begin
            LVBL_d           <= LVBL;
            vdump3_d         <= vdump[3];
            vbl_nmi_pulse    <= LVBL_d & ~LVBL;     // start of VBL
            timer_firq_pulse <= ~vdump3_d & vdump[3]; // every 8 lines
        end
    end

    // ==================================================================
    // Debug ports
    // ==================================================================
    assign snd_latch_dbg    = main_snd_latch;
    assign snd_irq_dbg      = main_snd_irq;
    assign video_enable_dbg = main_video_en;
    assign flip_screen_dbg  = main_flip;
    assign scrollx_dbg      = main_scrollx;
    assign scrolly_dbg      = main_scrolly;

    // PC introspection from mc6809i RegData[111:96]
    //   chinagate_top.u_main.u_cpu      -> cpu6809_wrap
    //   .u_cpu                          -> mc6809i (direct after wrapper rewrite)
    `ifdef SIMULATION
    assign main_pc_dbg = u_main.u_cpu.u_cpu.RegData[111:96];
    assign sub_pc_dbg  = u_sub .u_cpu.u_cpu.RegData[111:96];
    `else
    assign main_pc_dbg = 16'd0;
    assign sub_pc_dbg  = 16'd0;
    `endif

endmodule
