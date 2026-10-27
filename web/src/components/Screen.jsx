// ============================================================================
//  Screen.jsx -- ZX Spectrum 48K live framebuffer capture & screen rendering
//  Referenced from apple2e_TP20K/web
// ============================================================================

import React, { useEffect, useRef, useState, useCallback } from 'react'

const SCALE = 2 // 320x240 native (256x192 + 32px border) doubled to 640x480
const BORDER_X = 32
const BORDER_Y = 24
const CANVAS_W = (256 + BORDER_X * 2) * SCALE // 640
const CANVAS_H = (192 + BORDER_Y * 2) * SCALE // 480

// ZX Spectrum 16-color ULA Palette
const PALETTE = [
  // Normal (0..7) - Level 0xC0 (192)
  [0x00, 0x00, 0x00], // 0 Black
  [0x00, 0x00, 0xc0], // 1 Blue
  [0xc0, 0x00, 0x00], // 2 Red
  [0xc0, 0x00, 0xc0], // 3 Magenta
  [0x00, 0xc0, 0x00], // 4 Green
  [0x00, 0xc0, 0xc0], // 5 Cyan
  [0xc0, 0xc0, 0x00], // 6 Yellow
  [0xc0, 0xc0, 0xc0], // 7 White
  // Bright (8..15) - Level 0xFF (255)
  [0x00, 0x00, 0x00], // 8 Bright Black
  [0x00, 0x00, 0xff], // 9 Bright Blue
  [0xff, 0x00, 0x00], // 10 Bright Red
  [0xff, 0x00, 0xff], // 11 Bright Magenta
  [0x00, 0xff, 0x00], // 12 Bright Green
  [0x00, 0xff, 0xff], // 13 Bright Cyan
  [0xff, 0xff, 0x00], // 14 Bright Yellow
  [0xff, 0xff, 0xff], // 15 Bright White
]

const COLOR_NAMES = [
  'Black', 'Blue', 'Red', 'Magenta', 'Green', 'Cyan', 'Yellow', 'White',
]

const PALETTES = {
  color: {
    label: 'Color (RGB)',
    dot: 'linear-gradient(135deg, #d00000 25%, #00d000 50%, #0000d0 75%, #ffff00 100%)',
  },
  green: {
    label: 'Green',
    dot: '#20e820',
    on: [0x20, 0xe8, 0x20],
  },
  amber: {
    label: 'Amber',
    dot: '#ffb000',
    on: [0xff, 0xb0, 0x00],
  },
  white: {
    label: 'B&W',
    dot: '#eeeeee',
    on: [0xee, 0xee, 0xee],
  },
}

export default function Screen({
  screen,
  onCapture,
  busy,
  onClose,
}) {
  const canvas = useRef(null)
  const [palette, setPaletteState] = useState(() => {
    try {
      return localStorage.getItem('zx_screen_palette') || 'color'
    } catch {
      return 'color'
    }
  })
  const [scanlines, setScanlinesState] = useState(() => {
    try {
      return localStorage.getItem('zx_screen_scanlines') === '1'
    } catch {
      return false
    }
  })
  const [autoRefresh, setAutoRefreshState] = useState(() => {
    try {
      return Number(localStorage.getItem('zx_screen_autorefresh')) || 0
    } catch {
      return 0
    }
  })
  const [showOptions, setShowOptions] = useState(false)
  const [copiedImage, setCopiedImage] = useState(false)

  const setPalette = useCallback((p) => {
    setPaletteState(p)
    try { localStorage.setItem('zx_screen_palette', p) } catch {}
  }, [])

  const setScanlines = useCallback((s) => {
    setScanlinesState(s)
    try { localStorage.setItem('zx_screen_scanlines', s ? '1' : '0') } catch {}
  }, [])

  const setAutoRefresh = useCallback((sec) => {
    setAutoRefreshState(sec)
    try { localStorage.setItem('zx_screen_autorefresh', String(sec)) } catch {}
  }, [])

  // Auto-refresh timer
  useEffect(() => {
    if (autoRefresh <= 0) return undefined
    const interval = setInterval(() => {
      if (!busy) onCapture()
    }, autoRefresh * 1000)
    return () => clearInterval(interval)
  }, [autoRefresh, busy, onCapture])

  // Save screenshot as PNG
  const onSaveScreenshot = useCallback(() => {
    const cv = canvas.current
    if (!cv) return
    const a = document.createElement('a')
    a.download = `zx-spectrum-screen-${Date.now()}.png`
    a.href = cv.toDataURL('image/png')
    a.click()
  }, [])

  // Copy screenshot to clipboard
  const onCopyImage = useCallback(() => {
    const cv = canvas.current
    if (!cv) return
    try {
      if (typeof ClipboardItem !== 'undefined' && navigator.clipboard?.write) {
        cv.toBlob((blob) => {
          if (!blob) return
          navigator.clipboard
            .write([new ClipboardItem({ 'image/png': blob })])
            .then(() => {
              setCopiedImage(true)
              setTimeout(() => setCopiedImage(false), 2000)
            })
            .catch((err) => {
              console.error('Failed to copy image to clipboard:', err)
            })
        }, 'image/png')
      }
    } catch (err) {
      console.error('Failed to copy image:', err)
    }
  }, [])

  // Render framebuffer to canvas
  useEffect(() => {
    const cv = canvas.current
    if (!cv) return
    const ctx = cv.getContext('2d')
    if (!ctx) return

    if (cv.width !== CANVAS_W) cv.width = CANVAS_W
    if (cv.height !== CANVAS_H) cv.height = CANVAS_H

    ctx.imageSmoothingEnabled = false

    const img = ctx.createImageData(CANVAS_W, CANVAS_H)
    const buf = img.data

    const isColor = palette === 'color'
    const monoTheme = PALETTES[palette] || PALETTES.green
    const monoOn = monoTheme.on || [0x20, 0xe8, 0x20]

    const mapRgb = (r, g, b) => {
      if (isColor) return [r, g, b]
      const lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
      return [
        Math.round(monoOn[0] * lum),
        Math.round(monoOn[1] * lum),
        Math.round(monoOn[2] * lum),
      ]
    }

    const borderColIdx = screen ? (screen.border & 7) : 7
    const borderRgb = mapRgb(...PALETTE[borderColIdx])

    // 1. Fill entire border area
    const totalPixels = CANVAS_W * CANVAS_H
    for (let i = 0; i < totalPixels; i++) {
      const idx = i * 4
      buf[idx] = borderRgb[0]
      buf[idx + 1] = borderRgb[1]
      buf[idx + 2] = borderRgb[2]
      buf[idx + 3] = 255
    }

    // 2. Render 256x192 ZX screen if framebuffer data is present
    if (screen && screen.data && screen.data.length >= 6912) {
      const data = screen.data
      const flashPhase = Boolean(screen.flash)

      for (let y = 0; y < 192; y++) {
        // Interleaved ZX bitmap scanline offset:
        // addr = ((y >> 6) << 11) | ((y & 7) << 8) | (((y >> 3) & 7) << 5)
        const lineOffset = ((y >> 6) << 11) | ((y & 7) << 8) | (((y >> 3) & 7) << 5)
        const attrOffset = 6144 + ((y >> 3) << 5)

        for (let col = 0; col < 32; col++) {
          const bmp = data[lineOffset + col]
          const attr = data[attrOffset + col]

          const ink = attr & 7
          const paper = (attr >> 3) & 7
          const bright = (attr & 0x40) ? 8 : 0
          const flash = Boolean(attr & 0x80) && flashPhase

          for (let bit = 0; bit < 8; bit++) {
            const dot = (bmp >> (7 - bit)) & 1
            const cIdx = flash ? (dot ? paper : ink) : (dot ? ink : paper)
            const palIdx = cIdx ? (cIdx + bright) : 0
            const [r, g, b] = mapRgb(...PALETTE[palIdx])

            const px = (BORDER_X + col * 8 + bit) * SCALE
            const py = (BORDER_Y + y) * SCALE

            // Scale 2x2
            for (let dy = 0; dy < SCALE; dy++) {
              const rowStart = ((py + dy) * CANVAS_W + px) * 4
              for (let dx = 0; dx < SCALE; dx++) {
                const p = rowStart + dx * 4
                buf[p] = r
                buf[p + 1] = g
                buf[p + 2] = b
                buf[p + 3] = 255
              }
            }
          }
        }
      }
    }

    ctx.putImageData(img, 0, 0)
  }, [screen, palette])

  const borderName = screen ? COLOR_NAMES[screen.border & 7] : 'White'

  return (
    <section className="pane screen-pane">
      <header>
        <div className="pane-title-group">
          <h2>Screen</h2>
          <span className="hint">Live Framebuffer Capture (UART)</span>
        </div>
        <div className="pane-header-actions">
          <button
            type="button"
            className="btn-capture"
            onClick={onCapture}
            disabled={busy}
            title="Freeze ZX Spectrum CPU momentarily, dump 6912 bytes framebuffer over UART, and resume"
          >
            {busy ? 'Capturing...' : 'Freeze & capture'}
          </button>
          {screen && (
            <>
              <button
                type="button"
                className="btn-screen-action"
                onClick={onSaveScreenshot}
                title="Save screen capture as PNG image"
              >
                📷 PNG
              </button>
              <button
                type="button"
                className="btn-screen-action"
                onClick={onCopyImage}
                title="Copy screen capture image to clipboard"
              >
                {copiedImage ? '✓ Copied' : '🖼️ Copy Image'}
              </button>
            </>
          )}
          <button
            type="button"
            className={'btn-options-toggle' + (showOptions ? ' active' : '')}
            onClick={() => setShowOptions((o) => !o)}
            title="Toggle display options (Phosphor colors, CRT scanlines, Auto-refresh)"
            aria-pressed={showOptions}
          >
            ⚙ Options
          </button>
          {onClose && (
            <button
              type="button"
              className="pane-close-btn"
              onClick={onClose}
              title="Hide screen pane"
              aria-label="Close screen"
            >
              &times;
            </button>
          )}
        </div>
      </header>

      {showOptions && (
        <div className="options-strip screen-options" role="region" aria-label="Screen Options">
          <div className="option-group">
            <span className="opt-label">Display:</span>
            {Object.entries(PALETTES).map(([k, p]) => (
              <button
                key={k}
                type="button"
                className={'opt-pill' + (palette === k ? ' selected' : '')}
                onClick={() => setPalette(k)}
              >
                <span className="color-swatch" style={{ background: p.dot }} />
                {p.label}
              </button>
            ))}
          </div>

          <div className="option-group">
            <label className="opt-checkbox-label">
              <input
                type="checkbox"
                checked={scanlines}
                onChange={(e) => setScanlines(e.target.checked)}
              />
              CRT Scanlines
            </label>
          </div>

          <div className="option-group">
            <span className="opt-label">Auto-Poll:</span>
            {[
              { sec: 0, label: 'Off' },
              { sec: 2, label: '2s' },
              { sec: 5, label: '5s' },
            ].map((opt) => (
              <button
                key={opt.sec}
                type="button"
                className={'opt-pill' + (autoRefresh === opt.sec ? ' selected' : '')}
                onClick={() => setAutoRefresh(opt.sec)}
              >
                {opt.label}
              </button>
            ))}
            {autoRefresh > 0 && (
              <span className="opt-note warn" title="CPU is briefly frozen during each framebuffer capture">
                ⚠️ Pauses CPU every {autoRefresh}s
              </span>
            )}
          </div>
        </div>
      )}

      <div className={'screen-container' + (scanlines ? ' with-scanlines' : '')}>
        <canvas ref={canvas} className="screen" width={CANVAS_W} height={CANVAS_H} />
      </div>

      {screen ? (
        <p className="screen-status">
          ZX Spectrum 48K &middot; Border: {borderName} ({screen.border & 7}) &middot; Flash: {screen.flash} &middot; 256&times;192 (6912 bytes)
        </p>
      ) : (
        <p className="dim screen-status">
          Click <strong>Freeze &amp; capture</strong> to snapshot the live screen over UART. The CPU is paused for ~69 ms while streaming the 6.9 KB framebuffer.
        </p>
      )}
    </section>
  )
}
