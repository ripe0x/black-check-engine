# Current execution status

Stage: Phase 1 complete (game lifecycle proven on a mainnet fork). Phase 2 (custody and upgradeability) next.
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

## Evidence and test results
- `forge test --match-path 'test/fork/*.t.sol'` at block 26,302,000: 12 passed, 0 failed (real mainnet contracts;
  setup cheats listed in docs/RISKS.md "Phase 1 receipts"). Gas figures in the same section.
- Onchain reads (cast, same block): Checks 12,474 minted / 7,149 burned / 5,325 live; Editions 3,556; 0 Infinity
  events; 85 single-tier composites.

## Current blockers
None.

## Next executable action
Phase 2: threat model (docs/THREAT_MODEL.md), then the minimal custody set: vault, per-pool controller with fixed
recipients, council + timelock upgrade path; adversarial tests for extraction, approvals, malicious migration, and a
migration to a different FWA pool with pending draws settled.

## Review queue
docs/DECISIONS.md: D001 (Black Check needs 25.6% of all possible Check units), D002 (survival counts allocating
draws at processing).

## Continuity protocol
After each meaningful increment, update this file with phase, completed work, exact commands and test outcomes, risks,
next action, and relevant commit. Resume from this file in each new agent session.
