// ============================================================================
//  card-disk.js -- SD card sector read/write (b/u commands) and LinkStreamReader
//  Ported from apple2e_TP20K (disk.js) for ZX_TP20K
// ============================================================================

export const SECTOR_BYTES = 512
export const ACK_BYTE = 0x06 // ASCII ACK returned by sd_raw_bridge.v after each chunk

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/**
 * Helper to manage raw serial bytes during disk/card image transfers without
 * leaking binary bytes into the UI keyboard/screen streams.
 */
export class LinkStreamReader {
  /**
   * @param {{ onBytes: (b: Uint8Array) => void, write: (b: Uint8Array | number[]) => void }} link
   */
  constructor(link) {
    this.link = link
    this.prevOnBytes = link.onBytes
    this.buffer = new Uint8Array(0)
    /** @type {{ check: () => boolean, resolve: () => void, reject: (e: Error) => void } | null} */
    this.waiter = null

    this.link.onBytes = (chunk) => {
      if (!chunk || !chunk.length) return
      const next = new Uint8Array(this.buffer.length + chunk.length)
      next.set(this.buffer, 0)
      next.set(chunk, this.buffer.length)
      this.buffer = next

      if (this.waiter && this.waiter.check()) {
        const w = this.waiter
        this.waiter = null
        w.resolve()
      }
    }
  }

  /**
   * Wait until checkFn() returns true, or fail if no activity arrives within inactivityTimeoutMs.
   */
  waitFor(checkFn, inactivityTimeoutMs = 6000) {
    if (checkFn()) return Promise.resolve()
    return new Promise((resolve, reject) => {
      let timer = null
      const arm = () => {
        if (timer) clearTimeout(timer)
        timer = setTimeout(() => {
          this.waiter = null
          reject(new Error(`Timeout waiting for board response (${inactivityTimeoutMs}ms)`))
        }, inactivityTimeoutMs)
      }
      arm()
      this.waiter = {
        check: () => {
          arm()
          return checkFn()
        },
        resolve: () => {
          if (timer) clearTimeout(timer)
          resolve()
        },
        reject: (e) => {
          if (timer) clearTimeout(timer)
          reject(e)
        },
      }
    })
  }

  async readUntil(token, timeoutMs = 6000) {
    const decoder = new TextDecoder()
    await this.waitFor(() => decoder.decode(this.buffer).includes(token), timeoutMs)
    const text = decoder.decode(this.buffer)
    const idx = text.indexOf(token) + token.length
    const encoder = new TextEncoder()
    const prefixBytes = encoder.encode(text.slice(0, idx)).length
    this.buffer = this.buffer.subarray(prefixBytes)
  }

  async readBytes(count, onProgress, timeoutMs = 6000) {
    let lastLen = -1
    await this.waitFor(() => {
      if (this.buffer.length !== lastLen) {
        lastLen = this.buffer.length
        onProgress?.(Math.min(this.buffer.length, count), count)
      }
      return this.buffer.length >= count
    }, timeoutMs)
    const out = this.buffer.subarray(0, count)
    this.buffer = this.buffer.subarray(count)
    return out
  }

  async readAck(timeoutMs = 6000) {
    await this.waitFor(() => this.buffer.includes(ACK_BYTE), timeoutMs)
    const idx = this.buffer.indexOf(ACK_BYTE)
    this.buffer = this.buffer.subarray(idx + 1)
  }

  restore() {
    this.link.onBytes = this.prevOnBytes
    if (this.waiter) {
      this.waiter.reject(new Error('Operation cancelled'))
      this.waiter = null
    }
  }
}

export function parseCardStatus(text) {
  const m = /S:([0-9A-F]{4})/.exec(text)
  if (!m) return null
  const s = parseInt(m[1], 16)
  const bits = (n) => [0, 1, 2, 3].map((i) => Boolean((n >> i) & 1))
  return {
    present: bits(s),
    fail: bits(s >> 4),
    fsOk: Boolean(s & 0x200),
    busy: Boolean(s & 0x4000),
    loading: Boolean(s & 0x8000),
    error: s & 0x2000 ? (s >> 10) & 7 : null,
  }
}

export async function queryCardStatus(link, opts = {}) {
  const reader = new LinkStreamReader(link)
  const decoder = new TextDecoder()
  try {
    link.write([0x69]) // 'i'
    await reader.waitFor(() => parseCardStatus(decoder.decode(reader.buffer)) !== null, opts.timeoutMs ?? 3000)
    return parseCardStatus(decoder.decode(reader.buffer))
  } finally {
    reader.restore()
  }
}

const hex = (v, digits) => v.toString(16).toUpperCase().padStart(digits, '0')

export async function readSectors(link, lba, count, opts = {}) {
  if (!(count >= 1 && count <= 0xffff)) throw new Error(`Sector count must be 1-65535, got ${count}`)
  const timeoutMs = opts.timeoutMs ?? 6000
  const reader = new LinkStreamReader(link)
  const decoder = new TextDecoder()
  try {
    link.write([...new TextEncoder().encode(`b${hex(lba >>> 0, 8)}${hex(count, 4)}`)])
    await reader.waitFor(() => /SECTORS\r\n|lost/.test(decoder.decode(reader.buffer)), timeoutMs)
    const text = decoder.decode(reader.buffer)
    if (!text.includes('SECTORS')) throw new Error('The board refused the read: no SD card, or it is busy.')
    await reader.readUntil('SECTORS\r\n', timeoutMs)
    const want = count * SECTOR_BYTES
    const bytes = await reader.readBytes(want, undefined, timeoutMs)
    await reader.waitFor(() => /done|lost/.test(decoder.decode(reader.buffer)), timeoutMs)
    if (decoder.decode(reader.buffer).includes('lost')) throw new Error(`SD card read failed at sector ${lba}.`)
    return bytes
  } finally {
    reader.restore()
  }
}

export function* hdRecords(data) {
  const blocks = Math.ceil(data.length / SECTOR_BYTES)
  const isZero = (b) => {
    for (let i = b * SECTOR_BYTES; i < Math.min(data.length, (b + 1) * SECTOR_BYTES); i++) if (data[i]) return false
    return true
  }
  for (let b = 0; b < blocks; ) {
    if (!isZero(b)) {
      const bytes = new Uint8Array(1 + SECTOR_BYTES)
      bytes[0] = 0x01
      bytes.set(data.subarray(b * SECTOR_BYTES, (b + 1) * SECTOR_BYTES), 1)
      yield { bytes, blocks: 1 }
      b++
    } else {
      let n = 1
      while (b + n < blocks && n < 65536 && isZero(b + n)) n++
      yield { bytes: Uint8Array.of(0x00, (n - 1) >> 8, (n - 1) & 0xff), blocks: n }
      b += n
    }
  }
}

export async function writeSectors(link, lba, data, opts = {}) {
  const timeoutMs = opts.timeoutMs ?? 6000
  const total = Math.ceil(data.length / SECTOR_BYTES)
  const reader = new LinkStreamReader(link)
  const decoder = new TextDecoder()
  try {
    link.write([...new TextEncoder().encode(`u${hex(lba >>> 0, 8)}`)])
    await reader.waitFor(() => /UPLOAD HD|lost/.test(decoder.decode(reader.buffer)), timeoutMs)
    if (!decoder.decode(reader.buffer).includes('UPLOAD HD')) {
      throw new Error('The board refused the write: no SD card, or it is busy.')
    }
    reader.buffer = new Uint8Array(0)
    let done = 0
    for (const r of hdRecords(data)) {
      link.write(r.bytes)
      await reader.readAck(timeoutMs + r.blocks * 10)
      done += r.blocks
      opts.onProgress?.({ blocks: done, totalBlocks: total })
    }
    link.write([0x02])
    await reader.waitFor(() => /done|lost/.test(decoder.decode(reader.buffer)), timeoutMs)
    if (decoder.decode(reader.buffer).includes('lost')) throw new Error('Write failed: the board reported lost bytes.')
  } finally {
    reader.restore()
  }
}

export function cardDevice(link) {
  return {
    async read(lba, n) {
      const out = new Uint8Array(n * SECTOR_BYTES)
      for (let i = 0; i < n; i += 128) {
        out.set(await readSectors(link, lba + i, Math.min(128, n - i)), i * SECTOR_BYTES)
      }
      return out
    },
    async write(lba, bytes, onProgress) {
      await writeSectors(link, lba, bytes, {
        onProgress: onProgress && ((p) => onProgress(Math.min(p.blocks * SECTOR_BYTES, bytes.length), bytes.length)),
      })
    },
  }
}
