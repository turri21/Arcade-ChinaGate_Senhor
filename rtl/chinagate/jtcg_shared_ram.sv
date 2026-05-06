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
// Shared RAM 8K, dual-port, between main and sub CPU.
//
// Pattern uses jtframe_dual_ram (Jotego) for guaranteed M10K inference:
// true dual-port BRAM, 1-cycle synchronous read on each port.
// Same-cycle write collisions are not expected on the original game
// (the firmware uses semaphores).

module jtcg_shared_ram (
    input  logic        clk,

    // ---- port A (main CPU) ----
    input  logic [12:0] a_addr,
    input  logic [ 7:0] a_din,
    input  logic        a_we,
    output logic [ 7:0] a_dout,

    // ---- port B (sub CPU) ----
    input  logic [12:0] b_addr,
    input  logic [ 7:0] b_din,
    input  logic        b_we,
    output logic [ 7:0] b_dout
);

    jtframe_dual_ram #(.AW(13), .DW(8)) u_ram (
        .clk0   (clk),
        .data0  (a_din),
        .addr0  (a_addr),
        .we0    (a_we),
        .q0     (a_dout),

        .clk1   (clk),
        .data1  (b_din),
        .addr1  (b_addr),
        .we1    (b_we),
        .q1     (b_dout)
    );

endmodule
