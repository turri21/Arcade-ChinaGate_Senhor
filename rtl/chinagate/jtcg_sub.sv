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
// Sub CPU node: HD6309 sub + minimal address decode.
//
// Reference: docs/crossref_chinagate.md §3 (memory map SUB).
//
// Memory map:
//   $0000-$1FFF  shared RAM (8K, with main)
//   $2000        sub bankswitch (write only)
//   $2800        sub IRQ ack    (write only)
//   $4000-$7FFF  banked ROM (8 banks × 16K)
//   $8000-$FFFF  fixed ROM (32K)
//
// IRQ source (single line, level): asserted by main writing $3E04,
// cleared by sub writing $2800. Drives sprite_irq = M6809_IRQ_LINE.

module jtcg_sub (
    input  logic         clk,
    input  logic         cen,            // 1.5 MHz cycle pulse (currently unused, see cpu_quirks.md §5)
    input  logic         rst,

    // ---- IRQ from main ($3E04 W) / cleared by sub $2800 W ----
    input  logic         sub_irq_set,    // pulse from main

    // ---- bus ----
    output logic [15:0]  cpu_addr,
    output logic [ 7:0]  cpu_dout,
    output logic         cpu_we,
    output logic         cpu_oe,

    // chip selects
    output logic         ram_cs,         // $0000-$1FFF shared
    output logic         rom_fix_cs,     // $8000-$FFFF
    output logic         rom_bank_cs,    // $4000-$7FFF

    // read-back
    input  logic [ 7:0]  ram_dout,
    input  logic [ 7:0]  rom_fix_dout,
    input  logic [ 7:0]  rom_bank_dout,

    // bank
    output logic [ 2:0]  rom_bank,

    // bus stall (cache miss / SDRAM busy)
    input  logic         bus_busy,

    // debug
    output logic         cpu_vma,
    output logic         cpu_irq_ack,
    output logic         cpu_cen_q
);

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
    // Decode
    // we is held by the CPU for an entire E cycle (~16 sysclk). Strobe
    // writes on cen_q to capture them exactly once per E cycle.
    // ------------------------------------------------------------------
    wire we_pulse = cpu_we & cpu_cen_q;

    logic w_2000, w_2800;

    always_comb begin
        ram_cs      = (cpu_addr[15:13] == 3'b000);   // $0000-$1FFF
        rom_bank_cs = (cpu_addr[15:14] == 2'b01);    // $4000-$7FFF
        rom_fix_cs  =  cpu_addr[15];                  // $8000-$FFFF

        w_2000      = we_pulse && (cpu_addr == 16'h2000);
        w_2800      = we_pulse && (cpu_addr == 16'h2800);
    end

    // ------------------------------------------------------------------
    // Bank latch
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst)         rom_bank <= 3'b000;
        else if (w_2000) rom_bank <= cpu_dout[2:0];
    end

    // ------------------------------------------------------------------
    // IRQ latch (single line). Set by main pulse, cleared by sub $2800 W.
    // ------------------------------------------------------------------
    logic irq_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            irq_q <= 1'b0;
        end else begin
            if (sub_irq_set)      irq_q <= 1'b1;
            else if (w_2800)      irq_q <= 1'b0;
        end
    end

    assign nmi_n  = 1'b1;       // sub has no NMI on China Gate
    assign firq_n = 1'b1;       // sub has no FIRQ either
    assign irq_n  = ~irq_q;

    // ------------------------------------------------------------------
    // Read-back mux
    // ------------------------------------------------------------------
    always_comb begin
        if      (ram_cs)      cpu_din = ram_dout;
        else if (rom_fix_cs)  cpu_din = rom_fix_dout;
        else if (rom_bank_cs) cpu_din = rom_bank_dout;
        else                  cpu_din = 8'hFF;
    end

endmodule
