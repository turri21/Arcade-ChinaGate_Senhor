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

// chinagate_audio — sound subsystem ChinaGate (chinagat US/JP):
//   - Z80 sound CPU @ 3.579545 MHz
//   - YM2151 (jt51) @ 3.579545 MHz, stereo 16-bit
//   - OKI M6295 (jt6295) @ 1.065 MHz, mono 14-bit, ADPCM ROM 256KB
//   - Soundlatch 8-bit (NMI Z80 quando main scrive a $3E00)
//
// Z80 memory map:
//   0x0000-0x7FFF  Sound ROM (32KB, BRAM locale, caricata via dl)
//   0x8000-0x87FF  RAM 2KB
//   0x8800-0x8801  YM2151 r/w (a0 = addr[0])
//   0x9800-0x9800  OKI M6295 r/w
//   0xA000-0xA000  Soundlatch read (clear NMI)
//
// Output: AUDIO_L/R 16-bit signed.

module chinagate_audio (
    input  logic         clk,            // clk_sys (96 MHz)
    input  logic         rst,            // game reset

    // Cen (generati esternamente):
    //   cen_z80   = 3.579545 MHz pulse  (clk_sys / ~26.83 → divisore 27)
    //   cen_ym    = stesso del Z80 (jt51 vuole cen + cen_p1 a half rate)
    //   cen_oki   = 1.065 MHz pulse     (clk_sys / ~90)
    input  logic         cen_z80,
    input  logic         cen_ym,
    input  logic         cen_ym_p1,      // cen_ym al half rate
    input  logic         cen_oki,

    // Soundlatch da main CPU
    input  logic [ 7:0]  snd_latch,
    input  logic         snd_latch_wr,   // pulse 1 ciclo quando main scrive $3E00

    // Sound ROM download (32KB BRAM locale)
    input  logic         snd_rom_dl_wr,
    input  logic [14:0]  snd_rom_dl_addr,    // 32KB = 15-bit
    input  logic [ 7:0]  snd_rom_dl_data,

    // OKI ADPCM ROM (256KB, accesso esterno via SDRAM o BRAM)
    output logic [17:0]  oki_rom_addr,
    input  logic [ 7:0]  oki_rom_data,
    input  logic         oki_rom_ok,

    // OSD Audio Mixer Q4.4 (16 = 100%, 32 = 200%, 0 = mute)
    input  logic [ 5:0]  fm_vol,
    input  logic [ 5:0]  oki_vol,

    // OSD per-channel TL offsets (8 voci YM2151).
    // Ogni offset è 7-bit, sommato al TL del game prima di passare a jt51.
    // 0 = nessuna attenuazione extra, 127 = mute (TL=127).
    input  logic [ 6:0]  ch_tl_offset [0:7],

    // OSD: OKI "Polite" mode. Quando 1, sui sample con att<3 (più alto del
    // standard del game) forza att=3 (~-9 dB), allineando i picchi al
    // livello degli SFX standard. Quando 0, comportamento MAME esatto.
    input  logic         oki_polite,

    // Audio output
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r
);

    // ==================================================================
    // Z80 signals (forward decl)
    // ==================================================================
    logic [15:0] z80_addr;
    logic [ 7:0] z80_dout;
    logic [ 7:0] z80_din;
    logic        z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n, z80_m1_n;
    logic        z80_int_n, z80_nmi_n;
    logic [211:0] z80_reg;       // T80s REG output (debug, unused)

    // ==================================================================
    // CS decoder
    // ==================================================================
    wire rom_cs   = ~z80_mreq_n & (z80_addr[15] == 1'b0);                  // 0x0000-0x7FFF
    wire ram_cs   = ~z80_mreq_n & (z80_addr[15:11] == 5'b10000);           // 0x8000-0x87FF
    wire ym_cs    = ~z80_mreq_n & (z80_addr[15:1]  == 15'b100010000000000);// 0x8800-0x8801
    wire oki_cs   = ~z80_mreq_n & (z80_addr == 16'h9800);                  // 0x9800
    wire latch_cs = ~z80_mreq_n & (z80_addr == 16'hA000);                  // 0xA000

    // ==================================================================
    // Soundlatch + NMI
    // Main CPU scrive a $3E00 → snd_latch_wr=1 → latch + NMI pending.
    // Z80 legge a $A000 → clear NMI.
    // ==================================================================
    logic [7:0] latch_data;
    logic       nmi_pending;
    wire        latch_read = latch_cs & ~z80_rd_n;

    always_ff @(posedge clk) begin
        if (rst) begin
            latch_data  <= 8'h00;
            nmi_pending <= 1'b0;
        end else begin
            if (snd_latch_wr) begin
                latch_data  <= snd_latch;
                nmi_pending <= 1'b1;
            end else if (latch_read) begin
                nmi_pending <= 1'b0;
            end
        end
    end

    // ==================================================================
    // Z80 (T80s, Mode 0)
    // ==================================================================
    wire ym_irq_n;   // jt51 active-low IRQ output

    assign z80_int_n = ym_irq_n;
    assign z80_nmi_n = ~nmi_pending;

    T80s u_z80 (
        .RESET_n (~rst),
        .CLK     (clk),
        .CEN     (cen_z80),
        .WAIT_n  (1'b1),
        .INT_n   (z80_int_n),
        .NMI_n   (z80_nmi_n),
        .BUSRQ_n (1'b1),
        .M1_n    (z80_m1_n),
        .MREQ_n  (z80_mreq_n),
        .IORQ_n  (z80_iorq_n),
        .RD_n    (z80_rd_n),
        .WR_n    (z80_wr_n),
        .RFSH_n  (),
        .HALT_n  (),
        .BUSAK_n (),
        .OUT0    (1'b0),
        .A       (z80_addr),
        .DI      (z80_din),
        .DO      (z80_dout),
        .REG     (z80_reg)
    );

    // ==================================================================
    // Sound ROM 32KB BRAM (caricata via download)
    // ==================================================================
    (* ramstyle = "M10K,no_rw_check" *) logic [7:0] snd_rom [0:32767];
    logic [7:0] snd_rom_q;

    always_ff @(posedge clk) begin
        if (snd_rom_dl_wr) snd_rom[snd_rom_dl_addr] <= snd_rom_dl_data;
        snd_rom_q <= snd_rom[z80_addr[14:0]];
    end

    // ==================================================================
    // RAM 2KB
    // ==================================================================
    (* ramstyle = "M10K,no_rw_check" *) logic [7:0] z80_ram [0:2047];
    logic [7:0] z80_ram_q;

    always_ff @(posedge clk) begin
        if (ram_cs && !z80_wr_n)
            z80_ram[z80_addr[10:0]] <= z80_dout;
        z80_ram_q <= z80_ram[z80_addr[10:0]];
    end

    // ==================================================================
    // YM2151 (jt51)
    // jt51 cs_n attivo basso. Wr_n ok. a0 = z80_addr[0].
    // ==================================================================
    logic [7:0] ym_dout;
    logic signed [15:0] ym_left, ym_right;

    // ==================================================================
    // TL Modifier: intercetta scritture YM2151 al registro TL e attenua
    // per canale tramite OSD ch_tl_offset[0..7].
    //
    // YM2151 TL register layout:
    //   regsel = 0x60 + op*8 + ch    (op ∈ 0..3, ch ∈ 0..7)
    //   regsel[7:5] = 011..011 (= 0x60..0x7F → bit[7:5]=011 con bit[6:5]
    //                            che variano per op)
    //   regsel[4:3] = op[1:0]   (operator)
    //   regsel[2:0] = ch[2:0]   (canale 0..7)
    //   value = TL [6:0], bit7 ignorato
    //
    // TL = attenuazione: 0 = max volume, 127 = mute, step 0.75 dB.
    // Offset OSD viene SOMMATO al TL: TL_eff = min(127, TL + offset[ch]).
    // ==================================================================
    logic [7:0] last_regsel;
    logic       z80_wr_n_d;

    always_ff @(posedge clk) begin
        if (rst) begin
            last_regsel <= 8'h00;
            z80_wr_n_d  <= 1'b1;
        end else begin
            z80_wr_n_d <= z80_wr_n;
            // Falling edge di z80_wr_n con ym_cs alto e a0=0 = scrittura regsel
            if (z80_wr_n_d && !z80_wr_n && ym_cs && !z80_addr[0]) begin
                last_regsel <= z80_dout;
            end
        end
    end

    // Calcola TL effettivo quando regsel∈[0x60..0x7F] e a0=1 (write value)
    wire is_tl_reg = (last_regsel[7:5] == 3'b011);  // 0x60..0x7F
    wire [2:0] tl_ch   = last_regsel[2:0];
    wire [7:0] tl_sum  = {1'b0, z80_dout[6:0]} + {1'b0, ch_tl_offset[tl_ch]};
    // Saturate a 127 (TL max)
    wire [6:0] tl_eff  = tl_sum[7] ? 7'd127 : tl_sum[6:0];
    // din modificato al volo: se sta scrivendo TL value, sostituisci con TL_eff
    wire is_tl_value_write = z80_addr[0] && is_tl_reg;
    wire [7:0] din_modified = is_tl_value_write ? {1'b0, tl_eff} : z80_dout;

    // Uso xleft/xright (output linear esatto, bit-exact YM2151).
    jt51 u_ym2151 (
        .rst    (rst),
        .clk    (clk),
        .cen    (cen_ym),
        .cen_p1 (cen_ym_p1),
        .cs_n   (~ym_cs),
        .wr_n   (z80_wr_n),
        .a0     (z80_addr[0]),
        .din    (din_modified),
        .dout   (ym_dout),
        .ct1    (),
        .ct2    (),
        .irq_n  (ym_irq_n),
        .sample (),
        .left   (),
        .right  (),
        .xleft  (ym_left),
        .xright (ym_right)
    );

    // ==================================================================
    // OKI M6295 (jt6295) + Polite soft compressor
    //
    // Polite mode: applica un soft compressor al segnale audio OKI in
    // uscita dal chip. Sotto soglia (KNEE) il segnale passa invariato,
    // sopra soglia viene compresso 2:1 (ogni 2 LSB di input → 1 LSB di
    // output). Effetto: i sample con att=0 (~6 sample loud nel game,
    // incluso il coin gong) hanno picchi dimezzati; i sample standard
    // (att=3) sono già sotto soglia e passano puliti.
    //
    // KNEE = 2900 ≈ valore RMS di un sample att=3 (-9 dB rispetto al max
    // 14-bit signed ±8191). Compressione 2:1 sopra knee → picchi del
    // gong (~±8000) escono ~±5450 invece di ±8000, riducendo la
    // differenza coin/standard da ~9 dB a ~3 dB senza appiattire.
    // ==================================================================
    logic [7:0] oki_dout;
    logic signed [13:0] oki_sound;

    jt6295 #(.INTERPOL(0)) u_oki (
        .rst      (rst),
        .clk      (clk),
        .cen      (cen_oki),
        .ss       (1'b1),
        .wrn      (z80_wr_n | ~oki_cs),
        .din      (z80_dout),
        .dout     (oki_dout),
        .rom_addr (oki_rom_addr),
        .rom_data (oki_rom_data),
        .rom_ok   (oki_rom_ok),
        .sound    (oki_sound),
        .sample   ()
    );

    // ==================================================================
    // Z80 din mux
    // ==================================================================
    always_comb begin
        if      (rom_cs)   z80_din = snd_rom_q;
        else if (ram_cs)   z80_din = z80_ram_q;
        else if (ym_cs)    z80_din = ym_dout;
        else if (oki_cs)   z80_din = oki_dout;
        else if (latch_cs) z80_din = latch_data;
        else               z80_din = 8'hFF;
    end

    // ==================================================================
    // Mixer: replica MAME chinagat (mono, gain 0.8 entrambi) + OSD vol
    //
    // MAME normalization (verificato chinagat.cpp + ymfm_mame.h + okim6295.cpp):
    //   YM2151:  output / 32768 → ±1.0 (16-bit a unità)
    //   OKI M6295: output / 2048 → ±1.0 per voce (acc 4 voci 14-bit)
    // Per allineare OKI a YM: oki << 4 (×16 = 32768/2048).
    //
    // OSD volumes Q4.4: ym_scaled = (ym_in × fm_vol) >> 4
    //                    oki_scaled = (oki_in × oki_vol) >> 4
    // Default fm_vol=oki_vol=16 → ×1.0 (100%, identico a build pre-mixer).
    //
    // Mono mix:
    //   mono = 0.8 * (ym_L_scaled + ym_R_scaled + (oki_scaled<<4))
    // ==================================================================

    // FM scale: ym_left/right (16-bit signed) × fm_vol[5:0] / 16  (Q4.4)
    // 16-bit signed × 7-bit positive = 23-bit signed. /16 (>>>4): drop 4 LSB → 19-bit.
    // Slice [22:4] preserva il sign bit. Default vol=16 → ym_scaled = ym (16-bit).
    // Max vol=32 → ym_scaled = ym × 2 (17-bit needed, fits in 19).
    wire signed [22:0] ym_l_mul = $signed(ym_left)  * $signed({1'b0, fm_vol});
    wire signed [22:0] ym_r_mul = $signed(ym_right) * $signed({1'b0, fm_vol});
    wire signed [18:0] ym_l_scaled = ym_l_mul[22:4];
    wire signed [18:0] ym_r_scaled = ym_r_mul[22:4];

    // OKI Polite: attenuazione lineare uniforme ×1/2 (-6 dB).
    // Shift right 1, niente clipping. Tutto OKI scende di -6 dB.
    //
    //   ±2047 (att=0)  → ±1023 (-6 dB)
    //   ±700  (att=3)  → ±350
    //   ±400  (att=5)  → ±200
    wire signed [13:0] oki_attenuated = oki_sound >>> 1;
    wire signed [13:0] oki_post = oki_polite ? oki_attenuated : oki_sound;

    // OKI scale: oki_post (14-bit signed) × oki_vol[5:0]  (Q4.4 ma /1 perché
    // pre-mixer faceva oki<<4 = oki×16; con vol=16 default replico esattamente).
    // 14-bit signed × 7-bit positive = 21-bit signed.
    // Default vol=16 → oki_scaled = oki<<4 (18-bit, ±131072), identico pre-mixer.
    // Max vol=32 → oki<<5 (19-bit, ±262144).
    wire signed [20:0] oki_mul = $signed(oki_post) * $signed({1'b0, oki_vol});
    // oki_lvl = oki_mul (21-bit signed), allineato al livello YM (32768/2048=16)
    wire signed [20:0] oki_lvl = oki_mul;

    // Somma stereo YM: ±65534×2 max → 20-bit signed
    wire signed [19:0] ym_sum  = $signed({ym_l_scaled[18], ym_l_scaled}) +
                                 $signed({ym_r_scaled[18], ym_r_scaled});

    // Mix: ym_sum (20-bit) + oki_lvl (21-bit), range ±(131068 + 262144) → 22-bit
    wire signed [21:0] mix     = $signed({{2{ym_sum[19]}}, ym_sum}) +
                                 $signed({oki_lvl[20], oki_lvl});
    // 0.8 ≈ (>>1) + (>>2) + (>>4) = 0.8125
    wire signed [21:0] mix_08  = (mix >>> 1) + (mix >>> 2) + (mix >>> 4);

    wire signed [15:0] mono_out =
        (mix_08 >  22'sd32767)  ? 16'sh7FFF :
        (mix_08 < -22'sd32768)  ? 16'sh8000 :
        mix_08[15:0];

    assign audio_l = mono_out;
    assign audio_r = mono_out;

endmodule
