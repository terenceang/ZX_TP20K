// Tests for the tape library's wire format and the deck's model, plain node --test.
import test from 'node:test'
import assert from 'node:assert/strict'
import { BoardFrames, TapeLibrary, DEMO_TAPES } from '../src/library.js'
import {
  LIB_ENTRY, LIB_END, DECK_STATE, TAPE_POS, TAPE_CREDIT, DECK, SCR_FRAME, SCR_BYTES, encodeScreenCapture, CMD_SCR_CAP,
  encodeListRequest, encodeSelectTape, encodeEjectTape, encodePlayTape, LIB_CMD, LIB,
} from '../src/protocol.js'

const enc = (s) => Array.from(new TextEncoder().encode(s))

/** 0xF7 <len> <name…> <size le32> -- one entry, as the board sends it */
const entry = (name, size) => [
  LIB_ENTRY, name.length,
  ...enc(name),
  size & 0xff, (size >> 8) & 0xff, (size >> 16) & 0xff, (size >>> 24) & 0xff,
]

test('commands are FB <sub> [idx]', () => {
  assert.deepEqual(encodeListRequest(), Uint8Array.from([LIB_CMD, LIB.LIST]))
  assert.deepEqual(encodeSelectTape(0), Uint8Array.from([LIB_CMD, LIB.SELECT, 0]))
  assert.deepEqual(encodeSelectTape(9), Uint8Array.from([LIB_CMD, LIB.SELECT, 9]))
  assert.deepEqual(encodeEjectTape(), Uint8Array.from([LIB_CMD, LIB.EJECT]))
  assert.deepEqual(encodePlayTape(), Uint8Array.from([LIB_CMD, LIB.PLAY]))
})

test('entries arrive one at a time, then the end marker', () => {
  const events = []
  const f = new BoardFrames((e) => events.push(e))
  const stream = Uint8Array.from([
    ...entry('HOBBIT  TAP', 47178),
    ...entry('JETPAC  TAP', 30208),
    LIB_END, 2,
  ])
  const { text } = f.feed(stream)
  assert.equal(text.length, 0)
  assert.deepEqual(events, [
    { type: 'entry', name: 'HOBBIT.TAP', size: 47178 },
    { type: 'entry', name: 'JETPAC.TAP', size: 30208 },
    { type: 'list', count: 2 },
  ])
})

test('an empty library is just the end marker', () => {
  const events = []
  new BoardFrames((e) => events.push(e)).feed(Uint8Array.from([LIB_END, 0]))
  assert.deepEqual(events, [{ type: 'list', count: 0 }])
})

test('a frame split anywhere still parses', () => {
  const events = []
  const f = new BoardFrames((e) => events.push(e))
  const stream = Uint8Array.from([...entry('A       TAP', 700), LIB_END, 1])
  for (const b of stream) f.feed(Uint8Array.from([b]))
  assert.deepEqual(events, [
    { type: 'entry', name: 'A.TAP', size: 700 },
    { type: 'list', count: 1 },
  ])
})

test('deck state and position frames', () => {
  const events = []
  const f = new BoardFrames((e) => events.push(e))
  f.feed(Uint8Array.from([DECK_STATE, DECK.PLAYING, TAPE_POS, 3,
    1234 & 0xff, (1234 >> 8) & 0xff, (1234 >> 16) & 0xff,
    47178 & 0xff, (47178 >> 8) & 0xff, (47178 >> 16) & 0xff, (47178 >>> 24) & 0xff]))
  assert.deepEqual(events, [
    { type: 'deck', state: DECK.PLAYING },
    { type: 'progress', idx: 3, pos: 1234, len: 47178 },
  ])
})

test('text and credits pass through, frames do not leak into the banner', () => {
  const events = []
  const f = new BoardFrames((e) => events.push(e))
  const { text, credits } = f.feed(Uint8Array.from([...enc('ZX Spectrum'), TAPE_CREDIT, DECK_STATE, 2, ...enc('!')]))
  assert.equal(new TextDecoder().decode(text), 'ZX Spectrum!')
  assert.equal(credits, 1)
  assert.deepEqual(events, [{ type: 'deck', state: DECK.READY }])
})

test('the library model follows the board and drops a stale selection', () => {
  const lib = new TapeLibrary()
  lib.apply({ type: 'entry', name: 'A.TAP', size: 100 })
  lib.apply({ type: 'entry', name: 'B.TAP', size: 200 })
  lib.apply({ type: 'list', count: 2 })
  lib.selected = 1
  assert.equal(lib.deckEntry.name, 'B.TAP')

  lib.apply({ type: 'deck', state: DECK.LOADING })
  lib.apply({ type: 'progress', idx: 1, pos: 50, len: 200 })
  assert.equal(lib.loaded, 1)
  assert.equal(lib.held, false)
  assert.equal(lib.fraction, 0.25)

  lib.apply({ type: 'deck', state: DECK.PLAYING })
  assert.equal(lib.held, true)

  // a rescan clears, then lists one tape fewer
  lib.clearList()
  assert.equal(lib.entries.length, 0)
  assert.equal(lib.card, 'waiting')
  lib.apply({ type: 'entry', name: 'A.TAP', size: 100 })
  lib.apply({ type: 'list', count: 1 })
  assert.equal(lib.selected, -1)
  assert.equal(lib.loaded, -1)
  assert.equal(lib.state, DECK.EMPTY)
})

test('the demo library looks like a card of tapes', () => {
  assert.ok(DEMO_TAPES.length >= 4)
  for (const t of DEMO_TAPES) {
    assert.match(t.name, /\.tap$/)
    assert.ok(t.size > 1024 && t.size <= 0x100000)
  }
})

test('screen capture command and frame parsing', () => {
  assert.deepEqual(encodeScreenCapture(), Uint8Array.from([CMD_SCR_CAP]))

  const events = []
  const f = new BoardFrames((e) => events.push(e))

  const dummyData = new Uint8Array(SCR_BYTES)
  for (let i = 0; i < SCR_BYTES; i++) dummyData[i] = i & 0xff

  // Frame: SCR_FRAME (0xF5), status byte (border 5, flash 1 -> 0x0D), 6912 data bytes
  const stream = new Uint8Array(2 + SCR_BYTES)
  stream[0] = SCR_FRAME
  stream[1] = 0x0d // flash = 1, border = 5 (cyan)
  stream.set(dummyData, 2)

  // Feed in chunks
  f.feed(stream.subarray(0, 100))
  f.feed(stream.subarray(100, 3000))
  f.feed(stream.subarray(3000))

  assert.equal(events.length, 1)
  assert.equal(events[0].type, 'screen')
  assert.equal(events[0].border, 5)
  assert.equal(events[0].flash, 1)
  assert.equal(events[0].data.length, SCR_BYTES)
  assert.deepEqual(events[0].data, dummyData)
})

test('a second listing replaces the first instead of stacking onto it', () => {
  const lib = new TapeLibrary()
  const f = new BoardFrames((e) => lib.apply(e))
  const list = [...entry('HOBBIT~1TAP', 47178), ...entry('SNAP    Z80', 49179), LIB_END, 2]
  f.feed(Uint8Array.from([...list, ...list]))   // the page asks twice on connect
  assert.deepEqual(lib.entries.map((e) => e.name), ['HOBBIT~1.TAP', 'SNAP.Z80'])
  f.feed(Uint8Array.from([LIB_END, 0]))         // the last tape deleted
  assert.deepEqual(lib.entries, [])
})
