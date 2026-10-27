// ============================================================================
//  protocol.js -- the host side of the ZX_TP20K UART protocol
//
//  Plain JS so `node --test` can import the exact code the browser bundles.
//  The FPGA end is src/zx_input.v (keys) and src/zx_tape_lib.v (the tape
//  library); the wire rate is 1 Mbps 8N1 and the board announces itself with
//  the banner in serial-link.js's HANDSHAKE.
//
//    page -> board
//      0xFE <pos> <down>     one key event: pos = ZX matrix position row*5+col
//                            (0..39), down bit0 = pressed
//      0xFF 0x04             all keys up (sent on blur / tab-out)
//      0xFB <sub> [args]     the tape library
//                              0x4C ('L')            send the list again
//                              0x53 ('S') <idx>      load tape idx into DDR3
//                              0x43 ('C')            eject
//                              0x50 ('P')            play now (skip the hold)
//                              0x48 ('H')            pause / resume
//                              0x52 ('R')            rewind to the start, stopped
//                              0x41/0x61 ('A'/'a')   tape audio to HDMI on/off
//                              0x49 ('I') <off le24> instant load's hand-over
//                              0x56 ('V')            report the version
//      0xFA                  screen capture (src/zx_scr_cap.v)
//      0xFC <sub> ...        snapshot packets (src/zx_snap.v)
//      0x02 ... 'c'          raw SD card mode (src/sd/sd_raw_bridge.v)
//
//    board -> page
//      0xF7 <len> <name…> <size le32>   one library entry
//      0xF6 <count>                     end of the library list
//      0xF8 <state>          deck state, see DECK below
//      0xF9 <idx> <pos le24> <len le32>               where the tape is
//      0xF5 <status> <6912 bytes>       a captured screen
//      ASCII                 the boot banner
// ============================================================================

/** Leader for FE <pos> <down>. */
export const KEY_HDR = 0xfe

/** Leader for FF <kind>. */
export const CMD_HDR = 0xff

/** FF 04: release every key. */
export const ALL_UP = 0x04

/** Leader for FB <sub> [args]: the tape library's commands. */
export const LIB_CMD = 0xfb

/** Board -> page: one library entry, <len> <name…> <size le32>. */
export const LIB_ENTRY = 0xf7

/** Board -> page: the end of the list, <count>. */
export const LIB_END = 0xf6

/** Board -> page: the deck's state. */
export const DECK_STATE = 0xf8

/** Board -> page: the tape's position in the image. */
export const TAPE_POS = 0xf9

/** Leader for screen capture request: FA. */
export const CMD_SCR_CAP = 0xfa

/** Board -> page: screen capture frame header. */
export const SCR_FRAME = 0xf5

/** ZX Spectrum screen size: 6144 bitmap + 768 attribute bytes = 6912. */
export const SCR_BYTES = 6912

/** Deck states, as the board reports them. */
export const DECK = {
  EMPTY: 0,      // nothing in the player
  LOADING: 1,    // card -> DDR3
  READY: 2,      // whole image resident, held for LOAD ""
  PLAYING: 3,    // streaming into EAR
  ENDED: 4,      // played to the end of the image
  ERROR: 5,      // the card could not be read
  PAUSED: 6,     // held mid-tape: EAR frozen, the head where it was
}

/** Library sub-commands. */
export const LIB = {
  LIST: 0x4c,      // 'L'
  SELECT: 0x53,    // 'S'
  EJECT: 0x43,     // 'C'
  PLAY: 0x50,      // 'P'
  PAUSE: 0x48,     // 'H'
  REWIND: 0x52,    // 'R'
  INSTANT: 0x49,   // 'I'
  VERSION: 0x56,   // 'V'
  AUDIO_ON: 0x41,  // 'A'
  AUDIO_OFF: 0x61, // 'a'
}

/** Raw SD card mode (sd_raw_bridge.v): 0x02 enters, 'c' leaves. */
export const CARD_ENTER = 0x02
export const CARD_EXIT = 0x63

/** One key event. `pos` is the matrix position, `down` true to press. */
export function encodeKey(pos, down) {
  return Uint8Array.from([KEY_HDR, pos & 0x3f, down ? 1 : 0])
}

/** Release everything. */
export function encodeAllUp() {
  return Uint8Array.from([CMD_HDR, ALL_UP])
}

/** Ask the board for its library again. */
export function encodeListRequest() {
  return Uint8Array.from([LIB_CMD, LIB.LIST])
}

/** Put tape `idx` (0-based, in the order the board listed them) into the player. */
export function encodeSelectTape(idx) {
  return Uint8Array.from([LIB_CMD, LIB.SELECT, idx & 0x7f])
}

/** Empty the player. */
export function encodeEjectTape() {
  return Uint8Array.from([LIB_CMD, LIB.EJECT])
}

/** Start the tape now instead of waiting for the ROM's LOAD "". */
export function encodePlayTape() {
  return Uint8Array.from([LIB_CMD, LIB.PLAY])
}

/** Hold the tape where it is; again (or play) resumes. */
export function encodePauseTape() {
  return Uint8Array.from([LIB_CMD, LIB.PAUSE])
}

/** Back to the start of the tape, stopped: LOAD "" or play starts it again. */
export function encodeRewindTape() {
  return Uint8Array.from([LIB_CMD, LIB.REWIND])
}

/** Hear the tape through HDMI (at ZXCONFIG.TXT's VOL=, 5% by default) or not. */
export function encodeTapeAudio(on) {
  return Uint8Array.from([LIB_CMD, on ? LIB.AUDIO_ON : LIB.AUDIO_OFF])
}

/**
 * Instant load's hand-over: put the player's head at byte `offset` of its
 * .TAP and arm the trap there, so the ROM's next loads read DDR3 (le24).
 */
export function encodeInstantLoad(offset) {
  return Uint8Array.from([LIB_CMD, LIB.INSTANT, offset & 0xff, (offset >> 8) & 0xff, (offset >> 16) & 0xff])
}

/** Ask the board for its firmware/bitstream version. */
export function encodeVersionRequest() {
  return Uint8Array.from([LIB_CMD, LIB.VERSION])
}

/** Leader for Snapshot Loader packets: FC. */
export const SNAP_HDR = 0xfc

/** Enter snapshot mode (pause CPU). */
export function encodeSnapEnter() {
  return Uint8Array.from([SNAP_HDR, 0x01])
}

/** Write RAM chunk (addr 0x0000..0xBFFF maps to Spectrum 0x4000..0xFFFF). */
export function encodeSnapChunk(addr, data) {
  const len = data.length
  const out = new Uint8Array(6 + len)
  out[0] = SNAP_HDR
  out[1] = 0x02
  out[2] = addr & 0xff
  out[3] = (addr >> 8) & 0xff
  out[4] = len & 0xff
  out[5] = (len >> 8) & 0xff
  out.set(data, 6)
  return out
}

/** Set border color. */
export function encodeSnapBorder(border) {
  return Uint8Array.from([SNAP_HDR, 0x03, border & 0x07])
}

/** Configure CPU registers trampoline (28 bytes). */
export function encodeSnapRegs(regs28) {
  const out = new Uint8Array(2 + 28)
  out[0] = SNAP_HDR
  out[1] = 0x04
  out.set(regs28, 2)
  return out
}

/** Release CPU and execute trampoline to PC. */
export function encodeSnapExecute() {
  return Uint8Array.from([SNAP_HDR, 0x05])
}

/** Request a screen capture from the board. */
export function encodeScreenCapture() {
  return Uint8Array.from([CMD_SCR_CAP])
}


/** What the FPGA prints once, after reset. serial-link.js probes for this. */
export const HANDSHAKE = 'ZX Spectrum'
