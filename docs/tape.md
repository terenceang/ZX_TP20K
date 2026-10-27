# Loading tapes

Two ways in, one player out.  `src/config.vh`'s `ZX_TAPE_SD` picks the source
at build time; both end in `src/tap_player.v`, so the Spectrum cannot tell them
apart.

> **The library build** — a card-resident library, chosen from the page, with
> the image held in DDR3 — is described in [`tape-library.md`](tape-library.md).
> The store (`src/zx_tape_mem.v`) is built and simulated; the card scan, the
> listing over UART and the `zx_top` wiring are the remaining steps.  The
> descriptions below are the builds that are on the board today.

```
                    ┌──────────────────────────────────────────────┐
  microSD (J2) ──►  │ src/sd/sd_vol.v   FAT32 finder + CMD18 stream │──┐
                    └──────────────────────────────────────────────┘  │  f_up_*
                                                                      ▼
                                                          ┌────────────────────┐
  web page ──0xFD <byte>──► src/zx_tape_web.v ──FIFO──►   │  src/tap_player.v  │
             ◄──0x06 credit──                             └─────────┬──────────┘
                                                                    │ EAR
                                                                    ▼
                                                       zx_core, ULA port 0xFE bit 6
```

## Path A — microSD card (the default build)

**Card** (FAT32, root directory):

```
ZXCONFIG.TXT      TAPE=TAPE.TAP        ; S6D1=TAPE.TAP also works, ';' comments
TAPE.TAP          the tape image: 8.3 name, under 1 MB, one contiguous run
```

**Steps**

1. Power on / press **S0** (reset).  The ROM boots to the © prompt in ~1.5 s.
2. **Flip DIP4 on**: the board types `LOAD ""` + ENTER into its own keyboard
   path (one ASCII key per 100 ms, the same path a terminal uses) — or type it
   yourself if you prefer.  **That is what starts the deck**: the board
   watches for the ROM's LD-BYTES entry (0x0556) and only then lets the file
   stream, so the leader tone always begins at the moment the Spectrum asks
   for it (the normal cassette behaviour: press LOAD, the tape rolls).
   **LED5 lights** while it plays.

With **DIP5 ON** the deck does not wait: it rolls from reset, so `LOAD ""`
finds the leader already running ("instant" on the standard ROM).  Use it when
you want the tape to start by itself, e.g. an auto-run loader or a terminal
typing the command for you.

The whole file streams once at cassette speed; reset to replay it.

Notes:
- The name is 8.3 and the config is case-insensitive (`TAPE=tape.tap` is fine).
- The finder needs the file's clusters in **one run** (it streams them with a
  single CMD18, like the sibling project).  A file freshly copied to an empty
  card is contiguous; one appended to may not be.
- No config file, no tape: `sd_vol` finds nothing and the EAR line just stays
  idle high.

## Path B — the web page (comment out `ZX_TAPE_SD`, rebuild)

1. Connect the page (Chrome/Edge, Web Serial, 1 Mbps).
2. Click **Load tape (.tap)** and pick the file.
3. The page types `LOAD ""` + ENTER about a second in, and the board starts
   asking for bytes (credits) only once the ROM has entered LD-BYTES — so the
   file begins streaming exactly when the Spectrum is ready for the leader.
   The status line counts bytes; LED5 lights while it plays.  With DIP5 ON the
   board asks from reset instead, so the page starts pumping immediately.

Nothing to prepare on a card; the page is the deck.

## What comes out of the player

The real TAP structure, timed in 3.5 MHz T-states from `ce_cpu`:

| part | timing |
|---|---|
| pilot | 2168 T per pulse — 8063 pulses for a header (flag < 0x80), 3223 for data |
| sync | 667 T, then 735 T |
| bits | 2 pulses per bit, 855 T for 0, 1710 T for 1, MSB first |
| pause | 1000 ms between blocks |

`sim/tb_tape.v` measures every half period and checks the byte order.

## If it does not load

| Symptom | Look at |
|---|---|
| LED5 never lights | the source: card not mounted (FAT32? `ZXCONFIG.TXT` in the root?) or the page not pumping (byte counter frozen) |
| LED5 lights, but `LOAD ""` times out | you typed LOAD too late (the tape had already run past the leader) — reset and have the command ready, or rebuild with a longer `START_MS` |
| Leader found, then "R Tape loading error" | the file is fragmented, or not a TAP for this ROM (128K-only, or a TZX renamed) |
| No click when typing in the editor | the whole audio path, not the tape — try S1's 1 kHz tone |
