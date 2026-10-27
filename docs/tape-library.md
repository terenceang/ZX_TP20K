# The tape library

The tapes live on the microSD card; the player lives in DDR3.  The page shows
the card's library and may only pick from it — there is no way to push a file
from the computer, because the deck plays what is in it.

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
  fraction of a second, after which the card can be taken out: no card, no
  interruption, no re-read for a replay, and no long stream a yanked card can
  ruin.
* **DDR3 is big and random-access.**  The whole image sits there, so the deck
  can hold, rewind and replay, and instant load can walk the whole image
  without the card.  Address mapping: byte *n* is word *n>>1*, low byte first.

## The wire protocol

1 Mbps 8N1 on the debugger UART, the same link as the keyboard
(`src/zx_input.v`).  `web/src/protocol.js` is the page end of it.

| direction | bytes | meaning |
|---|---|---|
| page → board | `FB 4C` | send the library again |
| page → board | `FB 53 <idx>` | load tape *idx* into DDR3 |
| page → board | `FB 43` | eject |
| page → board | `FB 50` | play now, without waiting for `LOAD ""` |
| page → board | `FB 57`, then `FD <byte>`…, then `FB 45` | upload a tape into the player |
| board → page | `F7 <len> <name…> <size le32>` | one library entry |
| board → page | `F6 <count>` | the list has ended |
| board → page | `F8 <state>` | 0 empty, 1 loading, 2 ready, 3 playing, 4 ended, 5 error |
| board → page | `F9 <idx> <pos le24> <len le32>` | how far the tape has got |

Names go out as the card stores 8.3: eleven bytes, space padded, no dot
(`HOBBIT  TAP`); the page puts the dot back (`tapeName()` in
`web/src/library.js`).  The page parses the stream byte by byte
(`BoardFrames`), so a frame split across reads is fine, and it draws the list
as the entries arrive.

## The FPGA side

* **`src/sd/sd_vol.v`** — the vendored FAT32 volume manager, patched (the
  `ZX tape:` markers) with a library mode: `lib_go` + `lib_find` walks the root
  directory, and `lib_ent` pulses per `.TAP` with its name and size.  With
  `lib_find` the walk stops at entry `lib_idx`, puts it in drive 0 and streams
  it byte for byte on the existing `f_up_*` port.  Its own `L_WALK` checks the
  FAT chain, so a fragmented tape fails loudly (`lib_fail`) instead of playing
  the wrong bytes.
* **`src/zx_tape_lib.v`** — the join: commands from `zx_input`, the card
  wrapper, the byte stream into the store, the player's start/replay logic, and
  the UART frames (a four-deep queue, one frame at a time).
* **`src/zx_tape_mem.v`** — the DDR3 store: a byte port the card fills, and a
  read-ahead FIFO whose head the player pops.  It owns the `zx_ddr` client port
  (a one-clock `go` pulse when `idle`, `ack` later).  Tested by
  `sim/tb_tape_mem.v` against the behavioural DDR3 model — 301 bytes written,
  read back, rewound, read again — and by `sim/tb_mem_min.v`, the same store
  against a fake DDR for a fast run.
* **`src/zx_top.v`** — under `ZX_TAPE_LIB` in `src/config.vh`, which also
  requires `ZX_USE_DDR3`.  That build takes the DDR3 pins and the UART's
  `tx_req`; `DIP5` and the page's Play both start the tape, and the ROM's own
  `LOAD ""` (`tape_load`, fetch of `0x0556`) does too.

## Uploading without the card

`FB 57` clears the player, the `FD` packets that follow are the .TAP, and
`FB 45` closes it (`img_len` becomes what arrived, so an odd last byte is
flushed and the deck goes ready).  Nothing touches the card: this is how to
play a tape when the file is not on the card yet, or when the card path is
unhappy.  Progress frames for an uploaded tape carry index `0x7F`, which is how
the page keeps it apart from the card's entries.

Writing a tape *onto* the card from the page — FAT32 allocation and a
directory entry — is a different job and is not built yet.

## State of it

Built and simulated:

* the store, both benches above, `tb_input` covering the `FB` commands;
* the whole design builds with `ZX_USE_DDR3` + `ZX_TAPE_LIB`: 52% logic, 33%
  registers, all timing met (`clk_pixel` 50.6 MHz against 27 needed, `mclk`
  112.1 against 99.6, TNS 0).

The walk had a show-stopper until it was fixed: the library's cluster-follow
step (`L_LIBF`) was missing from the lookup's step list, so the scan read the
first directory cluster and then waited for a read that was never issued —
which is why the page sat on "waiting for the card".  Both steps (`L_LIB` and
`L_LIBF`) are in now.

Not yet proven on the board: the card scan, the frames and the player have
only been through Gowin's synthesiser, not a scope.  `sd_vol.v` cannot be
compiled by Icarus (it crashes on the file, patched or not), so the card walk
has no simulation behind it — if the page shows `waiting for the card`, the
first things to check are LED 5 blinking during the walk and `fs_ok` (a FAT32
card with 512-byte sectors).

## Limits

* 8.3 names, upper case (FAT long-name entries are ignored).
* 1 MB per tape, 8 MB of tape images in DDR3 in total.
* 32 tapes listed at most (5-bit index on the wire).
* The deck is one tape at a time: loading another replaces the image.
* A tape must be contiguous on the card; `L_WALK` fails a fragmented one.
