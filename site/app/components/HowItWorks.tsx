"use client";

import { collectionMeta } from "../lib/deployment";

// The flywheel as four pool balls on a ring, clockwise from the top; a small ball travels the ring. Centres on a
// 300×300 board, ring radius 104.
const STEPS = [
  { x: 150, y: 46, c: "#ff6b14", n: 1 },
  { x: 254, y: 150, c: "#1f4dff", n: 2 },
  { x: 150, y: 254, c: "#e5262c", n: 3 },
  { x: 46, y: 150, c: "#14843a", n: 4 },
];

/** A numbered pool ball, the same in the wheel and beside each step (the gloss gradient is the wheel's, `how-gloss`). */
const PoolBall = ({ x, y, c, n }: { x: number; y: number; c: string; n: number }) => (
  <g>
    <circle cx={x} cy={y} r="30" fill={c} />
    <circle cx={x} cy={y} r="14" fill="#fff" />
    <text x={x} y={y + 6} textAnchor="middle" className="how-num">{n}</text>
    <circle cx={x} cy={y} r="30" fill="url(#how-gloss)" />
    <ellipse cx={x - 10} cy={y - 16} rx="10" ry="4.5" fill="#fff" opacity=".5" transform={`rotate(-32 ${x - 10} ${y - 16})`} />
  </g>
);

/** How the coin, the vault, the pool and the buybacks feed each other. */
export function HowItWorks() {
  const sym = collectionMeta.ticker, ape = collectionMeta.short;
  const text = [
    { t: `Trade ${sym}`, d: "Trading fees fund the vault." },
    { t: "The vault builds the pool", d: `The vault acquires ${ape}s and funds ETH backed Shapes and Packs.` },
    { t: "People purchase NFTs", d: "Each purchase randomly selects an NFT. Shapes and Packs are replenished as they're purchased." },
    { t: `Revenue buys back ${sym}`, d: "Surplus revenue buys back and burns the coin." },
  ];
  return (
    <section id="how" className="how" aria-labelledby="how-title">
      <div className="how-intro">
        <h2>Building the pool</h2>
        <p className="lede">Trading fees from {sym} acquire the first Check and fund an initial board of ETH backed Shapes and Packs. Together, they form an FWA custom pool where anyone can purchase a randomly selected NFT with ETH.</p>
      </div>
      <h2 id="how-title">The cycle</h2>
      <div className="how-grid">
        <svg className="how-wheel" viewBox="0 0 300 300" role="img" aria-label="A loop: trading fees fund the vault, the vault builds the pool, people purchase NFTs from it, revenue buys back and burns the coin, and trading continues">
          <defs>
            <radialGradient id="how-gloss" cx="36%" cy="30%" r="70%">
              <stop offset="0" stopColor="#fff" stopOpacity=".28" />
              <stop offset=".5" stopColor="#fff" stopOpacity="0" />
              <stop offset="1" stopColor="#000" stopOpacity=".38" />
            </radialGradient>
            <marker id="how-arrow" viewBox="0 0 10 10" refX="5" refY="5" markerWidth="5" markerHeight="5" orient="auto">
              <path d="M0 0 10 5 0 10z" fill="#5b8dff" />
            </marker>
          </defs>
          <circle cx="150" cy="150" r="104" fill="none" stroke="#22252c" strokeWidth="14" />
          {/* clockwise arcs between the balls, each ending in an arrow */}
          {STEPS.map((s, i) => {
            const a0 = (i * 90 - 90 + 22) * (Math.PI / 180), a1 = (i * 90 + 22 - 44) * (Math.PI / 180);
            return <path key={s.n} d={`M${150 + 104 * Math.cos(a0)} ${150 + 104 * Math.sin(a0)} A104 104 0 0 1 ${150 + 104 * Math.cos(a1)} ${150 + 104 * Math.sin(a1)}`}
              fill="none" stroke="#5b8dff" strokeWidth="2.5" markerEnd="url(#how-arrow)" opacity=".8" />;
          })}
          <g className="how-orbit"><circle cx="150" cy="46" r="7" fill="#e9e8e3" /><circle cx="150" cy="46" r="7" fill="url(#how-gloss)" /></g>
          {STEPS.map((s) => <PoolBall key={s.n} {...s} />)}
          <text x="150" y="146" textAnchor="middle" className="how-mid">{sym}</text>
          <text x="150" y="166" textAnchor="middle" className="how-mid-sub">the flywheel</text>
        </svg>
        <ol className="how-steps">
          {text.map((s, i) => (
            <li key={s.t}><svg className="how-dot" viewBox="-1 -1 62 62" aria-hidden><PoolBall x={30} y={30} c={STEPS[i].c} n={i + 1} /></svg><div><b>{s.t}</b><p>{s.d}</p></div></li>
          ))}
        </ol>
      </div>
    </section>
  );
}
