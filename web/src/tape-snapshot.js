// ============================================================================
//  tape-snapshot.js -- instant load: a .TAP/.TZX turned into a snapshot
//
//  A headless 48K (z80-emulator + the real ROM) boots, types LOAD "" and runs
//  the tape the way the board would, only as fast as JavaScript goes.  Its
//  RAM, border and registers are the snapshot, in the shape parseZ80Snapshot
//  returns -- so App injects it through the same FC packets as a .Z80.
//
//  Standard-speed blocks are flash-loaded at LD-BYTES (0x0556): the ROM's
//  own contract (A = flag, CF = LOAD/VERIFY, IX, DE) done in one step.  Every
//  other block is played as EAR edges with its TZX timings, so turbo and
//  custom loaders load as on the real machine, just faster than real time.
//
//  It stops as soon as the program stops taking the tape:
//    * a data block starts and nothing is listening -- a loader samples the
//      EAR at least once per edge, so fewer reads than edges over its first
//      LISTEN edges means the program has moved on (a multi-load game
//      playing its first part).  `resume` names that block, and for a .TAP
//      its byte offset: App puts the board's head there with the trap armed
//      (zx_core, DivMMC style), so the later parts load off DDR3;
//    * the tape runs out, or meets a TZX stop block -- then SETTLE more
//      frames, so a loader can finish what it read.
//
//  ponytail: a "press any key" loop polling the port while the next part
//  rolls by looks like a loader; that part is then played into it, and the
//  hand-over starts one part later.
// ============================================================================

import { Z80 } from 'z80-emulator'
import { regs28 } from './z80-snapshot.js'

const T_FRAME = 69888            // T-states per 50 Hz frame
const T_MS = 3500                // T-states per millisecond
const SETTLE = 100               // frames the machine runs on after the tape
const LISTEN = 64                // data edges a block gets to find a listener
const GRACE = 1300 * 3500        // ...counted only after this long into it: the
                                 // ROM's LD-BYTES waits ~1 s before it listens
const MAX_T = T_MS * 1000 * 60 * 15   // give up after 15 emulated minutes
const LD_BYTES = 0x0556
const STD = { pilot: 2168, sync1: 667, sync2: 735, zero: 855, one: 1710 }

// LASTK codes the editor takes as typed: the LOAD token (K mode), ", ", ENTER
const LOAD_KEYS = [0xef, 0x22, 0x22, 0x0d]

// ---------------------------------------------------------------- the tape --

const le16 = (b, o) => b[o] | (b[o + 1] << 8)
const le24 = (b, o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16)
const le32 = (b, o) => (le24(b, o) | (b[o + 3] << 24)) >>> 0

const stdBlock = (data, pause) => ({
  type: 'data', std: true, ...STD,
  pilotLen: data[0] < 0x80 ? 8063 : 3223, lastBits: 8, pause, data,
})

/**
 * Blocks of a .TAP or .TZX image (Uint8Array).  Every TZX block keeps its
 * place (info blocks as 'info'), because jumps and calls count blocks.
 */
export async function parseTape(bytes) {
  const tzx = String.fromCharCode(...bytes.subarray(0, 7)) === 'ZXTape!'
  const blocks = tzx ? await parseTzx(bytes) : parseTap(bytes)
  if (!blocks.some((b) => ['data', 'pulses', 'direct', 'csw', 'gdb'].includes(b.type))) {
    throw new Error('No blocks in the tape image.')
  }
  return blocks
}

function parseTap(b) {
  const blocks = []
  for (let o = 0; o + 2 <= b.length;) {
    const n = le16(b, o)
    if (n === 0 || o + 2 + n > b.length) break
    blocks.push({ ...stdBlock(b.subarray(o + 2, o + 2 + n), 1000), offset: o })
    o += 2 + n
  }
  return blocks
}

async function inflate(data) {
  const out = new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate'))
  return new Uint8Array(await new Response(out).arrayBuffer())
}

async function parseTzx(b) {
  const blocks = []
  let o = 10
  while (o < b.length) {
    const id = b[o++]
    switch (id) {
      case 0x10: {
        const n = le16(b, o + 2)
        blocks.push(stdBlock(b.subarray(o + 4, o + 4 + n), le16(b, o)))
        o += 4 + n
        break
      }
      case 0x11: {
        const n = le24(b, o + 15)
        blocks.push({
          type: 'data', std: false,
          pilot: le16(b, o), sync1: le16(b, o + 2), sync2: le16(b, o + 4),
          zero: le16(b, o + 6), one: le16(b, o + 8), pilotLen: le16(b, o + 10),
          lastBits: b[o + 12], pause: le16(b, o + 13), data: b.subarray(o + 18, o + 18 + n),
        })
        o += 18 + n
        break
      }
      case 0x12: blocks.push({ type: 'pulses', pulses: new Array(le16(b, o + 2)).fill(le16(b, o)) }); o += 4; break
      case 0x13: {
        const n = b[o]
        const pulses = []
        for (let i = 0; i < n; i++) pulses.push(le16(b, o + 1 + 2 * i))
        blocks.push({ type: 'pulses', pulses })
        o += 1 + 2 * n
        break
      }
      case 0x14: {
        const n = le24(b, o + 7)
        blocks.push({
          type: 'data', std: false, pilotLen: 0,
          zero: le16(b, o), one: le16(b, o + 2), lastBits: b[o + 4],
          pause: le16(b, o + 5), data: b.subarray(o + 10, o + 10 + n),
        })
        o += 10 + n
        break
      }
      case 0x15: {
        const n = le24(b, o + 5)
        blocks.push({
          type: 'direct', tps: le16(b, o), pause: le16(b, o + 2),
          lastBits: b[o + 4], data: b.subarray(o + 8, o + 8 + n),
        })
        o += 8 + n
        break
      }
      case 0x18: {                                       // CSW recording
        const n = le32(b, o)
        const rate = le24(b, o + 6)
        const z = b[o + 9] === 2
        const raw = b.subarray(o + 14, o + 4 + n)
        blocks.push({ type: 'csw', pause: le16(b, o + 4), rate, rle: z ? await inflate(raw) : raw })
        o += 4 + n
        break
      }
      case 0x19: blocks.push(parseGdb(b, o)); o += 4 + le32(b, o); break
      case 0x20: {
        const ms = le16(b, o)
        blocks.push(ms ? { type: 'pause', ms } : { type: 'stop' })
        o += 2
        break
      }
      case 0x21: blocks.push({ type: 'info' }); o += 1 + b[o]; break             // group start
      case 0x22: blocks.push({ type: 'info' }); break                           // group end
      case 0x23: blocks.push({ type: 'jump', rel: (le16(b, o) << 16) >> 16 }); o += 2; break
      case 0x24: blocks.push({ type: 'loop', count: le16(b, o) }); o += 2; break
      case 0x25: blocks.push({ type: 'loopEnd' }); break
      case 0x26: {
        const n = le16(b, o)
        const rels = []
        for (let i = 0; i < n; i++) rels.push((le16(b, o + 2 + 2 * i) << 16) >> 16)
        blocks.push({ type: 'call', rels })
        o += 2 + 2 * n
        break
      }
      case 0x27: blocks.push({ type: 'return' }); break
      case 0x28: blocks.push({ type: 'info' }); o += 2 + le16(b, o); break     // select
      case 0x2a: blocks.push({ type: 'stop' }); o += 4; break                   // stop if 48K
      case 0x2b: blocks.push({ type: 'level', level: b[o + 4] & 1 }); o += 5; break
      case 0x30: blocks.push({ type: 'info' }); o += 1 + b[o]; break            // text
      case 0x31: blocks.push({ type: 'info' }); o += 2 + b[o + 1]; break        // message
      case 0x32: blocks.push({ type: 'info' }); o += 2 + le16(b, o); break      // archive info
      case 0x33: blocks.push({ type: 'info' }); o += 1 + 3 * b[o]; break        // hardware
      case 0x35: blocks.push({ type: 'info' }); o += 14 + le32(b, o + 10); break // custom info
      case 0x5a: blocks.push({ type: 'info' }); o += 9; break                   // glue
      default: blocks.push({ type: 'info' }); o += 4 + le32(b, o)              // v1.10+: length follows the id
    }
  }
  return blocks
}

/** TZX 0x19, generalized data: symbol tables for the pilot and the data. */
function parseGdb(b, o) {
  const pause = le16(b, o + 4)
  const totp = le32(b, o + 6), npp = b[o + 10], asp = b[o + 11] || 256
  const totd = le32(b, o + 12), npd = b[o + 16], asd = b[o + 17] || 256
  let p = o + 18
  const table = (count, np) => {
    const syms = []
    for (let s = 0; s < count; s++) {
      const pulses = []
      for (let k = 0; k < np; k++) {
        const t = le16(b, p + 1 + 2 * k)
        if (!t) break
        pulses.push(t)
      }
      syms.push({ flags: b[p] & 3, pulses })
      p += 1 + 2 * np
    }
    return syms
  }
  const pilotSyms = totp ? table(asp, npp) : []
  const pilot = []
  for (let i = 0; i < totp; i++, p += 3) pilot.push([b[p], le16(b, p + 1)])
  const dataSyms = totd ? table(asd, npd) : []
  const nb = Math.max(1, Math.ceil(Math.log2(asd)))
  return { type: 'gdb', pause, pilotSyms, pilot, dataSyms, totd, nb, stream: b.subarray(p, p + Math.ceil(totd * nb / 8)) }
}

/**
 * The deck: the blocks as EAR edges.  events() yields a number for "toggle
 * EAR, then wait n T", [level, n] for "set EAR, then wait n", and null for
 * "stop the tape"; it records which block and phase it is in.
 */
class Deck {
  constructor(blocks) {
    this.blocks = blocks
    this.ear = 0
    this.on = false
    this.ended = false          // ran out, or reached a stop block
    this.cur = 0
    this.phase = 'idle'
    this.gen = null
    this.next = 0
    this.edges = new Uint32Array(blocks.length)   // data-phase edges per block
    this.reads = new Uint32Array(blocks.length)   // EAR reads while they played
    this.ignored = -1           // a data block nobody listened to
    this.blockAt = 0            // when the current block started
  }

  start(from, now, pauseOnly = false) {
    this.gen = this.events(from, pauseOnly)
    this.cur = from
    this.phase = pauseOnly ? 'pause' : 'idle'   // a flash-loaded block is behind the head
    this.on = true
    this.next = now
  }

  advance(now) {
    while (this.on && now >= this.next) {
      const r = this.gen.next()
      if (r.done || r.value === null) {
        this.on = false
        this.ended = true
      } else if (typeof r.value === 'number') {
        this.ear ^= 1
        this.next += r.value
        if (this.phase === 'data' && this.next - this.blockAt > GRACE && ++this.edges[this.cur] === LISTEN &&
            this.reads[this.cur] < LISTEN && this.blocks[this.cur].type !== 'pulses') {
          this.ignored = this.cur
        }
      } else {
        this.ear = r.value[0]
        this.next += r.value[1]
      }
    }
  }

  * events(from, pauseOnly) {
    const loops = []
    const calls = []
    let i = from
    while (i >= 0 && i < this.blocks.length) {
      const b = this.blocks[i]
      this.cur = i
      this.blockAt = this.next
      switch (b.type) {
        case 'data': case 'direct': case 'csw': case 'gdb':
          if (!pauseOnly) yield* this[b.type](b)
          if (b.pause) {
            this.phase = 'pause'
            yield T_MS                       // the edge that ends the last pulse
            yield [0, b.pause * T_MS - T_MS]
          }
          break
        case 'pulses':
          this.phase = 'data'
          for (const p of b.pulses) yield p
          break
        case 'pause': this.phase = 'pause'; yield [0, b.ms * T_MS]; break
        case 'level': yield [b.level, 0]; break
        case 'stop': yield null; break
        case 'jump': i += b.rel; continue
        case 'loop': loops.push({ at: i + 1, left: b.count }); break
        case 'loopEnd': {
          const l = loops[loops.length - 1]
          if (l && --l.left > 0) { i = l.at; continue }
          loops.pop()
          break
        }
        case 'call':
          if (!b.rels.length) break
          calls.push({ base: i, rels: b.rels, k: 0 })
          i += b.rels[0]
          continue
        case 'return': {
          const c = calls[calls.length - 1]
          if (!c) break
          if (++c.k < c.rels.length) { i = c.base + c.rels[c.k]; continue }
          calls.pop()
          i = c.base + 1
          continue
        }
        default: break                       // info
      }
      pauseOnly = false
      i++
    }
  }

  * data(b) {
    this.phase = 'pilot'
    for (let i = 0; i < b.pilotLen; i++) yield b.pilot
    this.phase = 'data'
    if (b.pilotLen) { yield b.sync1; yield b.sync2 }
    const d = b.data
    for (let i = 0; i < d.length; i++) {
      const bits = i === d.length - 1 ? b.lastBits : 8
      for (let k = 0; k < bits; k++) {
        const t = (d[i] << k) & 0x80 ? b.one : b.zero
        yield t
        yield t
      }
    }
  }

  * direct(b) {
    this.phase = 'data'
    const d = b.data
    for (let i = 0; i < d.length; i++) {
      const bits = i === d.length - 1 ? b.lastBits : 8
      for (let k = 0; k < bits; k++) yield [(d[i] << k) & 0x80 ? 1 : 0, b.tps]
    }
  }

  // CSW: run lengths in samples, 0 then a le32 for the long ones
  * csw(b) {
    this.phase = 'data'
    const r = b.rle
    const t = 3500000 / b.rate
    for (let i = 0; i < r.length;) {
      let n = r[i++]
      if (n === 0) { n = le32(r, i); i += 4 }
      yield Math.round(n * t)
    }
  }

  * gdb(b) {
    this.phase = 'pilot'
    for (const [s, reps] of b.pilot) {
      for (let r = 0; r < reps; r++) yield* this.symbol(b.pilotSyms[s])
    }
    this.phase = 'data'
    for (let i = 0, bit = 0; i < b.totd; i++) {
      let s = 0
      for (let k = 0; k < b.nb; k++, bit++) s = (s << 1) | ((b.stream[bit >> 3] >> (7 - (bit & 7))) & 1)
      yield* this.symbol(b.dataSyms[s])
    }
  }

  // a symbol's first pulse may keep or force the level instead of toggling
  * symbol(s) {
    if (!s) return
    for (let k = 0; k < s.pulses.length; k++) {
      const t = s.pulses[k]
      if (k > 0 || s.flags === 0) yield t
      else if (s.flags === 1) yield [this.ear, t]
      else yield [s.flags & 1, t]
    }
  }

  /** The std block LD-BYTES would meet now, if it would meet one cleanly. */
  trappable() {
    if (this.on && this.phase === 'data') return -1
    let k = this.on ? this.cur + (this.phase === 'pause' ? 1 : 0) : this.ended ? -1 : 0
    while (k >= 0 && k < this.blocks.length) {
      const b = this.blocks[k]
      if (b.type === 'data') return b.std ? k : -1
      if (b.type !== 'pause' && b.type !== 'level' && b.type !== 'info') return -1
      k++
    }
    return -1
  }
}

// ------------------------------------------------------------- the machine --

/**
 * Run `tapeBytes` (.TAP or .TZX) through the 48K `rom` and return the
 * snapshot { ram, border, regs, pc, sp, resume } -- resume is null, or
 * { block, offset } for the first part the program did not take (offset:
 * its byte position in a .TAP, undefined for a .TZX).  onProgress(fraction)
 * is called now and then; the work yields to the event loop between slices.
 */
export async function tapeToSnapshot(rom, tapeBytes, onProgress = () => {}) {
  if (rom.length !== 16384) throw new Error('The 48K ROM must be 16384 bytes.')
  const deck = new Deck(await parseTape(tapeBytes))
  const mem = new Uint8Array(65536)
  mem.set(rom)
  let border = 7

  const hal = {
    tStateCount: 0,
    readMemory: (a) => mem[a],
    writeMemory: (a, v) => { if (a >= 0x4000) mem[a] = v },
    contendMemory: () => {},
    contendPort: () => {},
    readPort: (a) => {
      if (a & 1) return 0xff
      deck.advance(hal.tStateCount)
      if (deck.on && deck.phase === 'data' && hal.tStateCount - deck.blockAt > GRACE) deck.reads[deck.cur]++
      return 0xbf | (deck.ear << 6)          // no keys down; EAR on bit 6
    },
    writePort: (a, v) => { if (!(a & 1)) border = v & 7 },
  }
  const z = new Z80(hal)
  z.reset()

  let frame = 0
  let nextInt = T_FRAME
  let keys = 0
  let started = false
  let endFrame = -1

  for (;;) {
    const sliceEnd = hal.tStateCount + 50 * T_FRAME
    while (hal.tStateCount < sliceEnd && deck.ignored < 0) {
      if (z.regs.pc === LD_BYTES) {
        deck.advance(hal.tStateCount)
        const k = deck.trappable()
        if (k >= 0) {
          flashLoad(z, mem, deck.blocks[k].data)
          border = (mem[0x5c48] >> 3) & 7    // SA/LD-RET: BORDCR back
          deck.start(k, hal.tStateCount, true)   // on from that block's pause
        } else if (!started) {
          deck.start(0, hal.tStateCount)     // the motor: the first LOAD
        }
        started = true
      }
      z.step()
      if (hal.tStateCount >= nextInt) {
        nextInt += T_FRAME
        frame++
        z.maskableInterrupt()
        // type LOAD "" once the ROM is up, a key whenever the editor took
        // the last one (FLAGS bit 5 clear)
        if (frame >= 150 && frame % 5 === 0 && keys < LOAD_KEYS.length && !(mem[0x5c3b] & 0x20)) {
          mem[0x5c08] = LOAD_KEYS[keys++]
          mem[0x5c3b] |= 0x20
        }
      }
    }
    if (deck.ignored >= 0) break
    deck.advance(hal.tStateCount)
    if (deck.ended && endFrame < 0) endFrame = frame
    if (endFrame >= 0 && frame >= endFrame + SETTLE) break
    if (!started && frame > 600) throw new Error('LOAD "" did not start the tape.')
    if (hal.tStateCount > MAX_T) break
    onProgress(Math.min(1, deck.cur / deck.blocks.length))
    await new Promise((r) => setTimeout(r, 0))
  }
  onProgress(1)

  const r = z.regs
  const regs = regs28({
    pc: r.pc, sp: r.sp, af: r.af, bc: r.bc, de: r.de, hl: r.hl,
    af_: r.afPrime, bc_: r.bcPrime, de_: r.dePrime, hl_: r.hlPrime,
    ix: r.ix, iy: r.iy, i: r.i, r: (r.r7 & 0x80) | (r.r & 0x7f), im: r.im, iff1: r.iff1,
  })
  const k = deck.ignored
  const resume = k >= 0 ? { block: k, offset: deck.blocks[k].offset } : null
  return { ram: mem.slice(0x4000), border, regs, pc: r.pc, sp: r.sp, resume }
}

/** LD-BYTES in one step, then return to its caller with CF = ok. */
function flashLoad(z, mem, data) {
  const r = z.regs
  const load = r.f & 1
  let ok = data.length > 0 && data[0] === r.a
  if (ok) {
    let x = data[0]
    let i = 1
    while (r.de > 0) {
      if (i >= data.length) { ok = false; break }
      const v = data[i++]
      x ^= v
      if (load) { if (r.ix >= 0x4000) mem[r.ix] = v } else if (mem[r.ix] !== v) { ok = false; break }
      r.ix = (r.ix + 1) & 0xffff
      r.de = r.de - 1
    }
    if (ok) ok = i < data.length && (x ^ data[i]) === 0
  }
  r.f = ok ? r.f | 1 : r.f & 0xfe
  r.iff1 = r.iff2 = 1                         // SA/LD-RET's EI
  r.pc = z.popWord()
}
