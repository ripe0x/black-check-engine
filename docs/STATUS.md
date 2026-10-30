# Current execution status

Stage: Phase 2 implemented and fork-tested; independent security review in progress. Phase 3 (economic
simulation) started in parallel.
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
  `src/interfaces/IController.sol`; OZ TimelockController deployment in `test/fork/SystemBase.sol`.

## Evidence and test results
- `forge test --match-path 'test/fork/*.t.sol'` at block 26,302,000: 23 passed, 0 failed (Pins 3, Lifecycle 5,
  BlackCheck 3, Editions 1, Custody 8, Migration 3). Real mainnet contracts; setup cheats listed in docs/RISKS.md
  "Phase 1 receipts". `NextGenControllerMock` in Migration.t.sol is a labeled mock, not evidence about a real future
  FWA version.
- Onchain reads (cast, same block): Checks 12,474 minted / 7,149 burned / 5,325 live; Editions 3,556; 0 Infinity
  events; 85 single-tier composites.

## Current blockers
None.

## Next executable action
Resolve the independent review findings on Engine/FwaV2Controller/SurvivalCursor. In parallel: Phase 3 simulation
(`sim/`), FWA selection and fee math reproduced from the verified source.

## Review queue
docs/DECISIONS.md: D001 (Black Check needs 25.6% of all possible Check units), D002 (survival counts allocating
draws at processing), D003 (tier schedule pricing instead of signed quotes).

## Continuity protocol
After each meaningful increment, update this file with phase, completed work, exact commands and test outcomes, risks,
next action, and relevant commit. Resume from this file in each new agent session.
