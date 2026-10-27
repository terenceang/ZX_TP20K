# ZX Spectrum 48K on the Sipeed Tang Primer 20K

A from-scratch ZX Spectrum 48K in Verilog for the Tang Primer 20K Dock
(GW2A-LV18PG256C8/I7): the authentic 16K ROM boots to the BASIC prompt on
HDMI, the keyboard and tape deck are a web page over the USB-C serial port,
and tapes come off a microSD card into the board's DDR3.

```
     © 1982 Sinclair Research Ltd
```

## What it is

| Piece | What it does |
|---|---|
| `src/zx_core.v` | tv80 (Z80) at 3.5 MHz, 16K ROM + 48K RAM, the ULA's port `0xFE` (keyboard, border, beeper, EAR), 50 Hz interrupts, the instant-load trap |
| `src/zx_video.v` | the ULA picture: 256x192 doubled to 512x384 inside its border, on a 720x480p raster; the screen file's 64 bytes per line are prefetched during the left border |
| `src/zx_input.v` | the page's UART: 1 Mbaud, `FE <pos> <down>` matrix key events (no translation — the page does that) and the deck's `FB` commands |
| `src/zx_tape_lib.v`, `zx_tape_mem.v`, `tap_player.v`, `src/sd/` | the tape library: the card's files listed to the page, the chosen tape held in DDR3, played with real TAP timings; a raw sector bridge lets the page write the card |
| `src/zx_snap.v`, `src/zx_scr_cap.v` | snapshot injection (`.Z80` and instant load) and screen capture over the same UART |
| `src/zx_ddr.v` | the DDR3 (adapted from the sibling project's proven `aux_ram.v`): calibrates, self-tests, one client port |
| `src/hdmi/` | HDMI TX: TMDS encoders, data islands with 48 kHz audio (the beeper and the tape), AVI/ACR packets — shared with the sibling apple2e project |
| `web/` | the page: 40-key rubber keyboard, PC keyboard capture, paste-a-listing, the tape deck and library, instant load, screen capture |

## Build and load

Prerequisites: Gowin EDA 1.9.12 at `C:\Gowin\...` (as in the sibling project),
the OSS CAD Suite (`C:\oss-cad-suite`) for iverilog, node >= 20 for the web page.

```
make rom        # fetch + hash-verify the 48K ROM (not in the repo, see roms/README.md)
make build      # synthesis + place & route + bitstream -> build\bitstream\zx_tp20k.fs
make load       # SRAM load over the BL702 (lost on power cycle)
make flash      # or: write the config flash (persistent)
```

`scripts/build.ps1` fails on any negative timing slack, so a green run means
the timing report was clean.  First time on a board: `docs/bring-up.md`.

## The page

```
cd web
npm install
npm run dev      # http://localhost:5173
```

- **Connect** opens the Web Serial picker (Chrome/Edge) — pick the board's
  COM port.  The page confirms it by waiting for the boot banner
  (`[ ZX Spectrum 20K ]`); a board that has been up a while has already
  printed it, so the page connects unverified and says so.
- Type on the on-screen rubber keyboard or on your PC keyboard: left shift =
  CAPS SHIFT, right shift or alt = SYMBOL SHIFT, and a shifted symbol becomes
  the Spectrum's own chord (`"` sends SYMBOL SHIFT+P).  **Paste BASIC** types
  a listing at a rate the ROM's 50 Hz keyboard scan can follow.
- **Tapes**: the library lists the card's `.TAP`/`.TZX`/`.Z80` files.  Load
  one into the deck and press `LOAD ""`, or **Instant** to load it in a second
  or two.  **Upload to Card** and the delete buttons manage the card from the
  page.  All of it: `docs/tape-library.md`.

The link is 1 000 000 baud 8N1 (not 115200), and the board does no key
translation: it only sees matrix key events, like the real membrane.  What a
character *means* is the page's job (`web/src/zxkeys.js`).  The full wire
protocol is in `docs/tape-library.md`; the keyboard's part:

```
0xFE <pos> <down>   one key: pos = ZX matrix position row*5+col (0..39)
0xFF 0x04           all keys up
```

## Simulating

```
make sim                          # every testbench
sim\run.ps1 -Target tb_zx         # just the boot test
cd web; npm test                  # the page's protocol, keymap, card and tape tests
```

`tb_zx` is **the acceptance test**: it boots the real ROM and asserts the
authentic power-on screen — the ROM's own `© 1982 Sinclair Research Ltd`
glyphs in the bottom character row, nothing else inked, the ROM-computed
system variables, and the captured HDMI frame.  Look at it with:

```
sim\render-screen.ps1                                  # build\ram.hex -> build\screen.png
sim\render-screen.ps1 -Rgb build\frame.rgb -Out build\frame.png
```

`sim/README.md` lists every bench and what "booted" means exactly.

## Design notes

`docs/architecture.md` has the details.  The short version:

- Everything ZX runs in one 27 MHz pixel-clock domain (rPLL to 135 MHz for the
  TMDS serializers, `CLKDIV /5` back down — the OSER10 PCLK/FCLK pair needs
  that hardware divider).  The CPU is a clock enable at 3.5 MHz, exactly 7/54
  of 27 MHz.
- One RAM serves both the CPU and the video: `zx_video` owns its address port
  for the first 64 pixel clocks of each line while it prefetches the line's
  32 bitmap + 32 attribute bytes, and the CPU resumes at 66.  Because the
  CPU's address is stable for all 7-8 clocks between its enables, a
  synchronous (BSRAM) read is always final by the T-state that samples it —
  no wait states.
- The 50 Hz interrupt is counted, not derived from the 59.94 Hz video; the
  two never need each other.
- tv80's read bus is latched (`di_q`), because tv80 takes a read's byte one
  T-state after the data phase.

`docs/resources.md` has the utilisation and timing; `docs/pinout.md` the pins.

## Status

- [x] 48K core runs the authentic ROM to the BASIC prompt (`tb_zx`)
- [x] HDMI 720x480p with beeper audio; hold S1 or S2 for colour bars and a
      1 kHz tone, which bypasses the CPU, RAM and video
- [x] Web keyboard + paste
- [x] Tape library: card → DDR3 → player with real TAP timings, `LOAD ""`
      starts the deck, tape audio over HDMI at `ZXCONFIG.TXT`'s `VOL=`
- [x] Card management from the page (upload, delete) over the raw sector bridge
- [x] `.Z80` snapshots, instant load of `.TAP`/`.TZX` (with the DivMMC-style
      trap for multi-loads), screen capture
- [x] On hardware: boots, types, loads tapes (normal and instant)
- [ ] 128K (banks in the DDR3)
