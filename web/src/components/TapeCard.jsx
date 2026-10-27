// ============================================================================
//  TapeCard.jsx -- the tape library and the deck
//
//  The library is the card's: the board lists every .TAP in the root
//  directory and the page may only pick from that list.  A row's load button
//  streams it from the card into the DDR3 player; the ROM's own
//  LOAD "" (or the PLAY button) starts it.  Upload and each row's delete button
//  edit the card itself (App.jsx withCard), then the board is asked to relist.
// ============================================================================

import React, { useEffect, useState } from 'react'
import Cassette from './Cassette.jsx'
import { DECK } from '../protocol.js'

const kb = (n) => (n >= 1024 ? `${(n / 1024).toFixed(1)} KB` : `${n} B`)

// Tape time: a 5 s leader plus the data at the ROM's average byte, eight bits
// of 855 / 1710 T-state half-pulse pairs, half of them ones, at 3.5 MHz.
// ponytail: pilots and gaps between blocks are not counted (the page only
// knows the size); the clock waits at the end for the board's END.
const LEADER_SEC = 5
const BYTE_SEC = (8 * (2 * 855 + 2 * 1710)) / 2 / 3_500_000
export const tapeSeconds = (bytes) => (bytes > 0 ? LEADER_SEC + bytes * BYTE_SEC : 0)

/** Seconds of tape played: runs while PLAYING, holds otherwise. */
function usePlayClock(state, total) {
  const [t, setT] = useState(0)
  useEffect(() => {
    if (state === DECK.EMPTY || state === DECK.LOADING || state === DECK.READY) setT(0)
    if (state === DECK.ENDED) setT(total)
    if (state !== DECK.PLAYING) return
    setT((x) => (x >= total ? 0 : x))           // play after the end starts over
    let last = performance.now()
    const id = setInterval(() => {
      const now = performance.now()
      setT((x) => Math.min(total, x + (now - last) / 1000))
      last = now
    }, 250)
    return () => clearInterval(id)
  }, [state, total])
  return t
}

export default function TapeCard({
  library,
  connected,
  demo = false,
  uploadProgress = null,
  onRescan,
  onUpload,
  onSelect,
  onLoad,
  onEject,
  onPlay,
  onPause,
  onRewind,
  tapeAudio,
  onTapeAudio,
  onInstantLoad,
  onTypeLoad,
  onLoadSnapshot,
  onDelete,
}) {
  const { entries, selected, loaded, state, pos, len } = library
  const entry = library.deckEntry
  const canEject = connected && loaded >= 0
  const canPlay = connected && (state === DECK.READY || state === DECK.ENDED || state === DECK.PAUSED)
  const playing = state === DECK.PLAYING
  const paused = state === DECK.PAUSED
  const canRewind = connected && library.held
  const tapeBytes = len || (entry ? entry.size : 0)
  const total = tapeSeconds(tapeBytes)
  const elapsed = usePlayClock(state, total)

  return (
    <section className="tape-card">
      <div className="tc-head">
        <span className="tc-title">Tape</span>
        <span className="tc-sub">library on the SD card &middot; player in DDR3</span>
        {demo && <span className="tc-demo">demo &mdash; no board</span>}
        <label className={'tc-upload' + (connected && state !== DECK.LOADING ? '' : ' off')}>
          Upload to Card
          <input
            type="file"
            accept=".tap,.tzx,.z80,application/octet-stream"
            hidden
            disabled={!connected || state === DECK.LOADING}
            onChange={(e) => {
              const f = e.target.files && e.target.files[0]
              e.target.value = ''
              if (f) onUpload(f)
            }}
          />
        </label>
        <button className="tc-rescan" onClick={onRescan} disabled={!connected}>
          Rescan card
        </button>
      </div>

      {uploadProgress && (
        <div style={{ padding: '8px 16px', background: 'rgba(56, 189, 248, 0.12)', color: '#38bdf8', fontSize: '13px', display: 'flex', justifyContent: 'space-between', borderBottom: '1px solid rgba(56, 189, 248, 0.25)' }}>
          <span>{uploadProgress.detail}</span>
          <span>{uploadProgress.percent}%</span>
        </div>
      )}
      <div className="tc-body">
        {/* ---- the card's tapes ---------------------------------------- */}
        <div className="tc-lib">
          <div className="tc-lib-head">
            <span>Library</span>
            <span className="dim">
              {library.card === 'ok'
                ? `${entries.length} tape${entries.length === 1 ? '' : 's'}`
                : library.card === 'error' ? 'card error' : connected ? 'waiting for the card' : 'not connected'}
            </span>
          </div>

          {entries.length === 0 ? (
            <div className="tc-empty">
              {!connected
                ? 'Connect the board to read the card\u2019s tape library.'
                : library.card === 'ok'
                  ? 'No .TAP, .TZX, or .Z80 files in the card’s root. Put media on the card, then rescan.'
                  : library.card === 'error' ? 'SD card error or unformatted card. Insert a FAT32 card with files, or upload above.' : 'Waiting for the board to report the card’s files — this needs the tape-library bitstream.'}
            </div>
          ) : (
            <ul className="tc-list">
              {entries.map((t, i) => {
                const ext = (t.name.split('.').pop() || '').toUpperCase()
                const isZ80 = ext === 'Z80'
                return (
                  <li key={`${t.name}-${i}`}>
                    <button
                      className={
                        'tc-row' +
                        (i === selected ? ' sel' : '') +
                        (i === loaded ? ' in-player' : '')
                      }
                      onClick={() => onSelect(i)}
                      title={`${t.name}\n${kb(t.size)}${i === loaded ? '\nin the player' : ''}`}
                    >
                      <span className="tc-row-name">{library.displayName(t.name)}</span>
                      <span className={`tc-badge badge-${ext.toLowerCase()}`}>{ext}</span>
                      <span className="tc-row-size">{kb(t.size)}</span>
                      {i === loaded && <span className="tc-row-dot" title="in the player" />}
                    </button>
                    <button
                      className="tc-del tc-load"
                      onClick={() => (isZ80 ? (onSelect(i), onLoadSnapshot(t)) : onLoad(i))}
                      disabled={!connected || uploadProgress !== null || state === DECK.LOADING}
                      title={isZ80 ? 'Restore Z80 snapshot into memory' : 'Load tape into player'}
                      aria-label={`Load ${library.displayName(t.name)}`}
                    >
                      &#9660;
                    </button>
                    <button
                      className="tc-del"
                      onClick={() => onDelete(i)}
                      disabled={!connected || demo || uploadProgress !== null || state === DECK.LOADING}
                      title={`Delete ${library.displayName(t.name)} from the card`}
                      aria-label={`Delete ${library.displayName(t.name)}`}
                    >
                      &#10005;
                    </button>
                  </li>
                )
              })}
            </ul>
          )}
        </div>

        {/* ---- the deck ------------------------------------------------- */}
        <div className="tc-deck">
          <Cassette
            name={entry ? library.displayName(entry.name) : ''}
            size={tapeBytes}
            elapsed={elapsed}
            total={total}
            state={state}
            spinning={playing}
          />

          <div className="deck-keys" role="group" aria-label="Tape transport">
            <button className="dk" onClick={onRewind} disabled={!canRewind} title="Rewind to the start" aria-label="Rewind">
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M11 6v12l-8.5-6zM21 6v12l-8.5-6z" /></svg>
            </button>
            <button className={'dk play' + (playing ? ' on' : '')} onClick={onPlay} disabled={!canPlay} title="Play" aria-label="Play">
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 5v14l12-7z" /></svg>
            </button>
            <button className="dk stop" onClick={onPause} disabled={!playing || !connected} title="Stop where it is (LOAD &quot;&quot; or Play carries on)" aria-label="Stop">
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6h12v12H6z" /></svg>
            </button>
            <button className={'dk pause' + (paused ? ' on' : '')} onClick={onPause} disabled={!(playing || paused) || !connected} title={paused ? 'Resume' : 'Pause'} aria-label={paused ? 'Resume' : 'Pause'}>
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 5h4v14H6zM14 5h4v14h-4z" /></svg>
            </button>
            <button className="dk eject" onClick={onEject} disabled={!canEject} title="Eject" aria-label="Eject">
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 5l7.5 8.5h-15zM4.5 16h15v3h-15z" /></svg>
            </button>
            <button className={'dk audio' + (tapeAudio ? ' on' : '')} onClick={onTapeAudio} disabled={!connected} aria-pressed={!!tapeAudio} title="Hear the tape loading (level: VOL= in ZXCONFIG.TXT, 5% by default)" aria-label="Tape audio">
              <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9h4l5-4v14l-5-4H4z" />{tapeAudio && <path d="M15.5 8.5a5 5 0 0 1 0 7l-1.4-1.4a3 3 0 0 0 0-4.2zM18.4 5.6a9 9 0 0 1 0 12.8L17 17a7 7 0 0 0 0-9.9z" />}</svg>
            </button>
          </div>

          <div className="transport">
            <button
              className="tp instant"
              onClick={onInstantLoad}
              disabled={!connected || !entry || !/\.(tap|tzx)$/i.test(entry.name)}
              title="Run the tape in the page and load the result as a snapshot"
            >
              <span className="tp-icon" aria-hidden="true">&#9889;</span> Instant
            </button>
            <button
              className="tp typeload"
              onClick={onTypeLoad}
              disabled={!connected}
              title="Type LOAD &quot;&quot; + ENTER"
            >
              <span className="tp-icon" aria-hidden="true">&#9000;</span> LOAD ""
            </button>
            <span className={'tc-state' + (state === DECK.ERROR ? ' bad' : '')}>
              {library.stateLabel}
            </span>
          </div>

          <div className="tc-meter">
            <div className="tc-bar">
              <div
                className="tc-bar-fill"
                style={{ width: `${len ? Math.min(100, (pos / len) * 100) : 0}%` }}
              />
            </div>
            <span className="tc-count">
              {len
                ? state === DECK.PLAYING || state === DECK.PAUSED || state === DECK.ENDED
                  ? `${pos.toLocaleString()} of ${len.toLocaleString()} bytes played`
                  : `${library.resident.toLocaleString()} of ${len.toLocaleString()} bytes in DDR3`
                : 'DDR3 empty'}
            </span>
          </div>
        </div>
      </div>
    </section>
  )
}
