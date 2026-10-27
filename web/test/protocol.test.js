// Tests for the wire protocol and the key maps, plain node --test.
import test from 'node:test'
import assert from 'node:assert/strict'
import { encodeKey, encodeAllUp, encodeInstantLoad, KEY_HDR, CMD_HDR, ALL_UP, HANDSHAKE } from '../src/protocol.js'
import { KEYS, pos, eventToChord, charToChord } from '../src/zxkeys.js'

test('the key set is the 40-key matrix, no duplicate positions', () => {
  assert.equal(KEYS.length, 40)
  const seen = new Set(KEYS.map(pos))
  assert.equal(seen.size, 40)
})

test('CAPS SHIFT and SYMBOL SHIFT sit at 0 and 36', () => {
  assert.equal(pos(KEYS.find((k) => k.id === 'caps')), 0)
  assert.equal(pos(KEYS.find((k) => k.id === 'sym')), 36)
})

test('key packets are FE pos down', () => {
  assert.deepEqual(encodeKey(0, true), Uint8Array.from([KEY_HDR, 0, 1]))
  assert.deepEqual(encodeKey(37, false), Uint8Array.from([KEY_HDR, 37, 0]))
  assert.deepEqual(encodeAllUp(), Uint8Array.from([CMD_HDR, ALL_UP]))
})

test('a shifted P is SYMBOL SHIFT + P ("), a capital A is CAPS SHIFT + A', () => {
  const quote = eventToChord({ code: 'KeyP', key: '"', shiftKey: true, getModifierState: () => true })
  assert.deepEqual(quote.keys.map((k) => k.id), ['sym', 'p'])
  assert.deepEqual(quote.keys.map((k) => k.pos), [36, 25])
  const capA = eventToChord({ code: 'KeyA', key: 'A', shiftKey: true, getModifierState: () => true })
  assert.deepEqual(capA.keys.map((k) => k.id), ['caps', 'a'])
})

test('plain letters are one key, shifts are keys of their own', () => {
  const p = eventToChord({ code: 'KeyP', key: 'p', shiftKey: false, getModifierState: () => false })
  assert.deepEqual(p.keys.map((k) => k.id), ['p'])
  const lsh = eventToChord({ code: 'ShiftLeft', key: 'Shift', getModifierState: () => false })
  assert.deepEqual(lsh.keys.map((k) => k.id), ['caps'])
  const rsh = eventToChord({ code: 'ShiftRight', key: 'Shift', getModifierState: () => false })
  assert.deepEqual(rsh.keys.map((k) => k.id), ['sym'])
})

test('paste characters map to the red legends', () => {
  assert.deepEqual(charToChord('"').keys.map((k) => k.id), ['sym', 'p'])
  assert.deepEqual(charToChord('.').keys.map((k) => k.id), ['sym', 'm'])
  assert.deepEqual(charToChord('+').keys.map((k) => k.id), ['sym', 'k'])
  assert.deepEqual(charToChord('\n').keys.map((k) => k.id), ['enter'])
  assert.deepEqual(charToChord('5').keys.map((k) => k.id), ['5'])
  assert.equal(charToChord('§'), null)
})

test('the handshake is what zx_uart_tx.v prints', () => {
  assert.match('[ ZX Spectrum 20K ]', new RegExp(HANDSHAKE))
})

test('instant hand-over is FB 49 and the offset, le24 (src/zx_input.v PK_INST)', () => {
  assert.deepEqual([...encodeInstantLoad(0x010042)], [0xfb, 0x49, 0x42, 0x00, 0x01])
})
