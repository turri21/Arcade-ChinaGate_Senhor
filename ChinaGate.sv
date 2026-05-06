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

// China Gate (Technos 1988) — MiSTer core
// 2x HD6309 (or MC6809E) + Z80 (audio stub) + YM2151/OKI M6295 (audio stub)
// Sorgelig-style MiSTer wrapper with SDRAM ROM storage + per-CPU caches +
// per-renderer prefetch buffers.
//
// Based on MiSTer Template by Sorgelig and on the Darius / Darius 2 cores
// by Umberto Parisi (rmonic79).

module emu
(
	input         CLK_50M,
	input         RESET,
	inout  [48:0] HPS_BUS,
	output        CLK_VIDEO,
	output        CE_PIXEL,
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,
	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER,
	output        VGA_DISABLE,
	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,
	output        HDMI_BLACKOUT,
	output        HDMI_BOB_DEINT,

`ifdef MISTER_FB
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,
`ifdef MISTER_FB_PALETTE
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,
	output  [1:0] BUTTONS,

	input         CLK_AUDIO,
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,
	output  [1:0] AUDIO_MIX,

	inout   [3:0] ADC_BUS,

	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);

///////// Unused ports /////////
assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_SL      = 0;
assign VGA_F1      = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;

// Pause forward-declarations
reg pause_toggle;
reg joy_pause_prev;
wire pause;
assign HDMI_FREEZE    = 1'b0;  // overlay pausa renderizzato real-time, no freeze
assign HDMI_BLACKOUT  = 0;
assign HDMI_BOB_DEINT = 0;

// Audio: signed, mix mode default, valori da chinagate_audio
assign AUDIO_S   = 1;
assign AUDIO_MIX = 0;

assign LED_DISK  = 0;
assign LED_POWER = 0;
assign BUTTONS   = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

`include "build_id.v"
// OSD layer offsets: 6-bit signed 2's complement, default 0 on reset
// OSD offsets scollegati: hardcoded ai valori calibrati. Mantengo i nomi
// dei wire per non rompere i collegamenti a valle.
wire signed [9:0] osd_bg_xoff  = 10'sd0;
wire signed [9:0] osd_bg_yoff  = 10'sd0;
wire signed [9:0] osd_fg_xoff  = 10'sd2;
wire signed [9:0] osd_fg_yoff  = 10'sd0;
wire signed [9:0] osd_spr_xoff = -10'sd3;
wire signed [9:0] osd_spr_yoff = 10'sd1;

localparam CONF_STR = {
	"ChinaGate;;",
	"-;",
	"P1,Video;",
	"P1O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P1O[7:5],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"-;",
	// --- Pause + Offsets: Pause scollegato (joy bit funziona), Pause Style attivo ---
	"P2,System;",
	// "P2O[10],Pause,Off,On;",
	"P2O[11],Pause Style,Full,Clean;",
	"-;",
	// "P3,Offsets;",
	// "P3O[43:38],BG X Offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// "P3O[49:44],BG Y Offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// "P3O[55:50],FG X Offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// "P3O[61:56],FG Y Offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// "P3O[67:62],Sprite X Offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// "P3O[73:68],Sprite Y Offset,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,-32,-31,-30,-29,-28,-27,-26,-25,-24,-23,-22,-21,-20,-19,-18,-17,-16,-15,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
	// "-;",
	"P4,Audio Mixer;",
	"P4O[88:86],FM (YM2151) volume,100%,12%,25%,50%,75%,150%,200%,Mute;",
	"P4O[91:89],OKI ADPCM volume,100%,12%,25%,50%,75%,150%,200%,Mute;",
	"-;",
	"P4O[92],Pickup,Polite,MAME;",
	"P4O[94],Gong,MAME,Polite;",
	"-;",
	"DIP;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"-;",
	"J1,Attack,Jump,Special,Start,Coin;",
	"jn,A,B,X,Start,R;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire  [1:0] buttons;
wire [127:0] status;
wire [10:0] ps2_key;
wire [15:0] joy0, joy1;
wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire [ 7:0] ioctl_dout;
wire        ioctl_wait;

hps_io #(.CONF_STR(CONF_STR), .WIDE(0)) u_hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),
	.forced_scandoubler(forced_scandoubler),
	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),
	.ps2_key(ps2_key),
	.joystick_0(joy0),
	.joystick_1(joy1),
	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait)
);

///////////////////////   INPUTS   ///////////////////////////////
wire [7:0] p1_n = ~{joy0[10], joy0[6], joy0[5], joy0[4], joy0[2], joy0[3], joy0[1], joy0[0]};
wire [7:0] p2_n = ~{joy1[10], joy1[6], joy1[5], joy1[4], joy1[2], joy1[3], joy1[1], joy1[0]};
wire [2:0] coin_n = ~{1'b0, joy1[11], joy0[11]};

reg [15:0] dip_sw = 16'hFFFF;
always @(posedge clk_sys) begin
	if (ioctl_wr && (ioctl_index == 16'd254)) begin
		if (ioctl_addr[26:0] == 27'd0) dip_sw[ 7:0] <= ioctl_dout;
		if (ioctl_addr[26:0] == 27'd1) dip_sw[15:8] <= ioctl_dout;
	end
end

wire [7:0] dsw1 = dip_sw[ 7:0];
wire [7:0] dsw2 = dip_sw[15:8];

///////////////////////   CLOCKS   ///////////////////////////////
wire clk_sys;
wire pll_locked;
pll u_pll (
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

// Reset separati pattern Darius:
//   reset       = game (CPU + bus): incluso ioctl_download, game fermo durante load
//   bridge_reset = solo PLL: bridge SDRAM gira durante download per scrivere ROM
//   video_reset  = solo PLL: video sempre attivo per non perdere sync sul monitor
wire reset        = RESET | status[0] | buttons[1] | ~pll_locked | ioctl_download;
wire bridge_reset = ~pll_locked;
wire video_reset  = ~pll_locked;

// pxl_cen su video_reset (~pll_locked): sempre attivo durante download,
// così HS/VS oscillano, monitor mantiene sync, e si vede "ROM loading".
// cpu_cen su reset: CPU game ferma durante download.
reg [3:0] cen_div = 4'd0;
reg pxl_cen = 1'b0;
reg cpu_cen = 1'b0;
always @(posedge clk_sys) begin
	if (video_reset) begin
		cen_div <= 4'd0;
		pxl_cen <= 1'b0;
	end else begin
		cen_div <= cen_div + 4'd1;
		pxl_cen <= (cen_div == 4'd15);
	end
	cpu_cen <= (reset || pause) ? 1'b0 : (cen_div == 4'd15);
end

always @(posedge clk_sys) begin
	if (reset) begin
		pause_toggle  <= 1'b0;
		joy_pause_prev<= 1'b0;
	end else begin
		joy_pause_prev <= joy0[12] | joy1[12];
		if ((joy0[12] | joy1[12]) && !joy_pause_prev)
			pause_toggle <= ~pause_toggle;
	end
end
assign pause = pause_toggle | status[10];

///////////////////////   SDRAM   ////////////////////////////////
// Sorgelig 4-port Genesis controller. We use:
//   port 0: download writes + 3 gfx clients (chars/tiles/sprites)
//   port 1: main CPU 16-bit reads
//   port 2: sub  CPU 16-bit reads
//   port 3: spare

wire [24:1] sd_addr0, sd_addr1, sd_addr2, sd_addr3;
wire [15:0] sd_din0,  sd_din1,  sd_din2,  sd_din3;
wire        sd_wrl0,  sd_wrh0,  sd_wrl1,  sd_wrh1;
wire        sd_wrl2,  sd_wrh2,  sd_wrl3,  sd_wrh3;
wire        sd_req0,  sd_req1,  sd_req2,  sd_req3;
wire        sd_ack0,  sd_ack1,  sd_ack2,  sd_ack3;
wire [15:0] sd_dout0, sd_dout1, sd_dout2, sd_dout3;
wire        sdram_ready;

sdram sdram_ctrl (
	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_A(SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CLK(SDRAM_CLK),
	.SDRAM_CKE(SDRAM_CKE),

	.init(~pll_locked),
	.clk(clk_sys),
	.prio_mode(2'b00),
	.ready(sdram_ready),

	.addr0(sd_addr0), .wrl0(sd_wrl0), .wrh0(sd_wrh0),
	.din0(sd_din0), .dout0(sd_dout0), .req0(sd_req0), .ack0(sd_ack0),

	.addr1(sd_addr1), .wrl1(sd_wrl1), .wrh1(sd_wrh1),
	.din1(sd_din1), .dout1(sd_dout1), .req1(sd_req1), .ack1(sd_ack1),

	.addr2(sd_addr2), .wrl2(sd_wrl2), .wrh2(sd_wrh2),
	.din2(sd_din2), .dout2(sd_dout2), .req2(sd_req2), .ack2(sd_ack2),

	.addr3(sd_addr3), .wrl3(sd_wrl3), .wrh3(sd_wrh3),
	.din3(sd_din3), .dout3(sd_dout3), .req3(sd_req3), .ack3(sd_ack3)
);

///////////////////////   SDRAM BRIDGE   ////////////////////////
// game-side wires
wire [16:0] mc_byte_addr;        // main CPU sdram byte address
wire        mc_req;
wire [15:0] mc_data;
wire        mc_ready;

wire [16:0] sc_byte_addr;        // sub  CPU sdram byte address
wire        sc_req;
wire [15:0] sc_data;
wire        sc_ready;

wire [16:0] chars_byte_addr;
wire        chars_req;
wire [31:0] chars_data;
wire        chars_valid;

wire [17:0] tiles_byte_addr;
wire        tiles_req;
wire [31:0] tiles_data;
wire        tiles_valid;

wire [18:0] obj_byte_addr;
wire        obj_req;
wire [31:0] obj_data;
wire        obj_valid;

chinagate_sdram_bridge u_bridge (
	.clk           (clk_sys),
	.reset         (bridge_reset),
	.sdram_ready   (sdram_ready),

	.ioctl_download(ioctl_download),
	.ioctl_wr      (ioctl_wr),
	.ioctl_addr    (ioctl_addr),
	.ioctl_dout    (ioctl_dout),
	.ioctl_index   (ioctl_index),
	.ioctl_wait    (ioctl_wait),

	.chars_byte_addr(chars_byte_addr),
	.chars_req     (chars_req),
	.chars_data    (chars_data),
	.chars_valid   (chars_valid),

	.tiles_byte_addr(tiles_byte_addr),
	.tiles_req     (tiles_req),
	.tiles_data    (tiles_data),
	.tiles_valid   (tiles_valid),

	.obj_byte_addr (obj_byte_addr),
	.obj_req       (obj_req),
	.obj_data      (obj_data),
	.obj_valid     (obj_valid),

	.main_byte_addr(mc_byte_addr),
	.main_req      (mc_req),
	.main_data     (mc_data),
	.main_ready    (mc_ready),

	.sub_byte_addr (sc_byte_addr),
	.sub_req       (sc_req),
	.sub_data      (sc_data),
	.sub_ready     (sc_ready),

	.oki_byte_addr (oki_byte_addr),
	.oki_req       (oki_req),
	.oki_data      (oki_data),
	.oki_ready     (oki_ready),

	.sdram_addr0(sd_addr0), .sdram_din0(sd_din0),
	.sdram_wrl0(sd_wrl0), .sdram_wrh0(sd_wrh0),
	.sdram_req0(sd_req0), .sdram_ack0(sd_ack0), .sdram_dout0(sd_dout0),

	.sdram_addr1(sd_addr1), .sdram_din1(sd_din1),
	.sdram_wrl1(sd_wrl1), .sdram_wrh1(sd_wrh1),
	.sdram_req1(sd_req1), .sdram_ack1(sd_ack1), .sdram_dout1(sd_dout1),

	.sdram_addr2(sd_addr2), .sdram_din2(sd_din2),
	.sdram_wrl2(sd_wrl2), .sdram_wrh2(sd_wrh2),
	.sdram_req2(sd_req2), .sdram_ack2(sd_ack2), .sdram_dout2(sd_dout2),

	.sdram_addr3(sd_addr3), .sdram_din3(sd_din3),
	.sdram_wrl3(sd_wrl3), .sdram_wrh3(sd_wrh3),
	.sdram_req3(sd_req3), .sdram_ack3(sd_ack3), .sdram_dout3(sd_dout3)
);

///////////////////////   CPU CACHES   //////////////////////////
// Each cache stalls its CPU on miss via bus_busy.

wire [16:0] main_cpu_byte_addr;   // from chinagate_top main_bank/fix
wire        main_cpu_oe;
wire [ 7:0] main_cpu_data;
wire        main_bus_busy;

rom_cache_8bit #(.CACHE_BITS(8), .CPU_AW(17)) u_main_cache (
	.clk         (clk_sys),
	.reset       (reset),                  // Pattern Darius: cache si svuota al reset game
	.cpu_addr    (main_cpu_byte_addr),
	.cpu_oe      (main_cpu_oe),
	.cpu_data    (main_cpu_data),
	.bus_busy    (main_bus_busy),
	.sdram_byte_addr(mc_byte_addr),
	.sdram_req   (mc_req),
	.sdram_data  (mc_data),
	.sdram_ready (mc_ready)
);

wire [16:0] sub_cpu_byte_addr;
wire        sub_cpu_oe;
wire [ 7:0] sub_cpu_data;
wire        sub_bus_busy;

rom_cache_8bit #(.CACHE_BITS(8), .CPU_AW(17)) u_sub_cache (
	.clk         (clk_sys),
	.reset       (reset),                  // Pattern Darius: cache si svuota al reset game
	.cpu_addr    (sub_cpu_byte_addr),
	.cpu_oe      (sub_cpu_oe),
	.cpu_data    (sub_cpu_data),
	.bus_busy    (sub_bus_busy),
	.sdram_byte_addr(sc_byte_addr),
	.sdram_req   (sc_req),
	.sdram_data  (sc_data),
	.sdram_ready (sc_ready)
);

///////////////////////   GFX PREFETCH BUFFERS   ////////////////
// Each provides the JTFRAME-style "rom_data always valid" interface.

// FG chars: NO prefetch_buf, NO SDRAM. Chars ROM (128KB) caricata in BRAM
// locale dentro jtcg_video via chars_dl_* segnali.
wire        chars_dl_wr;
wire [16:0] chars_dl_addr;
wire [ 7:0] chars_dl_data;

// chars region SDRAM = [0x48000..0x67FFF]. Estraggo dall'ioctl stream.
// chars_dl_addr = ioctl_addr - 0x48000 (range 0..0x1FFFF)
wire [26:0] chars_dl_offset = ioctl_addr - 27'h048000;
assign chars_dl_wr   = ioctl_download && ioctl_wr && ioctl_index == 16'd0 &&
                       (ioctl_addr >= 27'h048000) && (ioctl_addr < 27'h068000);
assign chars_dl_addr = chars_dl_offset[16:0];
assign chars_dl_data = ioctl_dout;

// Tie off bridge chars + tiles ports (chars + tiles in BRAM locale ora)
wire g_obj_ok;
assign chars_byte_addr = 17'd0;
assign chars_req       = 1'b0;
assign tiles_byte_addr = 18'd0;
assign tiles_req       = 1'b0;

// BG tiles: estrazione segnali dl_* dall'ioctl stream
// tiles region SDRAM = [0xE8000..0x127FFF] (256KB)
// tiles_dl_addr = ioctl_addr - 0xE8000 (range 0..0x3FFFF)
wire [26:0] tiles_dl_offset = ioctl_addr - 27'h0E8000;
wire        tiles_dl_wr     = ioctl_download && ioctl_wr && ioctl_index == 16'd0 &&
                              (ioctl_addr >= 27'h0E8000) && (ioctl_addr < 27'h128000);
wire [17:0] tiles_dl_addr   = tiles_dl_offset[17:0];
wire [ 7:0] tiles_dl_data   = ioctl_dout;

wire [17:0] g_obj_addr;   // 18-bit word index = byte_addr / 2
wire        g_obj_cs;
wire [31:0] g_obj_data;
// obj prefetch: rd_addr 18 bit = word_addr (= byte_addr / 2)
// byte_addr = 2 * word_addr → {rd_addr, 1'b0} per ottenere 19 bit byte_addr
// con bit[0]=0 (allineato a 16-bit). Bit[1] preservato (= y[0] del decoder).
wire [17:0] obj_byte_addr_w;
assign obj_byte_addr = {obj_byte_addr_w, 1'b0};

gfx_prefetch_buf #(.ADDR_W(18)) u_obj_buf (
	.clk    (clk_sys),
	.reset  (reset),                        // Pattern Darius: cache si svuota al reset game
	.rd_addr(g_obj_addr),
	.rd_cs  (g_obj_cs),
	.rd_data(g_obj_data),
	.rd_ok  (g_obj_ok),
	.sd_addr(obj_byte_addr_w),
	.sd_req (obj_req),
	.sd_data(obj_data),
	.sd_valid(obj_valid)
);

///////////////////////   GAME   /////////////////////////////////

wire [ 8:0] hdump, vdump;
wire        LHBL, LVBL, HS, VS;
wire [ 3:0] R4, G4, B4;

// Audio soundlatch da chinagate_top
wire [ 7:0] snd_latch;
wire        snd_irq_pulse;

// Audio Mixer OSD (Darius2-style)
// 7 livelli + Mute. Q4.4 (16 = 100%, 32 = 200%, 0 = mute)
wire [2:0] osd_fm_vol  = status[88:86];
wire [2:0] osd_oki_vol = status[91:89];

// Coin Gong (FM CH7) mode: Polite (25%, default) o MAME (100%)
// Polite: ch_tl_offset[7] = 16 (~-12 dB, attenua effetti CH7 troppo forti)
// MAME:   ch_tl_offset[7] = 0 (passa TL del game invariato, come MAME)
// CH0..CH6 sempre invariati (offset 0).
wire [6:0] ch_tl_offset [0:7];
assign ch_tl_offset[0] = 7'd0;
assign ch_tl_offset[1] = 7'd0;
assign ch_tl_offset[2] = 7'd0;
assign ch_tl_offset[3] = 7'd0;
assign ch_tl_offset[4] = 7'd0;
assign ch_tl_offset[5] = 7'd0;
assign ch_tl_offset[6] = 7'd0;
assign ch_tl_offset[7] = status[92] ? 7'd0 : 7'd16;  // Pickup (CH7)

reg [5:0] fm_vol_q44, oki_vol_q44;
always @(*) begin
	case (osd_fm_vol)
		3'd0: fm_vol_q44 = 6'd16;
		3'd1: fm_vol_q44 = 6'd2;
		3'd2: fm_vol_q44 = 6'd4;
		3'd3: fm_vol_q44 = 6'd8;
		3'd4: fm_vol_q44 = 6'd12;
		3'd5: fm_vol_q44 = 6'd24;
		3'd6: fm_vol_q44 = 6'd32;
		3'd7: fm_vol_q44 = 6'd0;
	endcase
	case (osd_oki_vol)
		3'd0: oki_vol_q44 = 6'd16;
		3'd1: oki_vol_q44 = 6'd2;
		3'd2: oki_vol_q44 = 6'd4;
		3'd3: oki_vol_q44 = 6'd8;
		3'd4: oki_vol_q44 = 6'd12;
		3'd5: oki_vol_q44 = 6'd24;
		3'd6: oki_vol_q44 = 6'd32;
		3'd7: oki_vol_q44 = 6'd0;
	endcase
end

// chinagate_top now drives a single composite ROM byte address per CPU,
// muxed internally between bank ($4000-$7FFF) and fix ($8000-$FFFF).
// Disable CPU caches during ROM download: SDRAM contains garbage until
// the ioctl stream is finished. Without this gate, the cache fetches
// the first addr at boot and stores garbage, then on first CPU access
// it serves a hit with garbage → CPU executes invalid opcode.
assign main_cpu_oe = ~ioctl_download;
assign sub_cpu_oe  = ~ioctl_download;

chinagate_top u_game (
	.clk            (clk_sys),
	.pxl_cen        (pxl_cen),
	.cpu_cen        (cpu_cen),
	.rst            (reset),

	.coin_n         (coin_n),
	.p1_n           (p1_n),
	.p2_n           (p2_n),
	.dsw1           (dsw1),
	.dsw2           (dsw2),

	.osd_bg_xoff    (osd_bg_xoff),
	.osd_bg_yoff    (osd_bg_yoff),
	.osd_fg_xoff    (osd_fg_xoff),
	.osd_fg_yoff    (osd_fg_yoff),
	.osd_spr_xoff   (osd_spr_xoff),
	.osd_spr_yoff   (osd_spr_yoff),

	.main_rom_byte_addr (main_cpu_byte_addr),
	.main_rom_data      (main_cpu_data),
	.main_rom_ok        (~main_bus_busy),

	.sub_rom_byte_addr  (sub_cpu_byte_addr),
	.sub_rom_data       (sub_cpu_data),
	.sub_rom_ok         (~sub_bus_busy),

	.chars_dl_wr    (chars_dl_wr),
	.chars_dl_addr  (chars_dl_addr),
	.chars_dl_data  (chars_dl_data),

	.tiles_dl_wr    (tiles_dl_wr),
	.tiles_dl_addr  (tiles_dl_addr),
	.tiles_dl_data  (tiles_dl_data),

	.obj_rom_addr   (g_obj_addr),
	.obj_rom_data   (g_obj_data),
	.obj_rom_ok     (g_obj_ok),
	.obj_rom_cs     (g_obj_cs),

	.main_bus_busy  (main_bus_busy),
	.sub_bus_busy   (sub_bus_busy),

	.hdump          (hdump),
	.vdump          (vdump),
	.LHBL           (LHBL),
	.LVBL           (LVBL),
	.HS             (HS),
	.VS             (VS),
	.red            (R4),
	.green          (G4),
	.blue           (B4),

	.snd_latch_dbg     (snd_latch),
	.snd_irq_dbg       (snd_irq_pulse),
	.video_enable_dbg  (),
	.flip_screen_dbg   (),
	.scrollx_dbg       (),
	.scrolly_dbg       (),
	.main_pc_dbg       (),
	.sub_pc_dbg        ()
);

///////////////////////   AUDIO   ////////////////////////////////
// Z80 sound + YM2151 + OKI M6295.
//
// CEN matematici @ clk_sys = 96 MHz:
//   cen_z80   = 3.579545 MHz target → 96/27 = 3.555 MHz (errore -0.7%)
//   cen_ym    = stesso del Z80
//   cen_ym_p1 = half rate (toggle)
//   cen_oki   = 1.065 MHz target → 96/90 = 1.067 MHz (errore +0.18%)

reg [4:0] z80_div = 5'd0;       // 0..26
reg       cen_z80 = 1'b0;
reg       cen_ym_p1 = 1'b0;
reg       cen_ym_p1_toggle = 1'b0;

always @(posedge clk_sys) begin
	if (reset) begin
		z80_div          <= 5'd0;
		cen_z80          <= 1'b0;
		cen_ym_p1        <= 1'b0;
		cen_ym_p1_toggle <= 1'b0;
	end else begin
		cen_z80   <= 1'b0;
		cen_ym_p1 <= 1'b0;
		if (z80_div == 5'd26) begin
			z80_div <= 5'd0;
			cen_z80 <= 1'b1;
			cen_ym_p1_toggle <= ~cen_ym_p1_toggle;
			cen_ym_p1 <= cen_ym_p1_toggle;
		end else begin
			z80_div <= z80_div + 5'd1;
		end
	end
end

reg [6:0] oki_div = 7'd0;       // 0..89
reg       cen_oki = 1'b0;
always @(posedge clk_sys) begin
	if (reset) begin
		oki_div <= 7'd0;
		cen_oki <= 1'b0;
	end else begin
		cen_oki <= 1'b0;
		if (oki_div == 7'd89) begin
			oki_div <= 7'd0;
			cen_oki <= 1'b1;
		end else begin
			oki_div <= oki_div + 7'd1;
		end
	end
end

// Sound Z80 ROM: 32KB BRAM locale, caricata via ioctl @ BASE 0x040000..0x047FFF
wire [26:0] snd_dl_offset = ioctl_addr - 27'h040000;
wire        snd_dl_wr     = ioctl_download && ioctl_wr && ioctl_index == 16'd0 &&
                            (ioctl_addr >= 27'h040000) && (ioctl_addr < 27'h048000);
wire [14:0] snd_dl_addr   = snd_dl_offset[14:0];
wire [ 7:0] snd_dl_data   = ioctl_dout;

// OKI ADPCM ROM: 256KB su SDRAM port3 (BASE 0x128000).
// jt6295 chiede 1 byte ad un certo addr e usa rom_ok per stallarsi durante miss.
// Glue: detect cambio di oki_rom_addr -> abbassa rom_ok, fa request a SDRAM,
// quando oki_ready arriva latcha il byte e alza rom_ok.
wire [17:0] oki_rom_addr;
reg  [ 7:0] oki_rom_q;
reg         oki_rom_ok_w;
wire [17:0] oki_byte_addr;
reg         oki_req;
wire [15:0] oki_data;
wire        oki_ready;

assign oki_byte_addr = oki_rom_addr;

reg [17:0] oki_addr_pending;
reg        oki_busy;

always @(posedge clk_sys) begin
	if (reset) begin
		oki_req          <= 1'b0;
		oki_rom_ok_w     <= 1'b0;
		oki_rom_q        <= 8'h00;
		oki_addr_pending <= 18'd0;
		oki_busy         <= 1'b0;
	end else begin
		// Default: deasserta req (così il prossimo set genera rising edge)
		oki_req <= 1'b0;
		// Detect cambio di addr richiesto da jt6295 (o primo accesso)
		if (!oki_busy && (oki_rom_addr != oki_addr_pending || !oki_rom_ok_w)) begin
			oki_addr_pending <= oki_rom_addr;
			oki_req          <= 1'b1;          // pulse rising edge a bridge
			oki_busy         <= 1'b1;
			oki_rom_ok_w     <= 1'b0;          // stalla jt6295
		end
		// Quando bridge risponde
		if (oki_busy && oki_ready) begin
			oki_rom_q    <= oki_addr_pending[0] ? oki_data[15:8] : oki_data[7:0];
			oki_rom_ok_w <= 1'b1;
			oki_busy     <= 1'b0;
		end
	end
end

// Audio output wires
wire signed [15:0] audio_l_w, audio_r_w;

// Gate cen audio con pause (pattern Darius2): durante pause Z80+YM+OKI fermi
wire cen_z80_g    = cen_z80    & ~pause;
wire cen_ym_p1_g  = cen_ym_p1  & ~pause;
wire cen_oki_g    = cen_oki    & ~pause;

chinagate_audio u_audio (
	.clk            (clk_sys),
	.rst            (reset),
	.cen_z80        (cen_z80_g),
	.cen_ym         (cen_z80_g),
	.cen_ym_p1      (cen_ym_p1_g),
	.cen_oki        (cen_oki_g),

	.snd_latch      (snd_latch),
	.snd_latch_wr   (snd_irq_pulse),

	.snd_rom_dl_wr  (snd_dl_wr),
	.snd_rom_dl_addr(snd_dl_addr),
	.snd_rom_dl_data(snd_dl_data),

	.oki_rom_addr   (oki_rom_addr),
	.oki_rom_data   (oki_rom_q),
	.oki_rom_ok     (oki_rom_ok_w),  // SDRAM port3, stalla jt6295 durante miss

	.fm_vol         (fm_vol_q44),
	.oki_vol        (oki_vol_q44),
	.ch_tl_offset   (ch_tl_offset),
	.oki_polite     (status[94]),   // OSD label "MAME,Polite" → 0=MAME (default), 1=Polite

	.audio_l        (audio_l_w),
	.audio_r        (audio_r_w)
);

assign AUDIO_L = audio_l_w;
assign AUDIO_R = audio_r_w;

///////////////////////   VIDEO OUT   ////////////////////////////
// Pause overlay: dim + logo 48x48 scalato x2 (96x96) al centro su pause.
wire [3:0] R4_post, G4_post, B4_post;
pause_overlay u_pause_ovl (
	.clk       (clk_sys),
	.pause     (pause),
	.clean     (status[11]),
	.render_x  (hdump),
	.render_y  (vdump),
	.rgb_r_in  (R4),
	.rgb_g_in  (G4),
	.rgb_b_in  (B4),
	.rgb_r_out (R4_post),
	.rgb_g_out (G4_post),
	.rgb_b_out (B4_post)
);

// Maschera primi 7 pixel del visible (hdump 4..10 = screen_x 0..6).
// In quella zona MAME mostra cornice nera del FG; mio FG ha pen=0 lì
// e mostra sprite/BG sotto. Maschera forzata a nero copre il bug.
wire mask_left = (hdump >= 9'd4) && (hdump <= 9'd10);
assign VGA_R = mask_left ? 8'd0 : {R4_post, R4_post};
assign VGA_G = mask_left ? 8'd0 : {G4_post, G4_post};
assign VGA_B = mask_left ? 8'd0 : {B4_post, B4_post};
assign VGA_HS = HS;
assign VGA_VS = VS;

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL  = pxl_cen;

// AR 5:4 come JTDD (Double Dragon JT). ChinaGate usa stesso schermo Technos
// con pixel non-quadri: visible 256×240 a pixel ratio dà 5:4 fisico, non 4:3.
wire [11:0] arx = (!ar) ? 12'd5 : (ar - 1'd1);
wire [11:0] ary = (!ar) ? 12'd4 : 12'd0;

video_freak video_freak (
	.CLK_VIDEO  (clk_sys),
	.CE_PIXEL   (pxl_cen),
	.VGA_VS     (VS),
	.HDMI_WIDTH (HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE     (VGA_DE),
	.VIDEO_ARX  (VIDEO_ARX),
	.VIDEO_ARY  (VIDEO_ARY),
	.VGA_DE_IN  (LHBL & LVBL),
	.ARX        (arx),
	.ARY        (ary),
	.CROP_SIZE  (12'd0),
	.CROP_OFF   (5'd0),
	.SCALE      (status[7:5])
);

assign LED_USER = ioctl_download;

endmodule
