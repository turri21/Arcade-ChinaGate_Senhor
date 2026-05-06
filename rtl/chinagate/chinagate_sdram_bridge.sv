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

// chinagate_sdram_bridge — adapted 1:1 from Darius 2 sdram_bridge.sv with
// MRA layout reworked for China Gate (8-bit CPUs, 5 ROM regions).
//
// Sorgelig 4-port SDRAM controller usage:
//   Port 0: download writes + 3 gfx clients (chars/tiles/sprites) muxed RR
//   Port 1: main CPU 16-bit reads
//   Port 2: sub  CPU 16-bit reads
//   Port 3: spare (sound Z80 / OKI in future)
//
// Bank duplication: as in Darius 2, the download phase replicates each
// 16-bit word into all 4 SDRAM chip banks (sdram_addr[24:23] = bank_idx),
// so any of the 4 ports can read consistent data.
//
// MRA byte layout (matches the China Gate (US).mra file):
//   0x000000 +0x20000  main_rom      (128K, includes ROM_CONTINUE split)
//   0x020000 +0x20000  sub_rom       (128K)
//   0x040000 +0x08000  sound_rom     ( 32K, Z80, unused for now)
//   0x048000 +0x20000  chars_rom     (128K)
//   0x068000 +0x80000  sprites_rom   (512K)
//   0x0E8000 +0x40000  tiles_rom     (256K)
//
// All offsets are byte addresses; the SDRAM controller is word-addressed
// so we shift right by 1.

module chinagate_sdram_bridge (
    input             clk,
    input             reset,
    input             sdram_ready,

    // ---- Download from HPS (ioctl) ----
    input             ioctl_download,
    input             ioctl_wr,
    input  [26:0]     ioctl_addr,
    input  [ 7:0]     ioctl_dout,
    input  [15:0]     ioctl_index,
    output            ioctl_wait,

    // ---- Game gfx ports (32-bit reads). Convention used by jtframe_*:
    //      `cs` is asserted while data is needed; bridge serves a fresh
    //      32-bit word as soon as `cs` rises. We expose `valid` strobes
    //      that the prefetch buffer downstream samples. ----
    input  [16:0]     chars_byte_addr,    // 128 KB region
    input             chars_req,
    output [31:0]     chars_data,
    output reg        chars_valid,

    input  [17:0]     tiles_byte_addr,    // 256 KB region
    input             tiles_req,
    output [31:0]     tiles_data,
    output reg        tiles_valid,

    input  [18:0]     obj_byte_addr,      // 512 KB region
    input             obj_req,
    output [31:0]     obj_data,
    output reg        obj_valid,

    // ---- Main CPU read port (8-bit byte address; bridge returns 16-bit word) ----
    input  [16:0]     main_byte_addr,
    input             main_req,
    output [15:0]     main_data,
    output reg        main_ready,

    // ---- Sub CPU read port (same scheme) ----
    input  [16:0]     sub_byte_addr,
    input             sub_req,
    output [15:0]     sub_data,
    output reg        sub_ready,

    // ---- OKI ADPCM read port (256KB region @ 0x128000, 18-bit byte addr) ----
    input  [17:0]     oki_byte_addr,
    input             oki_req,
    output [15:0]     oki_data,
    output reg        oki_ready,

    // ---- SDRAM controller ports (Sorgelig 4-port toggle protocol) ----
    output reg [24:1] sdram_addr0,
    output reg [15:0] sdram_din0,
    output reg        sdram_wrl0,
    output reg        sdram_wrh0,
    output reg        sdram_req0,
    input             sdram_ack0,
    input      [15:0] sdram_dout0,

    output reg [24:1] sdram_addr1,
    output     [15:0] sdram_din1,
    output            sdram_wrl1,
    output            sdram_wrh1,
    output reg        sdram_req1,
    input             sdram_ack1,
    input      [15:0] sdram_dout1,

    output reg [24:1] sdram_addr2,
    output     [15:0] sdram_din2,
    output            sdram_wrl2,
    output            sdram_wrh2,
    output reg        sdram_req2,
    input             sdram_ack2,
    input      [15:0] sdram_dout2,

    output     [24:1] sdram_addr3,
    output     [15:0] sdram_din3,
    output            sdram_wrl3,
    output            sdram_wrh3,
    output            sdram_req3,
    input             sdram_ack3,
    input      [15:0] sdram_dout3
);

    // ----------------- read-only ports tie-offs -----------------
    assign sdram_din1 = 16'd0;
    assign sdram_wrl1 = 1'b0;
    assign sdram_wrh1 = 1'b0;
    assign sdram_din2 = 16'd0;
    assign sdram_wrl2 = 1'b0;
    assign sdram_wrh2 = 1'b0;
    assign sdram_din3 = 16'd0;
    assign sdram_wrl3 = 1'b0;
    assign sdram_wrh3 = 1'b0;

    // ----------------- region base byte offsets -----------------
    localparam [26:0] BASE_MAIN    = 27'h000000;
    localparam [26:0] BASE_SUB     = 27'h020000;
    localparam [26:0] BASE_CHARS   = 27'h048000;
    localparam [26:0] BASE_SPRITES = 27'h068000;
    localparam [26:0] BASE_TILES   = 27'h0E8000;
    localparam [26:0] BASE_OKI     = 27'h128000;

    // ==================================================================
    // PORT 0 — download writes + 3 gfx clients RR
    // ==================================================================

    // ---- Download FSM (replicates each word into 4 banks) ----
    reg  [ 7:0] dl_data_byte;
    reg [26:0]  dl_addr_save;
    reg         dl_wait_r;
    reg [ 1:0]  dl_bank_idx;
    reg         dl_toggle;

    wire dl_idle = (sdram_ack0 == dl_toggle);

    reg download_active;
    always @(posedge clk) begin
        if (reset) download_active <= 1'b0;
        else if (ioctl_download) download_active <= 1'b1;
        else if (dl_idle && !dl_wait_r) download_active <= 1'b0;
    end

    always @(posedge clk) begin
        if (reset) begin
            dl_toggle   <= 1'b0;
            dl_wait_r   <= 1'b0;
            dl_bank_idx <= 2'd0;
        end else begin
            if (~ioctl_download) dl_wait_r <= 1'b0;

            if (ioctl_download && ioctl_wr && ioctl_index == 16'd0) begin
                dl_data_byte <= ioctl_dout;
                dl_addr_save <= ioctl_addr;
                dl_wait_r    <= 1'b1;
                dl_bank_idx  <= 2'd0;
                dl_toggle    <= ~dl_toggle;
            end else if (dl_wait_r && dl_idle) begin
                if (dl_bank_idx < 2'd3) begin
                    dl_bank_idx <= dl_bank_idx + 2'd1;
                    dl_toggle   <= ~dl_toggle;
                end else begin
                    dl_wait_r <= 1'b0;
                end
            end
        end
    end

    assign ioctl_wait = dl_wait_r | (ioctl_download & ~sdram_ready);

    // ---- 3 gfx clients RR arbiter (chars / tiles / sprites) ----
    // Each fetches 2 sequential 16-bit words to assemble a 32-bit value.
    // We grant one client at a time using a 2-bit RR pointer.

    localparam [1:0] CL_CHARS = 2'd0;
    localparam [1:0] CL_TILES = 2'd1;
    localparam [1:0] CL_OBJ   = 2'd2;

    reg [1:0]  rr_cur;     // currently granted client
    reg [2:0]  fetch_state;
    reg [15:0] fetch_hi, fetch_lo;
    reg        fetch_toggle;

    localparam [2:0]
        F_IDLE    = 3'd0,
        F_REQ_HI  = 3'd1,
        F_WAIT_HI = 3'd2,
        F_REQ_LO  = 3'd3,
        F_WAIT_LO = 3'd4,
        F_DONE    = 3'd5;

    wire fetch_idle = (sdram_ack0 == fetch_toggle);

    // Track previous req-per-client (rising-edge detect)
    reg chars_req_d, tiles_req_d, obj_req_d;
    always @(posedge clk) begin
        chars_req_d <= chars_req;
        tiles_req_d <= tiles_req;
        obj_req_d   <= obj_req;
    end

    wire chars_pulse = chars_req & ~chars_req_d;
    wire tiles_pulse = tiles_req & ~tiles_req_d;
    wire obj_pulse   = obj_req   & ~obj_req_d;

    // Pending bits per client
    reg chars_pending, tiles_pending, obj_pending;
    always @(posedge clk) begin
        if (reset) begin
            chars_pending <= 0;
            tiles_pending <= 0;
            obj_pending   <= 0;
        end else begin
            if (chars_pulse) chars_pending <= 1'b1;
            if (tiles_pulse) tiles_pending <= 1'b1;
            if (obj_pulse)   obj_pending   <= 1'b1;
            if (fetch_state == F_DONE) begin
                if (rr_cur == CL_CHARS) chars_pending <= 1'b0;
                if (rr_cur == CL_TILES) tiles_pending <= 1'b0;
                if (rr_cur == CL_OBJ)   obj_pending   <= 1'b0;
            end
        end
    end

    // Round-robin grant + fetch FSM
    reg [23:0] gfx_word_addr;   // word-aligned SDRAM address (within bank 0)

    always @(posedge clk) begin
        if (reset || download_active) begin
            fetch_state  <= F_IDLE;
            chars_valid  <= 0;
            tiles_valid  <= 0;
            obj_valid    <= 0;
            fetch_toggle <= dl_toggle;
            rr_cur       <= CL_CHARS;
        end else begin
            chars_valid <= 0;
            tiles_valid <= 0;
            obj_valid   <= 0;

            case (fetch_state)
                F_IDLE: begin
                    // Pick next pending client in RR order starting from rr_cur+1
                    casez ({obj_pending, tiles_pending, chars_pending, rr_cur})
                        // Try to advance fairly: bias by current rr_cur
                        default: begin
                            // Simple fixed priority: chars > tiles > obj when starting,
                            // but rotate after each completion (rr_cur updated below).
                            if (chars_pending && rr_cur != CL_CHARS) begin
                                rr_cur <= CL_CHARS;
                                fetch_state <= F_REQ_HI;
                            end else if (tiles_pending && rr_cur != CL_TILES) begin
                                rr_cur <= CL_TILES;
                                fetch_state <= F_REQ_HI;
                            end else if (obj_pending && rr_cur != CL_OBJ) begin
                                rr_cur <= CL_OBJ;
                                fetch_state <= F_REQ_HI;
                            end else if (chars_pending) begin
                                rr_cur <= CL_CHARS;
                                fetch_state <= F_REQ_HI;
                            end else if (tiles_pending) begin
                                rr_cur <= CL_TILES;
                                fetch_state <= F_REQ_HI;
                            end else if (obj_pending) begin
                                rr_cur <= CL_OBJ;
                                fetch_state <= F_REQ_HI;
                            end
                        end
                    endcase
                end

                F_REQ_HI: begin
                    if (fetch_idle) begin
                        fetch_toggle <= ~fetch_toggle;
                        fetch_state  <= F_WAIT_HI;
                    end
                end
                F_WAIT_HI: begin
                    if (fetch_idle) begin
                        fetch_hi    <= sdram_dout0;
                        fetch_state <= F_REQ_LO;
                    end
                end
                F_REQ_LO: begin
                    if (fetch_idle) begin
                        fetch_toggle <= ~fetch_toggle;
                        fetch_state  <= F_WAIT_LO;
                    end
                end
                F_WAIT_LO: begin
                    if (fetch_idle) begin
                        fetch_lo <= sdram_dout0;
                        case (rr_cur)
                            CL_CHARS: chars_valid <= 1'b1;
                            CL_TILES: tiles_valid <= 1'b1;
                            CL_OBJ:   obj_valid   <= 1'b1;
                            default:;
                        endcase
                        fetch_state <= F_DONE;
                    end
                end
                F_DONE: begin
                    fetch_state <= F_IDLE;
                end
                default: fetch_state <= F_IDLE;
            endcase
        end
    end

    // Output assembly: { hi_word, lo_word } as in Darius 2 (word-swap at concat)
    assign chars_data = {fetch_lo, fetch_hi};
    assign tiles_data = {fetch_lo, fetch_hi};
    assign obj_data   = {fetch_lo, fetch_hi};

    // Compute base byte address for the current granted client
    reg [26:0] cur_byte_base;
    reg [26:0] cur_byte_addr;
    always @* begin
        case (rr_cur)
            CL_CHARS: begin
                cur_byte_base = BASE_CHARS;
                cur_byte_addr = cur_byte_base + {10'd0, chars_byte_addr};
            end
            CL_TILES: begin
                cur_byte_base = BASE_TILES;
                cur_byte_addr = cur_byte_base + {9'd0, tiles_byte_addr};
            end
            CL_OBJ: begin
                cur_byte_base = BASE_SPRITES;
                cur_byte_addr = cur_byte_base + {8'd0, obj_byte_addr};
            end
            default: begin
                cur_byte_base = BASE_CHARS;
                cur_byte_addr = BASE_CHARS;
            end
        endcase
    end

    // For 32-bit fetch, REQ_HI uses base addr, REQ_LO uses base addr +2 bytes.
    wire [23:1] gfx_word_hi = cur_byte_addr[23:1];
    wire [23:1] gfx_word_lo = cur_byte_addr[23:1] + 23'd1;

    // ---- Port 0 mux ----
    always @* begin
        if (download_active) begin
            sdram_addr0 = {dl_bank_idx, dl_addr_save[22:1]};
            // Replicate byte to both lanes; use byte enable per addr[0]
            sdram_din0  = {dl_data_byte, dl_data_byte};
            sdram_wrl0  = ~dl_addr_save[0];
            sdram_wrh0  =  dl_addr_save[0];
            sdram_req0  = dl_toggle;
        end else begin
            case (fetch_state)
                F_REQ_HI, F_WAIT_HI: sdram_addr0 = {1'b0, gfx_word_hi};
                F_REQ_LO, F_WAIT_LO: sdram_addr0 = {1'b0, gfx_word_lo};
                default:              sdram_addr0 = 24'd0;
            endcase
            sdram_din0 = 16'd0;
            sdram_wrl0 = 1'b0;
            sdram_wrh0 = 1'b0;
            sdram_req0 = fetch_toggle;
        end
    end

    // ==================================================================
    // PORT 1 — Main CPU reads
    // ==================================================================
    reg        main_pending;
    reg [15:0] main_data_reg;
    reg        main_req_d;

    always @(posedge clk) begin
        if (reset) begin
            sdram_req1   <= 0;
            main_pending <= 0;
            main_ready   <= 0;
            main_req_d   <= 0;
            main_data_reg<= 0;
        end else begin
            main_ready <= 0;
            main_req_d <= main_req;

            if (main_req && !main_req_d && !main_pending) begin
                sdram_req1   <= ~sdram_req1;
                main_pending <= 1'b1;
            end
            if (main_pending && (sdram_ack1 == sdram_req1)) begin
                main_data_reg <= sdram_dout1;
                main_ready    <= 1'b1;
                main_pending  <= 1'b0;
            end
        end
    end

    assign main_data = main_data_reg;

    always @* begin
        // bank 1 for main CPU
        // word offset within bank = (BASE_MAIN + main_byte_addr) / 2
        sdram_addr1 = {2'b01, (BASE_MAIN[22:1] + {6'd0, main_byte_addr[16:1]})};
    end

    // ==================================================================
    // PORT 2 — Sub CPU reads
    // ==================================================================
    reg        sub_pending;
    reg [15:0] sub_data_reg;
    reg        sub_req_d;

    always @(posedge clk) begin
        if (reset) begin
            sdram_req2  <= 0;
            sub_pending <= 0;
            sub_ready   <= 0;
            sub_req_d   <= 0;
            sub_data_reg<= 0;
        end else begin
            sub_ready <= 0;
            sub_req_d <= sub_req;

            if (sub_req && !sub_req_d && !sub_pending) begin
                sdram_req2  <= ~sdram_req2;
                sub_pending <= 1'b1;
            end
            if (sub_pending && (sdram_ack2 == sdram_req2)) begin
                sub_data_reg <= sdram_dout2;
                sub_ready    <= 1'b1;
                sub_pending  <= 1'b0;
            end
        end
    end

    assign sub_data = sub_data_reg;

    always @* begin
        sdram_addr2 = {2'b10, (BASE_SUB[22:1] + {6'd0, sub_byte_addr[16:1]})};
    end

    // ==================================================================
    // PORT 3 — OKI ADPCM reads (256KB region @ BASE_OKI)
    // ==================================================================
    reg        oki_pending;
    reg [15:0] oki_data_reg;
    reg        oki_req_d;

    always @(posedge clk) begin
        if (reset) begin
            sdram_req3  <= 0;
            oki_pending <= 0;
            oki_ready   <= 0;
            oki_req_d   <= 0;
            oki_data_reg<= 0;
        end else begin
            oki_ready <= 0;
            oki_req_d <= oki_req;

            if (oki_req && !oki_req_d && !oki_pending) begin
                sdram_req3  <= ~sdram_req3;
                oki_pending <= 1'b1;
            end
            if (oki_pending && (sdram_ack3 == sdram_req3)) begin
                oki_data_reg <= sdram_dout3;
                oki_ready    <= 1'b1;
                oki_pending  <= 1'b0;
            end
        end
    end

    assign oki_data = oki_data_reg;

    always @* begin
        // bank 3 per OKI
        // word offset within bank = (BASE_OKI + oki_byte_addr) / 2
        sdram_addr3 = {2'b11, (BASE_OKI[22:1] + {5'd0, oki_byte_addr[17:1]})};
    end

endmodule
