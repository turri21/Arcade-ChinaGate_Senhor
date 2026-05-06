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
// Wrapper around mc6809i (Greg Miller's cycle-accurate 6809) with the
// jtframe_6809wait clock-enable generator. We instantiate the pieces
// manually rather than use jtframe_sys6809 because we need to expose
// cen_Q externally for clean external-RAM write strobing.
//
// cen input  : pin clock (drive at 6 MHz for 1.5 MHz cycle E)
// cen_q out  : E-cycle quadrature pulse, use as we-gate for external RAM
//
// Standard 6809 active-low interrupts (nmi_n, irq_n, firq_n).

module cpu6809_wrap (
    input  logic         clk,
    input  logic         cen,
    input  logic         rst,
    // interrupts (active low, standard 6809)
    input  logic         nmi_n,
    input  logic         irq_n,
    input  logic         firq_n,
    // bus stall (high = freeze CPU until cache/SDRAM serves the byte)
    input  logic         bus_busy,
    // bus
    output logic [15:0]  addr,
    output logic [ 7:0]  dout,
    input  logic [ 7:0]  din,
    output logic         we,
    output logic         oe,
    // cycle E quadrature strobe (use to gate external memory writes)
    output logic         cen_q,
    // debug
    output logic         vma,
    output logic         irq_ack
);

    wire rstn = ~rst;

    wire cen_E, cen_Q;
    wire cpu_cen_unused;

    jtframe_6809wait #(.RECOVERY(0)) u_wait (
        .rstn     (rstn),
        .clk      (clk),
        .cen      (cen),
        .cpu_cen  (cpu_cen_unused),
        .dev_busy (bus_busy),
        .rom_cs   (1'b1),
        .rom_ok   (1'b1),
        .cen_E    (cen_E),
        .cen_Q    (cen_Q)
    );

    assign cen_q = cen_Q;

    wire BA, BS, AVMA;
    wire rnw;

    always_ff @(posedge clk, negedge rstn) begin
        if (!rstn) vma <= 1'b1;
        else if (cen_E) vma <= AVMA;
    end

    assign irq_ack = {BA, BS} == 2'b01;
    assign we = vma & ~rnw;
    assign oe = vma &  rnw;

    mc6809i u_cpu (
        .D       (din),
        .DOut    (dout),
        .ADDR    (addr),
        .RnW     (rnw),
        .clk     (clk),
        .cen_E   (cen_E),
        .cen_Q   (cen_Q),
        .BS      (BS),
        .BA      (BA),
        .nIRQ    (irq_n),
        .nFIRQ   (firq_n),
        .nNMI    (nmi_n),
        .AVMA    (AVMA),
        .BUSY    (),
        .LIC     (),
        .nDMABREQ(1'b1),
        .nHALT   (1'b1),
        .nRESET  (rstn),
        .OP      (),
        .RegData ()
    );

endmodule
