// ============================================================================
//  tape.test.js -- the virtual cassette's host side
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'
import { TapePump, loadCommand, typeLoadCommand } from '../src/tape.js'
import { TAPE_HDR } from '../src/protocol.js'

test('TapePump answers a credit with one 0xFD packet', () => {
  const p = new TapePump()
  p.load(Uint8Array.from([0x11, 0x22]), 'x.tap')
  const out = p.next(1)
  assert.deepEqual(Array.from(out), [TAPE_HDR, 0x11])
  assert.equal(p.remaining, 1)
  assert.equal(p.total, 2)
})

test('TapePump never runs past the file and ignores spare credits', () => {
  const p = new TapePump()
  p.load(Uint8Array.from([1, 2, 3]))
  const out = p.next(10)                 // more credits than bytes
  assert.equal(out.length, 6)            // 3 bytes x 2 wire bytes
  assert.equal(p.remaining, 0)
  assert.equal(p.playing, false)
  assert.equal(p.next(5).length, 0)
})

test('TapePump is empty until a file is loaded, and ejecting clears it', () => {
  const p = new TapePump()
  assert.equal(p.next(4).length, 0)
  p.load(Uint8Array.from([9, 9]))
  assert.equal(p.remaining, 2)
  p.load(null)
  assert.equal(p.remaining, 0)
  assert.equal(p.next(4).length, 0)
})

test('the load command is the J-key LOAD token, quotes, RETURN', () => {
  assert.equal(loadCommand(), 'j""\r')
})

test('typeLoadCommand sends paced matrix key events, not ASCII', async () => {
  const sent = []
  await typeLoadCommand((b) => sent.push(...b), { holdMs: 1, gapMs: 1, repeatGapMs: 1 })
  assert.deepEqual(sent, [
    0xfe, 33, 1, 0xfe, 33, 0,                              // J: the LOAD token
    0xfe, 36, 1, 0xfe, 25, 1, 0xfe, 25, 0, 0xfe, 36, 0,    // " = SYMBOL SHIFT+P chord
    0xfe, 36, 1, 0xfe, 25, 1, 0xfe, 25, 0, 0xfe, 36, 0,    // " again
    0xfe, 30, 1, 0xfe, 30, 0,                              // ENTER
  ])
})

test('the same chord twice waits out the ROM 5-frame key memory', async () => {
  const at = []
  const t0 = Date.now()
  await typeLoadCommand(() => at.push(Date.now() - t0), { holdMs: 1, gapMs: 1, repeatGapMs: 120 })
  // presses: J at 0, " at 2, " at 6 -> the second quote's first key-down
  assert.ok(at[6] - at[5] >= 110, `repeat gap was ${at[6] - at[5]} ms`)
})
