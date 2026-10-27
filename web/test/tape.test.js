// ============================================================================
//  tape.test.js -- the virtual cassette's host side
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'
import { TapePump, parseFromFpga, loadCommand } from '../src/tape.js'
import { TAPE_HDR, TAPE_CREDIT } from '../src/protocol.js'

test('parseFromFpga counts credits and keeps the text', () => {
  const { credits, text } = parseFromFpga(Uint8Array.from([0x5a, TAPE_CREDIT, 0x58, TAPE_CREDIT]))
  assert.equal(credits, 2)
  assert.deepEqual(text, [0x5a, 0x58])
})

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

test('the typed load command is LOAD "" and RETURN', () => {
  assert.deepEqual(loadCommand(), [0x4c, 0x4f, 0x41, 0x44, 0x20, 0x22, 0x22, 0x0d])
})
