import { test } from "node:test";
import assert from "node:assert/strict";
import { shouldAct, jobs } from "../src/policy.mjs";

const g = 1_000_000_000n;
const base = { maxBasefeeWei: 30n * g, backupAfterSeconds: 21_600n, gateWei: g, limitWei: 200n * g };

test("primary acts at or below its basefee ceiling, or when work is very old", () => {
  assert.equal(shouldAct({ ...base, mode: "primary", ageSeconds: 1n, basefeeWei: 30n * g }), true);
  assert.equal(shouldAct({ ...base, mode: "primary", ageSeconds: 1n, basefeeWei: 31n * g }), false);
  assert.equal(shouldAct({ ...base, mode: "primary", ageSeconds: 21_601n, basefeeWei: 100n * g }), true);
});

test("neither mode acts above the gas price limit, however old the work", () => {
  const capped = { ...base, limitWei: 10n * g };
  assert.equal(shouldAct({ ...capped, mode: "primary", ageSeconds: 1_000_000n, basefeeWei: 100n * g }), false);
  assert.equal(shouldAct({ ...capped, mode: "backup", ageSeconds: 1_000_000n, basefeeWei: 100n * g }), false);
  assert.equal(shouldAct({ ...capped, mode: "backup", ageSeconds: 1_000_000n, basefeeWei: 10n * g }), true);
});

test("backup waits six hours unless gas is cheap", () => {
  assert.equal(shouldAct({ ...base, mode: "backup", ageSeconds: 100n, basefeeWei: 5n * g }), false);
  assert.equal(shouldAct({ ...base, mode: "backup", ageSeconds: 21_601n, basefeeWei: 5n * g }), true);
  assert.equal(shouldAct({ ...base, mode: "backup", ageSeconds: 100n, basefeeWei: g - 1n }), true);
});

const idle = { activated: true, retiring: false, retired: false, ready: false, poolExists: true, unreleasedWins: [],
  burnerReady: false, reserve: 0n };

test("ordinary operation: sync (no FWA processing: players and the callback settle), then releases and buybacks when due", () => {
  assert.deepEqual(jobs(idle).map((j) => j.name), ["sync"]);
  const busy = { ...idle, unreleasedWins: [7n], burnerReady: true };
  assert.deepEqual(jobs(busy).map((j) => j.name), ["sync", "release", "buyback"]);
  assert.deepEqual(jobs(busy)[1].args, [7n]);
});

test("the live bid is swept when a sweep can forward", () => {
  assert.deepEqual(jobs({ ...idle, sweepReady: true }).map((j) => j.name), ["sync", "sweep"]);
});

test("funding mode: activation once ready; no pool means nothing to sync", () => {
  assert.deepEqual(jobs({ ...idle, activated: false, ready: true }).map((j) => j.name), ["sync", "activate"]);
  assert.deepEqual(jobs({ ...idle, activated: false, poolExists: false }), []);
});

test("retirement: settle and step; after it, hand over to the successor, flush the sunset, release the reserve", () => {
  assert.deepEqual(jobs({ ...idle, retiring: true }).map((j) => j.name), ["processAcquisitions", "retireStep"]);
  assert.deepEqual(jobs({ ...idle, retired: true }).map((j) => j.name), ["retireStep", "migrateApes", "migrateCapital"]);
  assert.deepEqual(jobs({ ...idle, retired: true, sunsetDue: true, reserve: 1n, burnerReady: true }).map((j) => j.name),
    ["retireStep", "migrateApes", "migrateCapital", "flushSunset", "releaseRetired", "buyback"]);
});
