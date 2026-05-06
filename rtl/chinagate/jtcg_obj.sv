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

// China Gate FPGA core - sprite engine.
//
// Direct adaptation of jtdd_obj.v (Jose Tejada / jotego, GPL-3) with the
// LAYOUT=DD branch fixed in (since China Gate's sprite layout matches the
// Double Dragon scheme: 5 bytes per sprite, attr1.bit7=enable, bit4=sizeL,
// bit2=yflip, bit3=xflip, bit0=Y_MSB, bit1=X_MSB, attr2[7:4]=color,
// attr2[3:0]=code high nibble).
//
// References:
//   - ddragon_v.cpp::draw_sprites() in mame_ref/
//   - jtdd_obj.v in jtdd_ref/
//   - crossref_chinagate.md §6
//
// Limitations of this first cut:
//   - 16x16 and 16x32 sprites only (size=0/1). 32x16/32x32 (size=2/3) are
//     drawn as plain 16x16 — refinement needed if china gate uses them.
//   - China Gate "sprite clip" wrap-around for negative coords [-15,-8] is
//     not implemented yet; jtframe_objdraw's natural wrap handles -15..0
//     and 256..271 differently from MAME.

module jtcg_obj #(parameter
    OW    = 19,         // sprite ROM address width (byte-level), 512KB -> 19
    // -- do not assign below --
    IDW   = OW - 15
)(
    input              clk,
    input              rst,
    input              pxl_cen,
    // screen
    input      [ 8:0]  hdump,
    input      [ 7:0]  VPOS,
    input              flip,
    input              HBL,
    input              hs,
    input signed [9:0] osd_xoff,
    input signed [9:0] osd_yoff,
    // RAM (sprite OAM, 384 byte = 76 sprites x 5 byte, padded to 512)
    output     [ 8:0]  oram_addr,
    input      [ 7:0]  oram_data,
    // ROM access
    output   [OW-1:1]  rom_addr,
    output             rom_cs,
    input      [31:0]  rom_data,
    input              rom_ok,
    // pixel out (8-bit: pal[3:0] + pix[3:0])
    output     [ 7:0]  pxl
);

    // bit positions inside attr1 (byte 1 of OAM entry) -- DD-style
    // attr1 = src[i+1]:
    //   bit 7   = E (enable / visible)
    //   bit 6,7 = flipy(2), flipx(3) — actually bit 2,3
    //   bit 5,4 = size [5:4]: 0=16x16, 1=16x32, 2=32x16, 3=32x32
    //   bit 1   = X MSB
    //   bit 0   = Y MSB
    localparam E = 7;  // enable
    localparam Y = 0;  // Y MSB
    localparam SY = 4; // size Y (large vertical) — 16x32 when set
    localparam SX = 5; // size X (large horizontal) — 32xN when set

    // visible-area shift between OAM coordinate and screen
    // HOFFSET: hdump del vtimer parte da H=HB_END=4 al primo pixel visibile
    // Per allineare sx_mame (= 240-byte4, coord 0..255 dello schermo) col
    // linebuffer indicizzato da hdump, sommiamo 4 (= xpos + 4 per il drawer).
    // Realizzato come HOFFSET signed (drawer riceve xpos - HOFFSET).
    localparam signed [8:0] HOFFSET = -9'sd4;

    // ------------------------------------------------------------------
    // OAM scan state machine
    // ------------------------------------------------------------------
    reg  [ 8:0] scan;
    reg  [ 2:0] offset;
    reg  [ 4:0] maxline;
    wire [ 8:0] next_scan = scan + 9'd5;
    // ChinaGate OAM: 76 entries × 5 byte = 380 byte (in $3800-$397F = 384 byte).
    // Scansionare oltre l'ultima entry valida significa leggere OAM padding o
    // memoria adiacente → sprite fantasma. Stop a entry 75 (next_scan == 380).
    wire        scan_done = next_scan == 9'd380;

    reg         HBL_l, wait_mem;
    wire        negedge_HBL = !HBL && HBL_l;

    wire [31:0] sorted;
    wire [ 3:0] pal;
    reg  [ 7:0] ypos, scan_attr, scan_attr2, id;
    reg  [ 8:0] xpos;
    reg         x_msb;            // X_MSB latchato in stato 2, applicato in stato 5
    wire [ 8:0] sumy = {1'b0, VPOS} + {1'b0, ypos} + osd_yoff[8:0];
    // inzone copre 16 righe (size_y=0) o 32 righe (size_y=1).
    // Per 32 righe sumy[4] può essere 0 o 1; per 16 righe deve essere 1.
    wire        inzone = &{sumy[7:5], ~(oram_data[Y]^sumy[8]), sumy[4]|oram_data[SY]};

    reg [2:0] st;
    wire      dr_busy;
    reg       line, draw;
    reg       half_x;          // 0 = primo tile orizzontale, 1 = secondo (per size_x=1)
    reg [7:0] draw_id;          // code del tile da disegnare (dopo mask + offset)
    reg [8:0] draw_xpos;        // xpos del tile da disegnare

    wire           hflip, vflip;
    wire [IDW-1:0] id_msb;

    // sorted swizzle non più usato — drawer custom jtcg_objdraw legge
    // direttamente rom_data ed estrae i pixel con xrev_perm_3210.
    assign sorted = rom_data;   // placeholder (unused dal drawer custom)

    // MAME draw_sprites: flipx = attr & 8 (= bit 3), flipy = attr & 4 (= bit 2).
    // NON negato.
    assign hflip  =  scan_attr[3];
    assign vflip  =  scan_attr[2];
    assign id_msb =  scan_attr2[0 +: IDW];
    assign pal    =  scan_attr2[7:4];

    assign oram_addr = scan + {5'd0, offset};

    // mask del code in funzione di size (MAME draw_sprites: which &= ~size).
    // size = {SX, SY} in 2 bit.
    //   size=0 (16x16): mask=00, no clear
    //   size=1 (16x32): mask=01, clear id[0]
    //   size=2 (32x16): mask=10, clear id[1]
    //   size=3 (32x32): mask=11, clear id[1:0]
    wire [1:0] sprite_size  = {scan_attr[SX], scan_attr[SY]};
    wire [7:0] id_mask      = {6'b111111, ~sprite_size};
    wire [7:0] id_masked    = id & id_mask;
    // selector tile interno al metatile:
    //   bit 0 = top/bottom (sumy[4] inverso, top=0 bottom=1)
    //     MAME: size=1: top=which+0, bottom=which+1 → tile_y = ~ypos[4] in nostre coord
    //     RTL ChinaGate aveva: id[0] <= id[0] ^ ypos[4] → equivalente
    //   bit 1 = left/right (half_x: left=0, right=1)
    //     MAME: size=2: left=which+0, right=which+2
    //           size=3: top-left=which+0, bottom-left=which+1, top-right=which+2, bottom-right=which+3
    wire       sel_y    = scan_attr[SY] & ypos[4];   // ypos[4]=1 -> bottom (which+1)
    wire       sel_x    = scan_attr[SX] & half_x;    // half_x=1 -> right (+2)
    wire [7:0] tile_id  = id_masked | {6'b0, sel_x, sel_y};

    // xpos: il tile sinistro è a xpos+dx (= xpos-16 con dx=-16, MAME),
    // il tile destro a xpos. Cioè:
    //   half_x=0 (left): xpos_draw = xpos - 16 (MAME: sx + dx)
    //   half_x=1 (right): xpos_draw = xpos      (MAME: sx)
    // Per size_x=0 c'è solo half_x=0 ma con xpos_draw = xpos (non shift).
    wire [8:0] xpos_left  = xpos - 9'd16;
    wire [8:0] xpos_now   = scan_attr[SX] ? (half_x ? xpos : xpos_left) : xpos;

    always @(posedge clk, posedge rst) begin
        if (rst) begin
            HBL_l   <= 1'b0;
            scan    <= 9'd0;
            offset  <= 3'd0;
            line    <= 1'b1;
            st      <= 3'd0;
            maxline <= 5'd0;
            wait_mem<= 1'b0;
            ypos    <= 8'd0;
            xpos    <= 9'd0;
            x_msb   <= 1'b0;
            id      <= 8'd0;
            scan_attr  <= 8'd0;
            scan_attr2 <= 8'd0;
            half_x  <= 1'b0;
            draw_id    <= 8'd0;
            draw_xpos  <= 9'd0;
        end else begin
            HBL_l <= HBL;
            draw  <= 1'b0;
            case (st)
                3'd0: if (negedge_HBL) begin
                    st       <= st + 3'd1;
                    line     <= ~line;
                    scan     <= 9'd0;
                    offset   <= 3'd0;
                    wait_mem <= 1'b1;
                    maxline  <= 5'd0;
                end
                3'd1: begin
                    wait_mem <= 1'b0;
                    if (!wait_mem) begin
                        ypos     <= oram_data;
                        offset   <= 3'd1;
                        wait_mem <= 1'b1;
                        st       <= st + 3'd1;
                    end
                end
                3'd2: begin
                    wait_mem <= 1'b0;
                    if (!wait_mem) begin
                        scan_attr <= oram_data;
                        x_msb     <= oram_data[1];
                        if (!inzone || !oram_data[E]) begin
                            if (!scan_done) begin
                                st       <= 3'd1;
                                offset   <= 3'd0;
                                scan     <= next_scan;
                                wait_mem <= 1'b1;
                            end else begin
                                st <= 3'd0;
                            end
                        end else begin
                            ypos   <= sumy[7:0];
                            offset <= 3'd3;
                            st     <= 3'd3;
                        end
                    end else begin
                        offset <= 3'd2;
                    end
                end
                3'd3: begin
                    offset     <= 3'd4;
                    scan_attr2 <= oram_data;
                    st         <= 3'd4;
                end
                3'd4: begin
                    id <= oram_data;
                    st <= 3'd5;
                end
                3'd5: begin
                    // MAME chinagat (ddragon_v.cpp:152-153):
                    //   sx = 240 - byte4 + (X_MSB << 8)
                    //   if (sx in [-15,-8]) sx += 256;     // wrap MAME chinagat-specific
                    // Sottrazione 9-bit completa con borrow corretto.
                    // Range wrap MAME: -15..-8 = 9'd497..9'd504 unsigned.
                    begin : xpos_calc
                        logic [8:0] xpos_raw;
                        xpos_raw = 9'd240 - {1'b0, oram_data} + {x_msb, 8'd0};
                        if (xpos_raw >= 9'd497 && xpos_raw <= 9'd504)
                            xpos <= xpos_raw + 9'd256;   // wrap a destra (MAME chinagat clip fix)
                        else
                            xpos <= xpos_raw;
                    end
                    half_x    <= 1'b0;
                    st        <= 3'd6;
                end
                3'd6: begin
                    if (!dr_busy) begin
                        // latch i parametri del tile da disegnare
                        draw_id   <= tile_id;
                        draw_xpos <= xpos_now;
                        draw      <= 1'b1;
                        if (scan_attr[SX] && !half_x) begin
                            // size_x=1: dobbiamo disegnare anche il right tile
                            half_x <= 1'b1;
                            st     <= 3'd6;   // re-enter stato 6 per secondo draw
                        end else begin
                            // fine OAM entry: passa al successivo
                            if (!scan_done & ~&maxline) begin
                                st       <= 3'd1;
                                offset   <= 3'd0;
                                scan     <= next_scan;
                                wait_mem <= 1'b1;
                                maxline  <= maxline + 5'd1;
                            end else begin
                                st <= 3'd0;
                            end
                        end
                    end
                end
                default: st <= 3'd0;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // jtcg_objdraw — drawer custom China Gate (xrev_perm_3210).
    // CW = OW-7 = 12, PW = 8, HJUMP = 1 (Technos hdump split).
    // ------------------------------------------------------------------
    jtcg_objdraw #(
        .CW    (OW-7),
        .PW    (8),
        .HJUMP (1),
        .LATCH (1),
        .SWAPH (0)
    ) u_draw (
        .rst      (rst),
        .clk      (clk),
        .pxl_cen  (pxl_cen),
        .hs       (hs),
        .flip     (flip),
        .hdump    (hdump),

        .draw     (draw),
        .busy     (dr_busy),
        .code     ({id_msb, draw_id}),
        .xpos     (draw_xpos - HOFFSET + osd_xoff[8:0]),
        .ysub     (ypos[3:0]),

        .hflip    (hflip),
        .vflip    (vflip),
        .pal      (pal),

        .rom_addr (rom_addr),
        .rom_cs   (rom_cs),
        .rom_ok   (rom_ok),
        .rom_data (rom_data),

        .pxl      (pxl)
    );

endmodule
