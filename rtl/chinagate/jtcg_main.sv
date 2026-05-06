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

// China Gate FPGA core
// Main CPU node: HD6309 main + address decode + bank switch + I/O latches.
//
// Reference: docs/crossref_chinagate.md §2 (memory map MAIN).
//
// This module is JUST the address-decode/glue around the CPU. It exposes
// chip-select strobes and write data to the surrounding modules:
//   - shared 8K RAM (with sub CPU)
//   - FG vram, BG vram, sprite RAM, palette
//   - banked + fixed program ROM
// and consumes:
//   - cabinet inputs (P1, P2, SYSTEM)
//   - DSW
//   - read-back data from each chip-select
//
// Interrupt sources (driven externally from the video timer):
//   - vbl_nmi    : pulse at vcount==0xF8 -> assert NMI
//   - timer_firq : pulse on (vcount&8) rising edge -> assert FIRQ
// Ack registers are written by the CPU at $3E01/$3E02/$3E03 to clear.

module jtcg_main (
    input  logic         clk,
    input  logic         cen,            // 1.5 MHz cpu cycle pulse
    input  logic         rst,

    // ---- interrupt sources (level set by external timer) ----
    input  logic         vbl_nmi_set,    // assert NMI when high
    input  logic         timer_firq_set, // assert FIRQ when high

    // ---- bus to memories / chips ----
    output logic [15:0]  cpu_addr,
    output logic [ 7:0]  cpu_dout,
    output logic         cpu_we,         // active high
    output logic         cpu_oe,         // active high (read)

    // chip selects (one-hot, asserted on a CPU cycle when address matches)
    output logic         ram_cs,         // $0000-$1FFF shared RAM
    output logic         cram_cs,        // $2000-$27FF FG vram
    output logic         vram_cs,        // $2800-$2FFF BG vram
    output logic         pal_lo_cs,      // $3000-$317F palette lo
    output logic         pal_hi_cs,      // $3400-$357F palette hi
    output logic         oram_cs,        // $3800-$397F sprite RAM
    output logic         rom_fix_cs,     // $8000-$FFFF fixed ROM
    output logic         rom_bank_cs,    // $4000-$7FFF banked ROM

    // ---- read-back from those chips (combinational mux) ----
    input  logic [ 7:0]  ram_dout,
    input  logic [ 7:0]  cram_dout,
    input  logic [ 7:0]  vram_dout,
    input  logic [ 7:0]  pal_dout,
    input  logic [ 7:0]  oram_dout,
    input  logic [ 7:0]  rom_fix_dout,
    input  logic [ 7:0]  rom_bank_dout,

    // ---- bank index (3-bit, 8 banks) ----
    output logic [ 2:0]  rom_bank,

    // ---- video / sound regs latched by main ($3E06, $3E07, $3F00) ----
    output logic [ 8:0]  scrollx,        // {scrollx_hi, scrollx_lo}
    output logic [ 8:0]  scrolly,
    output logic         flip_screen,
    output logic         video_enable,   // bit5 of $3F00 (TBD, see crossref §11)

    // ---- sound latch ($3E00 W) ----
    output logic [ 7:0]  snd_latch,
    output logic         snd_irq,        // pulse on $3E00 write

    // ---- sub CPU IRQ ($3E04 W) ----
    output logic         sub_irq_set,    // pulse on $3E04 write

    // ---- cabinet inputs ----
    input  logic         vblank_in,      // SYSTEM bit0
    input  logic [ 2:0]  coin_n,         // {COIN3,COIN2,COIN1} active low
    input  logic [ 7:0]  p1_n,           // P1 active low
    input  logic [ 7:0]  p2_n,           // P2 active low
    input  logic [ 7:0]  dsw1,
    input  logic [ 7:0]  dsw2,

    // ---- bus stall (cache miss / SDRAM busy) ----
    input  logic         bus_busy,

    // ---- debug ----
    output logic         cpu_vma,
    output logic         cpu_irq_ack,
    output logic         cpu_cen_q       // E-quadrature strobe
);

    // ------------------------------------------------------------------
    // CPU instance
    // ------------------------------------------------------------------
    logic [ 7:0] cpu_din;
    logic        nmi_n, firq_n, irq_n;

    cpu6809_wrap u_cpu (
        .clk      (clk),
        .cen      (cen),
        .rst      (rst),
        .nmi_n    (nmi_n),
        .irq_n    (irq_n),
        .firq_n   (firq_n),
        .bus_busy (bus_busy),
        .addr     (cpu_addr),
        .dout     (cpu_dout),
        .din      (cpu_din),
        .we       (cpu_we),
        .oe       (cpu_oe),
        .cen_q    (cpu_cen_q),
        .vma      (cpu_vma),
        .irq_ack  (cpu_irq_ack)
    );

    // ------------------------------------------------------------------
    // Address decode (combinational)
    // See docs/crossref_chinagate.md §2.
    // ------------------------------------------------------------------
    logic        io_3e_cs;       // $3E00-$3EFF (write-mostly)
    logic        io_3f_cs;       // $3F00-$3FFF (read inputs / write video_ctrl,bank)

    always_comb begin
        ram_cs       = (cpu_addr[15:13] == 3'b000);                            // $0000-$1FFF
        cram_cs      = (cpu_addr[15:11] == 5'b00100);                           // $2000-$27FF
        vram_cs      = (cpu_addr[15:11] == 5'b00101);                           // $2800-$2FFF
        pal_lo_cs    = (cpu_addr[15: 9] == 7'b0011000);                         // $3000-$317F
        pal_hi_cs    = (cpu_addr[15: 9] == 7'b0011010);                         // $3400-$357F
        oram_cs      = (cpu_addr[15: 9] == 7'b0011100) ||                       // $3800-$39FF
                       (cpu_addr[15: 9] == 7'b0011101);
        io_3e_cs     = (cpu_addr[15: 8] == 8'h3E);
        io_3f_cs     = (cpu_addr[15: 8] == 8'h3F);
        rom_bank_cs  = (cpu_addr[15:14] == 2'b01);                              // $4000-$7FFF
        rom_fix_cs   =  cpu_addr[15];                                            // $8000-$FFFF (high bit)
    end

    // ------------------------------------------------------------------
    // I/O register decode ($3E0x writes, $3F0x reads/writes)
    // we is held for an entire E cycle (~16 sysclk). We strobe writes on
    // cen_q (E-quadrature pulse, 1 sysclk per E cycle, fired when
    // cpu_dout is stable) so each write is captured exactly once.
    // ------------------------------------------------------------------
    wire we_pulse = cpu_we & cpu_cen_q;

    logic w_3e00, w_3e01, w_3e02, w_3e03, w_3e04, w_3e06, w_3e07;
    logic w_3f00, w_3f01;

    always_comb begin
        w_3e00 = io_3e_cs && we_pulse && (cpu_addr[7:0] == 8'h00);
        w_3e01 = io_3e_cs && we_pulse && (cpu_addr[7:0] == 8'h01);
        w_3e02 = io_3e_cs && we_pulse && (cpu_addr[7:0] == 8'h02);
        w_3e03 = io_3e_cs && we_pulse && (cpu_addr[7:0] == 8'h03);
        w_3e04 = io_3e_cs && we_pulse && (cpu_addr[7:0] == 8'h04);
        w_3e06 = io_3e_cs && we_pulse && (cpu_addr[7:0] == 8'h06);
        w_3e07 = io_3e_cs && we_pulse && (cpu_addr[7:0] == 8'h07);
        w_3f00 = io_3f_cs && we_pulse && (cpu_addr[7:0] == 8'h00);
        w_3f01 = io_3f_cs && we_pulse && (cpu_addr[7:0] == 8'h01);
    end

    // ------------------------------------------------------------------
    // Latches: scroll, video_ctrl, bank, sound latch
    // ------------------------------------------------------------------
    logic [7:0] scrollx_lo, scrolly_lo;
    logic       scrollx_hi, scrolly_hi;

    always_ff @(posedge clk) begin
        if (rst) begin
            scrollx_lo   <= '0;
            scrolly_lo   <= '0;
            scrollx_hi   <= 1'b0;
            scrolly_hi   <= 1'b0;
            flip_screen  <= 1'b0;
            video_enable <= 1'b0;
            rom_bank     <= 3'b000;
            snd_latch    <= '0;
            snd_irq      <= 1'b0;
            sub_irq_set  <= 1'b0;
        end else begin
            // single-cycle pulses default low
            snd_irq      <= 1'b0;
            sub_irq_set  <= 1'b0;

            // NOTE: until cen-based timing is wired through to the CPU core
            // we sample writes directly on every sysclk where cpu_we is high.
            // See docs/cpu_quirks.md §5.
            if (w_3e00) begin
                snd_latch <= cpu_dout;
                snd_irq   <= 1'b1;
            end
            if (w_3e04) sub_irq_set <= 1'b1;
            if (w_3e06) scrolly_lo  <= cpu_dout;
            if (w_3e07) scrollx_lo  <= cpu_dout;
            if (w_3f00) begin
                scrollx_hi   <= cpu_dout[0];
                scrolly_hi   <= cpu_dout[1];
                flip_screen  <= ~cpu_dout[2];     // active-LOW in driver
                video_enable <= cpu_dout[5];
            end
            if (w_3f01) rom_bank <= cpu_dout[2:0];
        end
    end

    assign scrollx = {scrollx_hi, scrollx_lo};
    assign scrolly = {scrolly_hi, scrolly_lo};

    // ------------------------------------------------------------------
    // Interrupt latches (NMI/FIRQ/IRQ) — set by external timer pulses,
    // cleared by CPU writes to $3E01/$3E02/$3E03.
    // ------------------------------------------------------------------
    logic nmi_q, firq_q, irq_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            nmi_q  <= 1'b0;
            firq_q <= 1'b0;
            irq_q  <= 1'b0;
        end else begin
            // set wins over clear when both fire same cycle
            if (vbl_nmi_set)             nmi_q  <= 1'b1;
            else if (w_3e01)             nmi_q  <= 1'b0;

            if (timer_firq_set)          firq_q <= 1'b1;
            else if (w_3e02)             firq_q <= 1'b0;

            // IRQ source unknown in driver; keep latch + ack scaffolding only.
            if (w_3e03)                  irq_q  <= 1'b0;
        end
    end

    assign nmi_n  = ~nmi_q;
    assign firq_n = ~firq_q;
    assign irq_n  = ~irq_q;

    // ------------------------------------------------------------------
    // Cabinet input mux ($3F00..$3F04 reads)
    // ------------------------------------------------------------------
    logic [7:0] cabinet_dout;

    // SYSTEM port at $3F00 (read): { [7:4]=1, COIN3_n, COIN2_n, COIN1_n, VBLANK }
    //   coin_n inputs are active-LOW (1 = no coin) and passed through.
    //   vblank_in is active-HIGH (driver: PORT_READ_LINE_DEVICE_MEMBER vblank).
    always_comb begin
        unique case (cpu_addr[2:0])
            3'd0: cabinet_dout = {4'b1111, coin_n, vblank_in};
            3'd1: cabinet_dout = dsw1;
            3'd2: cabinet_dout = dsw2;
            3'd3: cabinet_dout = p1_n;
            3'd4: cabinet_dout = p2_n;
            default: cabinet_dout = 8'hFF;
        endcase
    end

    // ------------------------------------------------------------------
    // CPU read-back mux
    // Priority: ram > cram > vram > pal_lo > pal_hi > oram > io_3f > rom_fix > rom_bank
    // ------------------------------------------------------------------
    always_comb begin
        if      (ram_cs)     cpu_din = ram_dout;
        else if (cram_cs)    cpu_din = cram_dout;
        else if (vram_cs)    cpu_din = vram_dout;
        else if (pal_lo_cs)  cpu_din = pal_dout;
        else if (pal_hi_cs)  cpu_din = pal_dout;
        else if (oram_cs)    cpu_din = oram_dout;
        else if (io_3f_cs)   cpu_din = cabinet_dout;
        else if (rom_fix_cs) cpu_din = rom_fix_dout;
        else if (rom_bank_cs)cpu_din = rom_bank_dout;
        else                 cpu_din = 8'hFF;
    end

endmodule
