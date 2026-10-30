import {test} from "node:test";
import assert from "node:assert/strict";
import {notional, repriceTarget, first, composePairs, blackBatch, jobs} from "../src/policy.mjs";

// launch-ish params: decay 20 bps/draw, floor 85%, step 5%
const dp = {decayBpsPerDraw: 20n, floorBps: 8500n, repriceStepBps: 500n};
const E = 10n ** 18n;

test("notional decays linearly to the floor", () => {
  assert.equal(notional({tierNotional: E, survived: 0n, ...dp}), E); // schedule
  assert.equal(notional({tierNotional: E, survived: 10n, ...dp}), (E * 9800n) / 10000n); // 10 draws -> -2%
  assert.equal(notional({tierNotional: E, survived: 1000n, ...dp}), (E * 8500n) / 10000n); // clamped at the floor
});

test("repriceTarget: null until the move clears the step, non-null at a boundary even if small", () => {
  // from the schedule, one survived draw moves 0.2% < 5% step -> wait
  assert.equal(repriceTarget({tierNotional: E, survived: 1n, oldPrice: E, ...dp}), null);
  // 30 draws -> -6% from schedule, clears the 5% step
  assert.equal(repriceTarget({tierNotional: E, survived: 30n, oldPrice: E, ...dp}), (E * 9400n) / 10000n);
  // already at the target -> null
  assert.equal(repriceTarget({tierNotional: E, survived: 30n, oldPrice: (E * 9400n) / 10000n, ...dp}), null);
  // reaching the floor is a boundary: taken even though the last step from 85.2% is under 5%
  const nearFloor = notional({tierNotional: E, survived: 74n, ...dp}); // 85.2%
  assert.equal(repriceTarget({tierNotional: E, survived: 75n, oldPrice: nearFloor, ...dp}), (E * 8500n) / 10000n);
});

test("first: more survived draws wins, lower id breaks a tie (Engine._first)", () => {
  assert.deepEqual(first({id: 2n, survived: 5n}, {id: 1n, survived: 3n}), {id: 2n, survived: 5n});
  assert.deepEqual(first({id: 7n, survived: 4n}, {id: 3n, survived: 4n}), {id: 3n, survived: 4n});
});

test("composePairs: same tier only, keep = first, no coin pairs", () => {
  const ready = [
    {id: 10n, tier: 0, survived: 5n}, {id: 11n, tier: 0, survived: 9n},
    {id: 20n, tier: 2, survived: 1n}, // unpaired, stays
    {id: 7n, tier: 6, survived: 9n}, // a single, not composed here
  ];
  const pairs = composePairs(ready);
  assert.equal(pairs.length, 1);
  assert.deepEqual(pairs[0], [11n, 10n]); // 11 survived more -> survivor
});

test("blackBatch: 64 ascending singles or null", () => {
  assert.equal(blackBatch([{id: 1n, tier: 6, survived: 9n}]), null);
  const singles = Array.from({length: 70}, (_, i) => ({id: BigInt(100 - i), tier: 6, survived: 9n}));
  const batch = blackBatch(singles);
  assert.equal(batch.length, 64);
  for (let i = 1; i < 64; i++) assert.ok(batch[i - 1] < batch[i]); // strictly ascending -> free
});

const empty = {processAcq: null, listChecks: [], listShapes: [], restock: [], reprice: [], composePairs: [],
  blackBatch: null, collectController: null, hook: null, releaseSurplus: false, burner: null};

test("jobs: nothing to do yields no jobs", () => {
  assert.deepEqual(jobs(empty), []);
});

test("jobs: queue settles first, then listing, restock, reprice, composes, proceeds", () => {
  const s = {...empty, processAcq: {}, listChecks: [1n], listShapes: [2n], restock: [3n], reprice: [4n],
    composePairs: [[5n, 6n]], blackBatch: null, collectController: "0xc", hook: "0xh", releaseSurplus: true, burner: "0xb"};
  assert.deepEqual(jobs(s).map((j) => j.name), [
    "processAcquisitions", "listChecks", "listShapes", "restockShapes", "reprice", "compose",
    "collect", "forward", "releaseSurplus", "burn",
  ]);
});
