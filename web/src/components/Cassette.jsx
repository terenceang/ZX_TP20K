// ============================================================================
//  Cassette.jsx -- the tape in the player, drawn as a C60
//
//  The reels turn while the tape is playing and hold still when it is not;
//  the pack of tape moves from the left hub to the right as the image is
//  played, so the picture is the position.  Everything is SVG so it scales
//  with the card, and every moving part is driven by props -- no local state,
//  no timers here.
// ============================================================================

import React from 'react'
import { DECK } from '../protocol.js'
import { tapeName } from '../library.js'

const PACK_MIN = 11
const PACK_MAX = 27

/** A reel: hub, spokes, and the pack of tape wound on it. */
function Reel({ cx, cy, pack, spinning }) {
  return (
    <g className={'reel' + (spinning ? ' spinning' : '')} style={{ transformOrigin: `${cx}px ${cy}px` }}>
      <circle cx={cx} cy={cy} r={pack} className="pack" />
      <circle cx={cx} cy={cy} r="9.5" className="hub" />
      {[0, 60, 120].map((a) => (
        <rect
          key={a}
          x={cx - 1.6}
          y={cy - 9}
          width="3.2"
          height="18"
          rx="1.2"
          className="spoke"
          transform={`rotate(${a} ${cx} ${cy})`}
        />
      ))}
      <circle cx={cx} cy={cy} r="3.2" className="axle" />
    </g>
  )
}

export default function Cassette({ name, size = 0, pos = 0, state = DECK.EMPTY, spinning = false }) {
  const f = size > 0 ? Math.max(0, Math.min(1, pos / size)) : 0
  const packL = PACK_MIN + (PACK_MAX - PACK_MIN) * (1 - f)
  const packR = PACK_MIN + (PACK_MAX - PACK_MIN) * f
  const counter = String(Math.floor(pos / 1024) % 10000).padStart(4, '0')
  const label = name ? tapeName(name) : 'no tape'

  return (
    <svg className="cassette" viewBox="0 0 360 216" role="img" aria-label={`cassette ${label}`}>
      {/* shell */}
      <rect x="2" y="2" width="356" height="212" rx="12" className="shell" />
      <rect x="8" y="8" width="344" height="200" rx="9" className="shell-in" />

      {/* label */}
      <rect x="22" y="18" width="316" height="66" rx="4" className="label" />
      <rect x="22" y="18" width="316" height="6" rx="3" className="label-stripe" />
      <text x="34" y="46" className="label-name">
        {label.length > 34 ? label.slice(0, 33) + '\u2026' : label}
      </text>
      <text x="34" y="64" className="label-sub">
        {size > 0 ? `${(size / 1024).toFixed(1)} KB` : '\u2014'}
        {size > 0 ? ' \u00b7 ZX Spectrum 48K' : ''}
      </text>
      <text x="326" y="64" className="label-side" textAnchor="end">
        {state === DECK.PLAYING ? 'PLAY' : state === DECK.READY ? 'READY' : ''}
      </text>

      {/* the window and the two hubs */}
      <rect x="58" y="96" width="244" height="72" rx="8" className="window" />
      <rect x="66" y="104" width="228" height="56" rx="5" className="window-in" />
      <Reel cx={120} cy={132} pack={packL} spinning={spinning} />
      <Reel cx={240} cy={132} pack={packR} spinning={spinning} />
      {/* the tape between the hubs */}
      <rect x="128" y={132 - 1.6} width="104" height="3.2" rx="1.6" className="tape" />

      {/* counter, screws, bottom edge */}
      <rect x="150" y="176" width="60" height="22" rx="3" className="counter-bg" />
      <text x="180" y="192" className="counter" textAnchor="middle">{counter}</text>

      {[[16, 16], [344, 16], [16, 200], [344, 200]].map(([x, y]) => (
        <circle key={`${x},${y}`} cx={x} cy={y} r="2.6" className="screw" />
      ))}

      <path d="M22 200 h316" className="bottom-line" />
      <text x="22" y="211" className="brand">ZX-TP20K</text>
      <text x="338" y="211" className="brand" textAnchor="end">C48</text>
    </svg>
  )
}
