// tape-snapshot.js against the real 48K ROM (skipped without roms/zx48.rom):
// sim/data/hello_tap.hex is a header + a BASIC program that autostarts at
// line 10: BORDER 2: PAPER 6: CLS: PRINT "TP20K TAPE OK".  Every TZX case
// below re-encodes those two blocks in another block type and must load the
// same program.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { deflateSync } from 'node:zlib'
import { tapeToSnapshot } from '../src/tape-snapshot.js'

const romPath = new URL('../../roms/zx48.rom', import.meta.url)
const rom = existsSync(romPath) ? new Uint8Array(readFileSync(romPath)) : null
const tap = Uint8Array.from(
  readFileSync(new URL('../../sim/data/hello_tap.hex', import.meta.url), 'utf8')
    .trim().split(/\s+/).map((h) => parseInt(h, 16)))

// the TAP's blocks, as [flag+data+checksum] arrays
const blocks = []
for (let o = 0; o < tap.length; o += 2 + (tap[o] | (tap[o + 1] << 8)))
  blocks.push([...tap.subarray(o + 2, o + 2 + (tap[o] | (tap[o + 1] << 8)))])

const w16 = (v) => [v & 0xff, (v >> 8) & 0xff]
const w24 = (v) => [v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff]
const w32 = (v) => [...w24(v), (v >>> 24) & 0xff]
const tzx = (body) => Uint8Array.from([...Buffer.from('ZXTape!\x1a\x01\x14', 'latin1'), ...body])
const pilotLen = (d) => (d[0] < 0x80 ? 8063 : 3223)

const std10 = (d) => [0x10, ...w16(1000), ...w16(d.length), ...d]
// 0x11 with the ROM's own timings: not flash-loaded, so the ROM reads edges
const turbo11 = (d) => [
  0x11, ...w16(2168), ...w16(667), ...w16(735), ...w16(855), ...w16(1710),
  ...w16(pilotLen(d)), 8, ...w16(1000), ...w24(d.length), ...d,
]

// 0x19: pilot symbols (tone, sync pair) and data symbols (0, 1) at ROM timings
function gdb19(d) {
  const sym = (a, b) => [0, ...w16(a), ...w16(b)]
  const body = [
    ...w16(1000), ...w32(2), 2, 2, ...w32(d.length * 8), 2, 2,
    ...sym(2168, 0), ...sym(667, 735),
    0, ...w16(pilotLen(d)), 1, ...w16(1),
    ...sym(855, 855), ...sym(1710, 1710),
    ...d,
  ]
  return [0x19, ...w32(body.length), ...body]
}

// 0x18: the block's pulses as a CSW at 3.5 MHz (one sample = one T-state)
function csw18(d, zlib) {
  const pulses = [...new Array(pilotLen(d)).fill(2168), 667, 735]
  for (const v of d) for (let k = 7; k >= 0; k--) pulses.push(...((v >> k) & 1 ? [1710, 1710] : [855, 855]))
  const rle = pulses.flatMap((n) => (n < 256 ? [n] : [0, ...w32(n)]))
  const data = zlib ? [...deflateSync(Uint8Array.from(rle))] : rle
  return [0x18, ...w32(10 + data.length), ...w16(1000), ...w24(3500000), zlib ? 2 : 1, ...w32(pulses.length), ...data]
}

function checkLoaded(snap) {
  const ram = snap.ram
  const prog = ram[0x5c53 - 0x4000] | (ram[0x5c54 - 0x4000] << 8)
  assert.deepEqual([...ram.subarray(prog - 0x4000, prog - 0x4000 + 41)], blocks[1].slice(1, 42),
    'the program is at PROG')
  assert.equal(snap.border, 2, 'BORDER 2 ran')
  assert.equal(ram[0x1800], 0x30, 'PAPER 6: CLS ran')
  // glyphs leave pixel line 0 blank: look at line 1 (0x100 in the screen file)
  assert.ok(ram.subarray(0x100, 0x120).some((b) => b !== 0), 'PRINT inked the top row')
}

test('TAP: flash-loaded, autostarted, nothing left over', { skip: !rom }, async () => {
  const s = await tapeToSnapshot(rom, tap)
  checkLoaded(s)
  assert.equal(s.resume, null)
})

test('TZX 0x10 standard blocks', { skip: !rom }, async () => {
  checkLoaded(await tapeToSnapshot(rom, tzx(blocks.flatMap(std10))))
})

test('TZX 0x11 turbo blocks at ROM timings (the ROM reads the edges)', { skip: !rom }, async () => {
  checkLoaded(await tapeToSnapshot(rom, tzx(blocks.flatMap(turbo11))))
})

test('TZX 0x19 generalized data', { skip: !rom }, async () => {
  checkLoaded(await tapeToSnapshot(rom, tzx(blocks.flatMap(gdb19))))
})

test('TZX 0x18 CSW, RLE and Z-RLE', { skip: !rom }, async () => {
  checkLoaded(await tapeToSnapshot(rom, tzx(blocks.flatMap((d) => csw18(d, false)))))
  checkLoaded(await tapeToSnapshot(rom, tzx(blocks.flatMap((d) => csw18(d, true)))))
})

test('TZX 0x26/0x27 call + 0x23 jump play the blocks in the right order', { skip: !rom }, async () => {
  //  0 call [+2, +4]   1 jump +5 (past the end)   2 header   3 return
  //  4 program         5 return
  const body = [
    0x26, ...w16(2), ...w16(2), ...w16(4),
    0x23, ...w16(5),
    ...std10(blocks[0]), 0x27,
    ...std10(blocks[1]), 0x27,
  ]
  checkLoaded(await tapeToSnapshot(rom, tzx(body)))
})

test('multi-load: stops at the first part nobody takes, with its .TAP offset', { skip: !rom }, async () => {
  // HELLO, then a CODE header + 4 bytes that nothing loads
  const code = [0x00, 0x03, ...Buffer.from('extra     ', 'latin1'), 4, 0, 0, 0x80, 0, 0x80]
  const hdr = [...code, code.reduce((x, v) => x ^ v, 0)]
  const dat = [0xff, 1, 2, 3, 4, 0xff ^ 1 ^ 2 ^ 3 ^ 4]
  const multi = Uint8Array.from([...tap, ...w16(hdr.length), ...hdr, ...w16(dat.length), ...dat])
  const s = await tapeToSnapshot(rom, multi)
  checkLoaded(s)
  assert.deepEqual(s.resume, { block: 2, offset: tap.length })
})
