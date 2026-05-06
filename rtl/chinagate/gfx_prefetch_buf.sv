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

// gfx_prefetch_buf — Direct-mapped prefetch cache between a JTFRAME-style
// renderer (which expects rom_data ALWAYS VALID at every clock when rom_cs
// is asserted) and the SDRAM bridge (which has variable latency).
//
// Behavior:
//   - 16-entry direct-mapped cache, 32-bit lines.
//   - On every cycle, if `rom_cs` is high, we look up rom_addr in the cache.
//     - HIT  -> rom_data driven from the cache (1-cycle BRAM latency).
//     - MISS -> rom_data shows the previous valid line (stale, but the
//               renderer may produce a wrong pixel for this cycle), AND
//               we issue a fetch to SDRAM. When the fetch completes, the
//               cache line is filled and subsequent accesses to the same
//               line will hit.
//
// This is NOT cycle-accurate. Pixels produced during a miss can be wrong.
// Acceptable for the first SDRAM-based build; a proper prefetch (run from
// HBL) is a future improvement.

module gfx_prefetch_buf #(
    parameter ADDR_W = 17       // bytes addressed by the renderer
)(
    input  wire             clk,
    input  wire             reset,

    // ---- renderer side (JTFRAME convention: rom_ok ignored) ----
    input  wire [ADDR_W-1:0] rd_addr,    // word address (from renderer)
    input  wire              rd_cs,
    output reg  [31:0]       rd_data,
    output wire              rd_ok,      // not used by JTFRAME but exposed

    // ---- SDRAM bridge side (request/valid handshake) ----
    output reg  [ADDR_W-1:0] sd_addr,
    output reg               sd_req,
    input  wire [31:0]       sd_data,
    input  wire              sd_valid
);

    localparam IDX_BITS = 4;             // 16 entries
    localparam ENTRIES  = 1 << IDX_BITS;
    localparam TAG_BITS = ADDR_W - IDX_BITS;

    (* ramstyle = "M10K,no_rw_check" *) reg [31:0]         line_data [0:ENTRIES-1];
    (* ramstyle = "M10K,no_rw_check" *) reg [TAG_BITS-1:0] line_tag  [0:ENTRIES-1];
    reg [ENTRIES-1:0] line_valid;

    wire [IDX_BITS-1:0] idx = rd_addr[IDX_BITS-1:0];
    wire [TAG_BITS-1:0] tag = rd_addr[ADDR_W-1:IDX_BITS];

    reg [31:0]         rd_lat_data;
    reg [TAG_BITS-1:0] rd_lat_tag;
    reg                rd_lat_valid;
    reg [IDX_BITS-1:0] rd_lat_idx;
    reg [ADDR_W-1:0]   rd_lat_addr;

    // tag/idx pipelinati di 1 ck per allineare al rd_lat_* della BRAM read.
    // Spezza il path critico rd_addr->tag/idx_combinatori->confronto in 1 ck.
    reg [TAG_BITS-1:0] tag_d;
    reg [IDX_BITS-1:0] idx_d;

    always @(posedge clk) begin
        rd_lat_data  <= line_data[idx];
        rd_lat_tag   <= line_tag[idx];
        rd_lat_valid <= line_valid[idx];
        rd_lat_idx   <= idx;
        rd_lat_addr  <= rd_addr;
        tag_d        <= tag;
        idx_d        <= idx;
    end

    wire hit = rd_lat_valid && (rd_lat_tag == tag_d) && (rd_lat_idx == idx_d);

    // ---- Fetch FSM ----
    reg fetch_busy;
    reg [TAG_BITS-1:0]   fetch_tag;
    reg [IDX_BITS-1:0]   fetch_idx;

    always @(posedge clk) begin
        if (reset) begin
            line_valid <= {ENTRIES{1'b0}};
            sd_req     <= 1'b0;
            fetch_busy <= 1'b0;
            rd_data    <= 32'h0;
        end else begin
            if (rd_cs && hit) begin
                rd_data <= rd_lat_data;
            end
            // On a miss, fire a single fetch (if not already busy)
            // Bridge expects a rising edge on sd_req: drive high until valid,
            // then drop so the next miss can be detected.
            if (rd_cs && !hit && !fetch_busy) begin
                sd_addr    <= rd_addr;
                sd_req     <= 1'b1;
                fetch_busy <= 1'b1;
                fetch_tag  <= rd_addr[ADDR_W-1:IDX_BITS];
                fetch_idx  <= idx;
            end
            if (sd_valid && fetch_busy) begin
                line_data [fetch_idx] <= sd_data;
                line_tag  [fetch_idx] <= fetch_tag;
                line_valid[fetch_idx] <= 1'b1;
                fetch_busy <= 1'b0;
                sd_req     <= 1'b0;
                rd_data    <= sd_data;       // serve the data right away
            end
        end
    end

    assign rd_ok = hit;

endmodule
