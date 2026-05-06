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

// China Gate FPGA core - color mix / palette.
//
// References:
//   - chinagat.cpp:709-713 (gfx decode regions: chars=0,16; sprites=128,8; tiles=256,8)
//   - ddragon_v.cpp:220-232 (drawing order: BG, sprites, FG)
//   - crossref §6 (palette is xBGR_444, split lo/hi at $3000/$3400)
//
// Palette memory layout (CPU view):
//   $3000-$317F : palette LOW byte  (8-bit: { G[3:0], R[3:0] })
//   $3400-$357F : palette HIGH byte (8-bit: { x[3:0], B[3:0] }), only B used
//   total: 384 colors, 9-bit index
//
// Priority (hardcoded, MAME-correct):
//   FG (pen != 0) > sprite (pen != 0) > BG
//
// Palette base offsets per layer:
//   FG     : base   0 (256 entries: 16 pals x 16 pens)
//   sprite : base 128 (overlap with FG upper half — intentional per gfx_decode)
//   BG     : base 256 (128 entries: 8 pals x 16 pens)

module jtcg_colmix (
    input  logic        clk,
    input  logic        rst,
    input  logic        pxl_cen,

    // ---- CPU bus (palette write + read) ----
    input  logic [ 8:0] cpu_pal_addr,    // 0..383 linear
    input  logic [ 7:0] cpu_pal_din,
    input  logic        cpu_pal_lo_we,   // write lo byte ($3000-$317F)
    input  logic        cpu_pal_hi_we,   // write hi byte ($3400-$357F)
    output logic [ 7:0] cpu_pal_lo_dout,
    output logic [ 7:0] cpu_pal_hi_dout,

    // ---- video sync ----
    input  logic        LHBL,
    input  logic        LVBL,

    // ---- pixel inputs ----
    input  logic [ 7:0] fg_pxl,          // 4-bit pal + 4-bit pen
    input  logic [ 7:0] obj_pxl,         // 4-bit pal + 4-bit pen
    input  logic [ 6:0] bg_pxl,          // 3-bit pal + 4-bit pen

    // ---- output RGB 4-4-4 ----
    output logic [ 3:0] red,
    output logic [ 3:0] green,
    output logic [ 3:0] blue
);

    // ------------------------------------------------------------------
    // Layer visibility (transparent pen = 0)
    // ------------------------------------------------------------------
    wire fg_visible  = |fg_pxl[3:0];
    wire obj_visible = |obj_pxl[3:0];

    // ------------------------------------------------------------------
    // Priority: FG > sprite > BG
    // pal_addr drives the palette BRAM read port.
    // ------------------------------------------------------------------
    logic [8:0] pal_addr_nx;

    always_comb begin
        if      (fg_visible)  pal_addr_nx = {1'b0,  fg_pxl[7:0]};         // 0..255
        else if (obj_visible) pal_addr_nx = {1'b0,  1'b1, obj_pxl[6:0]};  // 128..255
        else                  pal_addr_nx = {2'b10, bg_pxl[6:0]};         // 256..383
    end

    // Register pal_addr at pxl_cen for stable BRAM input
    logic [8:0] pal_addr;
    always_ff @(posedge clk) if (pxl_cen) pal_addr <= pal_addr_nx;

    // ------------------------------------------------------------------
    // Palette BRAMs (LO and HI, 512x8)
    // LO byte: { G[3:0], R[3:0] }
    // HI byte: { x[3:0], B[3:0] }
    // ------------------------------------------------------------------
    logic [7:0] pal_lo_q, pal_hi_q;

    jtframe_dual_ram #(.AW(9), .DW(8)) u_pal_lo (
        .clk0   (clk),
        .data0  (cpu_pal_din),
        .addr0  (cpu_pal_addr),
        .we0    (cpu_pal_lo_we),
        .q0     (cpu_pal_lo_dout),
        .clk1   (clk),
        .data1  (8'h00),
        .addr1  (pal_addr),
        .we1    (1'b0),
        .q1     (pal_lo_q)
    );

    jtframe_dual_ram #(.AW(9), .DW(8)) u_pal_hi (
        .clk0   (clk),
        .data0  (cpu_pal_din),
        .addr0  (cpu_pal_addr),
        .we0    (cpu_pal_hi_we),
        .q0     (cpu_pal_hi_dout),
        .clk1   (clk),
        .data1  (8'h00),
        .addr1  (pal_addr),
        .we1    (1'b0),
        .q1     (pal_hi_q)
    );

    // ------------------------------------------------------------------
    // Final RGB output, blanked outside visible window
    // ------------------------------------------------------------------
    always_ff @(posedge clk) if (pxl_cen) begin
        if (LHBL && LVBL) begin
            red   <= pal_lo_q[3:0];
            green <= pal_lo_q[7:4];
            blue  <= pal_hi_q[3:0];
        end else begin
            red   <= 4'h0;
            green <= 4'h0;
            blue  <= 4'h0;
        end
    end

endmodule
