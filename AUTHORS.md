# Authors and Credits

## ChinaGate_MiSTer core

**Author**: Umberto Parisi ([rmonic79](https://github.com/rmonic79))

The original RTL source files for the China Gate-specific logic (under
`rtl/chinagate/` and the project wrapper `ChinaGate.sv`) are copyright
Umberto Parisi and distributed under GNU GPL v3 or later.

## Third-party components

This core builds on top of excellent open-source projects. All third-party
sources retain their original copyright and license. The core as a whole
is distributed under **GNU GPL v3 or later** to stay compatible with the
most restrictive upstream (JTFRAME / JTCORES).

| Component | Author | Project | License |
|-----------|--------|---------|---------|
| **MC6809 / HD63C09** — cycle-accurate 6809 core | Greg Miller | [cavnex/mc6809](https://github.com/cavnex/mc6809) | GPL-3 |
| **T80** — Z80 core | Daniel Wallner, MikeJ | [MiSTer-devel/T80](https://github.com/MiSTer-devel/T80) | BSD / GPL |
| **JTFRAME / JTCORES** — framework, filters, tilemap, etc. | Jose Tejada ([@topapate](https://twitter.com/topapate)) | [jotego/jtcores](https://github.com/jotego/jtcores) | GPL-3 |
| **JT51** — YM2151 FM synthesizer | Jose Tejada | [jotego/jt51](https://github.com/jotego/jt51) | GPL-3 |
| **JT6295** — OKI M6295 ADPCM sample player | Jose Tejada | [jotego/jt6295](https://github.com/jotego/jt6295) | GPL-3 |
| **JT5205** — MSM5205 ADPCM (used in some bootlegs) | Jose Tejada | [jotego/jt5205](https://github.com/jotego/jt5205) | GPL-3 |
| **JT12** — YM2203/YM2612 FM synthesizer family | Jose Tejada | [jotego/jt12](https://github.com/jotego/jt12) | GPL-3 |
| **sdram.sv** — SDRAM controller | Sorgelig ([sorgelig](https://github.com/sorgelig)) | [MiSTer-devel](https://github.com/MiSTer-devel) | GPL-3 |
| **sys/ framework** — MiSTer HPS/IO, OSD, video scaler, audio | Sorgelig / MiSTer-devel | [MiSTer-devel/Main_MiSTer](https://github.com/MiSTer-devel/Main_MiSTer) | GPL-3 |

## Reference

- **China Gate / 西遊降魔録 arcade hardware** — Technos Japan, 1988.
  This FPGA core is a reimplementation from hardware documentation, MAME
  source code (chinagat.cpp, ddragon.cpp, ddragon_v.cpp), the Z80 sound
  ROM disassembly and observation of real hardware behavior. ROMs are
  **not** included and must be provided by the user.
- **MAME project** — invaluable reference for memory maps, timing,
  and driver behavior. [mamedev/mame](https://github.com/mamedev/mame)
