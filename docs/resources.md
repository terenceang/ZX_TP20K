# Resources and timing

Measured from the Gowin build on the GW2A-LV18PG256C8/I7 (GW2A-18C): 20736
LUTs, 16173 registers, 46 BSRAMs, 4 rPLLs, 207 pads.

Reports: `impl/pnr/zx_tp20k.rpt.txt` (resource usage), `impl/pnr/zx_tp20k_tr_content.html`
(Fmax / TNS), `impl/gwsynthesis/zx_tp20k_syn_resource.html` (per module),
`impl/pnr/zx_tp20k.power.html` (power).

## Two builds

`src/config.vh` decides whether the DDR3 bring-up block (`zx_ddr` + the
encrypted DDR3 IP + the 398.25 MHz PLL) is compiled in.  Nothing in the 48K
machine reads or writes the DDR3 yet, so the default build leaves it out; the
DDR3 pins are held in reset and deselected, and the DDR3 clocks do not exist
(`constraints/zx_lean.sdc`).  Define `ZX_USE_DDR3` for the DDR3 bring-up and
the 128K/storage work, and the build switches to `constraints/zx.sdc`.

| Resource | 48K build (default, DDR3 out) | with DDR3 (bring-up) |
|---|---|---|
| Logic | 3151 / 20736 (**16%**) | 5391 / 20736 (26%) |
| — LUT / ALU / ROM16 | 2822 / 209 / 0 | 4260 / 345 / 0 |
| — SSRAM (RAM16) | 20 | 131 |
| Registers | 888 / 16173 (**6%**) | 2204 / 16173 (14%) |
| CLS (slices) | 1891 / 10368 (19%) | 3409 / 10368 (33%) |
| BSRAM | 32 / 46 (**70%**) | 40 / 46 (87%) |
| — SDPB (the 48K RAM) | 24 | 24 |
| — pROM (the 16K ROM) | 8 | 8 |
| — SDPX9B (DDR3 IP FIFOs) | 0 | 8 |
| rPLL | 1 / 4 | 2 / 4 |
| IOLOGIC | 8 (4 × OSER10) | 128 |
| I/O pads | 66 / 207 | 66 / 207 |
| Worst Fmax | `clk_pixel` 65.4 MHz (27 needed) | `ddr_memory_clk` 431.0 MHz (398.2 needed) |
| Timing margin | 2.4× on the slowest clock | **+0.19 ns** on `ddr_memory_clk` (+0.85 ns on `mclk`) |

Both builds have zero setup and hold violations.  The Fmax numbers move a
few percent from build to build (placement has no fixed seed; the build gate is
TNS = 0, not a number), so read the margins as "how thin this clock is", not as
exact figures.

## Where the logic goes (48K logic; the DDR3 block is extra when enabled)

| Module | LUT | Registers |
|---|---|---|
| `u_cpu` (tv80 Z80, `Mode(0)`) | 1119 | 212 |
| HDMI stack (packets, 3 × ECC island slots, 3 × TMDS encoders, scheduler) | ~830 | ~460 |
| `u_keys` (`zx_input`: UART, protocol state machines, key map) | 298 | 141 |
| `u_core` (memory mux, ULA ports, interrupts, beeper → 48 kHz) | 214 | 50 |
| `zx_top` (reset/POR, LEDs), `u_video`, `u_clk_gen`, `u_banner` | ~180 | ~90 |

The DDR3 block, when enabled, adds 1364 LUTs, 1296 registers, 8 BSRAMs and
102 ALUs — it is the largest single consumer in the design by a wide margin,
and the only reason the design is not a single-clock build.

## What is already at its minimum

- **BSRAM.** 24 blocks hold 48 KB exactly (each block is 2048 × 9 and the
  memory is byte-wide, so 2048 bytes per block), 8 blocks hold the 16 KB ROM.
  That is the machine's memory map, not an implementation choice: a 128K
  Spectrum cannot live in BSRAM (it would need ~96 blocks) and has to use the
  DDR3.
- **Address arithmetic.** `a - 16'h4000` and `vram_addr - 16'h4000` look like
  subtractors but are bit slices: the synthesiser folds the constant, so
  `ram_raddr` is a 14-bit mux and nothing more.
- **The ULA's keyboard read.** `keys_c` ORs the five columns of every row the
  address selects, which the ROM relies on (`IN A,(FE)` has A15..A8 = 0 and so
  reads all rows at once).
- **The key-activity LED** no longer costs a 25-bit 27 MHz divider: it is a
  4-bit counter clocked by the ULA's existing 50 Hz tick (12 frames ≈ 0.24 s).

## What was considered and left alone

- **Merging the POR and HDMI-reset counters** in `zx_top` would save ~10 FFs
  and one 8-bit incrementer, but it would halve the OSER10 reset delay from
  128 to 64 pixel clocks.  Not worth the risk to the serialisers for that.
- **The ASCII key map** in `zx_input` (a 128-entry case, ~200 of those 298
  LUTs) was considered for compression and then deleted outright: the board
  now takes only `FE <pos> <down>` matrix events and the page does all
  translation (`web/src/zxkeys.js`), so both the LUTs and the dumb-terminal
  path are gone.
- **Deriving the 50 Hz interrupt from the video raster** would delete the
  540000-count divider, but the design keeps 50 Hz independent of the
  59.94 Hz HDMI frame on purpose (a mode change must never disturb the
  interrupt rhythm).
- **tv80 and the HDMI stack** are proven cores/snapshots; see the notes in
  `docs/architecture.md` for why they are not modified.

## If more headroom is needed

- Logic is not the constraint: 84% of the fabric is free in the 48K build.
- For the 128K work, the constraint is BSRAM (70% used by the 48K memory map
  alone) — so banks must come from the DDR3, and any logic added on the DDR3
  side has to live inside the 2.7% `mclk` margin or be pipelined.

## The TV effect stage

`zx_tv_fx` (DIP1 colour TV, DIP2/3 scanlines, DIP4/5 phosphor) costs
**+457 logic (3151 -> 3608, 18% of the device), +136 registers and 3 DSP
primitives** (the luma matrix: 2 x MULT9X9 + 1 x MULTADDALU18X18).  The
chroma filter, the RGB rebuild and the scanline attenuation are shifts and
adds, which is what they are.  `clk_pixel` Fmax with the stage in and
pipelined: **53.4 MHz** against the 27 MHz it needs (it was 20 MHz before the
pipeline, i.e. it did not close).  TNS is zero.
