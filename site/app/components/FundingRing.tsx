"use client";

// The progress ring around the dome while the game is funded (design handoff "pre-funded dome"): a 300° arc open at
// the bottom for the collar, in two segments sized by cost, the first Ape's bid then the board (with its reserve and
// opening keeper pay), a 16-unit gap between them. Drawn in the machine's own units (Dome: a 390 × 372 box, the glass a
// 320 circle centred at (195, 170)); the SVG's view box adds room around it for the labels and tags.

export const VIEW = { x: -55, y: -24, w: 500, h: 396 }; // the machine at (0, 0)-(390, 372) inside
const CX = 195, CY = 170, R = 172, LABEL_R = 196;
const ARC = 817, GAP = 16; // the handoff's arc length and gap, in its units: only their ratio is used

const point = (f: number, r = R) => {
  const a = ((120 + 300 * f) * Math.PI) / 180;
  return [CX + r * Math.cos(a), CY + r * Math.sin(a)] as const;
};
const arc = (f0: number, f1: number) => {
  if (f1 - f0 <= 0.0005) return "";
  const [x0, y0] = point(f0), [x1, y1] = point(f1);
  return `M ${x0.toFixed(2)} ${y0.toFixed(2)} A ${R} ${R} 0 ${300 * (f1 - f0) > 180 ? 1 : 0} 1 ${x1.toFixed(2)} ${y1.toFixed(2)}`;
};

export type RingProps = {
  apeT: number; boardT: number; // ETH each segment stands for
  ape: number; board: number; // ETH filled in each
  provisional?: number; // ETH beyond a full bid, waiting for the board (the bid is live, no Ape yet)
  preview?: number; pending?: boolean; // the fee of the trade being typed or sent, added from the current fill
  glow?: boolean; // the bid is live
  tag?: string; // a pill at the fill's end: a fee event, "BID LIVE"
  apeState: "active" | "done"; boardState: "upcoming" | "provisional" | "active" | "done";
  apeValue: string; boardValue: string;
};

export function FundingRing(p: RingProps) {
  const a1 = ((ARC - GAP) * p.apeT) / (p.apeT + p.boardT) / ARC, b0 = a1 + GAP / ARC;
  const apeF = (v: number) => a1 * Math.min(Math.max(v / p.apeT, 0), 1);
  const boardF = (v: number) => b0 + (1 - b0) * Math.min(Math.max(v / p.boardT, 0), 1);
  // a position along the whole way: the Ape first, then (after the gap) the board
  const at = (v: number) => (v <= p.apeT ? apeF(v) : boardF(v - p.apeT));
  const filled = p.ape < p.apeT ? p.ape : p.apeT + p.board;
  const end = p.ape < p.apeT || p.board > 0 ? at(filled) : null;
  const to = p.preview ? at(filled + p.preview) : 0;
  // the preview: on one segment, or across the gap into the board
  const previewPaths = !p.preview ? [] : (() => {
    const from = at(filled);
    if (from < a1 && to > a1) return [arc(from, a1), arc(b0, to)];
    return [arc(from, to)];
  })();
  const label = (f: number, anchor: "start" | "end", name: string, value: string, state: string) => {
    const [x, y] = point(f, LABEL_R);
    const colour = state === "upcoming" ? "#6b7080" : state === "provisional" ? "#9aa1b2" : "#8fb0ff";
    return (
      <text x={x} y={y} textAnchor={anchor} className="ring-label">
        <tspan x={x} fill={colour}>{name}</tspan>
        <tspan x={x} dy="1.25em" className="ring-value">{value}</tspan>
      </text>
    );
  };
  const tagAt = end ?? (p.ape >= p.apeT ? a1 : 0);
  const [tx, ty] = point(tagAt, R + 2);
  const tagW = p.tag ? p.tag.length * 5.6 + 16 : 0;
  return (
    <svg className="ring" viewBox={`${VIEW.x} ${VIEW.y} ${VIEW.w} ${VIEW.h}`} aria-hidden>
      <defs>
        <filter id="ring-glow" x="-20%" y="-20%" width="140%" height="140%">
          <feDropShadow dx="0" dy="0" stdDeviation="3" floodColor="#1f5bff" floodOpacity="1" />
        </filter>
      </defs>
      <path d={arc(0, a1)} className="ring-track" />
      <path d={arc(b0, 1)} className="ring-track" />
      <path d={arc(0, apeF(p.ape))} className="ring-fill" filter={p.glow ? "url(#ring-glow)" : undefined} />
      {p.provisional ? <path d={arc(b0, boardF(p.provisional))} className="ring-fill provisional" /> : null}
      {p.board > 0 ? <path d={arc(b0, boardF(p.board))} className="ring-fill" /> : null}
      {previewPaths.map((d, k) => <path key={k} d={d} className={p.pending ? "ring-pending" : "ring-preview"} />)}
      {end !== null && end > 0 ? (
        <g className="ring-marker" transform={`translate(${point(end)[0]} ${point(end)[1]})`}>
          <circle r="9" fill="#1f5bff" opacity=".25" /><circle r="4.5" fill="#fff" />
        </g>
      ) : null}
      {label(a1 / 2, "end", "FIRST APE", p.apeValue, p.apeState)}
      {label((b0 + 1) / 2, "start", "BOARD", p.boardValue, p.boardState)}
      {p.tag ? (
        <g className="ring-tag" transform={`translate(${tx + (tx < CX ? -tagW - 6 : 6)} ${ty - 22})`}>
          <rect width={tagW} height="18" rx="9" fill="#1f5bff" />
          <text x={tagW / 2} y="12.5" textAnchor="middle">{p.tag}</text>
        </g>
      ) : null}
    </svg>
  );
}
