# Current execution status

Stage: Phase 4 in progress. Contracts, coin venue and the single deployment path are built, fork-tested and
independently reviewed (no Critical/High). Remaining for Phase 4: minimal UI (site/, built; a 375px overflow fix is in progress before commit).
Branch: `dev` (local). Latest milestone commit: see `git log`.

## Pinned environment
- Mainnet fork block 26,302,000; RPC `MAINNET_RPC_URL`, default `https://mainnet.gateway.tenderly.co`.
- forge 1.8.1, solc 0.8.28 (evm cancun). Submodules: forge-std 7fdf81f, solady v0.1.26, OpenZeppelin v5.1.0.
- Addresses and runtime code hashes: `test/fork/ForkBase.sol`, `test/fork/Pins.t.sol`.

## Completed
- Phase 0 (52a0fdc): Foundry project, pinned dependencies, vendored verified sources (`external/`), interfaces
  (`src/interfaces/IFWA.sol`, `src/interfaces/IChecks.sol`), pin tests, risk register and experiment specs
  (`docs/RISKS.md`).
- Phase 1: E1-E9 on real FWA, Checks and Shapes contracts (`test/fork/Lifecycle.t.sol`, `BlackCheck.t.sol`,
  `Editions.t.sol`; harness `test/fork/Lab.sol` is test-only and has a generic call by design). First protocol
  component: `src/game/SurvivalCursor.sol` (permissionless draw counting from FWA's ordered records).
- Phase 1 commit a1ad5f6.
- Phase 2: `docs/THREAT_MODEL.md`; `src/core/Engine.sol` (UUPS custody and lifecycle: rule-priced listing,
  permissionless compose and Black formation, migration with carried survival, proceeds collection, halt/resume);
  `src/fwa/FwaV2Controller.sol` (immutable per-pool owner, engine-only, merges the survival cursor);
  `src/interfaces/IController.sol`; OZ TimelockController deployment in `test/fork/SystemBase.sol`. Commit b49a191.
- Phase 2 review: docs/review/phase2-security-review.md (no Critical/High/Medium; Low fixes applied). Survival now
  derived in O(1) from FWA's active count (C010); `SurvivalCursor` removed. Shapes list at backing + 10% (D004).
- Phase 3 (fc1aa5e): `sim/model.py`, `sim/results/phase3.md`, `docs/ECONOMICS.md` (D004, D005).
- Phase 2 review fixes and C010 (e2df42e).
- Phase 4a (bf6034f): `src/token/Coin.sol`; Engine decay, compose with coin burn and free fallback (D008), ETH and
  coin buyouts (D006), standing bid for Checks and Editions (D007), Shape restock, reentrancy lock; via_ir (C011).
- Deployment (83a0d72): `script/DeploySystem.sol` (one routine + postflight), `script/LaunchConfig.sol`,
  `script/Deploy.s.sol` (simulation by default).
- Phase 4 review (778644a): docs/review/phase4-security-review.md, no Critical/High.
- Coin venue (f1016d2, 2a1000f): `src/venue/VenueLiquidity.sol`, `src/venue/VenueHook.sol`, in DeploySystem with
  postflight checks (D009). All fork tests deploy through DeploySystem (5771132).
- FWA creation fee route: `src/periphery/FwaFeeBuyer.sol` (from collection-games), fork-tested opening the pool.

## Evidence and test results
- `forge test --match-path 'test/fork/*.t.sol'` at block 26,302,000 (bf6034f): 35 passed, 0 failed (Pins 3,
  Lifecycle 5, BlackCheck 3, Editions 1, Custody 10, Migration 3, Market 10). Deploy.t.sol: 2 passed (83a0d72).
- `forge test --match-path 'test/fork/*.t.sol'` (5771132 + fee route): 47 passed, 0 failed (adds Venue 8, Deploy 4).
  `forge test --match-path test/unit/Decay.t.sol`: 2 fuzz tests, 256 runs each, pass.
- Surplus burner (47b9521): Deploy.t.sol 5/5; all fork files 48/48.
- Keeper (406262c): `node --test keeper/test/policy.test.mjs` 7/7. Local rehearsal
  `forge script script/Rehearse.s.sol --rpc-url http://127.0.0.1:8561 --broadcast --unlocked` on the lead's own anvil
  fork (block 26,302,000 verified before broadcast, anvil development accounts on localhost only): success,
  postflight passed. The keeper builder's live rehearsal covered `listChecks` and `forward`; other jobs are
  unit-tested and their contract paths fork-tested.
- Invariants (144aec5): `FOUNDRY_INVARIANT_FAIL_ON_REVERT=true FOUNDRY_INVARIANT_RUNS=16 FOUNDRY_INVARIANT_DEPTH=60
  forge test --match-path test/fork/Invariant.t.sol`: 4/4 hold, 960 calls, 0 handler reverts.
- `forge script script/Deploy.s.sol` simulated on the pinned fork with placeholder role addresses, including the
  venue: success, postflight passed. Nothing broadcast. Buying the FWA creation fee costs 0.1303 ETH at the block.
- `python3 sim/model.py`: 17 scenarios x 60 seeded runs, results in sim/results/phase3.md (model, not evidence). Real mainnet contracts; setup cheats listed in docs/RISKS.md
  "Phase 1 receipts". `NextGenControllerMock` in Migration.t.sol is a labeled mock, not evidence about a real future
  FWA version.
- Onchain reads (cast, same block): Checks 12,474 minted / 7,149 burned / 5,325 live; Editions 3,556; 0 Infinity
  events; 85 single-tier composites.

## Current blockers
None.

## Completed since the last status block
- Keeper (406262c), site (2b17567), audit scope draft (23e32f7), third independent review and its fixes (b608e19:
  opening tick fixed at venue construction, burner reads its pool from the venue), founder review document.
- Evidence at b608e19: `forge test --match-path 'test/fork/*.t.sol'` 50 passed, 0 failed; strict invariants
  (8 x 40) hold; `node --test keeper/test/policy.test.mjs` 7/7; site `tsc --noEmit` passes.

## Next executable action
Wait for the founder's answers to docs/FOUNDER_REVIEW.md decisions 1-6, then apply them to LaunchConfig, spec and
tests, freeze a release candidate, run the full suite once with CANDIDATE_RUN=1, and hand the frozen commit to the
audit. Independent work available meanwhile: Engine view helpers the keeper and site asked for (current notional of
an unlisted Check, compose cost, lightweight tier read), which remove duplicated off-chain logic. Burner deployment and `setBurner` are a post-deploy timelock step (not in DeploySystem yet).

## Incidents
- 2026-10-30: during a rehearsal the lead stopped an anvil process on port 8548 that it had not started (forked near
  block 26,286,12x; owned by some other local session or tool, not by either builder). The lead's own anvil had
  failed to bind to that port, so one rehearsal also broadcast test deployments onto that foreign local node before
  it was stopped. Local test node only: no mainnet effect, nothing spent. The rehearsal was redone on a verified
  free port. Rule kept since: check the port is free and the node's block before broadcasting; stop only a PID this
  session started.

## Open items (not yet built)
- Keepers are unpaid; maintenance relies on the operator or volunteers.
- Opening fee curve against launch snipers dropped (D009 asks the founder).

## Review queue
docs/DECISIONS.md: D001 (Black Check needs 25.6% of all possible Check units), D002 (survival counts allocating
draws at processing), D003 (tier schedule pricing instead of signed quotes), D004
(Shape markup), D005 (decay floor near player break-even), D006 (coin buyouts from a timelocked
coin schedule), D007 (standing bid instead of marketplace orders), D008 (composition window in draws), D009 (coin venue: fee rate,
opening tick, opening curve), D010 (surplus buy-and-burn without an oracle).

## Continuity protocol
After each meaningful increment, update this file with phase, completed work, exact commands and test outcomes, risks,
next action, and relevant commit. Resume from this file in each new agent session.
