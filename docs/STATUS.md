# Current execution status

Stage: Phase 2 complete (independent review resolved). Phase 3 model complete. Phase 4 (minimum complete
protocol) next.
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

## Evidence and test results
- `forge test --match-path 'test/fork/*.t.sol'` at block 26,302,000: 25 passed, 0 failed (Pins 3, Lifecycle 5,
  BlackCheck 3, Editions 1, Custody 10, Migration 3).
- `python3 sim/model.py`: 17 scenarios x 60 seeded runs, results in sim/results/phase3.md (model, not evidence). Real mainnet contracts; setup cheats listed in docs/RISKS.md
  "Phase 1 receipts". `NextGenControllerMock` in Migration.t.sol is a labeled mock, not evidence about a real future
  FWA version.
- Onchain reads (cast, same block): Checks 12,474 minted / 7,149 burned / 5,325 live; Editions 3,556; 0 Infinity
  events; 85 single-tier composites.

## Current blockers
None.

## Next executable action
Phase 4: decay repricing in the engine (D005), manual composition with a BLACK burn, ETH and BLACK buyouts, BLACK
token and fee venue (R12), restricted acquisition path and FWA fee purchase, then keeper, unit/fuzz/invariant tests
and an independent review of the Phase 4 diff (including C010).

## Review queue
docs/DECISIONS.md: D001 (Black Check needs 25.6% of all possible Check units), D002 (survival counts allocating
draws at processing), D003 (tier schedule pricing instead of signed quotes), D004
(Shape markup), D005 (decay floor near player break-even).

## Continuity protocol
After each meaningful increment, update this file with phase, completed work, exact commands and test outcomes, risks,
next action, and relevant commit. Resume from this file in each new agent session.
