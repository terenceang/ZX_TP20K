# sim/

Testbenches (iverilog, via `sim\run.ps1` or `make sim`) and the tooling
around them.

| Testbench | What it proves |
|---|---|
| `tb_zx.v` | **the acceptance test**: the 48K ROM boots to the authentic power-on screen — the ROM's own "© 1982 Sinclair Research Ltd" glyphs in the bottom character row of an all-white display, nothing else inked, and the system variables the ROM's start-up code computes |
| `tb_type.v` | types the web page's LOAD "" macro (web/src/zxkeys.js pacing) into the real ROM and checks the editor line and the `tape_load` pulse |
| `tb_video.v` | `zx_video`'s screen-file interleave: known pixel bytes at known (row, line, column) positions come out in exactly those character cells of the 720x480 frame |
| `tb_input.v` | the web keyboard's UART: `FE <pos> <down>` chords, `FF 04`, and that anything else is ignored |
| `tb_ddr.v` | `zx_ddr` against the behavioural IP model: self-test, write/read-back, masked writes |
| `tb_top.v` | the whole top level elaborates; PLLs lock; frames arrive; pixels are palette-legal; TMDS clock lane toggles |
| `tb_tv80.v` | tv80 against the strobe scheme `zx_core` uses: EXX/shadow registers, ED-group stores, indexed BIT/SET/RES on IY |
| `tb_dbg.v`, `tb_ts.v` | development probes (not in the pass/fail suite): instruction trace, T-state/bus trace — run them directly when a boot misbehaves |
| `tb_tmds_encoder`, `tb_packet_ecc`, `tb_packets`, `tb_data_island` | the shared HDMI stack's own suite (same files as the sibling project) |

## What "booted" means

The 48K ROM's start-up (`NEW` at 0x11B7) clears the display and then prints
one message: at 0x1295 it loads `DE=0x1538` and calls `PO_MSG`, which prints
`© 1982 Sinclair Research Ltd`.  `CLS` left the lower print line at line 23,
column 33 (`0x0DAA: LD BC,$1721`), so the message lands in the bottom
character row and the print position ends one cell past its last glyph.
Then the ROM opens channel K and waits for a key (`WAIT_KEY` at 0x15D4).

So the authentic power-on screen is: white border, white paper, and the
copyright line in the bottom row — no report, no cursor, until a key is
pressed.  `tb_zx` checks exactly that, four independent ways:

* every glyph of the line equals the ROM font's byte pattern
  (`0x3D00 + (char-0x20)*8`)
* nothing else in the 6144-byte display file is inked
* all 768 attribute cells are `0x38` (paper 7, ink 0, from `ATTR-P`)
* the system variables hold the values the ROM's own instructions compute:
  `RAMTOP=0xFF57`, `DF_CC=0x4000`, `S_POSN=33/24`, `DF_CCL=0x50FC`,
  `S_POSNL=5/23`, `VARS=PROG=0x5CCB`, `E_LINE=0x5CCC`, `STKBOT=0x5CCE`,
  `CHARS=0x3C00`, `ERR_NR=0xFF`, `DF_SZ=2`, `TV_FLAG=0x21`,
  `ERR_SP=0xFF50` (the editor's two pushes below the ROM's 0xFF54)

and then that the captured HDMI frame carries that ink in the bottom
character row only, over nothing but the plain white the border and paper
produce.

## Seeing the boot

`tb_zx` dumps the whole 48K to `build/ram.hex` every 100 ms and writes one
720x480 RGB frame of the real video output to `build/frame.rgb` at the end:

```
sim\render-screen.ps1                                  # build\ram.hex -> build\screen.png
sim\render-screen.ps1 -Rgb build\frame.rgb -Out build\frame.png
open build\frame.png                                   # what the HDMI sink would show
```

The RAM dump is the raw 48K: the screen file sits at offset 0 (address
0x4000) as 6144 bitmap bytes then 768 attribute bytes, in ZX interleaved
order (see `zx_video.v` for the address bits), and the system variables are
at offsets 0x1C00-0x1CFF (addresses 0x5C00-0x5CFF).

## Timing notes

The 48K's boot is *slow by design*: the ROM's power-on RAM test fills 0x02
down from 0xFFFF to 0x4000 (one byte per 32 T-states, ~450 ms), walks the
whole 48K decrementing each byte, and runs a second pass for the size
detection -- a few seconds of machine time at 3.5 MHz in total.  `tb_zx`
runs with `+fast=2` (CPU enable every clock = 27 MHz; the ROM is
speed-independent, and the boot takes ~240 ms of simulated time instead of
~1.8 s), which is also the memory path's minimum read margin.  `+ms=<n>`
sets the window, and the watchdog fires 300 ms later.  For the honest
full-rate boot use `+fast=0 +ms=1800`.
