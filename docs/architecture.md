# Architecture

One clock, one CPU enable, one shared RAM.  The interesting parts are the
video fetch arbitration, why the CPU needs no wait states, and where the
borders of the simplifications are.

## Clocks

```
27 MHz (H11)
  |
  +-- rPLL x5 --> 135 MHz clk_tmds --+
  |                                  |  CLKDIV /5
  |                                  v
  +-- rPLL -------> 398.25 MHz ddr_memory_clk     (DDR3 IP; its clk_out
                                                   is mclk ~99.56 MHz)
clk_pixel = 27 MHz, everything ZX runs here
```

`clk_pixel` is deliberately derived from `clk_tmds` through the hardware
`CLKDIV`, not tapped off the crystal: OSER10 needs PCLK and FCLK phase-locked
through one divider, and two independently-routed 27 MHz nets lose that
alignment (seen on hardware as the display dropping in and out of sync).

Clock enables in the pixel domain:

| Enable | Rate | Math |
|---|---|---|
| `ce_cpu` | 3.5 MHz | 7/54 of 27 MHz, fractional accumulator |
| `ce_48k` | 48 kHz | 16/9000, feeds the HDMI audio packets |

The CPU is thus not a clock domain at all: tv80 advances on `cen` and its
address holds still for 7-8 pixel clocks around each T-state.  That property
is load-bearing twice (below).

## Memory map and the shared RAM

```
0x0000-0x3FFF   ROM, 16K, roms/zx48.hex ($readmemh -> BSRAM)
0x4000-0xFFFF   RAM, 48K (BSRAM); screen file at 0x4000-0x5AFF
```

One 48K RAM array, one port.  Every line of the 720x480 raster:

```
x:    0 ......... 63 | 67 ..................... 719 | 720....857
      ULA prefetch   |   CPU enabled                | blanking
      (CPU stalled)  |
```

`zx_video` spends the left border reading the line's 32 bitmap bytes and 32
attribute bytes into registers (64 reads, one per clock, done by x = 64).
During that window the RAM's address port is the video's; the CPU's `cen` is
masked.  The two boundaries are deliberately different clocks:

- the address **mux** hands back to the CPU at x = 64 (the last video read is
  at x = 63);
- the CPU's **enable** waits until x = 66, because the byte a T-state samples
  at its edge was registered on the clock before it: with the mux switching
  at 64 the read is valid at 65, so the CPU may sample from 66.

Gating both at the same x corrupts one byte per line -- the CPU latches the
video's byte instead of its own -- which shows up as stray bits in system
variables and a ROM that reaches the editor with a broken pointer.

The stall costs about 8% of the frame's T-states.  It is also a nod to the
real ULA, which stalls the CPU for every contended cycle; the 48K ROM and
BASIC are entirely indifferent to it.

### Why no wait states

tv80's address is registered when a T-state advances and is sampled one
T-state later (data is taken at `ts[2]`).  Between those edges lie 7-8 pixel
clocks, and the RAM's registered read re-samples the (stable) address every
one of them -- so by the sampling edge the read data is final.  A
synchronous BSRAM therefore behaves like combinational memory from tv80's
point of view.  Writes fire once per machine cycle on `ce && ts[2]` (the
microcode holds `write` for the whole cycle; `ts[2]` catches it once), the
same pattern the sibling project's SoftCard uses.

### The read bus must be *held*, not just presented

tv80 takes a read's byte home one T-state **after** the data phase, through
`DI_Reg`, which is `di` sampled combinationally at that later edge -- by
which time the address has already moved to the next fetch.  Feeding tv80
the live bus therefore loads the *next opcode* into whatever register the
instruction was writing: `LD A,n` loads the following opcode, and the ROM's
RAM fill (`LD (HL),n` in a tight loop) writes opcode bytes instead of its
operand.  The symptom is a CPU that walks a plausible instruction stream
while all its data is wrong.

The fix is the latch the sibling project wraps around tv80: during the read
cycle's T3 the data bus is live on `di`, and a register (`di_q`) latches it
at that same edge and holds it until the next read.  `mem_dout`/`io_dout`
are muxed into `di_q` by `is_rd` (M1, memory read or I/O read, but never an
interrupt acknowledge).


### Why the video needs no line buffer

A ZX line is 64 bytes (32 bitmap + 32 attributes).  The prefetch window is
64 clocks and display starts at x = 104 -- 40 clocks of slack -- so the
whole line sits in 64 bytes of registers, read back through a 32:1 mux at
2x scaling.  No second RAM port, no BSRAM for the display path.

## The ULA's ports

Decoding is `A0 = 0` (as on hardware, which ignores A1-A7 on the ULA):

```
IN  0xFE   bits 4:0 = keyboard columns of the row(s) in ~A[15:8]
           bit 6 = EAR (idle high), bits 5,7 = 1
OUT 0xFE   bits 2:0 border, bit 4 beeper
```

The keyboard is the 8x5 matrix; `zx_input` supplies a 40-bit pressed-map and
`zx_core` ORs the selected rows out of it.  The ROM scans one row per read;
chords (CAPS SHIFT + keys) work because the web page holds every key down
until its release packet.

Interrupts: a 540 000-count divider at 27 MHz is exactly 50 Hz; `/INT` is
held for 32 CPU T-states, like the ULA's.  The video frame is 59.94 Hz --
deliberately unrelated.  Nothing in the 48K can tell, and keeping them
uncoupled means a video mode change never disturbs the interrupt rhythm.

## Video path

`hdmi_tx` owns the 720x480p raster (CEA VIC 2, 27 MHz pixel / 135 MHz TMDS)
and calls back with active-pixel coordinates.  `zx_video` answers with:

- the ULA palette (3 bits + BRIGHT at 0xC0/0xFF levels), border non-bright,
- the picture at 2x, 512x384 at (104, 48),
- FLASH phase at ~1.5 Hz.

HDMI audio carries the beeper: the 1-bit speaker sampled at 48 kHz into the
audio sample packets, so `BEEP` is audible on the display's speaker.  With
the tape deck's speaker button on (`FB 41`; `FB 61` turns it off) the EAR is
mixed in too, as the ULA feeds EAR to the real speaker, so a load sounds like
one.  Its level is `ZXCONFIG.TXT`'s `VOL=` (percent of full scale, 5 by
default); it scales the tape only — the beeper stays at ±7000 — and the sum
saturates rather than wraps above about `VOL=78`.

## The television (DIP switches)

`zx_tv_fx.v` sits between the ULA's RGB and the HDMI transmitter.  Two DIP
switches select what it does (Documents/pinout.md):

| DIP | Signal | Off | On |
|---|---|---|---|
| 1 (C7) | `sw_color_tv` | sharp RGB | soft composite: colours bleed sideways |
| 2 (E9) | `sw_scanline` | scanlines off | 25% darker on alternate raster lines |

DIP3 (E8), DIP4 (T4) and DIP5 (T5) are free: a Spectrum had a colour TV or a
colour monitor, never a monochrome terminal, so there are no phosphor modes.

The colour mode is the interesting one.  Composite video keeps full luma but
only about 1.3 MHz of chroma, so colours smear sideways while the picture
stays sharp.  That is done properly: luma `Y = 77R + 150G + 29B` on the DSP
multipliers, chroma as `R-Y` and `B-Y`, a 2-tap chroma filter across output
pixels (half a ZX pixel at the 2x upscale), then back to RGB with shift-add
reconstruction (`G = Y - 0.509Cr - 0.186Cb`, and the 0.509/0.186 are
1/2+1/128 and 1/8+1/16).

The stage is pipelined three deep so the multiplier chain fits the 27 MHz
pixel clock (it was 20 MHz with everything in one path).  **The latency is
compensated in `zx_video`'s `X0`**: `zx_core` instantiates the video with
`X0 = 104 - 3`, so the picture stays at x = 104..615 on the raster.

Scanlines are a shift (`c - c/4` on odd lines), so they cost nothing.

### Test pattern

`src/colorbar_gen.v` (the sibling project's, unchanged) draws 720x480 colour
bars, a white active-area border and a blinking liveness box combinationally
from `(pixel_x, pixel_y)`.  `zx_top` muxes it in front of the HDMI transmitter
when **S1 (T3)** or **S2 (T2)** is held, and swaps the beeper for a 1 kHz
square (24 samples per half period on the 48 kHz strobe).  That path exercises
only the clocks, the TMDS serialisers and the audio packetiser, so a bad picture
there is the display/board, not the Spectrum.

## The power-on screen

What appears at power-up is entirely the ROM's doing, and knowing the exact
state makes the acceptance test possible.  `NEW` (0x11B7) determines RAMTOP,
initialises the system variables, clears the display (`CLS`, 0x0D6B) and
then prints one message:

```
1295  XOR A             ; message 0
1296  LD DE,$1538       ; the message table entry
1299  CALL PO_MSG       ; "© 1982 Sinclair Research Ltd"
129C  SET 5,(IY+$02)    ; TV-FLAG: the lower part will need clearing
12A0  JR MAIN_1         ; then channel K, and the editor waits for a key
```

`CLS` ends with `LD BC,$1721` (0x0DAA) -- line 23, column 33, the lower
print line -- so the message lands in the **bottom character row** and the
print position ends one cell past its 28th glyph.  The screen file therefore
holds, at 0x50E0 + line*0x100, the ROM font bytes for
`© 1982 Sinclair Research Ltd` and nothing else; every attribute cell is
`0x38` (paper 7, ink 0).  The border is white (`OUT (0xFE),7` at 0x11CE).

The resulting system variables are equally specific, and `tb_zx` asserts
them:

| Variable | Value | Why |
|---|---|---|
| `RAMTOP` (0x5CB2) | `0xFF57` | the 48K RAM test passed; the top 168 bytes are the UDG area |
| `ERR_NR` (0x5C3A) | `0x00` | the RAM test leaves RAM zeroed and the start-up never writes it; `LINE_SCAN` (0x1B1E) is the first code to store `0xFF` |
| `ERR_SP` (0x5C3D) | `0xFF50` | `0xFF54` from 0x122B, less `EDITOR`'s two pushes (0x0F2F-0x0F34), under `MAIN_2`'s `CALL EDITOR` return address |
| `DF_CC` (0x5C84) | `0x4000` | `CL_ALL`'s `CL_SET`: the main screen's cleared position, top row |
| `S_POSN` (0x5C88) | `0x1821` | column 33, line 24 -- the top row, end of line |
| `DF_CCL` (0x5C86) | `0x50FC` | one cell past the message: `0x50E0` + 28 |
| `S_POSNL` (0x5C8A) | `0x1705` | column 5 (= 33 - 28), line 23 |
| `VARS`/`PROG` (0x5C4B/0x5C53) | `0x5CCB` | after the 21-byte channel area at 0x5CB6 |
| `E_LINE` (0x5C59) | `0x5CCC` | `0x80` end marker, then `0x0D 0x80` |
| `STKBOT` (0x5C63) | `0x5CCE` | `WORKSP`/`STKEND` too |
| `CHARS` (0x5C36) | `0x3C00` | from 0x121C |
| `DF_SZ` (0x5C6B) | `0x02` | the lower part is two lines |
| `TV_FLAG` (0x5C3C) | `0x21` | lower part in use (bit 0), clear it after a key (bit 5) |

The editor then sits in `WAIT_KEY` (0x15D4).  It does not draw a cursor until
a key arrives: `KEY_INPUT` (0x10A8) clears the lower part because `TV_FLAG`
bit 5 is set, and only then does the edit line appear.

## Tape: two cassette sources, one player

`src/tap_player.v` turns a `.TAP` byte stream into the ULA's EAR bit (port
0xFE bit 6) with the real TAP structure: pilot 2168 T per pulse (8063 for a
header, 3223 for data), sync 667/735, bits 855/1710 MSB-first, 1 s pauses,
counted in 3.5 MHz T-states from `ce_cpu`.  `tb_tape` measures every half
period and the byte order.  Two sources feed it; `src/config.vh`'s
`ZX_TAPE_SD` picks one at build time.

**Card (default, `ZX_TAPE_SD` defined).** `src/sd/sd_vol.v` + `spi_byte.v` are
vendored from the sibling `apple2e_TP20K` project (hardware-proven SD/FAT32),
patched only where a `.TAP` replaces a floppy image (marked `ZX tape:`).  It
mounts the card, reads **`ZXCONFIG.TXT`** from the root, and streams the named
file byte for byte, stalling its SPI clock whenever `src/zx_tape_sd.v`'s FIFO
is full — so the file is pulled at cassette speed and never buffered in bulk.

```
ZXCONFIG.TXT      TAPE=TAPE.TAP        (8.3 names; S6D1=TAPE.TAP also works)
                  VOL=5                (tape audio level, 0..100 %, 5 if absent)
TAPE.TAP          the image, under 1 MB, clusters in one run
```

The deck is **on hold until the ROM enters LD-BYTES** (0x0556): `zx_core`
pulses `tape_load` when the CPU fetches it, i.e. when `LOAD ""` runs, and only
then does the file stream — so the leader tone always starts at the moment the
Spectrum is listening.  **DIP5** (`sw_tape_auto`) skips the wait and rolls from
reset.  LED5 is on while it plays.

**Web (`ZX_TAPE_SD` commented out).** `src/zx_tape_web.v` takes bytes from the
keyboard's own UART — `0xFD <byte>` per tape byte, and a `0x06` credit byte
back while its FIFO has room — so the page drip-feeds the file.  The page's
**Load tape** button loads the `.TAP`, answers credits, and types `LOAD ""` +
ENTER for you.

Both paths end in the same player, so the Spectrum cannot tell them apart.

## DDR3

`zx_ddr.v` is the sibling project's `aux_ram.v` trimmed to what a ZX needs:
the encrypted Gowin IP (the 1.9.8 netlist -- see that directory's README for
why not 1.9.12), the reset sequencing, the power-on self-test (write a
patterned burst, read it back, mask-write one word, read that back), and one
general client port (latch-on-go, ack-pulse, 26-bit word address, byte
enables).  The 27 MHz client side and the IP's ~100 MHz user clock cross by
toggle handshakes with two-clock stability; the .sdc declares the domains
asynchronous.

It is brought up but unused by the 48K core -- it is there so the 128K
banks, tape/snapshot storage and anything after that have a proven, idle
memory to land in.

## What is simplified

- **No memory contention modelling.**  The real ULA steals cycles from the
  CPU when it touches the screen; here the CPU loses a fixed window per line
  instead.  Timing-sensitive software (cassette loading, precise cycle
  counting) would notice; the ROM, BASIC and games do not.
- **No floating bus.**  Reads from unused ports return 0xFF, not the ULA's
  semi-random bus byte; a handful of demoscene effects abuse that.
- **Border effects** (per-pixel border changes, the famous loading stripes)
  render at video-line granularity from the last written value, not per
  T-state.
- **EAR is a constant** -- there is no tape input (yet).
