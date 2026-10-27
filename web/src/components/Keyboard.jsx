// ============================================================================
//  Keyboard.jsx -- the 40-key rubber keyboard, drawn like the real case
//
//  Renders LAYOUT: four rows of ten, every legend printed where the 48K prints
//  it -- colour word and white function above the number keys, the green
//  SYMBOL SHIFT keyword above the letters, the orange symbol on the key face,
//  the white CAPS SHIFT keyword under it, the extended-mode word below.
//
//  Presses go out as FE <pos> <down>.  The PC keyboard is captured too: left
//  shift is CAPS SHIFT, right shift or alt SYMBOL SHIFT, and a shifted symbol
//  becomes the Spectrum's own chord.
// ============================================================================

import React, { useCallback, useEffect, useRef, useState } from 'react'
import { LAYOUT, KEY_BY_ID, pos as posOf, eventToChord, typeText } from '../zxkeys.js'
import { encodeKey, encodeAllUp } from '../protocol.js'

/** width of a key, in normal-key units */
const widthOf = (k) => k.w || 1

/** wide keys print their two words stacked on the key face */
const isStacked = (k) => Boolean(k.w && k.sub)

/** the number row prints four arrow functions, drawn larger than words */
const ARROWS = ['\u2190', '\u2191', '\u2192', '\u2193']

export default function Keyboard({ link, connected }) {
  /** ids of keys currently held, on screen or by the PC keyboard */
  const [held, setHeld] = useState(() => new Set())

  const send = useCallback((bytes) => link.write(bytes), [link])

  const press = useCallback((id) => {
    const k = KEY_BY_ID[id]
    if (!k || !connected) return
    send(encodeKey(posOf(k), true))
    setHeld((s) => new Set(s).add(id))
  }, [connected, send])

  const release = useCallback((id) => {
    const k = KEY_BY_ID[id]
    if (!k || !connected) return
    send(encodeKey(posOf(k), false))
    setHeld((s) => {
      const n = new Set(s)
      n.delete(id)
      return n
    })
  }, [connected, send])

  const chordDown = useCallback((chord) => {
    if (!chord || !connected) return
    for (const k of chord.keys) press(k.id)
  }, [connected, press])

  const chordUp = useCallback((chord) => {
    if (!chord || !connected) return
    // the key before its shifts: a bare main key never shows between scans
    for (const k of [...chord.keys].reverse()) release(k.id)
  }, [connected, release])

  // ---- PC keyboard --------------------------------------------------------
  const downChords = useRef(new Map()) // ev.code -> chord (for the up event)

  useEffect(() => {
    if (!connected) return
    const onKeyDown = (ev) => {
      if (ev.repeat) { ev.preventDefault(); return }
      const chord = eventToChord(ev)
      if (!chord) return
      ev.preventDefault()
      downChords.current.set(ev.code, chord)
      chordDown(chord)
    }
    const onKeyUp = (ev) => {
      const chord = downChords.current.get(ev.code)
      if (!chord) return
      downChords.current.delete(ev.code)
      chordUp(chord)
    }
    const onBlur = () => {
      if (link.port) link.write(encodeAllUp())
      downChords.current.clear()
      setHeld(new Set())
    }
    window.addEventListener('keydown', onKeyDown)
    window.addEventListener('keyup', onKeyUp)
    window.addEventListener('blur', onBlur)
    return () => {
      window.removeEventListener('keydown', onKeyDown)
      window.removeEventListener('keyup', onKeyUp)
      window.removeEventListener('blur', onBlur)
    }
  }, [connected, link, chordDown, chordUp])

  // ---- paste a BASIC listing ---------------------------------------------
  const [pasteOpen, setPasteOpen] = useState(false)
  const [pasteText, setPasteText] = useState('')

  const paste = useCallback(() => {
    void typeText(pasteText, send, { connected })
    setPasteOpen(false)
  }, [pasteText, send, connected])

  return (
    <div className="kbd">
      <div className="kbd-note">
        click the keys, or type on your PC &middot; left shift = CAPS SHIFT,
        right shift / alt = SYMBOL SHIFT
      </div>

      <div className="case">
        <div className="case-top">
          <span className="wordmark">sinclair</span>
          <span className="model">ZX Spectrum</span>
          <span className="tagline">&quot;the world&apos;s best selling home computer&quot;</span>
        </div>

        <div className="keys">
          {LAYOUT.map((row, r) => (
            <div className="krow" key={r}>
              {row.map((k) => (
                <div
                  className="cell"
                  key={k.id}
                  style={{ '--w': widthOf(k) }}
                >
                  <div className="top-legend">
                    {k.name && (
                      <span
                        className={'name' + (k.chip ? ' chip' : '')}
                        style={{ color: k.chip ? '#f2f4f5' : k.ink }}
                      >
                        {k.name}
                      </span>
                    )}
                    {k.fn && (
                      <span className={'fn' + (ARROWS.includes(k.fn) ? ' arrow' : '')}>
                        {k.fn}
                      </span>
                    )}
                    {k.above && <span className="kw">{k.above}</span>}
                  </div>

                  <button
                    className={
                      'key' +
                      (held.has(k.id) ? ' down' : '') +
                      (isStacked(k) ? ' stacked' : '') +
                      (k.w >= 2 ? ' big' : '') +
                      (k.warm ? ' warm' : '')
                    }
                    onPointerDown={(e) => { e.preventDefault(); press(k.id) }}
                    onPointerUp={(e) => { e.preventDefault(); release(k.id) }}
                    onPointerLeave={() => held.has(k.id) && release(k.id)}
                    aria-label={k.id}
                  >
                    <span className="glyph">{k.main}</span>
                    {k.sym && <span className="sym">{k.sym}</span>}
                    {k.sub && <span className="sub">{k.sub}</span>}
                  </button>

                  <div className="bottom-legend">
                    {k.below && <span className="ext">{k.below}</span>}
                  </div>
                </div>
              ))}
            </div>
          ))}
        </div>

        <div className="rainbow" aria-hidden="true" />
      </div>

      <div className="kbd-tools">
        <button onClick={() => setPasteOpen(!pasteOpen)}>Paste BASIC</button>
        <button
          onClick={() => {
            if (connected && link.port) link.write(encodeAllUp())
            setHeld(new Set())
          }}
        >
          Release all
        </button>
      </div>

      {pasteOpen && (
        <div className="paste">
          <textarea
            rows={6}
            placeholder={'10 PRINT "HELLO "\n20 GOTO 10'}
            value={pasteText}
            onChange={(e) => setPasteText(e.target.value)}
          />
          <div>
            <button onClick={paste} disabled={!connected}>Type it</button>
            <button onClick={() => setPasteOpen(false)}>Close</button>
          </div>
        </div>
      )}
    </div>
  )
}
