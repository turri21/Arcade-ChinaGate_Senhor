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

// jtcg_objdraw — wrapper attorno a jtcg_draw + jtframe_obj_buffer.
// Sostituto drop-in di jtframe_objdraw per China Gate.
// Stessa interfaccia esterna; usa drawer custom xrev_perm_3210.

module jtcg_objdraw #(
    parameter CW    = 12,
    parameter PW    = 8,
    parameter SWAPH = 0,    // ignorato (custom drawer)
    parameter HJUMP = 0,
    parameter LATCH = 1,    // sempre 1
    parameter FLIP_OFFSET = 0,
    parameter ALPHA       = 0
)(
    input               rst,
    input               clk,
    input               pxl_cen,
    input               hs,
    input               flip,
    input        [ 8:0] hdump,

    input               draw,
    output              busy,
    input    [CW-1:0]   code,
    input      [ 8:0]   xpos,
    input      [ 3:0]   ysub,

    input               hflip,
    input               vflip,
    input      [PW-5:0] pal,

    output     [CW+6:1] rom_addr,
    output              rom_cs,
    input               rom_ok,
    input      [31:0]   rom_data,

    output     [PW-1:0] pxl
);

    wire [PW-1:0] buf_din;
    wire    [8:0] buf_addr;
    reg     [8:0] aeff, hdf;
    wire          buf_we;

    always @* begin
        case (HJUMP)
            1: begin
                aeff = {buf_addr[8], buf_addr[8] | buf_addr[7], buf_addr[6:0]};
                hdf  = hdump ^ {1'b0, flip & ~hdump[8], {7{flip}}};
            end
            2: begin
                aeff = {buf_addr[8], ~buf_addr[8] | buf_addr[7], buf_addr[6:0]};
                hdf  = hdump ^ {1'b0, flip & hdump[8], {7{flip}}};
            end
            default: begin
                aeff = buf_addr;
                hdf  = hdump ^ {1'b0, {8{flip}}};
            end
        endcase
    end

    jtcg_draw #(
        .CW(CW),
        .PW(PW)
    ) u_draw (
        .rst       (rst),
        .clk       (clk),
        .draw      (draw),
        .busy      (busy),
        .code      (code),
        .xpos      (xpos),
        .ysub      (ysub),
        .hflip     (hflip),
        .vflip     (vflip),
        .pal       (pal),
        .rom_addr  (rom_addr),
        .rom_cs    (rom_cs),
        .rom_ok    (rom_ok),
        .rom_data  (rom_data),
        .buf_addr  (buf_addr),
        .buf_we    (buf_we),
        .buf_din   (buf_din)
    );

    jtframe_obj_buffer #(
        .DW         (PW),
        .ALPHA      (ALPHA),
        .FLIP_OFFSET(FLIP_OFFSET)
    ) u_linebuf (
        .clk     (clk),
        .flip    (1'b0),
        .LHBL    (~hs),
        .we      (buf_we),
        .wr_data (buf_din),
        .wr_addr (aeff),
        .rd      (pxl_cen),
        .rd_addr (hdf),
        .rd_data (pxl)
    );

endmodule
