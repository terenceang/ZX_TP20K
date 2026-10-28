# Resources and timing

Measured from the Gowin build on the GW2A-LV18PG256C8/I7 (GW2A-18C): 20736
LUTs, 16173 registers, 46 BSRAMs, 4 rPLLs, 207 pads.

Reports: `impl/pnr/zx_tp20k.rpt.txt` (resource usage), `impl/pnr/zx_tp20k_tr_content.html`
(Fmax / TNS), `impl/gwsynthesis/zx_tp20k_syn_resource.html` (per module),
`impl/pnr/zx_tp20k.power.html` (power).

## The build (1.0.14 + the dead-code cleanup)

| Resource | Used |
|---|---|
| Logic | 11831 / 20736 (**58%**) |
| — LUT / ALU / ROM16 | 9813 / 1142 / 0 |
| — SSRAM (RAM16) | 146 |
| Registers | 6158 / 16173 (39%) |
| CLS (slices) | 7935 / 10368 (77%) |
| BSRAM | 40 / 46 (**87%**) |
| — SDPB (the 48K RAM) | 24 |
| — pROM (the 16K ROM) | 8 |
| — SDPX9B (DDR3 IP FIFOs) | 8 |
| DSP | 1 × MULT9X9 |
| rPLL | 2 / 4 (TMDS, DDR3) |
| IOLOGIC | 128 / 207 (4 × OSER10 for HDMI, the rest the DDR3 PHY) |
| I/O pads | 72 / 207 |

| Clock | Needed | Fmax |
|---|---|---|
| `clk` (crystal, the DDR3 IP's `.clk`) | 27.0 MHz | 218 MHz |
| `clk_pixel` (everything ZX) | 27.0 MHz | 52 MHz |
| `mclk` (DDR3 IP user clock) | 99.6 MHz | 113 MHz |
| `ddr_memory_clk` | 398.2 MHz | 630 MHz |

Zero setup and hold violations; `scripts/build.ps1` fails the build on any.
Fmax moves a few percent between builds (placement has no fixed seed; the gate
is TNS = 0), so read these as "how thin is this clock", not as exact figures.
`mclk` is the thin one, and its worst paths are inside the encrypted IP.

## Where it goes

From earlier per-block measurements: the SD/FAT32 volume manager (`sd_vol`)
~3.3k LUTs, the DDR3 IP + `zx_ddr` ~1.4k LUTs and 1.3k registers, tv80
~1.1k LUTs, the HDMI stack ~0.8k.  The current per-module numbers are in
`impl/gwsynthesis/zx_tp20k_syn_resource.html`.

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
- **The key-activity LED** is a 4-bit counter clocked by the ULA's existing
  50 Hz tick (12 frames ≈ 0.24 s), not a 25-bit divider.
- **No ASCII key map** on the board: it takes only `FE <pos> <down>` matrix
  events and the page does all translation (`web/src/zxkeys.js`).

## What was considered and left alone

- **Merging the POR and HDMI-reset counters** in `zx_top` would save ~10 FFs
  and one 8-bit incrementer, but it would halve the OSER10 reset delay from
  128 to 64 pixel clocks.  Not worth the risk to the serialisers for that.
- **Deriving the 50 Hz interrupt from the video raster** would delete the
  540000-count divider, but the design keeps 50 Hz independent of the
  59.94 Hz HDMI frame on purpose (a mode change must never disturb the
  interrupt rhythm).
- **tv80 and the HDMI stack** are proven cores/snapshots; see the notes in
  `docs/architecture.md` for why they are not modified.

## If more headroom is needed

- BSRAM is the constraint (87%): the 128K banks have to come from the DDR3,
  and anything added on the DDR3 side has to live inside `mclk`'s margin or be
  pipelined.
- Logic has ~40% free.
