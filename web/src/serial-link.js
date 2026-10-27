// ============================================================================
//  serial-link.js -- straight from the browser to the board, no bridge
//
//  Web Serial opens the BL702's COM port itself (the board must be plugged
//  into the machine running the browser), at 1 Mbps 8N1 -- the same rate
//  src/uart_defs.vh gives the FPGA.
//
//  Which port is the FPGA?  The Dock exposes the BL702's own console next to
//  the FPGA's UART and the picker cannot tell them apart, so the choice is
//  confirmed the only way that works: the board prints a banner on reset
//  (src/zx_uart_tx.v) and we wait for it.
//
//  Adapted from the sibling apple2e_TP20K project's serial-link.js.
// ============================================================================

import { HANDSHAKE } from './protocol.js'

export const BAUD = 1000000
const PROBE_TIMEOUT_MS = 2000

/** Is Web Serial usable here at all? */
export function serialSupported(serial) {
  const s = serial ?? (typeof navigator !== 'undefined' ? navigator.serial : undefined)
  return Boolean(s && typeof s.requestPort === 'function')
}

const hex4 = (n) => n.toString(16).toUpperCase().padStart(4, '0')

export function describePort(port) {
  if (!port) return 'no port'
  const info = typeof port.getInfo === 'function' ? port.getInfo() : {}
  const v = info.vendorId
  const p = info.productId
  return v != null && p != null ? `USB serial ${hex4(v)}:${hex4(p)}` : 'USB serial'
}

/** Watch bytes for the banner. */
export function makeHandshake() {
  let seen = ''
  return {
    feed(chunk) {
      seen += typeof chunk === 'string' ? chunk : new TextDecoder().decode(chunk)
      if (seen.length > 4096) seen = seen.slice(-2048)
      return seen.includes(HANDSHAKE)
    },
    get text() {
      return seen
    },
    reset() {
      seen = ''
    },
  }
}

export class SerialLink {
  constructor(opts = {}) {
    this.serial = opts.serial ?? (typeof navigator !== 'undefined' ? navigator.serial : null)
    this.onBytes = () => {}
    this.onState = () => {}
    this.port = null
    this.writer = null
    this.reader = null
    this.closing = false
    this.queue = []
    this.draining = false
    this.state = 'idle'
    this.detail = null
  }

  describe() {
    return describePort(this.port)
  }

  emit(state, detail = null) {
    this.state = state
    this.detail = detail
    this.onState({ state, detail })
  }

  /**
   * Ports this site has already been given, with no picker and no click.
   * Web Serial allows this from page load; requestPort() does not.
   * @returns {Promise<SerialPort[]>}
   */
  async grantedPorts() {
    if (!this.serial || typeof this.serial.getPorts !== 'function') return []
    try {
      return await this.serial.getPorts()
    } catch {
      return []
    }
  }

  /**
   * Open a remembered port without the picker, so the page comes up already
   * connected on a board it has seen before.
   * @returns {Promise<'ok'|'none'|'wrong-port'|'cancelled'>} 'none' when the
   *          browser has never been given a port for this site.
   */
  async openGranted(opts = {}) {
    const ports = await this.grantedPorts()
    if (!ports.length) return 'none'
    // the BL702 exposes its UART next to its JTAG channel; the page cannot
    // tell them apart, so take the first that opens and let the board's
    // silence speak for itself
    for (const port of ports) {
      const r = await this.open({ ...opts, port })
      if (r === 'ok') return 'ok'
    }
    return ports.length ? 'wrong-port' : 'none'
  }

  /**
   * Ask for a port and confirm it is the FPGA's UART.
   * open() must be called from a user gesture (requestPort shows a picker).
   * @returns {Promise<'ok'|'wrong-port'|'cancelled'>}
   */
  async open(opts = {}) {
    if (!serialSupported(this.serial)) {
      this.emit('error', 'this browser has no Web Serial')
      return 'cancelled'
    }
    await this.close()
    this.closing = false
    this.emit('opening')
    try {
      this.port = opts.port ?? (await this.serial.requestPort())
    } catch (e) {
      this.port = null
      this.emit(e?.name === 'NotFoundError' ? 'idle' : 'error', null)
      return 'cancelled'
    }

    try {
      await this.port.open({
        baudRate: BAUD,
        dataBits: 8,
        stopBits: 1,
        parity: 'none',
        bufferSize: 4096,
      })
    } catch {
      try {
        await this.port.open({ baudRate: BAUD })
      } catch (e) {
        this.emit('error', `could not open the port: ${e?.message ?? e}`)
        await this.close()
        return 'cancelled'
      }
    }

    this.startReading()

    if (opts.verify === false) {
      this.emit('open')
      return 'ok'
    }
    return this.verify()
  }

  /**
   * The banner goes out once, right after the board's reset, so a page that
   * connects later will not see it.  We ask anyway, and accept silence as
   * "probably fine" only when the user says so (opts.requireBanner).
   * @returns {Promise<'ok'|'wrong-port'>}
   */
  verify() {
    if (this._verify) return this._verify
    this._verify = new Promise((resolve) => {
      const hs = makeHandshake()
      const previous = this.onBytes
      let settled = false
      this.emit('probing')

      const timer = setTimeout(() => {
        if (settled) return
        settled = true
        this.onBytes = previous
        this._verify = null
        this.emit('open-unverified')
        resolve('ok')   // no banner in flight: assume the right port, say so
      }, PROBE_TIMEOUT_MS)

      this.onBytes = (bytes) => {
        previous(bytes)
        if (hs.feed(bytes) && !settled) {
          settled = true
          clearTimeout(timer)
          this.onBytes = previous
          this._verify = null
          this.emit('open')
          resolve('ok')
        }
      }
    })
    return this._verify
  }

  startReading() {
    const readable = this.port?.readable
    if (!readable) return
    this.reader = readable.getReader()
    const pump = async () => {
      try {
        while (this.reader && !this.closing) {
          const { value, done } = await this.reader.read()
          if (done) break
          if (value && value.length) this.onBytes(new Uint8Array(value))
        }
      } catch {
        if (!this.closing) this.emit('error', 'the port closed')
      }
    }
    void pump()
  }

  /** Queue bytes; the writer is held open for the life of the connection. */
  write(bytes) {
    if (!this.port?.writable) return
    this.queue.push(Uint8Array.from(bytes))
    void this.drain()
  }

  async drain() {
    if (this.draining) return
    this.draining = true
    try {
      if (!this.writer) this.writer = this.port.writable.getWriter()
      while (this.queue.length) {
        const chunk = this.queue.shift()
        await this.writer.write(chunk)
      }
    } catch (e) {
      if (!this.closing) this.emit('error', `write failed: ${e?.message ?? e}`)
    } finally {
      this.draining = false
    }
  }

  async close() {
    this.closing = true
    this.queue = []
    if (this.reader) {
      try {
        await this.reader.cancel()
      } catch {
        /* already gone */
      }
      try {
        this.reader.releaseLock()
      } catch {
        /* ignore */
      }
      this.reader = null
    }
    if (this.writer) {
      try {
        await this.writer.close()
      } catch {
        /* ignore */
      }
      this.writer = null
    }
    if (this.port) {
      try {
        await this.port.close()
      } catch {
        /* ignore */
      }
    }
    this.port = null
    this.closing = false
    this.emit('idle')
  }
}
