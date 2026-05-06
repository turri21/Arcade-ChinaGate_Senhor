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

// jtcg_draw — Sprite tile-row drawer custom per China Gate.
//
// Sostituisce jtframe_draw. Disegna 16 pixel di una riga di tile 16x16 4bpp
// applicando il MAME chinagat tilelayout direttamente:
//   per ogni X-quad q (0..3): fetch 1 word 16-bit da SDRAM @ word_addr =
//                              T*64 + q*16 + y
//     byte_lo = SDRAM[2*word_addr]      (j7/j8: planes 2,3)
//     byte_hi = SDRAM[2*word_addr + 1]  (j9/ja: planes 0,1)
//   per pixel x in 0..3:
//     bit_pos = 3 - (x % 4) se hflip=0 else (x % 4)   (xrev_perm_3210)
//     p0 = byte_hi[bit_pos + 4]
//     p1 = byte_hi[bit_pos]
//     p2 = byte_lo[bit_pos + 4]
//     p3 = byte_lo[bit_pos]
//     pen = {p3, p2, p1, p0}
//
// Verificato 100% match MAME via _dev/scripts/tile_viewer.py
// (decoder xrev_perm_3210 + MRA US).
//
// Interfaccia compatibile con jtframe_obj_buffer (= line buffer).

module jtcg_draw #(
    parameter CW = 12,    // code width
    parameter PW = 8      // pixel width (4 pal + 4 pen)
)(
    input               rst,
    input               clk,

    input               draw,
    output reg          busy,
    input    [CW-1:0]   code,
    input      [ 8:0]   xpos,
    input      [ 3:0]   ysub,

    input               hflip,
    input               vflip,
    input    [PW-5:0]   pal,

    // ROM access: rom_addr = SDRAM word index (= byte_addr / 2).
    // 18 bit = [18:1] del byte_addr (bit[0]=0 per allineamento word).
    // Il prefetch_buf espone {rom_addr, 1'b0} = byte_addr 19 bit al bridge.
    // Bridge fetcha 32 bit (= 2 word SDRAM consecutive); drawer usa solo
    // i 16 bit bassi = word richiesto.
    output reg [CW+6:1] rom_addr,
    output reg          rom_cs,
    input               rom_ok,
    input      [31:0]   rom_data,   // bridge fornisce 32 bit; useremo solo [15:0]

    output reg [ 8:0]   buf_addr,
    output              buf_we,
    output     [PW-1:0] buf_din
);

    // 4 X-quad per riga, ognuna 4 pixel.
    // FSM: per ogni X-quad fa fetch + estrai 4 pixel in 4 cicli scrittura.
    //
    // States:
    //   IDLE      → wait for draw=1
    //   FETCH     → emit rom_addr, wait rom_ok
    //   WRITE     → 4 cicli, 1 pixel/ciclo in line buffer
    //   NEXT      → q++ se q<3 → FETCH, else IDLE

    reg [2:0] state;
    localparam S_IDLE     = 3'd0;
    localparam S_FETCH_REQ = 3'd1;
    localparam S_FETCH_WAIT = 3'd2;
    localparam S_WRITE    = 3'd3;
    localparam S_NEXT     = 3'd4;

    reg [1:0]   q;          // X-quad index 0..3
    reg [1:0]   px_in_q;    // pixel within X-quad 0..3
    reg [15:0]  fetched;    // dati word fetched
    reg         dr_hflip, dr_vflip;
    reg [PW-5:0] dr_pal;
    reg [CW-1:0] dr_code;
    reg [ 8:0]   dr_xpos;
    reg [ 3:0]   dr_ysub;

    wire [3:0] ysubf = dr_ysub ^ {4{dr_vflip}};

    // word_addr SDRAM = code*64 + q*16 + ysubf
    // byte_addr = 2 * word_addr (bit [0] = 0, allineamento word 16-bit).
    // Per code (CW=12 bit), max word_addr = 4096*64-1 = 0x3FFFF = 18 bit.
    // byte_addr_full = 19 bit. rom_addr port [CW+6:1] = [18:1] = word index.
    wire [17:0] word_addr = {dr_code, q, ysubf};   // 12+2+4 = 18 bit
    wire [18:0] byte_addr_full = {word_addr, 1'b0};   // 19 bit

    always @* begin
        rom_addr = byte_addr_full[CW+6:1];   // 18 bit = byte_addr[18:1] = word index
    end

    // pixel decoding — 4 pixel per fetch
    wire [7:0] byte_lo = fetched[ 7:0];   // planes 2,3
    wire [7:0] byte_hi = fetched[15:8];   // planes 0,1

    // bit_pos dentro la X-quad (4 pixel)
    // xrev_perm_3210 verificato: bit_pos = px_in_q (NO inversione, NO hflip-mod)
    // hflip è applicato al level X-quad order (q in S_IDLE).
    wire [2:0] bit_pos = {1'b0, px_in_q};   // 0..3

    // perm 0123 (verificato tool tile_viewer su sprite reale code 0x08b6
    // color 1 vs MAME ground truth):
    //   p0 = byte_lo[bit_pos]
    //   p1 = byte_lo[bit_pos + 4]
    //   p2 = byte_hi[bit_pos]
    //   p3 = byte_hi[bit_pos + 4]
    wire p0 = byte_lo[bit_pos];
    wire p1 = byte_lo[bit_pos + 4];
    wire p2 = byte_hi[bit_pos];
    wire p3 = byte_hi[bit_pos + 4];
    wire [3:0] pxl = {p3, p2, p1, p0};

    assign buf_din = {dr_pal, pxl};
    assign buf_we  = (state == S_WRITE);

    always @(posedge clk, posedge rst) begin
        if (rst) begin
            state    <= S_IDLE;
            busy     <= 0;
            rom_cs   <= 0;
            q        <= 0;
            px_in_q  <= 0;
            fetched  <= 0;
            buf_addr <= 0;
            dr_hflip <= 0;
            dr_vflip <= 0;
            dr_pal   <= 0;
            dr_code  <= 0;
            dr_xpos  <= 0;
            dr_ysub  <= 0;
        end else begin
            case (state)
                S_IDLE: begin
                    rom_cs <= 0;
                    if (draw) begin
                        // latch inputs (LATCH=1 style)
                        dr_code  <= code;
                        dr_xpos  <= xpos;
                        dr_ysub  <= ysub;
                        dr_hflip <= hflip;
                        dr_vflip <= vflip;
                        dr_pal   <= pal;
                        // start: hflip determina ordine X-quad
                        // hflip=0: q goes 0,1,2,3 (left→right)
                        // hflip=1: q goes 3,2,1,0 (right→left)
                        q        <= hflip ? 2'd3 : 2'd0;
                        px_in_q  <= hflip ? 2'd3 : 2'd0;
                        buf_addr <= xpos;
                        busy     <= 1;
                        state    <= S_FETCH_REQ;
                    end
                end
                S_FETCH_REQ: begin
                    // primo ciclo: assert rom_cs, prefetch_buf vede miss e
                    // alza fetch_busy (rd_ok va basso al ciclo successivo)
                    rom_cs <= 1;
                    state  <= S_FETCH_WAIT;
                end
                S_FETCH_WAIT: begin
                    // aspetta che il fetch completi (rom_ok=1 dopo che cache
                    // ha ricevuto sd_valid e ha messo fetch_busy=0)
                    if (rom_ok) begin
                        fetched <= rom_data[15:0];
                        rom_cs  <= 0;
                        state   <= S_WRITE;
                    end
                end
                S_WRITE: begin
                    // scrivi 1 pixel, incrementa buf_addr e px_in_q
                    // Con hflip: px_in_q va 3→2→1→0 (decrementing), poi prossimo X-quad parte da 3
                    // Senza hflip: px_in_q va 0→1→2→3 (incrementing), prossimo X-quad parte da 0
                    buf_addr <= buf_addr + 9'd1;
                    if ((!dr_hflip && px_in_q == 2'd3) || (dr_hflip && px_in_q == 2'd0)) begin
                        // ultima della X-quad
                        if (q == 2'd3 && !dr_hflip) begin
                            // ultima riga (left→right)
                            busy  <= 0;
                            state <= S_IDLE;
                        end else if (q == 2'd0 && dr_hflip) begin
                            // ultima riga (right→left)
                            busy  <= 0;
                            state <= S_IDLE;
                        end else begin
                            q       <= dr_hflip ? (q - 1'd1) : (q + 1'd1);
                            px_in_q <= dr_hflip ? 2'd3 : 2'd0;
                            state   <= S_FETCH_REQ;
                        end
                    end else begin
                        px_in_q <= dr_hflip ? (px_in_q - 1'd1) : (px_in_q + 1'd1);
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
