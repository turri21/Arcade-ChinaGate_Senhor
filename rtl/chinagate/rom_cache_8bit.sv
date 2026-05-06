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

// rom_cache_8bit — Direct-mapped instruction cache for an 8-bit CPU.
// Adapted from rom_cache.sv (Darius 2 / Umberto Parisi). The Darius
// version is 16-bit because it serves a 68000; here the CPU is 6809 (8-bit
// data bus) but we still load 16-bit words from SDRAM (since the SDRAM bus
// is 16-bit wide). The cache stores 16-bit words and we select the right
// byte based on cpu_addr[0] before returning it.
//
// 256 entries × 16-bit data ≈ 4 Kbit ≈ 1 M10K per cache.
//
// Protocol toward CPU side (chinagate_top expects the OLD bram-style flat
// interface: addr in -> data out 1-cycle later):
//   - CPU drives `cpu_addr` continuously; we sample it on every clock.
//   - We assert `bus_busy` when the cache is filling from SDRAM.
//   - When `bus_busy` is high, the CPU's cen_E is gated -> CPU effectively
//     halts. When low, the CPU runs at full speed and `cpu_data` returns
//     the byte for `cpu_addr` of the previous cycle (1-cycle latency).

module rom_cache_8bit #(
    parameter CACHE_BITS = 8,        // 2^8 = 256 entries
    parameter CPU_AW     = 17        // CPU address width (e.g. 17 for 128KB)
)(
    input  wire              clk,
    input  wire              reset,

    // ---- CPU side (flat addr/data) ----
    input  wire [CPU_AW-1:0] cpu_addr,
    input  wire              cpu_oe,        // high when CPU is reading this region
    output reg  [ 7:0]       cpu_data,
    output reg               bus_busy,

    // ---- SDRAM side (toggle req/ack via bridge) ----
    output reg  [CPU_AW-1:0] sdram_byte_addr,
    output reg               sdram_req,
    input  wire [15:0]       sdram_data,
    input  wire              sdram_ready
);

    localparam ENTRIES  = 1 << CACHE_BITS;
    // Each cache line holds a 16-bit word (covers 2 byte addresses).
    // word_addr = cpu_addr[CPU_AW-1:1]
    // index     = word_addr[CACHE_BITS-1:0]
    // tag       = word_addr[CPU_AW-2:CACHE_BITS]
    localparam WORD_AW   = CPU_AW - 1;
    localparam TAG_BITS  = WORD_AW - CACHE_BITS;

    (* ramstyle = "M10K,no_rw_check" *) reg [15:0]         cache_data [0:ENTRIES-1];
    (* ramstyle = "M10K,no_rw_check" *) reg [TAG_BITS-1:0] cache_tag  [0:ENTRIES-1];
    reg [ENTRIES-1:0] cache_valid;

    wire [WORD_AW-1:0]    word_addr = cpu_addr[CPU_AW-1:1];
    wire [CACHE_BITS-1:0] idx       = word_addr[CACHE_BITS-1:0];
    wire [TAG_BITS-1:0]   tag       = word_addr[WORD_AW-1:CACHE_BITS];
    wire                  byte_sel  = cpu_addr[0];

    // Registered cache read on the current cpu_addr (1-cycle BRAM latency)
    reg [15:0]         rd_data;
    reg [TAG_BITS-1:0] rd_tag;
    reg                rd_valid;
    reg [CACHE_BITS-1:0] rd_idx;
    reg                rd_byte_sel;

    always @(posedge clk) begin
        rd_data     <= cache_data[idx];
        rd_tag      <= cache_tag [idx];
        rd_valid    <= cache_valid[idx];
        rd_idx      <= idx;
        rd_byte_sel <= byte_sel;
    end

    // FSM
    localparam S_IDLE       = 2'd0;
    localparam S_FETCH      = 2'd1;
    localparam S_REFRESH_RD = 2'd2;   // 1-cycle dwell so BRAM rd_* sees the fresh fill

    reg [1:0]              state;
    reg [TAG_BITS-1:0]     pending_tag;
    reg [CACHE_BITS-1:0]   pending_idx;
    reg [WORD_AW-1:0]      pending_word_addr;
    reg                    pending_byte_sel;

    wire hit_now = rd_valid && (rd_tag == tag) && (rd_idx == idx);

    always @(posedge clk) begin
        if (reset) begin
            state       <= S_IDLE;
            cache_valid <= {ENTRIES{1'b0}};
            sdram_req   <= 1'b0;
            bus_busy    <= 1'b0;
            cpu_data    <= 8'h00;
        end else begin
            case (state)
                S_IDLE: begin
                    if (cpu_oe) begin
                        if (hit_now) begin
                            // Cache hit on the address registered last cycle.
                            cpu_data <= rd_byte_sel ? rd_data[15:8] : rd_data[7:0];
                            bus_busy <= 1'b0;
                        end else begin
                            // Miss: stall the CPU and start a fetch.
                            // Bridge expects a rising edge on req (level-sensitive
                            // pulse): drive req high until ready arrives, then drop.
                            pending_tag       <= tag;
                            pending_idx       <= idx;
                            pending_word_addr <= word_addr;
                            pending_byte_sel  <= byte_sel;
                            sdram_byte_addr   <= {word_addr, 1'b0};
                            sdram_req         <= 1'b1;
                            bus_busy          <= 1'b1;
                            state             <= S_FETCH;
                        end
                    end else begin
                        bus_busy <= 1'b0;
                    end
                end

                S_FETCH: begin
                    if (sdram_ready) begin
                        cache_data [pending_idx] <= sdram_data;
                        cache_tag  [pending_idx] <= pending_tag;
                        cache_valid[pending_idx] <= 1'b1;
                        cpu_data  <= pending_byte_sel ? sdram_data[15:8] : sdram_data[7:0];
                        sdram_req <= 1'b0;
                        // Stay busy 1 more cycle so the registered BRAM read
                        // (`rd_data`/`rd_tag`/`rd_valid`) catches up with the
                        // freshly-filled cache line before the next S_IDLE
                        // hit check.
                        state     <= S_REFRESH_RD;
                    end
                end

                S_REFRESH_RD: begin
                    bus_busy <= 1'b0;
                    state    <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
