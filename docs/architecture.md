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

## Tape, snapshots and the card

`docs/tape-library.md` has the whole of it.  In short: `zx_tape_lib` lists
the card's `.TAP`/`.TZX`/`.Z80` files to the page, streams the chosen tape
into DDR3 (`zx_tape_mem`), and `tap_player` turns it into EAR pulses (port
0xFE bit 6) with the real timings.  The deck waits for the ROM's `LD-BYTES`
(0x0556, `tape_load`) so the leader starts when `LOAD ""` runs.

Three more things ride the same UART, all in `zx_core`'s domain:

* `zx_snap` holds the CPU, writes RAM, sets the border and starts a register
  trampoline: how a `.Z80` or an instant load goes in.
* `zx_core`'s instant-load trap: while armed, `LD-BYTES` from 0x0562 reads as a
  93-byte routine that takes the `.TAP` from port 0x5B (the store's head),
  holding the CPU on `wait_n` while it is empty.
* `zx_scr_cap` pauses the CPU and streams the 6912-byte screen file back to
  the page, off the video's prefetch window like the CPU.

## DDR3

`zx_ddr.v` is the sibling project's `aux_ram.v` trimmed to what a ZX needs:
the encrypted Gowin IP (the 1.9.8 netlist -- see that directory's README for
why not 1.9.12), the reset sequencing, the power-on self-test (write a
patterned burst, read it back, mask-write one word, read that back), and one
general client port (latch-on-go, ack-pulse, 26-bit word address, byte
enables).  The 27 MHz client side and the IP's ~100 MHz user clock cross by
toggle handshakes with two-clock stability; the .sdc declares the domains
asynchronous.

The tape store is its one client today; the 128K banks would be the next.
The IP's user clock `mclk` is the design's tightest timing (a few percent
of margin), and its worst paths are inside the encrypted IP.

## What is simplified

- **No memory contention modelling.**  The real ULA steals cycles from the
  CPU when it touches the screen; here the CPU loses a fixed window per line
  instead.  Software that counts cycles precisely would notice; the ROM,
  BASIC, tape loading and most games do not.
- **No floating bus.**  Reads from unused ports return 0xFF, not the ULA's
  semi-random bus byte; a handful of demoscene effects abuse that.
- **Border effects** (per-pixel border changes, the famous loading stripes)
  render at video-line granularity from the last written value, not per
  T-state.
