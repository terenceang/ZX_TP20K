// tape-snapshot.js against the real 48K ROM (skipped without roms/zx48.rom):
// sim/data/hello_tap.hex is a header + a BASIC program that autostarts at
// line 10: BORDER 2: PAPER 6: CLS: PRINT "TP20K TAPE OK".
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { tapeToSnapshot } from '../src/tape-snapshot.js'

const romPath = new URL('../../roms/zx48.rom', import.meta.url)
const rom = existsSync(romPath) ? new Uint8Array(readFileSync(romPath)) : null
const tap = Uint8Array.from(
  readFileSync(new URL('../../sim/data/hello_tap.hex', import.meta.url), 'utf8')
    .trim().split(/\s+/).map((h) => parseInt(h, 16)))

// the TAP's blocks, as [flag+data+checksum] arrays
const blocks = []
for (let o = 0; o < tap.length; o += 2 + (tap[o] | (tap[o + 1] << 8)))
  blocks.push(tap.subarray(o + 2, o + 2 + (tap[o] | (tap[o + 1] << 8))))

const tzx = (blockBytes) => Uint8Array.from([...Buffer.from('ZXTape!\x1a\x01\x14', 'latin1'), ...blockBytes])
const w16 = (v) => [v & 0xff, v >> 8]

const std10 = blocks.flatMap((d) => [0x10, ...w16(1000), ...w16(d.length), ...d])
// 0x11 with the ROM's own timings: not flash-loaded, so the ROM reads edges
const turbo11 = blocks.flatMap((d) => [
  0x11, ...w16(2168), ...w16(667), ...w16(735), ...w16(855), ...w16(1710),
  ...w16(d[0] < 0x80 ? 8063 : 3223), 8, ...w16(1000), d.length & 0xff, d.length >> 8, 0, ...d,
])

function checkLoaded(snap) {
  const ram = snap.ram
  const prog = ram[0x5c53 - 0x4000] | (ram[0x5c54 - 0x4000] << 8)
  assert.deepEqual([...ram.subarray(prog - 0x4000, prog - 0x4000 + 41)], [...blocks[1].subarray(1, 42)],
    'the program is at PROG')
  assert.equal(snap.border, 2, 'BORDER 2 ran')
  assert.equal(ram[0x1800], 0x30, 'PAPER 6: CLS ran')
  // "TP20K TAPE OK" printed at the top left: some ink in the first cell row
  assert.ok(ram.subarray(0, 32).some((b) => b !== 0) || ram.subarray(0x100, 0x120).some((b) => b !== 0),
    'PRINT inked the top row')
}

test('TAP converts to a snapshot of the loaded, running program', { skip: !rom }, async () => {
  const s = await tapeToSnapshot(rom, tap)
  checkLoaded(s)
  assert.equal(s.custom, false)
  assert.equal(s.unloaded, 0, 'single load: nothing left for the trap')
})

test('TZX standard blocks (flash-loaded)', { skip: !rom }, async () => {
  const s = await tapeToSnapshot(rom, tzx(std10))
  checkLoaded(s)
  assert.equal(s.custom, false)
})

test('TZX turbo blocks at ROM timings (loaded from EAR edges): custom', { skip: !rom }, async () => {
  const s = await tapeToSnapshot(rom, tzx(turbo11))
  checkLoaded(s)
  assert.equal(s.custom, true, 'the blocks were read edge by edge')
})

test('a tape with parts left over is a multi-load: entry snapshot at LD-BYTES', { skip: !rom }, async () => {
  // HELLO, then a CODE header + 4 bytes that nothing loads
  const code = [0x00, 0x03, ...Buffer.from('extra     ', 'latin1'), 4, 0, 0, 0x80, 0, 0x80]
  const hdr = [...code, code.reduce((x, v) => x ^ v, 0)]
  const dat = [0xff, 1, 2, 3, 4, 0xff ^ 1 ^ 2 ^ 3 ^ 4]
  const multi = Uint8Array.from([...tap, ...w16(hdr.length), ...hdr, ...w16(dat.length), ...dat])
  const s = await tapeToSnapshot(rom, multi)
  checkLoaded(s)
  assert.equal(s.custom, false, 'the editor polling the keyboard is not a loader')
  assert.equal(s.unloaded, 2)
  assert.equal(s.entry.pc, 0x0556, 'entry snapshot sits at LD-BYTES')
})
