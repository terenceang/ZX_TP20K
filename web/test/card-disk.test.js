// Tests for the raw card sector transfers and LinkStreamReader, plain node --test.
//
// The board answers a read it cannot do with "\r\nlost\r\n" where the payload
// would be, and a record it cannot write with "lost" instead of the ACK.  Both
// used to leave the page waiting for bytes that never come, which the UI
// reported as "Timeout waiting for board response (6000ms)".
import test from 'node:test'
import assert from 'node:assert/strict'
import { readSectors, writeSectors, LinkStreamReader, SECTOR_BYTES, ACK_BYTE } from '../src/card-disk.js'

const enc = (s) => new TextEncoder().encode(s)
const cat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let o = 0
  for (const p of parts) {
    out.set(p, o)
    o += p.length
  }
  return out
}

/** A link whose board answers every write straight away, as the UART would. */
function fakeLink(board) {
  const link = {
    onBytes: null,
    writes: [],
    write(bytes) {
      const b = Uint8Array.from(bytes)
      link.writes.push(b)
      const out = board(b)
      if (out && out.length) link.onBytes(out)
    },
  }
  return link
}

const sector = (seed) => Uint8Array.from({ length: SECTOR_BYTES }, (_, i) => (i * 7 + seed) & 0xff)

test('readSectors returns the payload, then drops the trailing done', async () => {
  const data = sector(3)
  const link = fakeLink((b) => {
    assert.equal(String.fromCharCode(b[0]), 'b')
    return cat(enc('\r\nSECTORS\r\n'), data, enc('\r\ndone\r\n'))
  })
  const got = await readSectors(link, 32, 1)
  assert.equal(got.length, SECTOR_BYTES)
  assert.deepEqual(got, data)
})

test('readSectors fails at once when the board sends lost instead of data', async () => {
  const link = fakeLink(() => cat(enc('\r\nSECTORS\r\n'), enc('\r\nlost\r\n')))
  await assert.rejects(() => readSectors(link, 12288, 1), /read failed at sector 12288/)
})

test('readSectors fails at once when lost arrives part way through', async () => {
  const link = fakeLink(() => cat(enc('\r\nSECTORS\r\n'), sector(1).subarray(0, 100), enc('\r\nlost\r\n')))
  await assert.rejects(() => readSectors(link, 40, 1), /read failed at sector 40/)
})

test('readSectors still reports a refused read', async () => {
  const link = fakeLink(() => enc('\r\nH:00 S:0200 Q:00\r\nlost\r\n'))
  await assert.rejects(() => readSectors(link, 8, 1), /refused the read/)
})

test('writeSectors acks each record and ends on done', async () => {
  const link = fakeLink((b) => {
    if (b[0] === 0x75) return enc('\r\nUPLOAD HD\r\n') // 'u'
    if (b[0] === 0x02) return enc('\r\ndone\r\n')
    assert.equal(b.length, 1 + SECTOR_BYTES)
    return Uint8Array.of(ACK_BYTE)
  })
  await writeSectors(link, 32, sector(5))
  assert.equal(link.writes.length, 3)
  assert.deepEqual(link.writes[1].subarray(1), sector(5))
})

test('writeSectors reports lost instead of waiting out the ACK timeout', async () => {
  const link = fakeLink((b) => {
    if (b[0] === 0x75) return enc('\r\nUPLOAD HD\r\n')
    return enc('\r\nlost\r\n')
  })
  await assert.rejects(() => writeSectors(link, 32, sector(5)), /lost bytes/)
})

test('writeSectors sends a zero run as 00 <n-1 hi> <n-1 lo>', async () => {
  const link = fakeLink((b) => {
    if (b[0] === 0x75) return enc('\r\nUPLOAD HD\r\n')
    if (b[0] === 0x02) return enc('\r\ndone\r\n')
    return Uint8Array.of(ACK_BYTE)
  })
  await writeSectors(link, 200, new Uint8Array(4 * SECTOR_BYTES))
  assert.deepEqual(link.writes[1], Uint8Array.of(0x00, 0x00, 0x03))
})

test('LinkStreamReader hands the link back on restore', () => {
  const link = fakeLink(() => null)
  const before = link.onBytes
  const reader = new LinkStreamReader(link)
  assert.notEqual(link.onBytes, before)
  reader.restore()
  assert.equal(link.onBytes, before)
})
