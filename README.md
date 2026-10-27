# ZX Spectrum 48K on the Sipeed Tang Primer 20K

A from-scratch ZX Spectrum 48K in Verilog for the Tang Primer 20K Dock
(GW2A-LV18PG256C8/I7): the authentic 16K ROM boots to the BASIC prompt on
HDMI, the keyboard is a web page over the USB-C serial port, and the board's
DDR3 is brought up and self-tested, ready for the cores that use it next.

```
     © 1982 Sinclair Research Ltd
```

## What it is

| Piece | What it does |
|---|---|
| `src/zx_core.v` | tv80 (Z80) at 3.5 MHz, 16K ROM + 48K RAM, the ULA's port `0xFE` (keyboard + border + beeper), 50 Hz interrupts |
| `src/zx_video.v` | the ULA picture: 256x192 doubled to 512x384 inside its border, on a 720x480p raster; the screen file's 64 bytes per line are prefetched during the left border |
| `src/zx_input.v` | the web keyboard's UART: 1 Mbaud, `FE <pos> <down>` matrix key events (no translation — the page does that) |
| `src/zx_uart_tx.v` | the boot banner the page probes for |
| `src/zx_ddr.v` | the DDR3 (adapted from the sibling project's proven `aux_ram.v`): calibrates, self-tests, exposes one client port |
| `src/hdmi/` | HDMI TX: TMDS encoders, data islands with 48 kHz audio (the beeper), AVI/ACR packets — shared with the sibling apple2e project and verified on this hardware |
| `web/` | the keyboard page: on-screen 40-key rubber keyboard, PC keyboard capture, paste-a-BASIC-listing |

## Build and load

Prerequisites: Gowin EDA 1.9.12 at `C:\Gowin\...` (as in the sibling project),
the OSS CAD Suite (`C:\oss-cad-suite`) for iverilog, node >= 20 for the web page.

```
make rom        # fetch + hash-verify the 48K ROM (not in the repo, see roms/README.md)
make            # synthesis + place & route + bitstream -> build\bitstream\zx_tp20k.fs
make load       # SRAM load over the BL702 (lost on power cycle)
make flash      # or: write the config flash (persistent)
```

`scripts/build.ps1` fails on any negative timing slack, so a green run means
the timing report was clean.

## Keyboard

Open the page, connect, and type on the Spectrum:

```
cd web
npm install
npm run dev      # http://localhost:5173
```

- **Connect** opens the Web Serial picker — pick the board's COM port. The
  page confirms it found the FPGA by waiting for the boot banner
  (`[ ZX Spectrum 20K ]`); if the banner is not in flight (the board has been
  up a while) it connects unverified and says so.
- Type on the on-screen rubber keyboard, or on your PC keyboard: left shift =
  CAPS SHIFT, right shift or alt = SYMBOL SHIFT, and a shifted symbol becomes
  the Spectrum's own chord (`"P` sends SYMBOL SHIFT+P, which is `"`).
- **Paste BASIC** types a listing at a rate the ROM's 50 Hz keyboard scan
  can follow.

- The link is raw Web Serial (115200 is *not* the rate — it is **1 000 000**
  8N1), and the board does no translation: it only sees matrix key events,
  like the real keyboard's membrane.  What a character *means* is the page's
  job (`web/src/zxkeys.js`).

Protocol, both ends (`web/src/protocol.js`, `src/zx_input.v`):

```
0xFE <pos> <down>   one key: pos = ZX matrix position row*5+col (0..39)
0xFF 0x04           all keys up
anything else       ignored
```

## Simulating

```
make sim                          # every testbench
sim\run.ps1 -Target tb_zx         # just the boot test
```

- `tb_zx` — **the acceptance test**: runs the 48K boot and asserts the
  authentic power-on screen (the ROM's own `© 1982 Sinclair Research Ltd`
  glyphs in the bottom character row, nothing else inked, the ROM-computed
  system variables, and the captured HDMI frame).  It dumps the whole 48K to
  `build/ram.hex` and one frame of the real video output to
  `build/frame.rgb`.  Then look at both:

  ```
  sim\render-screen.ps1                                  # RAM dump -> screen.png
  sim\render-screen.ps1 -Rgb build\frame.rgb -Out build\frame.png
  ```

  The suite runs it with `+fast=2` (a 27 MHz CPU: the ROM is
  speed-independent, and the boot is ~8x cheaper to simulate; it is also the
  memory path's minimum read margin).  The honest full-rate boot is
  `sim\run.ps1 -Target tb_zx` with `+fast=0 +ms=1800`, which takes a while --
  the ROM's RAM fill alone is ~600 ms of machine time at 3.5 MHz.
- `tb_video` — `zx_video`'s screen-file interleave: known pixel bytes at
  known (row, line, column) positions come out in exactly those cells.
- `tb_tv80` — tv80 against the strobe scheme `zx_core` uses (EXX shadow
  registers, ED-group stores, indexed BIT/SET/RES).

- `tb_ddr` — the DDR3 wrapper against the behavioural IP model.
- `tb_top` — the whole top level with the Gowin primitives modelled.
- `tb_*` on `src/hdmi` — the shared HDMI stack's own suite.

## Design notes

`docs/architecture.md` has the details; the two ways to load a tape are in
`docs/tape.md`.  The short version:

- Everything runs in one 27 MHz pixel-clock domain (rPLL to 135 MHz for the
  TMDS serializers, `CLKDIV /5` back down — the OSER10 PCLK/FCLK pair needs
  that hardware divider).  The CPU is a clock enable at 3.5 MHz, exactly 7/54
  of 27 MHz.
- One RAM serves both the CPU and the video: the ULA side owns its address
  port for the first 67 pixel clocks of each line while `zx_video` prefetches
  the line's 32 bitmap + 32 attribute bytes; the CPU is stalled there (~7% of
  the frame, in the spirit of ULA contention).  Because the CPU's address is
  stable for all 7-8 clocks between its enables, a synchronous (BSRAM) read
  is always final by the T-state that samples it -- no wait states.
- The 50 Hz interrupt is counted, not derived from the 59.94 Hz video; the
  two never need each other.
- tv80 is `Mode(0)` (Z80) with writes strobed once per machine cycle at
  `ts[2]`, the same proven pattern the sibling project's SoftCard uses.

## Status

- [x] 48K core runs the authentic ROM to the BASIC prompt: RAM test, UDG copy,
      screen clear, and the ROM's own "© 1982 Sinclair Research Ltd" in the
      bottom character row of an all-white display (`tb_zx` compares the
      glyphs to the ROM font, checks the attributes and the system variables,
      and checks the captured HDMI frame)
- [x] HDMI 720x480p with beeper audio; TMDS path verified in simulation
- [x] Display bring-up test pattern: hold S1 or S2 for colour bars + a 1 kHz
      tone, which bypasses the CPU/RAM/video entirely
- [x] Web keyboard + paste, protocol verified end to end
- [x] TV effect switches: DIP1 soft composite colour (luma on the DSP
      multipliers + a chroma smear), DIP2 25% scanlines — `tb_tv_fx` checks the
      numbers (`docs/architecture.md`)
- [x] Tape: one player (`src/tap_player.v`, real TAP pulse timing) with two
      sources — the **microSD card** (default; `ZXCONFIG.TXT` in the root says
      `TAPE=TAPE.TAP`, streamed by the sibling project's vendored SD/FAT32
      finder) or the **web page** (`ZX_TAPE_SD` off; the page feeds `.TAP`
      bytes over the keyboard UART and types `LOAD ""`).
- [x] Tape loading sound: the deck's speaker button mixes the EAR into the
      HDMI audio at `ZXCONFIG.TXT`'s `VOL=` (percent, 5 by default).- [x] Gowin build: timing clean, bitstream written
- [x] Lean by default: the unused DDR3 bring-up block is compiled out of the
      48K build (logic 26% → 16%, registers 14% → 6%, BSRAM 87% → 70%,
      IOLOGIC 62% → 4%, and no thin timing margin) — one `define` in
      `src/config.vh` brings it back; numbers in `docs/resources.md`
- [ ] First hardware bring-up (see `docs/bring-up.md`)

### Where the boot screen comes from

The screen is the ROM's, not ours.  `NEW` clears the display and prints
`© 1982 Sinclair Research Ltd` on the **bottom line** (`CLS` leaves the lower
print line at line 23, column 33), then opens channel K and waits for a key.
So the authentic power-on state is a white border, white paper and that one
line of black text at the bottom -- no report, no cursor until a key is
pressed.  Two variables that look wrong are right: `ERR_NR` is `0x00` at the
prompt (only `LINE_SCAN` writes `0xFF`, when the first line is scanned) and
`ERR_SP` is `0xFF50` (the ROM's `0xFF54` less `EDITOR`'s two pushes).

To look at it:

```
make sim                                 # every testbench, incl. the acceptance run
pwsh -File sim/render-screen.ps1         # build/ram.hex   -> build/screen.png
pwsh -File sim/render-screen.ps1 -Rgb build/frame.rgb -Out build/frame.png
```

`sim/tb_zx.v` also prints the ROM's system variables, and `+trace=1` logs
every system-variable write with the PC that made it; `sim/tb_dbg.v` samples
the PC and `sim/tb_ts.v` traces the bus in a window.  The boot is slow by
design (the ROM's RAM test walks all 48K twice), so the benches run the CPU
at 27 MHz (`+fast=2`, which is also the memory path's minimum read margin);
`+fast=0 +ms=1800` is the honest full-rate boot.

What is already ruled out: the CPU core (directed tests), LDIR/LDDR and
read-modify-write cycles, the interrupt path (the same state results with
`+noint=1`), and the memory read timing at both 13.5 and 27 MHz.

