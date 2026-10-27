// ============================================================================
//  card.js -- SD card operations for ZX_TP20K using client-side FAT32
// ============================================================================

import { Fat32, from83 } from './fat32.js'
import { cardDevice, queryCardStatus } from './card-disk.js'

export { from83, cardDevice, queryCardStatus }

export class Card {
  constructor(fs) {
    this.fs = fs
  }

  static async open(device) {
    const fs = new Fat32(device)
    await fs.mount()
    return new Card(fs)
  }

  async scan() {
    return this.fs.scan()
  }

  async upload(name, data, onProgress) {
    return this.fs.create(name, data, onProgress)
  }

  async download(file, onProgress) {
    return this.fs.readFile(file, onProgress)
  }

  async remove(file) {
    await this.fs.remove(file)
  }
}
