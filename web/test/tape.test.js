// ============================================================================
//  tape.test.js -- the LOAD "" macro
// ============================================================================

import test from 'node:test'
import assert from 'node:assert/strict'
import { loadCommand, typeLoadCommand } from '../src/tape.js'

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
