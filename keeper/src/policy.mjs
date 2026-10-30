// Pure decision logic for the keeper. No network: every function here takes already-read state and returns what the
// keeper would do. index.mjs reads the chain, calls these, simulates each chosen action with eth_call and only then
// sends. The engine makes all of these permissionless, so the keeper never does anything a stranger could not.

const BPS = 10_000n;

// Engine._notional: the schedule, decaying linearly to the floor. Mirrors src/core/Engine.sol exactly.
export function notional({tierNotional, survived, decayBpsPerDraw, floorBps}) {
  const drop = survived * decayBpsPerDraw;
  const share = drop >= BPS - floorBps ? floorBps : BPS - drop;
  return (tierNotional * share) / BPS;
}

// The target price if a reprice would move this listing enough to be worth it, else null. Mirrors Engine.reprice:
// skip when unchanged, zero, or below the step unless the target is exactly the floor or the schedule (a boundary).
export function repriceTarget({tierNotional, survived, oldPrice, decayBpsPerDraw, floorBps, repriceStepBps}) {
  const target = notional({tierNotional, survived, decayBpsPerDraw, floorBps});
  if (target === oldPrice || target === 0n) return null;
  const diff = target > oldPrice ? target - oldPrice : oldPrice - target;
  const boundary = target === (tierNotional * floorBps) / BPS || target === tierNotional;
  if (!boundary && diff * BPS < oldPrice * repriceStepBps) return null;
  return target;
}

// Engine._first: the deterministic survivor is the one with more survived draws, lower id breaking a tie.
export function first(a, b) {
  if (a.survived !== b.survived) return a.survived > b.survived ? a : b;
  return a.id < b.id ? a : b;
}

// Free, deterministic compose pairs from the ready checks. A check is "ready" when it is eligible and has survived
// grace draws past its tier threshold (readyAt(id, graceDraws)), which is what makes the compose free (no coin). We
// pair same-tier ready checks; keep = first(pair) and swap=false, so the outcome is exactly the deterministic one the
// contract gives away for free. Tiers 0..5 only (6 is a single -> Black via formBlack).
export function composePairs(ready) {
  const byTier = new Map();
  for (const c of ready) {
    if (c.tier > 5) continue;
    if (!byTier.has(c.tier)) byTier.set(c.tier, []);
    byTier.get(c.tier).push(c);
  }
  const pairs = [];
  for (const group of byTier.values()) {
    const q = [...group];
    while (q.length >= 2) {
      const a = q.pop();
      const b = q.pop();
      const keep = first(a, b);
      const burn = keep === a ? b : a;
      pairs.push([keep.id, burn.id]);
    }
  }
  return pairs;
}

// 64 ready singles (tier 6), ids strictly ascending, so formBlack is free (the lowest id survives). null if fewer.
export function blackBatch(ready) {
  const singles = ready.filter((c) => c.tier === 6).map((c) => c.id);
  if (singles.length < 64) return null;
  return singles.sort((x, y) => (x < y ? -1 : 1)).slice(0, 64);
}

// The jobs to try this tick, in order. `s` is the classified on-chain state (index.mjs). Settling the FWA queue comes
// first because the other maintenance needs an empty queue; then listing, restock, reprice, compositions, proceeds.
// Every job is still simulated before it is sent, so an entry here only means "there may be work".
export function jobs(s) {
  const out = [];
  if (s.processAcq) out.push({name: "processAcquisitions"});
  if (s.listChecks.length) out.push({name: "listChecks", ids: s.listChecks});
  if (s.listShapes.length) out.push({name: "listShapes", ids: s.listShapes});
  if (s.restock.length) out.push({name: "restockShapes", ids: s.restock});
  if (s.reprice.length) out.push({name: "reprice", ids: s.reprice});
  for (const [keep, burn] of s.composePairs) out.push({name: "compose", pair: [keep, burn]});
  if (s.blackBatch) out.push({name: "formBlack", ids: s.blackBatch});
  if (s.collectController) out.push({name: "collect", address: s.collectController});
  if (s.hook) out.push({name: "forward"});
  if (s.releaseSurplus) out.push({name: "releaseSurplus"}); // engine.burner() is set
  if (s.burner) out.push({name: "burn"}); // BURNER contract configured
  return out;
}
