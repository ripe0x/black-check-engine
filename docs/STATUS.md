# Current execution status

Stage: Phase 5. Release candidate `rc2` (commit 6b00eed, local tag) frozen and verified
(docs/receipts/rc2-verification.md): rc1 plus the rc1 audit fixes. Not re-audited; not deployable until the gates
below close.
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

## Release candidate rc1 (0aeea0e)
- Founder decisions 1-6 approved 2026-10-30. Pre-candidate review (docs/review/rc-repairs-review.md): no bug, four
  risks fixed (Burner launch and zero-chunk guards, postflight refuses tick 0, view consistency), one documented.
- Evidence, each run once on the frozen tree: full suite 55/55; strict invariants 32 x 100, 3,200 calls, 0 reverts;
  Slither triaged, no change; deploy simulation with postflight; local rehearsal; keeper 7/7; site typecheck and
  build. Commands and limits: docs/receipts/rc1-verification.md.

## rc1 audit (owner-arranged, 2026-10-30)
- Report: docs/review/rc1-audit.md (fork block 26,305,656). Findings H1 burner sandwich, H2 caller-chosen FWA
  purchaser stranding a Shape, H3 deployer-only launch, M1 fee-buyer refund, and the coin-name gate: all fixed on
  `dev` (D011, D010 amended).
- Focused evidence on the fixes: `forge test --match-path "test/fork/{Deploy,Venue,Market,Lifecycle,Custody,Migration}.t.sol"`
  all pass (Deploy 10, Venue 9, Market 12, Lifecycle 11, Custody 11, Migration 3); `forge test --match-path
  test/fork/Invariant.t.sol` 4/4, 1,600 calls, 0 reverts. The audit's reproductions, run against the fixed tree
  (not committed), now fail as intended. Contract sizes: Burner, controller, venue and fee buyer well under EIP-170.

- rc2 (6b00eed) frozen and verified once: full suite 60/60; strict invariants 32 x 100, 3,200 calls, 0 reverts;
  Slither 92 results, same classes as triaged; deploy simulation and local rehearsal pass.

## Completed since the last status block
- Keeper (406262c), site (2b17567), audit scope draft (23e32f7), third independent review and its fixes (b608e19:
  opening tick fixed at venue construction, burner reads its pool from the venue), founder review document.
- Evidence at b608e19: `forge test --match-path 'test/fork/*.t.sol'` 50 passed, 0 failed; strict invariants
  (8 x 40) hold; `node --test keeper/test/policy.test.mjs` 7/7; site `tsc --noEmit` passes.

## Next executable action
Owner's choice: a retest of `rc2` (6b00eed) against the rc1 findings and the changed code (Burner, FwaV2Controller,
VenueLiquidity, FwaFeeBuyer, DeploySystem), and whether to push `rc2`. Findings get fixed on `dev`, affected checks
repeated, and a new tag frozen. Before any mainnet deployment: final
venue fee and opening tick, name and ticker, council and guardian keys, legal review, keeper pay, and the
timelock-settable placeholders in docs/FOUNDER_REVIEW.md. Deployment, the FWA fee purchase and the coin launch need
explicit owner authorization.

## Incidents
- 2026-10-30: during a rehearsal the lead stopped an anvil process on port 8548 that it had not started (forked near
  block 26,286,12x; owned by some other local session or tool, not by either builder). The lead's own anvil had
  failed to bind to that port, so one rehearsal also broadcast test deployments onto that foreign local node before
  it was stopped. Local test node only: no mainnet effect, nothing spent. The rehearsal was redone on a verified
  free port. Rule kept since: check the port is free and the node's block before broadcasting; stop only a PID this
  session started.

## Open items (not yet built)
- Keepers are unpaid; maintenance relies on the operator or volunteers.
- No opening fee curve against launch snipers in the candidate (D009 approved without it).

## Review queue
Approved 2026-10-30: D001, D003, D005, D006, D007, D009 (fee and tick placeholders). Optional reviews still open:
D002, D004, D008, D010.

## Continuity protocol
After each meaningful increment, update this file with phase, completed work, exact commands and test outcomes, risks,
next action, and relevant commit. Resume from this file in each new agent session.
