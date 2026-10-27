// ============================================================================
//  App.jsx -- connect, then type; the tape lives on the card
// ============================================================================

import React, { useCallback, useEffect, useRef, useState } from 'react'
import { SerialLink, serialSupported } from './serial-link.js'
import Keyboard from './components/Keyboard.jsx'
import TapeCard from './components/TapeCard.jsx'
import Screen from './components/Screen.jsx'
import { BoardFrames, TapeLibrary, DemoBoard } from './library.js'
import { Card, cardDevice, queryCardStatus, from83 } from './card.js'
import {
  encodeListRequest,
  encodeSelectTape,
  encodeEjectTape,
  encodePlayTape,
  encodePauseTape,
  encodeRewindTape,
  encodeInstantLoad,
  encodeVersionRequest,
  encodeScreenCapture,
  encodeSnapEnter,
  encodeSnapChunk,
  encodeSnapBorder,
  encodeSnapRegs,
  encodeSnapExecute,
  CARD_ENTER,
  CARD_EXIT,
} from './protocol.js'
import { parseZ80Snapshot } from './z80-snapshot.js'
import { typeLoadCommand } from './tape.js'
import versionInfo from './version.json'

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

const DEMO = typeof location !== 'undefined' && /[?&]demo=1\b/.test(location.search)

export default function App() {
  const [link] = useState(() => new SerialLink())
  const [conn, setConn] = useState({ state: DEMO ? 'demo' : 'auto', detail: null })
  const [banner, setBanner] = useState('')
  const [screen, setScreen] = useState(null)
  const [capturing, setCapturing] = useState(false)
  const [uploadProgress, setUploadProgress] = useState(null)
  const [showScreen, setShowScreenState] = useState(() => {
    try {
      return localStorage.getItem('zx_show_screen') !== '0'
    } catch {
      return true
    }
  })
  const captureTimeout = useRef(null)

  const setShowScreen = useCallback((val) => {
    setShowScreenState((prev) => {
      const next = typeof val === 'function' ? val(prev) : val
      try { localStorage.setItem('zx_show_screen', next ? '1' : '0') } catch {}
      return next
    })
  }, [])

  const lib = useRef(new TapeLibrary())
  const [, bump] = useState(0)
  const rerender = useCallback(() => bump((n) => n + 1), [])

  const frames = useRef(new BoardFrames((ev) => {
    if (ev.type === 'screen') {
      setScreen(ev)
      setCapturing(false)
      if (captureTimeout.current) {
        clearTimeout(captureTimeout.current)
        captureTimeout.current = null
      }
    } else {
      lib.current.apply(ev)
      if (ev.type === 'list') refreshNames.current()
    }
    rerender()
  }))
  const refreshNames = useRef(() => {})
  const demo = useRef(null)
  const [firmwareVersion, setFirmwareVersion] = useState(null)

  useEffect(() => {
    link.onState = (s) => {
      setConn({ state: s.state, detail: s.detail })
      // a fresh connection knows nothing about the card: ask for library and FW version
      if (s.state === 'open' || s.state === 'open-unverified') {
        lib.current.clearList()
        link.write(encodeListRequest())
        setTimeout(() => link.write(encodeListRequest()), 600)
        link.write(encodeVersionRequest())
        setTimeout(() => link.write(encodeVersionRequest()), 1200)
      }
    }

    link.onBytes = (bytes) => {
      const { text } = frames.current.feed(bytes)
      if (text.length) {
        const t = new TextDecoder().decode(text)
        setBanner((b) => (b + t).slice(-400))
        const fw = /FW:\s*(v[^\r\n]+)/.exec(t)
        if (fw) {
          setFirmwareVersion(fw[1].trim())
        }
      }
    }
  }, [link])

  const queryFirmware = useCallback(() => {
    if (conn.state === 'open' || conn.state === 'open-unverified') {
      link.write(encodeVersionRequest())
    }
  }, [conn.state, link])

  // ---- the demo deck, when there is no board on this machine ------------
  useEffect(() => {
    if (!DEMO) return undefined
    const d = new DemoBoard((ev) => {
      lib.current.apply(ev)
      rerender()
    })
    demo.current = d
    d.start()
    d.list()
    return () => { d.stop(); demo.current = null }
  }, [rerender])

  const connected = conn.state === 'open' || conn.state === 'open-unverified'

  /** everything the page sends goes through here (and nowhere in demo mode) */
  const send = useCallback((bytes) => {
    if (demo.current) return
    if (connected) link.write(bytes)
  }, [link, connected])

  /**
   * Run `fn(card)` with the board in raw card mode, and always hand the UART
   * back.  The board's own SD jobs (a tape streaming into DDR3, a listing) make
   * raw reads answer "lost", so wait for the card to go idle first.
   */
  const withCard = useCallback(async (fn) => {
    send([CARD_ENTER])
    await sleep(60)
    try {
      let status
      for (let t = 0; t < 30; t++) {
        status = await queryCardStatus(link, { timeoutMs: 2000 })
        if (!status?.busy && !status?.loading) break
        await sleep(100)
      }
      if (!status || !status.fsOk) throw new Error('SD card filesystem is not ready.')
      if (status.busy || status.loading) throw new Error('SD card is busy.')
      return await fn(await Card.open(cardDevice(link)))
    } finally {
      send([CARD_EXIT])
      await sleep(50)
    }
  }, [send, link])

  // The board lists 8.3 names; the long ones are in the card's own LFN
  // entries, so read the root once the listing settles (the board is asked
  // twice on connect, hence the debounce) and show those instead.
  const namesTimer = useRef(null)
  refreshNames.current = () => {
    if (demo.current) return
    clearTimeout(namesTimer.current)
    namesTimer.current = setTimeout(async () => {
      try {
        const files = await withCard((card) => card.fs.list())
        lib.current.longNames = new Map(files.map((f) => [from83(f.short), f.name]))
        rerender()
      } catch (err) {
        console.warn('Long names unavailable:', err)
      }
    }, 800)
  }

  // ---- come up connected ------------------------------------------------
  // Web Serial lets a page open a port it has already been given, with no
  // click and no picker (getPorts, not requestPort), so a board this browser
  // has seen before is picked up as the page loads -- and retried, because a
  // port left open by another tab, or a board plugged in later, becomes
  // available a moment after the page starts.
  const autoTried = useRef(false)
  useEffect(() => {
    if (DEMO || autoTried.current) return
    autoTried.current = true
    let stop = false
    let tries = 0

    const attempt = async () => {
      if (stop || link.port) return
      tries += 1
      const r = await link.openGranted()
      if (stop || link.port) return
      if (r === 'none') {
        setConn({
          state: 'idle',
          detail: tries < 3 ? 'looking for a port' : 'no port yet',
        })
      } else if (r === 'wrong-port') {
        setConn({ state: 'idle', detail: 'that port did not answer' })
      }
      if (tries < 6) setTimeout(() => void attempt(), 3000)
    }

    void attempt()

    // a browser that never answers getPorts() must not leave the page saying
    // "looking for the board" for ever
    const settle = setTimeout(() => {
      setConn((c) => (c.state === 'auto' ? { state: 'idle', detail: 'no port yet' } : c))
    }, 2500)

    // a port granted (or freed) in another window: try again on return
    const onVisible = () => {
      if (document.visibilityState === 'visible' && !link.port) void attempt()
    }
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      stop = true
      clearTimeout(settle)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [link])

  const connect = async () => {
    setBanner('')
    await link.open()
  }
  const disconnect = async () => {
    await link.close()
  }

  const onSelect = useCallback((i) => {
    lib.current.selected = i
    rerender()
  }, [rerender])

  const writeTapeConfig = (card, name) =>
    card.upload('ZXCONFIG.TXT', new TextEncoder().encode(name ? `TAPE=${name}\r\n` : '; no tape in the player\r\n'))

  // ZXCONFIG.TXT's TAPE= is the tape in the player: the board mounts it at
  // boot (and on reset), so a load survives a power cycle.  Best effort: a
  // card that cannot be written still loads, it just will not persist.
  const saveTape = useCallback(async (name) => {
    try {
      await withCard((card) => writeTapeConfig(card, name))
    } catch (err) {
      console.warn('ZXCONFIG.TXT not written:', err)
    }
  }, [withCard])

  const onLoad = useCallback(async (i) => {
    const l = lib.current
    if (i < 0) return
    l.selected = i
    rerender()
    if (l.loaded >= 0) {
      const cur = l.displayName(l.entries[l.loaded]?.name || '')
      const msg = i === l.loaded
        ? `${cur} is already in the player. Load it again?`
        : `${cur} is in the player. Replace it with ${l.displayName(l.entries[i].name)}?`
      if (!window.confirm(msg)) return
    }
    if (demo.current) return demo.current.select(i)
    await saveTape(l.entries[i].name)
    send(encodeSelectTape(i))
  }, [send, rerender, saveTape])

  const onEject = useCallback(async () => {
    if (demo.current) return demo.current.eject()
    send(encodeEjectTape())
    await saveTape(null)
  }, [send, saveTape])

  const onInstantLoad = useCallback(() => {
    if (demo.current) return
    send(encodeInstantLoad())
    // Auto-type LOAD "" so the game runs immediately
    setTimeout(() => typeLoadCommand(send), 100)
  }, [send])

  const onTypeLoad = useCallback(() => {
    if (demo.current) return
    typeLoadCommand(send)
  }, [send])

  const onLoadSnapshot = useCallback(async (entry) => {
    if (!entry || !entry.name) return
    if (!window.confirm(`Load snapshot "${entry.name}"?\nCurrent Spectrum state will be overwritten.`)) {
      return
    }
    if (demo.current) {
      alert('Snapshot loading is not available in demo mode.')
      return
    }

    try {
      setUploadProgress({ percent: 0, detail: 'Reading snapshot from SD card...' })
      const name = entry.name
      const fileData = await withCard(async (card) => {
        const f = await card.fs.find(name)
        if (!f) throw new Error(`${name} is not on the card.`)
        return card.download(f, (done, total) => {
          const percent = total ? Math.round((done / total) * 100) : 0
          setUploadProgress({
            percent,
            detail: `Reading snapshot: ${Math.round(done / 1024)} / ${Math.round(total / 1024)} KB`,
          })
        })
      })

      setUploadProgress({ percent: 100, detail: 'Injecting snapshot into memory...' })
      const snap = parseZ80Snapshot(fileData)

      // Enter snapshot mode (pause CPU)
      send(encodeSnapEnter())
      await sleep(10)

      // Set border
      send(encodeSnapBorder(snap.border))

      // Stream 48K RAM into memory in 1KB chunks
      const CHUNK = 1024
      for (let addr = 0; addr < 49152; addr += CHUNK) {
        const chunk = snap.ram.subarray(addr, Math.min(addr + CHUNK, 49152))
        send(encodeSnapChunk(addr, chunk))
        await sleep(15)
      }

      // Set CPU registers
      send(encodeSnapRegs(snap.regs))
      await sleep(10)

      // Release CPU and jump to PC
      send(encodeSnapExecute())
      setUploadProgress(null)
    } catch (err) {
      console.error('Snapshot loading failed:', err)
      alert(`Snapshot loading failed: ${err.message}`)
      setUploadProgress(null)
    }
  }, [send, withCard])

  // Upload exclusively to the SD card
  const onUpload = useCallback(async (file) => {
    if (!file) return
    const bytes = new Uint8Array(await file.arrayBuffer())
    if (!bytes.length) return

    if (demo.current) {
      alert('Upload to SD card is not available in demo mode.')
      return
    }

    if (lib.current.card !== 'ok') {
      alert('SD card is not ready. Please insert a FAT32 microSD card.')
      return
    }

    try {
      setUploadProgress({ percent: 0, detail: 'Preparing SD card...' })
      await withCard(async (card) => {
        // the same name again replaces the file on the card (fat32.js create)
        if (await card.fs.find(file.name) && !window.confirm(`${file.name} is already on the card. Replace it?`)) return
        await card.upload(file.name, bytes, (done, total) => {
          const percent = total ? Math.round((done / total) * 100) : 0
          setUploadProgress({
            percent,
            detail: `Writing to SD card: ${Math.round(done / 1024)} / ${Math.round(total / 1024)} KB`,
          })
        })
        setUploadProgress({ percent: 100, detail: 'Finishing up...' })
      })
    } catch (err) {
      console.error('SD card upload failed:', err)
      alert(`SD card upload failed: ${err.message}`)
    } finally {
      setUploadProgress(null)
      send(encodeListRequest())
      setTimeout(() => send(encodeListRequest()), 400)
    }
  }, [send, withCard])

  const captureScreen = useCallback(() => {
    setCapturing(true)
    if (demo.current) {
      demo.current.captureScreen()
      setCapturing(false)
      return
    }
    send(encodeScreenCapture())
    if (captureTimeout.current) clearTimeout(captureTimeout.current)
    captureTimeout.current = setTimeout(() => {
      captureTimeout.current = null
      setCapturing(false)
    }, 4000)
  }, [send])

  const onRescan = useCallback(() => {
    if (demo.current) demo.current.list()
    else {
      lib.current.clearList()
      rerender()
      send(encodeListRequest())
    }
  }, [send, rerender])

  const onDelete = useCallback(async (i) => {
    const entry = lib.current.entries[i]
    if (!entry || demo.current) return
    const name = entry.name
    if (!window.confirm(`Delete ${name} from the SD card?`)) return
    // the board lists by position: a deleted tape in the player goes with it
    if (i === lib.current.loaded) send(encodeEjectTape())
    try {
      setUploadProgress({ percent: 0, detail: `Deleting ${name}...` })
      await withCard(async (card) => {
        const f = await card.fs.find(name)
        if (!f) throw new Error(`${name} is not on the card.`)
        await card.remove(f)
        if (i === lib.current.loaded) await writeTapeConfig(card, null)
      })
    } catch (err) {
      console.error('SD card delete failed:', err)
      alert(`Delete failed: ${err.message}`)
    } finally {
      setUploadProgress(null)
      onRescan()
    }
  }, [send, withCard, onRescan])

  return (
    <main>
      <header>
        <h1>ZX Spectrum <span className="dim">on Tang Primer 20K</span></h1>
        <div className="bar">
          <span className={`dot ${connected || DEMO ? 'on' : ''}`} />
          <span className="state">
            {DEMO ? 'demo' : conn.state}
            {conn.detail ? ` \u2014 ${conn.detail}` : ''}
          </span>
          <button
            type="button"
            className={'toggle-btn' + (showScreen ? ' active' : '')}
            onClick={() => setShowScreen((s) => !s)}
            title={showScreen ? 'Hide Screen Pane' : 'Show Screen Pane'}
          >
            📺 Screen
          </button>
          {!DEMO && (connected
            ? <button onClick={disconnect}>Disconnect</button>
            : <button onClick={connect} disabled={!serialSupported()}>
                {conn.detail === 'no port yet' ? 'Pick port' : 'Connect'}
              </button>)}
        </div>
      </header>

      {!serialSupported() && !DEMO && (
        <p className="warn">
          This browser has no Web Serial. Use Chrome or Edge over http://localhost
          (or https) &mdash; Web Serial is not available to plain file:// pages.
        </p>
      )}

      <TapeCard
        library={lib.current}
        connected={connected || DEMO}
        demo={DEMO}
        onRescan={onRescan}
        onUpload={onUpload}
        uploadProgress={uploadProgress}
        onSelect={onSelect}
        onLoad={onLoad}
        onEject={onEject}
        onPlay={() => (demo.current ? demo.current.play() : send(encodePlayTape()))}
        onPause={() => (demo.current ? demo.current.pause() : send(encodePauseTape()))}
        onRewind={() => (demo.current ? demo.current.rewind() : send(encodeRewindTape()))}
        onInstantLoad={onInstantLoad}
        onTypeLoad={onTypeLoad}
        onLoadSnapshot={onLoadSnapshot}
        onDelete={onDelete}
      />

      {showScreen && (
        <Screen
          screen={screen}
          onCapture={captureScreen}
          busy={capturing}
          onClose={() => setShowScreen(false)}
        />
      )}

      {banner && <pre className="banner">{banner}</pre>}

      <Keyboard link={link} connected={connected} />

      <footer>
        <p>
          The Spectrum boots its own 48K ROM to BASIC on the HDMI output; this
          page types on it and picks tapes off the card. Protocol:
          {' '}<code>FE &lt;pos&gt; &lt;down&gt;</code> per key,
          {' '}<code>FB 53 &lt;idx&gt;</code> to put a tape in the player &mdash;
          see src/zx_input.v and src/zx_tape_lib.v.
        </p>
      </footer>

      <footer className="app-footer">
        <div className="footer-item">
          <span className="footer-label">Web Companion:</span>
          <strong className="footer-val">{versionInfo.display}</strong>
        </div>
        <div className="footer-item">
          <span
            className={`footer-status-dot ${connected ? 'connected' : ''}`}
            title={connected ? 'Connected' : 'Disconnected'}
          />
          <span className="footer-label">Bitstream (.fs):</span>
          <strong
            className={`footer-val ${connected ? 'clickable' : ''}`}
            onClick={connected ? queryFirmware : undefined}
            title={connected ? 'Click to re-query bitstream version from board' : undefined}
          >
            {connected ? (firmwareVersion ?? 'Detecting...') : 'Not connected'}
          </strong>
          {connected && (
            <button
              type="button"
              className="footer-refresh-btn"
              onClick={queryFirmware}
              title="Re-query bitstream version from board"
              aria-label="Refresh bitstream version"
            >
              ↻
            </button>
          )}
        </div>
      </footer>
    </main>
  )
}
