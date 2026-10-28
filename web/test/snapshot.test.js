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

test('compressed v1 and v2 images expand the same ED ED runs', () => {
  const runs = [0x11, 0xed, 0xed, 0x05, 0x77, 0x22]       // 11, five 77s, 22
  const want = [0x11, 0x77, 0x77, 0x77, 0x77, 0x77, 0x22]

  // v1: compressed flag in byte 12, the image ends with 00 ED ED 00
  const v1 = new Uint8Array([...new Array(30).fill(0), ...runs, 0x00, 0xed, 0xed, 0x00, 0x99])
  v1[7] = 0x80; v1[12] = 0x20
  assert.deepEqual([...parseZ80Snapshot(v1).ram.subarray(0, 8)], [...want, 0])

  // v2: PC = 0 in the header, 23 extra header bytes, then page 8 (0x4000)
  const v2 = new Uint8Array([...new Array(30).fill(0), 23, 0, 0x00, 0x80, ...new Array(21).fill(0),
    runs.length, 0, 8, ...runs])
  const snap = parseZ80Snapshot(v2)
  assert.equal(snap.pc, 0x8000)
  assert.deepEqual([...snap.ram.subarray(0, 8)], [...want, 0])
})
