// ============================================================================
//  tape.js -- the host side of the virtual cassette deck
//
//  The FPGA has no bulk memory for a tape, so the page drip-feeds the .TAP at
//  cassette speed, one byte per credit the board sends back (0x06).  The
//  board's FIFO is what sets the pace: it asks while it has room, the player
//  drains a byte every ~855 T-states, so a whole file trickles through with a
//  few tens of bytes in flight at any moment.
//
//    page -> board   0xFD <byte>     one tape byte
//    board -> page   0x06            "send me another"
// ============================================================================

import { TAPE_HDR } from './protocol.js'
import { typeText } from './zxkeys.js'

/** A .TAP being played: hold the bytes, answer credits with 0xFD packets. */
export class TapePump {
  constructor() {
    this.bytes = new Uint8Array(0)
    this.off = 0
    this.name = ''
  }

  /** Load a file (Uint8Array) or clear it with no argument. */
  load(bytes, name = '') {
    this.bytes = bytes ? Uint8Array.from(bytes) : new Uint8Array(0)
    this.off = 0
    this.name = name
  }

  get total() { return this.bytes.length }
  get remaining() { return this.bytes.length - this.off }
  get playing() { return this.remaining > 0 }

  /** Bytes to send for `credits` credit bytes (never past the end of the file). */
  next(credits) {
    const n = Math.max(0, Math.min(credits | 0, this.remaining))
    if (n === 0) return new Uint8Array(0)
    const out = new Uint8Array(n * 2)
    for (let i = 0; i < n; i++) {
      out[i * 2] = TAPE_HDR
      out[i * 2 + 1] = this.bytes[this.off + i]
    }
    this.off += n
    return out
  }
}

/**
 * The text the page types to start a tape: a plain 'j' is the LOAD keyword
 * token at the ROM's K cursor (the letters L,O,A,D would type "LOAD" as
 * ordinary characters), then two quotes, then RETURN.
 */
export function loadCommand() {
  return 'j""\r'
}

/**
 * Types LOAD "" + ENTER as paced matrix key events (FE packets): 'j' presses
 * J, each quote is the SYMBOL SHIFT+P chord, RETURN ends the line.  The board
 * only sees key presses -- the character-to-key translation lives in the page
 * (zxkeys.js), like the real membrane, which never knows what a key "means".
 */
export function typeLoadCommand(send, opts) {
  return typeText(loadCommand(), send, opts)
}
