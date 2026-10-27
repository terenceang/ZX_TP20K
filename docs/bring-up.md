# Bring-up

The first time the bitstream meets the board.  Do things in this order; each
step has a visible symptom if the previous one is broken.

## 0. What you need

- Tang Primer 20K Dock + SOM, HDMI monitor, USB-C cable to the PC
- `build\bitstream\zx_tp20k.fs` from a green `make`
- the web page (`cd web && npm install && npm run dev`)

## 1. Load and look at the LEDs

```
make load
```

| LED | Meaning | Good |
|---|---|---|
| 0 (C13) | PLL not locked | **off** |
| 1 (A13) | DDR3 not ready | **off** — after ~1 s of calibration in a `ZX_USE_DDR3=1` build; tied off ("ready") in the lean default build, which has no DDR3 block (see `docs/resources.md`) |
| 2 (N16) | CPU HALT | breathing — the editor HALTs between 50 Hz interrupts |
| 3 (N14) | FLASH phase | blinking at ~1.5 Hz once BASIC is up |
| 4 (L14) | keyboard traffic | lights for ~1/4 s after each UART key packet |
| 5 (L16) | spare | off |

## 2. The screen

A good boot is the authentic 48K power-on screen: a white border, a white
display, and `© 1982 Sinclair Research Ltd` in the **bottom character row**.
That is where the ROM puts it: `NEW` prints the message at 0x1295 after
`CLS` has left the lower print line at line 23, column 33 (`0DAA: LD
BC,$1721`), and it then opens channel K and waits for a key.  There is no
report and no cursor until a key is pressed.

It takes a few seconds: the 48K ROM's power-on RAM test fills all 48K with
`$02`, walks it decrementing each byte, and does it again for the size
detection -- several million T-states at 3.5 MHz.  During that the screen
still holds the RAM-test pattern and the border strobes with it; the © line
appears at the end, on a clean white screen.

Symptoms:

| Symptom | First suspect |
|---|---|
| No sync at all | HDMI lanes: check the `.cst` pairs (G16/H15, H14/H16, J15/K16, K14/K15), `TLVDS_OBUF` + `LVDS25 DRIVE=3.5` |
| Sync but no picture, LEDs frozen | `clk_pixel` is not from the `CLKDIV` — check `clk_gen.v` is unchanged |
| Picture garbled in 8-pixel stripes | the screen-file interleaving in `zx_video.v` — `tb_video` proves the mapping |
| © line in the wrong row, or only partly drawn | the same interleaving: the © line lives at 0x50E0 + line*0x100, and `tb_video` puts known bytes in known cells |
| Picture doubled wrong / border offset | the X0/Y0 parameters |
| Boot hangs at black | the CPU: run `tb_zx` — if the sim boots, suspect the DDR3 PLL's interference or power; if the sim fails too, it is RTL |
| S♥ft w♥rd b♥oken per character row | an attribute fetch address (0x5800 block) |

## 2b. The TV effect switches

| DIP | Off | On | What you should see |
|---|---|---|---|
| 1 | sharp RGB | soft composite | colours bleed sideways, white stays white (try a red pixel on white) |
| 2 | scanlines off | 25% darker | alternate raster lines slightly dimmer |
| 4 | — | flip on → the board **types `LOAD ""` + ENTER** itself, once |
| 5 | tape waits for `LOAD ""` | tape rolls from reset | with 5 off the deck starts when the ROM enters LOAD; with 5 on it is already running |

DIP3 (E8) is spare.  With a tape on the card, the whole load is then: card in,
reset, wait for the prompt, **flip DIP4**.  All are 1.5 V bank inputs with pull-downs, so an unpopulated switch
reads as off.

## 2c. Colour bars and the 1 kHz tone (S1 or S2)

Hold **S1 (T3)** or **S2 (T2)** and the HDMI output switches to a test pattern
instead of the Spectrum: eight full-range vertical bars, a white 1-pixel border
around the active area, and a blinking 40x40 box top-left so a frozen picture is
obvious — plus a 1 kHz square wave instead of the beeper.  Release to go back.

This is the "is it the display or the design?" check: it bypasses the CPU, the
RAM and the video pipeline entirely (only the clocking, TMDS serialisers and the
audio packets are in the path).  `src/colorbar_gen.v` is the sibling project's
generator, unchanged; the tone is 24 samples per half period on the 48 kHz
strobe (1 kHz).

## 3. The DDR3

The DDR3 block is **not in the default build** (`src/config.vh` has
`ZX_USE_DDR3` commented out): nothing in the 48K machine uses it, and leaving
it out saves 26% of the logic, 58% of the registers, 8 BSRAMs and the tightest
timing path — see `docs/resources.md`.  Define `ZX_USE_DDR3` and rebuild for
the checks below; in the lean build LED 1 is simply off.

LED 1 off means the wrapper's self-test passed (calibration + patterned
burst + masked write).  This board's DDR3 is picky about IP generation: this
project vendors the same 1.9.8 netlist the sibling project calibrated with —
do not regenerate the IP with 1.9.12 (see `src/ddr3_memory_interface/README.md`).

If LED 1 stays on: the wrapper's `diag` port is a static 32-bit word for
exactly this moment — `{8'hD3, 8'd0, calib, ready, tst, tbad, tval, ...}`.
`tst` says which of the four self-test steps failed (0 write, 1 read,
2 masked write, 3 read); `tval` is the first wrong word.  A failure at
calibration (`calib` never rising) is a board/IP problem, not RTL: re-seat
the SOM, check the DDR3 balls against Sipeed's example.

## 3b. The tape

The default build plays a tape off the microSD card.  Format the card FAT32 and
put two files in the root:

```
ZXCONFIG.TXT     containing:  TAPE=TAPE.TAP
TAPE.TAP         the tape image (8.3 name, under 1 MB)
```

Then reset the board, wait for the ZX prompt, and type `LOAD ""` + ENTER: the
deck starts *on that keypress* (the board watches the ROM enter LD-BYTES), so
the leader tone always begins when the Spectrum is listening.  LED5 is on while
it plays.  With DIP5 ON it rolls from reset instead.

Checks, in order: LED5 or not; that the card mounted at all (a FAT32 volume with
the config in the root); that `ZXCONFIG.TXT` says `TAPE=` with an 8.3 name; that
the file is one contiguous run of clusters (a file freshly copied to an empty
card is; one that has been appended to may not be — the sibling project's
`web/src/fat32.js` can reorganise it).

To use the web instead, comment out `ZX_TAPE_SD` in `src/config.vh`: the page
then grows a **Load tape (.tap)** button that feeds the same player over the
keyboard's UART and types `LOAD ""` for you.

## 4. The keyboard

Open the page: it connects by itself to a port this browser has already been
given (Web Serial's getPorts, no picker), so after the first visit the board
is picked up as the page loads.  The very first visit needs **Pick port** --
that is the browser's rule, not the page's -- and every reload after it is
automatic.  If the page says *no port yet* after a reload, the port grant was
forgotten: click **Pick port** once more.

To choose a different port, Disconnect and Pick port again.  If no port answers with the
banner, the page says `unverified` — that is normal on a board that has been
up for a while (the banner prints once, after reset); the port is still
probably right, and any key you type will move LED 4.

The on-screen keyboard is drawn from `web/src/zxkeys.js`: `KEYS` is the 8x5
matrix (what gets sent), `LAYOUT` is the four rows of ten as the 48K case
prints them — colour word and white function above the number keys, the green
SYMBOL SHIFT keyword above the letters, the orange symbol on the key face, the
white CAPS SHIFT keyword beneath it, the extended-mode word below.  Legends
are allowed to spill into the gap between keys, as they do on the real case, so
fix a label there rather than in the component or the stylesheet.

Nothing types?  Check the rate first: the FPGA's UART is **1 000 000** 8N1.
A terminal set to 115200 will produce garbage packets (which the FPGA drops,
unless the garbage happens to start with 0xFE).

In BASIC, a quick end-to-end check:

```
10 PRINT "HELLO "
20 GOTO 10
RUN
```

via the paste box, or typed.  Remember the Spectrum's own rules: the first
letter of each keyword comes out as the keyword itself (P in K-mode is
PRINT), `"` is SYMBOL SHIFT+P, and ENTER is the wide key under `;`.

## 5. Reset

S0 (T10) resets the Spectrum (not the DDR3 — its contents survive, like the
sibling project's aux RAM).  If the machine ever wedges, S0 is the way out;
RECONFIG (S4, B10) reloads the FPGA entirely.
