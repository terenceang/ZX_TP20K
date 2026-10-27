# The tape library

The tapes live on the microSD card; the player lives in DDR3.  The page shows
the card's library, puts files on the card and takes them off, and picks the
tape the deck plays.  The board plays only what is in DDR3.

```
   SD card                         FPGA                                   page
   ┌───────────────┐   scan    ┌──────────────┐   0xF7 entries     ┌──────────────┐
   │ HOBBIT .TAP   │──────────▶│ zx_tape_lib  │──────────────────▶│ library list │
   │ JETPAC .TAP   │           │  (sd_vol:    │   0xF6 end         │              │
   │ ATICAT .TAP   │   stream  │   names,     │   0xFB 53 idx      │   [ Load ]   │
   │ …             │◀─────────▶│   sizes,     │◀──────────────────│              │
   └───────────────┘           │   clusters)  │                   └──────────────┘
                                └──────┬───────┘
                                       │ bytes
                                       ▼
                                ┌──────────────┐   head/pop  ┌──────────────┐
                                │ zx_tape_mem  │────────────▶│ tap_player   │──▶ ULA
                                │   (DDR3)     │             │  (timings)   │    0xFE bit 6
                                └──────────────┘             └──────────────┘
```

## Why two memories

* **The card is slow and removable.**  Reading a 47 KB tape off it takes a
  fraction of a second, after which the card can be taken out: no re-read for
  a replay, and no long stream a yanked card can ruin.
* **DDR3 is big and random-access.**  The whole image sits there, so the deck
  can hold, rewind and replay, and instant load can hand over at any byte.
  Address mapping: byte *n* is word *n>>1*, low byte first.

## The card

FAT32, root directory, 8.3 names.  The board lists `.TAP`, `.TZX` and `.Z80`
files; the player plays `.TAP` (a `.TZX` goes through *Instant*, a `.Z80` is
restored as a snapshot).

```
ZXCONFIG.TXT      TAPE=HOBBIT.TAP      ; the tape in the player (S6D1= also works)
                  VOL=5                ; tape audio level, 0..100 % (5 if absent)
```

The page rewrites `TAPE=` whenever it loads a tape, so the board mounts the
same tape after a reset or a power cycle.

## The page

| Control | What happens |
|---|---|
| **Load** (a row's ▶) | `FB 53 <idx>`: the board streams that tape into DDR3; the deck goes *ready* |
| `LOAD ""` | types the command (`web/src/tape.js`); the deck starts when the ROM enters `LD-BYTES` (0x0556, `zx_core`'s `tape_load`) |
| ▶ / ■ / ❚❚ / ⏮ / ⏏ | play now, stop, pause/resume, rewind, eject (`FB 50 48 52 43`) |
| speaker | the EAR mixed into the HDMI audio at `VOL=` (`FB 41` on / `FB 61` off; the page resends it on connect) |
| **Instant** | runs the tape in the page and loads the result (below) |
| a `.Z80` row | read off the card by the page and injected through the snapshot packets |
| **Upload to card** / 🗑 | writes or deletes a file on the card through the raw card bridge (`fat32.js` over `sd_raw_bridge`) |
| **Freeze & capture** | `FA`: the board pauses the CPU and sends the 6912-byte screen |

## The wire protocol

1 Mbps 8N1 on the debugger UART, the same link as the keyboard
(`src/zx_input.v`).  `web/src/protocol.js` is the page end of it.

| direction | bytes | meaning |
|---|---|---|
| page → board | `FE <pos> <down>`, `FF 04` | keys (README) |
| page → board | `FB 4C` | send the library again |
| page → board | `FB 53 <idx>` | load tape *idx* into DDR3 |
| page → board | `FB 43` | eject |
| page → board | `FB 50` | play now, without waiting for `LOAD ""` |
| page → board | `FB 48` | pause / resume |
| page → board | `FB 52` | rewind (disarms the instant trap) |
| page → board | `FB 49 <off le24>` | instant load's hand-over: head to byte *off*, trap armed (see *Instant load*) |
| page → board | `FB 41` / `FB 61` | tape audio to HDMI on / off |
| page → board | `FB 56` | report the firmware version |
| page → board | `FA` (or `FF 05`) | screen capture |
| page → board | `FC <sub> …` | snapshot: `01` hold the CPU, `02 <addr le16> <len le16> <data>`, `03 <border>`, `04 <28 regs>`, `05` run (`src/zx_snap.v`) |
| page → board | `02` … `c` | raw card mode on … off (`src/sd/sd_raw_bridge.v`: sector read/write for the page's FAT32) |
| board → page | `F7 <len> <name…> <size le32>` | one library entry |
| board → page | `F6 <count>` | the list has ended |
| board → page | `F8 <state>` | 0 empty, 1 loading, 2 ready, 3 playing, 4 ended, 5 error |
| board → page | `F9 <idx> <pos le24> <len le32>` | how far the tape has got |
| board → page | `F5 <status> <6912 bytes>` | the captured screen; status = `{flash, border}` |

Names go out as the card stores 8.3: eleven bytes, space padded, no dot
(`HOBBIT  TAP`); the page puts the dot back (`tapeName()` in
`web/src/library.js`).  The page parses the stream byte by byte
(`BoardFrames`), so a frame split across reads is fine.  While `zx_snap` is
inside a packet it reports `busy`, and the keyboard parser and the card bridge
ignore the stream: snapshot RAM is full of bytes that would otherwise read as
commands.

## The FPGA side

* **`src/sd/sd_vol.v`** — the vendored FAT32 volume manager, patched (the
  `ZX tape:` markers) with a library mode: `lib_go` walks the root directory
  and `lib_ent` pulses per entry with its name and size; with `lib_find` the
  walk stops at entry `lib_idx` and streams it byte for byte on `f_up_*`.  Its
  `L_WALK` checks the FAT chain, so a fragmented tape fails loudly
  (`lib_fail`) instead of playing the wrong bytes.
* **`src/zx_tape_lib.v`** — the join: commands from `zx_input`, the card
  wrapper and the raw card bridge, the byte stream into the store, the deck's
  states, the instant trap's feed, and the UART frames.
* **`src/zx_tape_mem.v`** — the DDR3 store: a byte port the card fills, and a
  read-ahead FIFO whose head the player (or the trap) pops.  It owns the
  `zx_ddr` client port.
* **`src/tap_player.v`** — the `.TAP` as EAR pulses, timed in 3.5 MHz
  T-states from `ce_cpu`:

  | part | timing |
  |---|---|
  | pilot | 2168 T per pulse — 8063 pulses for a header (flag < 0x80), 3223 for data |
  | sync | 667 T, then 735 T |
  | bits | 2 pulses per bit, 855 T for 0, 1710 T for 1, MSB first |
  | pause | 1000 ms between blocks |

LED5 is on while the tape plays.

## Instant load

The deck's **Instant** button: the page runs the tape, the board takes over
where the page stopped.

**The page runs the tape.**  It reads the `.TAP`/`.TZX` off the card and runs
it through a 48K of its own (`web/src/tape-snapshot.js`: `z80-emulator` and
the real ROM, bundled from `roms/zx48.rom` when `make rom` has fetched it).
The emulated ROM gets `LOAD ""` through `LASTK`; standard-speed blocks are
flash-loaded at `LD-BYTES`, everything else plays as EAR edges with its TZX
timings -- turbo, pure tone/pulses/data, direct recording, CSW (RLE and
Z-RLE), generalized data, with loops, jumps and calls -- so custom loaders
load too, in a fraction of real time.  It stops as soon as the program stops
taking the tape: a data block nobody reads (a loader samples the EAR at least
once per edge; the first 1.3 s of a block are not counted, because the ROM's
`LD-BYTES` waits that long before it listens), or the tape's end or a TZX
stop block (then 2 s more, so a loader can finish).  That machine goes in
through the snapshot packets (`FC`, `src/zx_snap.v`), like a `.Z80`.

**The board takes over.**  With the same `.TAP` in the player, the page also
sends, while the CPU is still held:

* `FB 49 <offset le24>` when parts were left over (a multi-load game): the
  head goes to the first part the program did not take, and `zx_core`'s trap
  is armed there, DivMMC style.  From `0x0562` (where the ROM has put the flag
  and LOAD/VERIFY in AF', done `DI` and pushed `SA/LD-RET`) `LD-BYTES` reads
  as a 93-byte routine taking the `.TAP` from port `0x5B`, the DDR3 store's
  head, the CPU held on `wait_n` while it is empty.  It checks the flag and
  the parity and reads a rejected or over-long block to its end, so the next
  call starts on the next block; past the image the port reads `00` (a zero
  length: the ROM keeps looking until BREAK).  A part with a custom loader
  needs **Play**, which starts the player from the head and disarms the trap,
  as rewind, select and eject do.
* `FB 52` (rewind) when nothing was left, which also disarms an older trap.

`zx_snap` reports `busy` while it is inside a packet, and the keyboard parser
and the card bridge ignore the stream then: snapshot RAM is full of bytes
that would otherwise read as `FB 53` (select), `FE` (keys) or `02` (card
mode).

Tests: `web/test/tape-snapshot.test.js` loads `sim/data/hello_tap.hex` as a
TAP and re-encoded as every TZX data block type and through call/jump, and
checks the multi-load hand-over offset; `sim/tb_type.v +instant=1` loads it
through the trap and the real ROM; `sim/tb_input.v` checks `FB 49 <offset>`
and the held stream.

## If it does not load

| Symptom | Look at |
|---|---|
| the list says *waiting for the card* | a FAT32 card with 512-byte sectors; then **Rescan card** |
| the deck goes *error* on Load | the tape is fragmented on the card (copy it to a fresh card), or over 1 MB |
| LED1 on | DDR3 calibration (placement-dependent between builds): reload the bitstream |
| `LOAD ""` finds nothing | the deck is not *ready* (load the tape first), or it was played past the leader: rewind |
| "R Tape loading error" | not a TAP for the 48K ROM (128K-only, or a TZX renamed `.TAP`) |
| silent load | the speaker button is off, or `VOL=0` |

Tests: `tb_tape` (every half period and the byte order), `tb_tape_mem` and
`tb_mem_min` (the store), `tb_tape_deck` (card bytes → DDR3 → player → EAR),
`tb_vol` (`VOL=`), `tb_raw_bridge`, `tb_input` (the `FB` commands),
`tb_scr_cap`, `tb_type +instant=1`, and the page's `npm test`.

## Limits

* 8.3 names, upper case (FAT long-name entries are ignored).
* 1 MB per tape, 8 MB of tape images in DDR3 in total.
* 32 entries listed at most (5-bit index on the wire).
* The deck is one tape at a time: loading another replaces the image.
* A tape must be contiguous on the card; `L_WALK` fails a fragmented one.
* The player plays `.TAP` only, so instant load hands a multi-load over to
  the board for a `.TAP`; a `.TZX`'s later parts are not reachable from the deck.
