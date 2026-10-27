// ============================================================================
//  library.js -- the tape library the card holds, and the deck that plays it
//
//  The library is the SD card's, not the page's: the board scans the card's
//  root directory for .TAP files at power-on and sends the list down the same
//  UART as the keyboard (src/zx_tape_lib.v).  The page asks for one of those
//  entries by position; files reach the card through the page's raw-card
//  FAT32 (fat32.js), never straight into the player.
//
//  Byte stream from the board (see protocol.js):
//
//      0xF7 <count> { <len> <name...> <size le32> }   the list
//      0xF8 <state>                                   the deck's state
//      0xF9 <idx> <pos le24> <len le32>               the tape's position
//      0x06                                           old web-deck credit
//
//  BoardFrames is a byte-at-a-time parser (the link hands over whatever
//  arrives, split anywhere) that turns that stream into events; TapeLibrary is
//  the state a component renders.  Both are plain JS so `node --test` covers
//  them without a browser.
// ============================================================================

import { LIB_ENTRY, LIB_END, DECK_STATE, TAPE_POS, TAPE_CREDIT, DECK, SCR_FRAME, SCR_BYTES } from './protocol.js'

/** The parser's states, one per field of the frames above. */
const S = {
  IDLE: 0,
  COUNT: 1,
  LEN: 2,
  NAME: 3,
  SIZE: 4,
  DECK: 5,
  POS_IDX: 6,
  POS: 7,
  POS_LEN: 8,
  SCR_STATUS: 9,
  SCR_DATA: 10,
}

/** The card stores 8.3 names, space padded: "HOBBIT  TAP" is HOBBIT.TAP. */
export function tapeName(raw) {
  if (raw.length === 11 && !raw.includes('.')) {
    const base = raw.slice(0, 8).replace(/\s+$/, '')
    const ext = raw.slice(8).replace(/\s+$/, '')
    return ext ? `${base}.${ext}` : base
  }
  return raw
}

const le32 = (a, i) => (a[i] | (a[i + 1] << 8) | (a[i + 2] << 16) | (a[i + 3] << 24)) >>> 0
const le24 = (a, i) => (a[i] | (a[i + 1] << 8) | (a[i + 2] << 16)) >>> 0

/**
 * Splits the board's byte stream into library frames and plain text.
 *
 * `on(event)` receives:
 *   { type: 'list', entries: [{ name, size }] }
 *   { type: 'deck', state }
 *   { type: 'progress', idx, pos, len }
 */
export class BoardFrames {
  constructor(on = () => {}) {
    this.on = on
    this.st = S.IDLE
    this.count = 0
    this.entries = []
    this.nameLen = 0
    this.name = []
    this.size = []
    this.cmd = 0
    this.idx = 0
    this.pos = []
    this.posLen = []
    this.scrBorder = 0
    this.scrFlash = 0
    this.scrBuf = null
    this.scrIdx = 0
  }

  /**
   * @param {Uint8Array|number[]} bytes whatever the port delivered
   * @returns {{ text: Uint8Array, credits: number }} the bytes that were not a
   *          frame (the boot banner) and the count of tape credits
   */
  feed(bytes) {
    const text = []
    let credits = 0

    for (const b of bytes) {
      switch (this.st) {
        case S.IDLE:
          if (b === LIB_ENTRY) { this.st = S.LEN }
          else if (b === LIB_END) this.st = S.COUNT
          else if (b === DECK_STATE) this.st = S.DECK
          else if (b === TAPE_POS) this.st = S.POS_IDX
          else if (b === TAPE_CREDIT) credits += 1
          else if (b === SCR_FRAME) {
            this.scrBuf = new Uint8Array(SCR_BYTES)
            this.scrIdx = 0
            this.st = S.SCR_STATUS
          }
          else text.push(b)
          break

        case S.SCR_STATUS:
          this.scrBorder = b & 0x07
          this.scrFlash = (b >> 3) & 1
          this.st = S.SCR_DATA
          break

        case S.SCR_DATA:
          this.scrBuf[this.scrIdx++] = b
          if (this.scrIdx >= SCR_BYTES) {
            this.on({
              type: 'screen',
              border: this.scrBorder,
              flash: this.scrFlash,
              data: this.scrBuf,
            })
            this.st = S.IDLE
          }
          break

        case S.COUNT:
          this.count = b
          this.on({ type: 'list', count: b })
          this.st = S.IDLE
          break

        case S.LEN:
          this.nameLen = b
          this.name = []
          this.st = b ? S.NAME : S.SIZE
          break

        case S.NAME:
          this.name.push(b)
          if (this.name.length === this.nameLen) {
            this.size = []
            this.st = S.SIZE
          }
          break

        case S.SIZE:
          this.size.push(b)
          if (this.size.length === 4) {
            this.on({
              type: 'entry',
              name: tapeName(new TextDecoder().decode(Uint8Array.from(this.name))),
              size: le32(this.size, 0),
            })
            this.st = S.IDLE
          }
          break

        case S.DECK:
          this.on({ type: 'deck', state: b })
          this.st = S.IDLE
          break

        case S.POS_IDX:
          this.idx = b
          this.pos = []
          this.st = S.POS
          break

        case S.POS:
          this.pos.push(b)
          if (this.pos.length === 3) {
            this.posLen = []
            this.st = S.POS_LEN
          }
          break

        case S.POS_LEN:
          this.posLen.push(b)
          if (this.posLen.length === 4) {
            this.on({
              type: 'progress',
              idx: this.idx,
              pos: le24(this.pos, 0),
              len: le32(this.posLen, 0),
            })
            this.st = S.IDLE
          }
          break

        default:
          this.st = S.IDLE
      }
    }

    return { text: Uint8Array.from(text), credits }
  }

}

/** What the page renders: the card's tapes, the selection, and the deck. */
export class TapeLibrary {
  constructor() {
    this.entries = []
    this.selected = -1     // the row the user clicked
    this.loaded = -1       // the tape the board has in DDR3
    this.state = DECK.EMPTY
    this.pos = 0           // the head's position, in bytes
    this.len = 0           // the image's size
    this.resident = 0      // bytes actually in DDR3
    this.card = 'waiting'  // 'waiting' | 'ok' | 'error'
    this.error = ''
    this.listing = false   // entries are arriving: the next end marker closes the list
    this.longNames = new Map()  // 8.3 -> long name, read from the card's LFN entries
  }

  /** The card's long name for an 8.3 entry, when the page has read one. */
  displayName(name) {
    return this.longNames.get(name) ?? name
  }

  /** Apply a BoardFrames event. */
  apply(ev) {
    if (ev.type === 'clear') {
      this.entries = []
      this.card = 'waiting'
      this.selected = -1
      this.listing = false
    } else if (ev.type === 'entry') {
      // every listing is the whole card: the first entry after an end marker
      // starts a fresh list, so repeated or overlapping requests never stack
      if (!this.listing) { this.entries = []; this.listing = true }
      this.entries.push({ name: ev.name, size: ev.size })
      this.card = 'ok'
    } else if (ev.type === 'list') {
      if (!this.listing) this.entries = []
      this.listing = false
      this.card = 'ok'
      this.count = ev.count ?? this.entries.length
      // a selection that is no longer there, and not loaded, is dropped
      if (this.selected >= this.entries.length) this.selected = -1
      if (this.loaded >= this.entries.length) { this.loaded = -1; this.state = DECK.EMPTY }
    } else if (ev.type === 'deck') {
      this.state = ev.state
      if (ev.state === DECK.EMPTY) {
        this.loaded = -1; this.pos = 0; this.len = 0; this.resident = 0
      }
      if (ev.state === DECK.READY) {
        // the whole image is in the player: the counter starts at the head
        this.pos = 0
        if (!this.resident) this.resident = this.len
      }
      if (ev.state === DECK.ERROR) {
        this.error = 'the card could not be read'
        if (this.card === 'waiting') this.card = 'error'
      }
      else if (ev.state !== DECK.ERROR) this.error = ''
    } else if (ev.type === 'progress') {
      this.loaded = ev.idx
      this.len = ev.len || this.len
      if (this.state === DECK.LOADING) {
        // while the card is streaming, this is how much has landed in DDR3
        this.resident = ev.pos
        this.pos = ev.pos
      } else {
        this.pos = ev.pos
      }
    }
    return this
  }

  /** Forget the list before asking for it again. */
  clearList() {
    this.entries = []
    this.card = 'waiting'
    this.selected = -1
    this.listing = false
    return this
  }

  /** Is the board holding a tape the page can start? */
  get held() {
    return this.state === DECK.READY || this.state === DECK.PLAYING || this.state === DECK.ENDED
  }

  /** 0..1, or null while the size is unknown. */
  get fraction() {
    if (!this.len) return null
    return Math.max(0, Math.min(1, this.pos / this.len))
  }

  /** The row the deck shows: the loaded tape, else the one under the cursor. */
  get deckEntry() {
    const i = this.loaded >= 0 ? this.loaded : this.selected
    return i >= 0 ? (this.entries[i] ?? null) : null
  }

  get stateLabel() {
    switch (this.state) {
      case DECK.LOADING: return 'loading from card'
      case DECK.READY: return 'ready \u00b7 type LOAD ""'
      case DECK.PLAYING: return 'playing'
      case DECK.ENDED: return 'end of tape'
      case DECK.ERROR: return 'card error'
      default: return this.loaded < 0 ? 'no tape' : 'empty'
    }
  }
}

// ---------------------------------------------------------------------------
//  A demo deck: the same events the board sends, generated in the browser so
//  the page can be reviewed without a board (?demo=1).  It is deliberately
//  small and clearly labelled in the UI.
// ---------------------------------------------------------------------------

export const DEMO_TAPES = [
  { name: 'Hobbit, The v1.2 (1982)(Melbourne House).tap', size: 47178 },
  { name: 'Jetpac (1983)(Ultimate).tap', size: 30208 },
  { name: 'Atic Atac (1983)(Ultimate).tap', size: 42432 },
  { name: 'Manic Miner (1983)(Bug-Byte).tap', size: 33792 },
  { name: 'Skool Daze (1984)(Microsphere).tap', size: 50432 },
  { name: 'Chuckie Egg (1983)(A&F).tap', size: 33792 },
  { name: 'Sabre Wulf (1984)(Ultimate).tap', size: 42496 },
  { name: 'Knight Lore (1984)(Ultimate).tap', size: 46080 },
]

/** A fake board: same event stream, driven by timers. */
export class DemoBoard {
  constructor(onFrame, total = 1_000_000) {
    this.onFrame = onFrame
    this.tapes = DEMO_TAPES
    this.timer = null
    this.state = DECK.EMPTY
    this.idx = -1
    this.pos = 0
    this.loadMs = 1400
    this.bytesPerTick = 900
    this.total = total
  }

  start() {
    this.timer = setInterval(() => this.tick(120), 120)
    // put the first tape in and let it run: the page is being reviewed, and a
    // deck with a tape in it says more than an empty one
    setTimeout(() => { this.list(); this.select(0) }, 200)
  }

  stop() {
    if (this.timer) clearInterval(this.timer)
    this.timer = null
  }

  /** Feed the same parsed events the board would send. */
  _emit(ev) {
    this.onFrame(ev)
  }

  list() {
    this.onFrame({ type: 'clear' })
    for (const t of this.tapes) this._emit({ type: 'entry', name: t.name, size: t.size })
    this._emit({ type: 'list', count: this.tapes.length })
  }

  select(idx) {
    const t = this.tapes[idx]
    if (!t) return
    this.idx = idx
    this.pos = 0
    this.set(DECK.LOADING)
    this._emit({ type: 'progress', idx, pos: 0, len: t.size })
    this.loadAt = Date.now() + this.loadMs
  }

  eject() {
    this.idx = -1
    this.pos = 0
    this.set(DECK.EMPTY)
  }

  play() {
    if (this.state === DECK.READY || this.state === DECK.ENDED) {
      if (this.state === DECK.ENDED) this.pos = 0
      this.set(DECK.PLAYING)
    }
  }

  captureScreen() {
    // Generate a simulated Sinclair ZX Spectrum boot screen
    const buf = new Uint8Array(SCR_BYTES)
    // Default paper: all 768 attributes = 0x38 (paper white, ink black)
    for (let i = 6144; i < 6912; i++) buf[i] = 0x38
    // Bottom line text: (C) 1982 Sinclair Research Ltd
    // Scanlines for row 23 (bottom line, y=184..191): block 2 (128..191), row 7 (56..63)
    this._emit({ type: 'screen', border: 7, flash: 0, data: buf })
  }

  set(s) {
    this.state = s
    this._emit({ type: 'deck', state: s })
  }

  tick() {
    const t = this.idx >= 0 ? this.tapes[this.idx] : null
    if (!t) return
    if (this.state === DECK.LOADING) {
      this.pos = Math.min(t.size, this.pos + 16000)
      this._emit({ type: 'progress', idx: this.idx, pos: this.pos, len: t.size })
      if (this.pos >= t.size) {
        this.set(DECK.READY)
        this.playAt = Date.now() + 1200
      }
    } else if (this.state === DECK.READY && this.playAt && Date.now() >= this.playAt) {
      this.playAt = 0
      this.play()
    } else if (this.state === DECK.ENDED && this.rewindAt && Date.now() >= this.rewindAt) {
      this.rewindAt = 0
      this.pos = 0
      this._emit({ type: 'progress', idx: this.idx, pos: 0, len: t.size })
      this.play()
    } else if (this.state === DECK.PLAYING) {
      this.pos = Math.min(t.size, this.pos + this.bytesPerTick)
      this._emit({ type: 'progress', idx: this.idx, pos: this.pos, len: t.size })
      if (this.pos >= t.size) {
        this.set(DECK.ENDED)
        this.rewindAt = Date.now() + 1500
      }
    }
  }
}
