// ============================================================================
//  z80-snapshot.js -- Z80 Snapshot (.Z80) parser and decompressor
//
//  Supports version 1, 2, and 3 .z80 snapshot files for ZX Spectrum 48K.
//  Returns:
//    {
//      ram: Uint8Array(49152), // addresses 0x4000..0xFFFF
//      border: number,         // 0..7
//      regs: Uint8Array(28),   // register state buffer for zx_snap
//      pc: number,
//      sp: number,
//    }
// ============================================================================

const le16 = (b, o) => b[o] | (b[o + 1] << 8)

function decompressV1(src, srcOff, dest) {
  let di = 0
  let si = srcOff
  const len = src.length
  while (si < len && di < dest.length) {
    if (si + 3 < len && src[si] === 0x00 && src[si + 1] === 0xed && src[si + 2] === 0xed && src[si + 3] === 0x00) {
      break // End marker
    }
    if (si + 3 < len && src[si] === 0xed && src[si + 1] === 0xed) {
      const count = src[si + 2]
      const val = src[si + 3]
      si += 4
      for (let k = 0; k < count && di < dest.length; k++) dest[di++] = val
    } else {
      dest[di++] = src[si++]
    }
  }
}

function decompressBlock(src, srcOff, srcLen, dest, destOff) {
  let si = srcOff
  const end = srcOff + srcLen
  let di = destOff
  const max = destOff + 16384
  while (si < end && di < max) {
    if (si + 3 < end && src[si] === 0xed && src[si + 1] === 0xed) {
      const count = src[si + 2]
      const val = src[si + 3]
      si += 4
      for (let k = 0; k < count && di < max; k++) dest[di++] = val
    } else {
      dest[di++] = src[si++]
    }
  }
}

export function parseZ80Snapshot(bytes) {
  if (bytes.length < 30) throw new Error('Invalid .z80 snapshot (file too short)')

  const a = bytes[0]
  const f = bytes[1]
  const c = bytes[2]
  const b = bytes[3]
  const l = bytes[4]
  const h = bytes[5]
  let pc = le16(bytes, 6)
  const sp = le16(bytes, 8)
  const i = bytes[10]
  let r = bytes[11] & 0x7f
  const b12 = bytes[12] === 255 ? 1 : bytes[12]
  if (b12 & 0x01) r |= 0x80
  const border = (b12 >> 1) & 0x07
  const compressedV1 = (b12 & 0x20) !== 0

  const e = bytes[13]
  const d = bytes[14]
  const c_ = bytes[15]
  const b_ = bytes[16]
  const e_ = bytes[17]
  const d_ = bytes[18]
  const l_ = bytes[19]
  const h_ = bytes[20]
  const a_ = bytes[21]
  const f_ = bytes[22]
  const iy = le16(bytes, 23)
  const ix = le16(bytes, 25)
  const iff1 = bytes[27] !== 0 ? 1 : 0
  const b29 = bytes[29]
  const im = b29 & 0x03

  const ram = new Uint8Array(49152)

  if (pc !== 0) {
    // Version 1
    if (compressedV1) {
      decompressV1(bytes, 30, ram)
    } else {
      ram.set(bytes.subarray(30, 30 + 49152))
    }
  } else {
    // Version 2 or 3
    const extraLen = le16(bytes, 30)
    pc = le16(bytes, 32)
    let off = 32 + extraLen

    while (off < bytes.length) {
      const blkLen = le16(bytes, off)
      const page = bytes[off + 2]
      off += 3

      // For 48K Spectrum:
      // Page 4: 0x8000..0xBFFF (RAM offset 0x4000)
      // Page 5: 0xC000..0xFFFF (RAM offset 0x8000)
      // Page 8: 0x4000..0x7FFF (RAM offset 0x0000)
      let destOffset = -1
      if (page === 8) destOffset = 0x0000
      else if (page === 4) destOffset = 0x4000
      else if (page === 5) destOffset = 0x8000

      if (blkLen === 0xffff) {
        if (destOffset >= 0) ram.set(bytes.subarray(off, off + 16384), destOffset)
        off += 16384
      } else {
        if (destOffset >= 0) decompressBlock(bytes, off, blkLen, ram, destOffset)
        off += blkLen
      }
    }
  }

  // Build the 28-byte register buffer expected by zx_snap.v:
  // 0..1: PC, 2..3: SP, 4..5: AF, 6..7: BC, 8..9: DE, 10..11: HL
  // 12..13: AF', 14..15: BC', 16..17: DE', 18..19: HL'
  // 20..21: IX, 22..23: IY
  // 24: I, 25: R, 26: IM (0, 1, 2), 27: IFF1 (0: DI, 1: EI)
  const regs = new Uint8Array(28)
  regs[0] = pc & 0xff; regs[1] = (pc >> 8) & 0xff
  regs[2] = sp & 0xff; regs[3] = (sp >> 8) & 0xff
  regs[4] = f;         regs[5] = a
  regs[6] = c;         regs[7] = b
  regs[8] = e;         regs[9] = d
  regs[10] = l;        regs[11] = h
  regs[12] = f_;       regs[13] = a_
  regs[14] = c_;       regs[15] = b_
  regs[16] = e_;       regs[17] = d_
  regs[18] = l_;       regs[19] = h_
  regs[20] = ix & 0xff; regs[21] = (ix >> 8) & 0xff
  regs[22] = iy & 0xff; regs[23] = (iy >> 8) & 0xff
  regs[24] = i
  regs[25] = r
  regs[26] = im
  regs[27] = iff1

  return { ram, border, regs, pc, sp }
}
