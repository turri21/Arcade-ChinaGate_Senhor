# Arcade-ChinaGate_MiSTer

FPGA core for **China Gate** (Technos Japan, 1988) targeting the
[MiSTer FPGA](https://github.com/MiSTer-devel) platform (Terasic DE10-Nano).

China Gate (Japanese title: *Sai Yu Gou Ma Roku — Ryuu Bou You Gi no Shou*,
西遊降魔録 流棒妖技ノ章) is a side-scrolling action / beat-em-up arcade game
running on the same Technos hardware family as Double Dragon II: dual
HD63C09 main + sub CPUs sharing RAM, a Z80 sound subsystem driving YM2151
FM synthesis and an OKI M6295 ADPCM sample player. The core reimplements
the hardware in SystemVerilog from the MAME driver, the PCB schematics
and pixel-accurate validation against MAME and original PCB footage.

## Status

**Current version: 1.0** (May 2026) — first public release.

The core runs the full game with audio and inputs.

**Features**
- HD63C09 main CPU @ 1.5 MHz (cycle-accurate core)
- HD63C09 sub CPU @ 1.5 MHz (sharing RAM with main via the Technos
  bus-arbiter pattern)
- Z80 sound CPU @ 3.579545 MHz
- YM2151 FM (jt51) + OKI M6295 ADPCM (jt6295) with MAME-accurate mixer
- 256×240 active video area
- FG text layer, BG tilemap with X/Y scroll, 16×16 sprites
- MiSTer OSD with audio mixer (FM/OKI volume + Pickup/Gong attenuators)
- Pause overlay with logo + supporters scroll

**ROM sets supported**
- China Gate (US) — reference set (chinagat)
- Sai Yu Gou Ma Roku (Japan) — original Japanese release (saiyugou)

## Hardware emulated

| Component        | Spec                                                |
|------------------|-----------------------------------------------------|
| Master clock     | 12 MHz crystal (video) + 3.579545 MHz (sound)       |
| Main CPU         | HD63C09 @ 1.5 MHz                                   |
| Sub CPU          | HD63C09 @ 1.5 MHz (shared RAM with main)            |
| Sound CPU        | Z80 @ 3.579545 MHz                                  |
| Sound chip 1     | Yamaha YM2151 (jt51)                                |
| Sound chip 2     | OKI M6295 (jt6295) ADPCM, pin7=HIGH, ~1.056 MHz     |
| Video resolution | 256×240 active                                      |
| Refresh rate     | ~57 Hz                                              |
| FG layer         | 4bpp text/HUD layer                                 |
| BG layer         | 4bpp tilemap with X/Y scroll                        |
| Sprites          | 4bpp 16×16, with horizontal/vertical flip          |

## Hardware requirements

- Terasic DE10-Nano
- MiSTer I/O board (recommended)
- Works on HDMI displays and on 15 kHz CRTs via the analog video output

## Building from source

Requires Quartus Prime 17.0 (free Lite Edition).

```
Open ChinaGate.qpf in Quartus → Processing → Start Compilation
```

Output bitstream is generated in `output_files/ChinaGate.rbf` (~3.7 MB).

## Running on MiSTer

The [releases/](releases/) folder contains the parent MRA for the
reference ROM set:

- `China Gate (US).mra` — parent MRA (reference set)

Alternative ROM sets are provided in [releases/alternatives/](releases/alternatives/):

- `China Gate - Sai Yu Gou Ma Roku (JP).mra` — Japanese release (saiyugou)

Following the MiSTer-devel convention, the alternative sets can be also
mirrored to the official [MRA-Alternatives_MiSTer](https://github.com/MiSTer-devel/MRA-Alternatives_MiSTer)
repository, where they are picked up automatically by **Update_All**.

Steps:

1. Copy the `.rbf` to `_Arcade/cores/` on the MiSTer SD card.
2. Copy the desired `.mra` file(s) to `_Arcade/` on the MiSTer SD card.
3. Provide your legally-owned China Gate ROM files where each MRA
   expects them (usually in `games/mame/`).

**ROMs are NOT included in this repository.** You must provide them yourself.

## Repository layout

```
Arcade-ChinaGate_MiSTer/
├── rtl/
│   ├── chinagate/    China Gate-specific core RTL
│   ├── pll/          Clock PLL
│   ├── sound/        Sound chip cores (jt12, jt51, jt5205, jt6295, t80)
│   └── sdram.sv      SDRAM controller (Sorgelig)
├── jtframe/          JTFRAME framework modules
├── sys/              MiSTer framework (Sorgelig / MiSTer-devel)
├── logo/             Pause overlay assets (font, logo, supporter list)
├── releases/         Parent MRA + alternatives
│   └── alternatives/ MRA files for alternate ROM sets
├── ChinaGate.qpf     Quartus project
├── ChinaGate.qsf     Quartus assignments
├── ChinaGate.sv      Top-level wrapper
├── Template.sdc      Timing constraints
├── files.qip         HDL file list
├── build_id.v        Build version stamp
└── README.md         This file
```

## Acknowledgements

- **Jose Tejada** ([@jotego](https://github.com/jotego)) for JT51 (YM2151),
  JT6295 (OKI M6295), JT12, JT5205 and the JTFRAME framework.
- **Greg Miller** for the cycle-accurate MC6809 / HD63C09 core.
- **Daniel Wallner** and **MikeJ** for the T80 (Z80) core.
- **Sorgelig** and the **MiSTer-devel team** for the framework, SDRAM
  controller and Template.
- The **MAME** project for invaluable hardware reference (chinagat.cpp,
  ddragon.cpp, ddragon_v.cpp).

## Support this project

If you enjoy this core and want to support its development:

- [Ko-fi](https://ko-fi.com/ibecerivideoludici) — one-time support
- [Patreon](https://www.patreon.com/IBeceriVideoludici) — monthly support
- [PayPal](https://www.paypal.me/IBeceriVideoludici) — one-time donation

## Follow

- [Twitch](https://twitch.tv/ibecerivideoludici) — live streams
- [YouTube](https://www.youtube.com/c/IBeceriVideoludici/playlists) — playlists and videos

## License

The RTL source code in this repository is provided as-is for educational
and preservation purposes. Original ROM data is not included; users must
provide their own legally obtained copies.

Original China Gate / 西遊降魔録 arcade hardware © Technos Japan Corp., 1988.
