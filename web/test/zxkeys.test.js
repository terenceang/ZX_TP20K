// ============================================================================
//  zxkeys.test.js -- the character-to-key translation (the page's job, not
//  the FPGA's: the board only ever sees matrix key events)
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'
import { charToChord, eventToChord, pos, KEYS, KEY_BY_ID } from '../src/zxkeys.js'

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

test('Backspace is DELETE: CAPS SHIFT + 0', () => {
  const c = eventToChord({ code: 'Backspace', key: 'Backspace' })
  assert.deepEqual(c.keys.map((k) => k.pos).sort((a, b) => a - b), [0, 20])
})

test('joystick: arrows and ctrl follow the selected scheme, off passes through', async () => {
  const { joyChord } = await import('../src/zxkeys.js')
  assert.deepEqual(joyChord('ArrowUp', 'cursor').keys, [{ id: '7', pos: pos(KEY_BY_ID['7']) }])
  assert.deepEqual(joyChord('ControlLeft', 'sinclair1').keys, [{ id: '0', pos: pos(KEY_BY_ID['0']) }])
  assert.deepEqual(joyChord('ArrowLeft', 'qaop').keys, [{ id: 'o', pos: pos(KEY_BY_ID.o) }])
  assert.equal(joyChord('ArrowUp', 'off'), null)
  assert.equal(joyChord('KeyQ', 'cursor'), null)
})

test('joystick: gamepad stick, d-pad and fire', async () => {
  const { padDirs } = await import('../src/zxkeys.js')
  const btn = (on) => Array.from({ length: 16 }, (_, i) => ({ pressed: on.includes(i) }))
  assert.deepEqual(padDirs({ axes: [-1, 0.1], buttons: btn([0]) }),
    { up: false, down: false, left: true, right: false, fire: true })
  assert.deepEqual(padDirs({ axes: [0, 0], buttons: btn([12, 15]) }),
    { up: true, down: false, left: false, right: true, fire: false })
})
