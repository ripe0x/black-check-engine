"use client";

import { useEffect, useLayoutEffect, useRef, useState } from "react";
import type { Address } from "viem";
import { Ball } from "./Ball";

/**
 * A ball in the dome: an Ape, or a small Shape or Pack (`nft` set, `small`), its art read from its tokenURI; or a ball
 * with art given directly (`src`) or plain (`colour`), as on the promo.
 */
export type DomeBall = { key: string; i: number; tokenId: bigint; label?: string; nft?: Address; small?: boolean; colour?: string; src?: string };

// Physics runs in the dome's own pixels: a 316px circle (the 320px glass less its 2px border). Rendering is in
// percentages of that circle, so the machine scales with its container.
const S = 316, C = S / 2, R = S / 2;
const G = 1800, BOUNCE = 0.45; // px/s², restitution
const REST = 8, REST_FOR = 0.4, MAX_RUN = 8; // settled below REST px/s for REST_FOR s; hard stop after MAX_RUN s

// held: the ball being dragged. It follows the pointer (its velocity is the pointer's) and pushes the others like
// an immovable body; on release it keeps that velocity, so it can be thrown. lifted: a won ball the machine raises
// to the top of the glass and holds there, pushing the others aside the same way.
type Body = { x: number; y: number; vx: number; vy: number; r: number; rot: number; held?: boolean; lifted?: boolean };

// The blower while a draw is picked: an air jet from the base lifts balls in the lower glass and a swirl turns them
// about the centre, reversing every few seconds, so the pile tumbles like a lottery machine.
const JET = 5200, SWIRL = 1100, VMAX = 1500; // px/s², px/s², px/s
function blow(bs: Body[], h: number, mix: number, t: number) {
  const dir = Math.sin(t / 1700) > 0 ? 1 : -1;
  for (const b of bs) {
    if (b.held || b.lifted) continue;
    const dx = b.x - C, dy = b.y - C, depth = dy / R; // -1 at the top, 1 at the bottom
    if (depth > -0.15) b.vy -= JET * mix * (0.45 + depth) * (0.6 + Math.random() * 0.8) * h;
    const d = Math.hypot(dx, dy) || 1;
    b.vx += (-dy / d) * SWIRL * mix * dir * h + (Math.random() - 0.5) * 900 * mix * h;
    b.vy += (dx / d) * SWIRL * mix * dir * h;
    const v = Math.hypot(b.vx, b.vy);
    if (v > VMAX) { b.vx *= VMAX / v; b.vy *= VMAX / v; }
  }
}

/** Moves the lifted balls toward their spots in a row near the top of the glass. */
function raise(bs: Body[], h: number) {
  const up = bs.filter((b) => b.lifted);
  const w = up.reduce((a, b) => a + 2.2 * b.r, 0);
  let x = C - w / 2;
  for (const b of up) {
    const tx = x + 1.1 * b.r, ty = C - R * 0.42 + b.r * 0.2, k = Math.min(1, 7 * h);
    x += 2.2 * b.r;
    const nx = b.x + (tx - b.x) * k, ny = b.y + (ty - b.y) * k;
    b.vx = (nx - b.x) / h; b.vy = (ny - b.y) / h; b.x = nx; b.y = ny;
  }
}

/** One physics step: gravity, ball-ball collisions and the round wall. */
function step(bs: Body[], h: number) {
  for (const b of bs) {
    if (b.held || b.lifted) { b.rot += ((b.vx * h) / b.r) * (180 / Math.PI); continue; }
    b.vy += G * h;
    b.x += b.vx * h;
    b.y += b.vy * h;
    b.rot += ((b.vx * h) / b.r) * (180 / Math.PI);
  }
  for (let i = 0; i < bs.length; i++) for (let j = i + 1; j < bs.length; j++) {
    const a = bs[i], b = bs[j], dx = b.x - a.x, dy = b.y - a.y, d = Math.hypot(dx, dy), min = a.r + b.r;
    if (d >= min || d === 0) continue;
    const nx = dx / d, ny = dy / d, over = min - d;
    // a held ball does not give way: the other takes the whole push and the whole impulse
    const fa = a.held || a.lifted, fb = b.held || b.lifted;
    if (fa && fb) continue;
    const wa = fa ? 0 : fb ? 1 : 0.5, wb = 1 - wa;
    a.x -= nx * over * wa; a.y -= ny * over * wa; b.x += nx * over * wb; b.y += ny * over * wb;
    const vrel = (b.vx - a.vx) * nx + (b.vy - a.vy) * ny;
    if (vrel < 0) {
      const k = -(1 + BOUNCE) * vrel;
      a.vx -= k * wa * nx; a.vy -= k * wa * ny; b.vx += k * wb * nx; b.vy += k * wb * ny;
    }
  }
  for (const b of bs) {
    const dx = b.x - C, dy = b.y - C, d = Math.hypot(dx, dy), max = R - b.r;
    if (d <= max) continue;
    const nx = dx / d, ny = dy / d, vn = b.vx * nx + b.vy * ny;
    b.x = C + nx * max; b.y = C + ny * max;
    if (vn > 0 && !b.held && !b.lifted) { b.vx -= (1 + BOUNCE) * vn * nx; b.vy -= (1 + BOUNCE) * vn * ny; b.vx *= 0.97; b.vy *= 0.97; }
  }
}

const SMALL = 0.2; // a small ball's area against an Ape ball's (diameter ≈ 45%)

/** Ball diameter for this mix: sizes shrink with the count so the settled pile fills about half the glass. */
function sizeFor(small: boolean[]) {
  const area = small.reduce((a, s) => a + (s ? SMALL : 1), 0);
  return area ? Math.min(160, 2 * R * Math.sqrt(0.5 / area)) : 0;
}

/** A new ball at a random free spot in the upper glass (anywhere if none is free), already falling. */
function place(others: Body[], r: number): Body {
  for (let k = 0; k < 200; k++) {
    const a = Math.PI + Math.random() * Math.PI, m = Math.sqrt(Math.random()) * (R - r); // upper half
    const x = C + m * Math.cos(a), y = C + m * Math.sin(a) * 0.9 + R * 0.15;
    if (others.every((o) => Math.hypot(o.x - x, o.y - y) >= o.r + r)) return { x, y, vx: (Math.random() - 0.5) * 160, vy: 150 + Math.random() * 300, r, rot: Math.random() * 360 - 180 };
  }
  return { x: C + (Math.random() - 0.5) * R, y: C - R / 2, vx: 0, vy: 200, r, rot: 0 }; // the collision step pushes it clear
}

/**
 * The glass dome on its lit base. Tapping a ball selects it; tapping the glass anywhere else, or the base (also a
 * keyboard button), throws the balls about and lets them settle again.
 *
 * While a draw runs, `mixing` (0-1) turns the blower on; `lift` raises the won Apes (by token id) to the top of the
 * glass, each named for a view transition (`ape-<id>`) so it can fly out to the win screen. A lifted Ape no longer in
 * `balls` (the board already let it go) is added back for the moment.
 */
export function Dome({ balls: given, mixing = 0, lift = [], nudge = 0 }: { balls: DomeBall[]; mixing?: number; lift?: bigint[]; nudge?: number }) {
  const lifting = new Set(lift.map(String));
  const balls: DomeBall[] = [...given, ...lift.filter((t) => !given.some((b) => !b.small && b.tokenId === t))
    .map((t, k) => ({ key: `won-${t}`, i: k + 1, tokenId: t }))];
  const ids = balls.map((b) => b.key).join(",");
  const kinds = balls.map((b) => (b.small ? "s" : "a")).join("");
  const live = useRef(new Map<string, Body>()); // by ball key, so balls arriving later join those already falling
  const [bodies, setBodies] = useState(new Map<string, Body>());
  const raf = useRef(0);
  const el = useRef<HTMLDivElement>(null);
  const glass = useRef<HTMLDivElement>(null);
  const since = useRef(0); // seconds since the pile was last disturbed (a drop, a throw, a shake)
  const reduce = useRef(false);
  const mix = useRef(0);
  mix.current = reduce.current ? 0 : mixing;
  const snapshot = () => setBodies(new Map([...live.current].map(([k, b]) => [k, { ...b }])));

  /** Runs the physics until the pile is at rest. */
  const run = () => {
    if (raf.current) return;
    let last = performance.now(), calm = 0;
    since.current = 0;
    const tick = (t: number) => {
      const bs = [...live.current.values()];
      // a frame's timestamp can precede the performance.now() the loop started at: no step for that frame (a zero or
      // negative step would divide by zero in `raise`)
      const dt = Math.min((t - last) / 1000, 1 / 30);
      if (dt <= 0) { raf.current = requestAnimationFrame(tick); return; }
      last = t; since.current += dt;
      for (let i = 0; i < 4; i++) {
        if (mix.current) blow(bs, dt / 4, mix.current, t);
        raise(bs, dt / 4);
        step(bs, dt / 4);
      }
      if (mix.current) { since.current = 0; calm = 0; }
      const held = bs.some((b) => b.held);
      calm = !held && bs.every((b) => Math.hypot(b.vx, b.vy) < REST) ? calm + dt : 0;
      snapshot();
      if (!held && (calm > REST_FOR || since.current > MAX_RUN)) {
        for (const b of bs) { b.vx = 0; b.vy = 0; }
        raf.current = 0;
        return;
      }
      raf.current = requestAnimationFrame(tick);
    };
    raf.current = requestAnimationFrame(tick);
  };

  // On load, and whenever balls are added (the Shapes sample arriving after the Apes, an Ape listed), the new ones
  // appear at random spots already falling, so the pile differs every load and is in motion from the first frame.
  // Balls already in the glass keep moving; removed ones (an Ape won) leave. With reduced motion it settles at once.
  useLayoutEffect(() => {
    const m = live.current, want = new Set(balls.map((b) => b.key));
    for (const k of [...m.keys()]) if (!want.has(k)) m.delete(k);
    const d = sizeFor(balls.map((b) => !!b.small)), rOf = (b: DomeBall) => (b.small ? d * Math.sqrt(SMALL) : d) / 2;
    for (const b of balls) { const o = m.get(b.key); if (o) o.r = rOf(b); }
    for (const b of [...balls].sort((x, y) => Number(!!x.small) - Number(!!y.small))) { // big balls first
      if (!m.has(b.key)) m.set(b.key, place([...m.values()], rOf(b)));
    }
    reduce.current = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduce.current) {
      const bs = [...m.values()];
      for (let t = 0; t < 900; t++) step(bs, 1 / 240);
      for (const b of bs) { b.vx = 0; b.vy = 0; }
      snapshot();
      return;
    }
    snapshot();
    run();
    // stopping here (not in a separate unmount effect) means any rerun, StrictMode's included, restarts the loop
    return () => {
      cancelAnimationFrame(raf.current);
      raf.current = 0;
    };
  }, [ids, kinds]);

  // The blower and the lift: mark the lifted balls (by token id; Apes only) and keep the physics running. With reduced
  // motion there is no blower and a lifted ball moves to its spot at once.
  const liftKey = lift.join(",");
  useEffect(() => {
    for (const b of balls) {
      const o = live.current.get(b.key);
      if (!o) continue;
      const up = !b.small && lifting.has(String(b.tokenId));
      if (o.lifted && !up) { o.lifted = false; o.vy = 0; }
      if (up) { o.lifted = true; o.held = false; }
    }
    if (reduce.current) {
      const bs = [...live.current.values()];
      for (let t = 0; t < 600; t++) { raise(bs, 1 / 120); step(bs, 1 / 240); }
      for (const b of bs) { b.vx = 0; b.vy = 0; }
      snapshot();
      return;
    }
    since.current = 0;
    run();
  }, [liftKey, mixing, ids]); // eslint-disable-line react-hooks/exhaustive-deps

  // A nudge (each change of `nudge`, e.g. a trading fee arriving while the game is funded): a small upward impulse
  // through the pile, much gentler than a shake. None with reduced motion.
  useEffect(() => {
    if (!nudge || reduce.current) return;
    for (const b of live.current.values()) {
      if (b.held || b.lifted) continue;
      b.vx += (Math.random() - 0.5) * 260;
      b.vy -= 220 + Math.random() * 260;
    }
    since.current = 0;
    run();
  }, [nudge]); // eslint-disable-line react-hooks/exhaustive-deps

  // Dragging: pointer positions in the glass's own units; the held ball's velocity is the pointer's, smoothed
  const drag = useRef<{ key: string; id: number; x: number; y: number; t: number; moved: boolean } | null>(null);
  const toGlass = (e: React.PointerEvent) => {
    const r = glass.current!.getBoundingClientRect();
    return { x: ((e.clientX - r.left) / r.width) * S, y: ((e.clientY - r.top) / r.height) * S };
  };
  const grab = (key: string, e: React.PointerEvent) => {
    const b = live.current.get(key);
    if (!b || b.lifted || drag.current) return;
    e.preventDefault();
    glass.current!.setPointerCapture(e.pointerId);
    const p = toGlass(e);
    drag.current = { key, id: e.pointerId, ...p, t: performance.now(), moved: false };
    b.held = true; b.vx = 0; b.vy = 0;
    since.current = 0;
    run();
  };
  const move = (e: React.PointerEvent) => {
    const g = drag.current, b = g && live.current.get(g.key);
    if (!g || !b || e.pointerId !== g.id) return;
    const p = toGlass(e), t = performance.now(), dt = Math.max((t - g.t) / 1000, 1 / 240);
    b.vx = b.vx * 0.5 + ((p.x - g.x) / dt) * 0.5; b.vy = b.vy * 0.5 + ((p.y - g.y) / dt) * 0.5;
    b.x = p.x; b.y = p.y;
    if (Math.hypot(p.x - g.x, p.y - g.y) > 1) g.moved = true;
    Object.assign(g, p, { t });
  };
  const drop = (e: React.PointerEvent) => {
    const g = drag.current, b = g && live.current.get(g.key);
    if (!g || e.pointerId !== g.id) return;
    if (b) {
      b.held = false;
      // a throw keeps the pointer's speed, capped so a flick cannot tunnel through the others
      const v = Math.hypot(b.vx, b.vy), cap = 2400;
      if (v > cap) { b.vx *= cap / v; b.vy *= cap / v; }
    }
    drag.current = null;
    justDragged.current = true; // the click that follows a drag must not shake
    since.current = 0;
    run();
  };
  const justDragged = useRef(false);

  const shake = () => {
    for (const b of live.current.values()) { b.vx += (Math.random() - 0.5) * 1400; b.vy -= 700 + Math.random() * 700; }
    since.current = 0;
    el.current?.animate(
      [{ transform: "none" }, { transform: "translate(-1.3%,-0.8%) rotate(-2deg)" }, { transform: "translate(1.3%,-0.5%) rotate(2deg)" }, { transform: "translate(-0.5%,0) rotate(-1deg)" }, { transform: "none" }],
      { duration: 380, easing: "ease-out" },
    );
    run();
  };

  // Space presses the button while the machine is on screen: down on keydown (it shakes then, like a press), up on
  // keyup. Not while typing or using another control, not while a sheet is open, not on key repeat.
  const [pressed, setPressed] = useState(false);
  const shakeRef = useRef(shake);
  shakeRef.current = shake;
  useEffect(() => {
    let inView = false;
    const io = new IntersectionObserver(([e]) => { inView = e.intersectionRatio >= 0.4; }, { threshold: [0, 0.4, 1] });
    if (el.current) io.observe(el.current);
    const busy = (t: EventTarget | null) => t instanceof HTMLElement && !!t.closest("input, textarea, select, button, a, [contenteditable], [role=dialog]");
    const down = (e: KeyboardEvent) => {
      if (e.code !== "Space" || !inView || busy(e.target) || document.querySelector("[role=dialog]")) return;
      e.preventDefault(); // the page would scroll
      if (e.repeat) return;
      setPressed(true);
      shakeRef.current();
    };
    const up = (e: KeyboardEvent) => { if (e.code === "Space") setPressed(false); };
    const release = () => setPressed(false); // a key released outside the window never sends keyup here
    window.addEventListener("keydown", down);
    window.addEventListener("keyup", up);
    window.addEventListener("blur", release);
    return () => {
      io.disconnect();
      window.removeEventListener("keydown", down);
      window.removeEventListener("keyup", up);
      window.removeEventListener("blur", release);
    };
  }, []);

  const pct = (v: number) => `${(v / S) * 100}%`;
  return (
    <div ref={el} className={`machine${mixing && !reduce.current ? " mixing" : ""}`}>
      {/* drag any ball about; tap the glass (not a ball) or press the button to shake them all */}
      <div ref={glass} className="machine-glass" onPointerMove={move} onPointerUp={drop} onPointerCancel={drop}
        onClick={(e) => {
          if (justDragged.current) { justDragged.current = false; return; }
          if (!(e.target as HTMLElement).closest(".machine-ball")) shake();
        }}>
        {balls.map((b, i) => {
          const p = bodies.get(b.key);
          if (!p) return null;
          const style = { left: pct(p.x - p.r), top: pct(p.y - p.r), width: pct(2 * p.r), zIndex: p.lifted ? 900 : p.held ? 800 : i + 1,
            // from the prop, not the physics state (a frame behind), so a view transition never sees the name twice
            viewTransitionName: !b.small && lifting.has(String(b.tokenId)) ? `ape-${b.tokenId}` : undefined };
          return (
            <div key={b.key} className={`machine-ball${p.held ? " held" : ""}${p.lifted ? " lifted" : ""}`} aria-hidden style={style} onPointerDown={(e) => grab(b.key, e)}>
              {b.colour || b.src ? (
                <div className={b.small ? "ball fit" : "ball"} style={{ background: b.colour ?? (b.small ? "#000000" : undefined) }}>
                  {b.src ? <img src={b.src} alt="" style={{ transform: `rotate(${p.rot}deg) scale(1.06)` }} /> : null}
                </div>
              ) : <Ball tokenId={b.tokenId} nft={b.nft} rot={p.rot} fit={!!b.small} />}
            </div>
          );
        })}
        <Gloss />
      </div>
      <Body />
      <button type="button" className={`machine-push${pressed ? " pressed" : ""}`} aria-label="Shake the machine (or press Space)" onClick={shake}><span /></button>
    </div>
  );
}

// ---- The machine's drawing, lit like the balls: one light, upper left ----

/** An annular band between radii ri and ro from angle a0 to a1 (degrees, SVG's clockwise from +x). */
function band(c: number, ro: number, ri: number, a0: number, a1: number) {
  const p = (r: number, a: number) => `${(c + r * Math.cos((a * Math.PI) / 180)).toFixed(2)} ${(c + r * Math.sin((a * Math.PI) / 180)).toFixed(2)}`;
  const large = a1 - a0 > 180 ? 1 : 0;
  return `M${p(ro, a0)} A${ro} ${ro} 0 ${large} 1 ${p(ro, a1)} L${p(ri, a1)} A${ri} ${ri} 0 ${large} 0 ${p(ri, a0)} Z`;
}
function arc(c: number, r: number, a0: number, a1: number) {
  const p = (a: number) => `${(c + r * Math.cos((a * Math.PI) / 180)).toFixed(2)} ${(c + r * Math.sin((a * Math.PI) / 180)).toFixed(2)}`;
  return `M${p(a0)} A${r} ${r} 0 0 1 ${p(a1)}`;
}

/** Reflections on the glass, over the balls: a fresnel rim, a softbox window upper left, a small window right, and
 * the base's glow caught low on the right. In the glass's own 320 units. */
function Gloss() {
  return (
    <svg className="machine-gloss" viewBox="0 0 320 320" aria-hidden>
      <defs>
        <radialGradient id="gl-body" cx=".5" cy=".5" r=".5">
          <stop offset="0" stopColor="#fff" stopOpacity="0" />
          <stop offset=".8" stopColor="#fff" stopOpacity="0" />
          <stop offset=".95" stopColor="#fff" stopOpacity=".05" />
          <stop offset="1" stopColor="#fff" stopOpacity=".1" />
        </radialGradient>
        <linearGradient id="gl-rim" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#fff" stopOpacity=".55" />
          <stop offset=".42" stopColor="#fff" stopOpacity=".07" />
          <stop offset=".8" stopColor="#8fb0ff" stopOpacity=".1" />
          <stop offset="1" stopColor="#8fb0ff" stopOpacity=".3" />
        </linearGradient>
        <linearGradient id="gl-sheen" x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#fff" stopOpacity=".3" />
          <stop offset=".6" stopColor="#fff" stopOpacity=".06" />
          <stop offset="1" stopColor="#fff" stopOpacity="0" />
        </linearGradient>
        <filter id="gl-soft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="2.4" /></filter>
        <filter id="gl-fine"><feGaussianBlur stdDeviation=".5" /></filter>
      </defs>
      <circle cx="160" cy="160" r="159" fill="url(#gl-body)" />
      <path d={band(160, 147, 120, 196, 264)} fill="url(#gl-sheen)" filter="url(#gl-soft)" />
      <path d={arc(160, 146, 199, 260)} fill="none" stroke="#fff" strokeOpacity=".32" strokeWidth="1.4" strokeLinecap="round" filter="url(#gl-fine)" />
      <path d={band(160, 141, 129, 298, 322)} fill="#fff" fillOpacity=".1" filter="url(#gl-soft)" />
      <path d={arc(160, 151, 28, 78)} fill="none" stroke="#5b8dff" strokeOpacity=".3" strokeWidth="5" strokeLinecap="round" filter="url(#gl-soft)" />
      <circle cx="160" cy="160" r="158.6" fill="none" stroke="url(#gl-rim)" strokeWidth="2.2" />
    </svg>
  );
}

/** The collar the glass seats in, and the pedestal with its light strip and the push button's recess. In the machine's
 * 390×372 frame (glass centre 195,170, radius 160). */
function Body() {
  return (
    <svg className="machine-body" viewBox="0 0 390 372" aria-hidden>
      <defs>
        <linearGradient id="mb-metal" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#363a43" />
          <stop offset=".32" stopColor="#1c1f24" />
          <stop offset="1" stopColor="#0a0b0d" />
        </linearGradient>
        <linearGradient id="mb-side" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stopColor="#000" stopOpacity=".35" />
          <stop offset=".28" stopColor="#fff" stopOpacity=".05" />
          <stop offset=".62" stopColor="#000" stopOpacity="0" />
          <stop offset="1" stopColor="#000" stopOpacity=".55" />
        </linearGradient>
        <linearGradient id="mb-chrome" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stopColor="#111316" />
          <stop offset=".2" stopColor="#5d636e" />
          <stop offset=".45" stopColor="#262a31" />
          <stop offset=".7" stopColor="#4c525c" />
          <stop offset="1" stopColor="#101215" />
        </linearGradient>
        <filter id="mb-blur" x="-10%" y="-200%" width="120%" height="500%"><feGaussianBlur stdDeviation="5" /></filter>
        <filter id="mb-glow" x="-10%" y="-400%" width="120%" height="900%"><feGaussianBlur stdDeviation="3" /></filter>
      </defs>
      {/* ground shadow */}
      <ellipse cx="195" cy="364" rx="160" ry="6" fill="#000" opacity=".75" filter="url(#mb-blur)" />
      {/* pedestal */}
      <path d="M84 298 H306 Q320 298 324 311 L343 345 Q347 360 332 360 H58 Q43 360 47 345 L66 311 Q70 298 84 298 Z" fill="url(#mb-metal)" />
      <path d="M84 298 H306 Q320 298 324 311 L343 345 Q347 360 332 360 H58 Q43 360 47 345 L66 311 Q70 298 84 298 Z" fill="url(#mb-side)" />
      <path d="M86 298.7 H304" stroke="#fff" strokeOpacity=".2" strokeWidth="1" />
      {/* collar where the glass seats */}
      <rect x="90" y="287" width="210" height="13" rx="6.5" fill="url(#mb-chrome)" />
      <rect x="96" y="287.6" width="198" height="1.2" rx=".6" fill="#fff" opacity=".28" />
      {/* recessed light strip */}
      <rect x="118" y="318" width="154" height="5" rx="2.5" fill="#05070c" />
      <rect x="124" y="319.4" width="142" height="2.2" rx="1.1" fill="#5b8dff" filter="url(#mb-glow)" opacity=".8" />
      <rect x="124" y="319.6" width="142" height="1.8" rx=".9" fill="#a9c1ff" />
      {/* the push button's recess (the button itself is HTML, so it can be pressed) */}
      <rect x="166" y="331" width="58" height="19" rx="9.5" fill="#040506" />
      <rect x="166" y="331" width="58" height="19" rx="9.5" fill="none" stroke="url(#mb-chrome)" strokeWidth="1.4" />
    </svg>
  );
}
