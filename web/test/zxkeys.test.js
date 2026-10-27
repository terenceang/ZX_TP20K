// ============================================================================
//  zxkeys.test.js -- the character-to-key translation (the page's job, not
//  the FPGA's: the board only ever sees matrix key events)
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'
import { charToChord, pos, KEYS, KEY_BY_ID } from '../src/zxkeys.js'

test('pos is row*5+col for every key, all 40 distinct', () => {
  assert.equal(KEYS.length, 40)
  const ps = new Set(KEYS.map(pos))
  assert.equal(ps.size, 40)
})

test('lowercase letters are plain keys', () => {
  assert.deepEqual(charToChord('j'), { keys: [{ id: 'j', pos: pos(KEY_BY_ID.j) }] })
})

test('capitals chord CAPS SHIFT + the letter', () => {
  assert.deepEqual(charToChord('A').keys, [
    { id: 'caps', pos: 0 },
    { id: 'a', pos: pos(KEY_BY_ID.a) },
  ])
})

test('red legends chord SYMBOL SHIFT + the key', () => {
  assert.deepEqual(charToChord('"').keys, [
    { id: 'sym', pos: pos(KEY_BY_ID.sym) },
    { id: 'p', pos: pos(KEY_BY_ID.p) },
  ])
})

test('RETURN and SPACE are plain keys, unknown chars are skipped', () => {
  assert.deepEqual(charToChord('\r').keys, [{ id: 'enter', pos: pos(KEY_BY_ID.enter) }])
  assert.deepEqual(charToChord(' ').keys, [{ id: 'space', pos: pos(KEY_BY_ID.space) }])
  assert.equal(charToChord('\t'), null)
})
