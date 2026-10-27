// ============================================================================
//  zxkeys.js -- the 40-key rubber keyboard, as data
//
//  The ZX Spectrum's 8x5 matrix.  The row is what the ULA drives low (the
//  high byte of the port address), the column is what it reads back; a key
//  connects its row to its column.  Matrix position = row*5 + col, which is
//  the `pos` the web page sends and src/zx_input.v applies.
//
//  Key positions (row, col) -- the standard layout:
//      row0: CAPS SHIFT  Z  X  C  V      row1: A  S  D  F  G
//      row2: Q  W  E  R  T               row3: 1  2  3  4  5
//      row4: 0  9  8  7  6               row5: P  O  I  U  Y
//      row6: ENTER  L  K  J  H           row7: SPACE  SYMBOL SHIFT  M  N  B
//
//  `sub` is the red legend (SYMBOL SHIFT); `white` is the white legend
//  (CAPS SHIFT, mostly BASIC tokens, which the ROM itself provides -- we do
//  not send tokens, just keys).
// ============================================================================

/** @typedef {{id: string, row: number, col: number, legend: string, sub?: string, wide?: boolean, latch?: boolean}} ZxKey */

/** pos = row*5+col for a key. */
export const pos = (k) => k.row * 5 + k.col

/** @type {ZxKey[]} */
export const KEYS = [
  // row 0
  { id: 'caps', row: 0, col: 0, legend: 'CAPS SHIFT', wide: true },
  { id: 'z', row: 0, col: 1, legend: 'Z', sub: ':' },
  { id: 'x', row: 0, col: 2, legend: 'X', sub: '£' },
  { id: 'c', row: 0, col: 3, legend: 'C', sub: '?' },
  { id: 'v', row: 0, col: 4, legend: 'V', sub: '/' },
  // row 1
  { id: 'a', row: 1, col: 0, legend: 'A', sub: '~' },
  { id: 's', row: 1, col: 1, legend: 'S', sub: '|' },
  { id: 'd', row: 1, col: 2, legend: 'D', sub: '\\' },
  { id: 'f', row: 1, col: 3, legend: 'F', sub: '{' },
  { id: 'g', row: 1, col: 4, legend: 'G', sub: '}' },
  // row 2
  { id: 'q', row: 2, col: 0, legend: 'Q', sub: '<=' },
  { id: 'w', row: 2, col: 1, legend: 'W', sub: '<>' },
  { id: 'e', row: 2, col: 2, legend: 'E', sub: '>=' },
  { id: 'r', row: 2, col: 3, legend: 'R', sub: '<' },
  { id: 't', row: 2, col: 4, legend: 'T', sub: '>' },
  // row 3
  { id: '1', row: 3, col: 0, legend: '1', sub: '!' },
  { id: '2', row: 3, col: 1, legend: '2', sub: '@' },
  { id: '3', row: 3, col: 2, legend: '3', sub: '#' },
  { id: '4', row: 3, col: 3, legend: '4', sub: '$' },
  { id: '5', row: 3, col: 4, legend: '5', sub: '%' },
  // row 4
  { id: '0', row: 4, col: 0, legend: '0', sub: '_' },
  { id: '9', row: 4, col: 1, legend: '9', sub: ')' },
  { id: '8', row: 4, col: 2, legend: '8', sub: '(' },
  { id: '7', row: 4, col: 3, legend: '7', sub: "'" },
  { id: '6', row: 4, col: 4, legend: '6', sub: '&' },
  // row 5
  { id: 'p', row: 5, col: 0, legend: 'P', sub: '"' },
  { id: 'o', row: 5, col: 1, legend: 'O', sub: ';' },
  { id: 'i', row: 5, col: 2, legend: 'I', sub: 'STOP' },
  { id: 'u', row: 5, col: 3, legend: 'U', sub: ']' },
  { id: 'y', row: 5, col: 4, legend: 'Y', sub: '[' },
  // row 6
  { id: 'enter', row: 6, col: 0, legend: 'ENTER', wide: true },
  { id: 'l', row: 6, col: 1, legend: 'L', sub: '=' },
  { id: 'k', row: 6, col: 2, legend: 'K', sub: '+' },
  { id: 'j', row: 6, col: 3, legend: 'J', sub: '-' },
  { id: 'h', row: 6, col: 4, legend: 'H', sub: '^' },
  // row 7
  { id: 'space', row: 7, col: 0, legend: 'SPACE', wide: true },
  { id: 'sym', row: 7, col: 1, legend: 'SYMBOL SHIFT', wide: true },
  { id: 'm', row: 7, col: 2, legend: 'M', sub: '.' },
  { id: 'n', row: 7, col: 3, legend: 'N', sub: ',' },
  { id: 'b', row: 7, col: 4, legend: 'B', sub: '*' },
]

export const KEY_BY_ID = Object.fromEntries(KEYS.map((k) => [k.id, k]))

// ---------------------------------------------------------------------------
//  The PC keyboard: browser event.code -> a ZX key id
//
//  What each key *types* is decided here, not in the FPGA: the page turns a
//  chord (e.g. shift+P for '"') into the Spectrum's own chord (SYMBOL SHIFT
//  held + P), so BASIC gets a key sequence it believes.
// ---------------------------------------------------------------------------

const PC_TO_ZX = {
  KeyQ: 'q', KeyW: 'w', KeyE: 'e', KeyR: 'r', KeyT: 't', KeyY: 'y', KeyU: 'u',
  KeyI: 'i', KeyO: 'o', KeyP: 'p',
  KeyA: 'a', KeyS: 's', KeyD: 'd', KeyF: 'f', KeyG: 'g', KeyH: 'h', KeyJ: 'j',
  KeyK: 'k', KeyL: 'l',
  KeyZ: 'z', KeyX: 'x', KeyC: 'c', KeyV: 'v', KeyB: 'b', KeyN: 'n', KeyM: 'm',
  Digit1: '1', Digit2: '2', Digit3: '3', Digit4: '4', Digit5: '5',
  Digit6: '6', Digit7: '7', Digit8: '8', Digit9: '9', Digit0: '0',
  Enter: 'enter', NumpadEnter: 'enter', Space: 'space',
  ShiftLeft: 'caps', ShiftRight: 'sym', AltRight: 'sym',
  Backspace: 'caps',   // CAPS SHIFT+0 is DELETE on the Spectrum; plain caps at least edits
}

/** The character a PC keystroke types, as {zxKey, sym, caps}. */
const CHAR_MAP = {
  '!': { zx: '1', sym: true }, '@': { zx: '2', sym: true }, '#': { zx: '3', sym: true },
  $: { zx: '4', sym: true }, '%': { zx: '5', sym: true }, '&': { zx: '6', sym: true },
  "'": { zx: '7', sym: true }, '(': { zx: '8', sym: true }, ')': { zx: '9', sym: true },
  _: { zx: '0', sym: true },
  '+': { zx: 'k', sym: true }, '-': { zx: 'j', sym: true }, '*': { zx: 'b', sym: true },
  '/': { zx: 'v', sym: true }, '=': { zx: 'l', sym: true }, '^': { zx: 'h', sym: true },
  '.': { zx: 'm', sym: true }, ',': { zx: 'n', sym: true }, ':': { zx: 'z', sym: true },
  ';': { zx: 'o', sym: true }, '"': { zx: 'p', sym: true }, '?': { zx: 'c', sym: true },
  '<': { zx: 'r', sym: true }, '>': { zx: 't', sym: true },
}

/**
 * Turn a browser KeyboardEvent into the Spectrum keys it means.
 * @returns {{keys: {id: string, pos: number}[]}|null} the chord to send, or null
 */
export function eventToChord(ev) {
  const zxId = PC_TO_ZX[ev.code]
  if (!zxId) {
    // printable punctuation by character
    if (ev.key.length === 1) {
      const ch = ev.key
      const m = CHAR_MAP[ch]
      if (m) return chord(m.zx, m.sym, false)
    }
    return null
  }
  if (zxId === 'caps' || zxId === 'sym') return chord(zxId, false, false)
  const shift = ev.getModifierState?.('Shift') ?? ev.shiftKey
  if (shift && ev.key.length === 1 && CHAR_MAP[ev.key]) {
    const m = CHAR_MAP[ev.key]
    return chord(m.zx, m.sym, false)
  }
  // letters: shift (or caps lock) means CAPS SHIFT
  const caps = shift && /^[a-z]$/i.test(ev.key)
  return chord(zxId, false, caps)
}

function chord(zxId, sym, caps) {
  const keys = []
  if (caps) keys.push('caps')
  if (sym) keys.push('sym')
  keys.push(zxId)
  return {
    keys: keys
      .map((id) => KEY_BY_ID[id])
      .filter(Boolean)
      .map((k) => ({ id: k.id, pos: pos(k) })),
  }
}

export { CHAR_MAP }

/** A single character as the Spectrum chord that types it. */
export function charToChord(ch) {
  if (ch === '\n' || ch === '\r') return chord('enter', false, false)
  if (ch === ' ') return chord('space', false, false)
  if (/[a-z]/.test(ch)) return chord(ch, false, false)
  if (/[A-Z]/.test(ch)) return chord(ch.toLowerCase(), false, true)
  if (/[0-9]/.test(ch)) return chord(ch, false, false)
  const m = CHAR_MAP[ch]
  if (m) return chord(m.zx, m.sym, false)
  return null
}

// ---------------------------------------------------------------------------
//  LAYOUT -- the keyboard exactly as the 48K case prints it: four rows of ten,
//  with the legends around each key.  Read off the reference photo.
//
//    name/ink  the colour word above a number key, printed in that colour
//    fn        the white function above a number key (EDIT, CAPS LOCK, ...)
//    above     the green SYMBOL SHIFT keyword above a letter key
//    sym       the small orange legend on the right of the key face
//    sub       the white CAPS SHIFT keyword on the key face
//    below     the orange extended-mode word below the key
//    w         width in normal-key units
// ---------------------------------------------------------------------------
export const LAYOUT = [
  // ---- 1 2 3 4 5 6 7 8 9 0 ------------------------------------------------
  [
    { id: '1', main: '1', name: 'BLUE',    ink: '#3a56d0', fn: 'EDIT',       sym: '!',  below: 'DEF FN' },
    { id: '2', main: '2', name: 'RED',     ink: '#e8262f', fn: 'CAPS LOCK',  sym: '@',  below: 'FN' },
    { id: '3', main: '3', name: 'MAGENTA', ink: '#c94fb0', fn: 'TRUE VIDEO', sym: '#',  below: 'LINE' },
    { id: '4', main: '4', name: 'GREEN',   ink: '#2fa83a', fn: 'INV. VIDEO', sym: '$',  below: 'OPEN #' },
    { id: '5', main: '5', name: 'CYAN',    ink: '#22a8b0', fn: '\u2190',     sym: '%',  below: 'CLOSE #' },
    { id: '6', main: '6', name: 'YELLOW',  ink: '#e8df1c', fn: '\u2193',     sym: '&',  below: 'MOVE' },
    { id: '7', main: '7', name: 'WHITE',   ink: '#ffffff', fn: '\u2191',     sym: "'",  below: 'ERASE' },
    { id: '8', main: '8', fn: '\u2192',                                       sym: '(',  below: 'POINT' },
    { id: '9', main: '9', name: 'GRAPHICS', ink: '#ffffff',                   sym: ')',  below: 'CAT' },
    { id: '0', main: '0', name: 'BLACK',   ink: '#0b0b0c', chip: true, fn: 'DELETE', sym: '_', below: 'FORMAT' },
  ],

  // ---- Q W E R T Y U I O P ------------------------------------------------
  [
    { id: 'q', main: 'Q', above: 'SIN',   sym: '<=',  sub: 'PLOT',   below: 'ASN' },
    { id: 'w', main: 'W', above: 'COS',   sym: '<>',  sub: 'DRAW',   below: 'ACS' },
    { id: 'e', main: 'E', above: 'TAN',   sym: '>=',  sub: 'REM',    below: 'ATN' },
    { id: 'r', main: 'R', above: 'INT',   sym: '<',   sub: 'RUN',    below: 'VERIFY' },
    { id: 't', main: 'T', above: 'RND',   sym: '>',   sub: 'RAND',   below: 'MERGE' },
    { id: 'y', main: 'Y', above: 'STR $', sym: 'AND', sub: 'RETURN', below: '[' },
    { id: 'u', main: 'U', above: 'CHR $', sym: 'OR',  sub: 'IF',     below: ']' },
    { id: 'i', main: 'I', above: 'CODE',  sym: 'AT',  sub: 'INPUT',  below: 'IN' },
    { id: 'o', main: 'O', above: 'PEEK',  sym: ';',   sub: 'POKE',   below: 'OUT' },
    { id: 'p', main: 'P', above: 'TAB',   sym: '"',   sub: 'PRINT',  below: '\u00a9' },
  ],

  // ---- A S D F G H J K L ENTER -------------------------------------------
  [
    { id: 'a', main: 'A', above: 'READ',    sym: 'STOP', sub: 'NEW',   below: '~' },
    { id: 's', main: 'S', above: 'RESTORE', sym: 'NOT',  sub: 'SAVE',  below: '|' },
    { id: 'd', main: 'D', above: 'DATA',    sym: 'STEP', sub: 'DIM',   below: '\\' },
    { id: 'f', main: 'F', above: 'SGN',     sym: 'TO',   sub: 'FOR',   below: '{' },
    { id: 'g', main: 'G', above: 'ABS',     sym: 'THEN', sub: 'GOTO',  below: '}' },
    { id: 'h', main: 'H', above: 'SQR',     sym: '\u2191', sub: 'GOSUB', below: 'CIRCLE' },
    { id: 'j', main: 'J', above: 'VAL',     sym: '-',    sub: 'LOAD',  below: 'VAL $' },
    { id: 'k', main: 'K', above: 'LEN',     sym: '+',    sub: 'LIST',  below: 'SCREEN $' },
    { id: 'l', main: 'L', above: 'USR',     sym: '=',    sub: 'LET',   below: 'ATTR' },
    { id: 'enter', main: 'ENTER', w: 1.35 },
  ],

  // ---- CAPS SHIFT Z X C V B N M SYMBOL SHIFT BREAK SPACE ------------------
  [
    { id: 'caps',  main: 'CAPS',   sub: 'SHIFT', w: 1.4 },
    { id: 'z', main: 'Z', above: 'LN',      sym: ':',    sub: 'COPY',   below: 'BEEP' },
    { id: 'x', main: 'X', above: 'EXP',     sym: '\u00a3', sub: 'CLEAR', below: 'INK' },
    { id: 'c', main: 'C', above: 'L PRINT', sym: '?',    sub: 'CONT',   below: 'PAPER' },
    { id: 'v', main: 'V', above: 'L LIST',  sym: '/',    sub: 'CLS',    below: 'FLASH' },
    { id: 'b', main: 'B', above: 'BIN',     sym: '*',    sub: 'BORDER', below: 'BRIGHT' },
    { id: 'n', main: 'N', above: 'IN KEY $', sym: ',',   sub: 'NEXT',   below: 'OVER' },
    { id: 'm', main: 'M', above: 'PI',      sym: '.',    sub: 'PAUSE',  below: 'INVERSE' },
    { id: 'sym',   main: 'SYMBOL', sub: 'SHIFT', w: 1.4, warm: true },
    { id: 'space', main: 'BREAK',  sub: 'SPACE', w: 2.05 },
  ],
]
