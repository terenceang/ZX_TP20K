import test from 'node:test'
import assert from 'node:assert/strict'
import { parseZ80Snapshot } from '../src/z80-snapshot.js'

test('parse basic v1 z80 snapshot', () => {
  const file = new Uint8Array(30 + 49152)
  file[0] = 0x12 // A
  file[1] = 0x34 // F
  file[2] = 0x56 // C
  file[3] = 0x78 // B
  file[4] = 0x9a // L
  file[5] = 0xbc // H
  file[6] = 0x00 // PC lo (v1: 0x8000)
  file[7] = 0x80 // PC hi
  file[8] = 0xff // SP lo (0xFFFE)
  file[9] = 0xff // SP hi
  file[10] = 0x3f // I
  file[11] = 0x15 // R
  file[12] = (2 << 1) // Border color 2, uncompressed

  // Fill sample RAM data
  file[30] = 0xaa
  file[30 + 16384] = 0x55

  const snap = parseZ80Snapshot(file)
  assert.equal(snap.border, 2)
  assert.equal(snap.pc, 0x8000)
  assert.equal(snap.sp, 0xffff)
  assert.equal(snap.ram[0], 0xaa)
  assert.equal(snap.ram[16384], 0x55)
  assert.equal(snap.regs.length, 28)
  assert.equal(snap.regs[0], 0x00) // PC lo
  assert.equal(snap.regs[1], 0x80) // PC hi
  assert.equal(snap.regs[4], 0x34) // F
  assert.equal(snap.regs[5], 0x12) // A
})
