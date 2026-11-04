# Current execution status

Stage: rebase on collection-games (docs/REBASE_PLAN.md), phases R0-R5 built. Tracking PR: ripe0x/black-check-engine#1
(draft; updated per phase). Not audited, not deployed.
Branch: `claude/wizardly-shannon-440owk`. The pre-rebase implementation is archived at tag `rc2` (6b00eed).

## Pinned environment
- Fork block 26,337,000 for every fork test (after FWA reopened V2 pool creation at 26,335,860; D014, C014). RPC
  `MAINNET_RPC_URL`; run suites against a local anvil fork of the Tenderly gateway:
  `anvil --fork-url https://mainnet.gateway.tenderly.co --fork-block-number 26337000 --port 8546`.
- forge 1.8.1 (982849d, release binaries in ~/.foundry/bin), solc 0.8.28, cancun, `via_ir = true` (C015).
  `FOUNDRY_PROFILE=fast` (no IR) is for iteration only; its EIP-170 size test fails by design. Use `forge build --force`
  before a recorded run: an incremental build once kept a stale pool owner inside a test contract.
- Submodules: forge-std 7fdf81f, solady acd959a, v4-core 59d3ecf, v4-periphery 60cd938, shapes 1b84c10, shape-packs
  3a463f7. OpenZeppelin only from Shapes' vendored v5.5.0.

## Rebase progress (2026-11-03/04)
- R0: rc2 tag on the remote; FWA V2 creation off 26,329,277-26,335,859, on again from 26,335,860 (read-only calls).
- R1 (33440ff): collection-games 409ca75 imported unchanged. Base suite at 26,284,000: 269/281; the 12 throughput
  studies passed every assertion and stopped only at writing receipts into a missing directory.
- R2-R5 (b54de86): fork block 26,337,000; council authority in Admin/Governed (D012); Checks pool owner (tiers,
  schedule, survival C010, decay D005, desk operations); ChecksDesk (composition D008, Black formation, ETH and coin
  buyouts D006); vault buys 80-Check Originals only, Editions via `sellEdition`, nothing above 120% of the 80 price.
- R6-R7 (40599e6, 5d8db23): market values D016 (`sim/checks_market.py`); the council is a real OZ TimelockController
  (Safe proposes, 7 days, guardian cancels); council-only value powers; owner bounds (markup >= 5%, keeper pay caps);
  survival carried across a migration (`Nft.carried`); a real V2 -> community-pool migration test (community factory
  switches opened locally only: off on mainnet at this block).
- R8 (a240060, 8a52cfb): keeper free-composition job (unit 9/9); site Checks page, typecheck and build pass (28 pages);
  rehearsal script converted (not yet run).
- R9: independent security review (docs/review/rebase-security-review.md): C-1 (a composite sold at an 80-Check's
  price in the sunset) and M-1 (buying back below the vault's purchase price) fixed in 0e02aab, L-2 fixed, L-1/L-3
  recorded (D017). Slither triaged (docs/review/slither-rebase.md, nothing new to fix). Throughput study on the Checks
  board 12/12 (sim/results/throughput.md). Founder review, audit scope and a sealed audit prompt written.
- Rehearsal found a bug (fixed in 186c363): the shown live bid could exceed the 120%-of-schedule purchase cap, so a
  holder taking it was refused; `liveBid` now stops at the cap. Also fixed: the rehearsal script's own bugs (the
  postflight script did not load the desk and council; a bulk rename had broken its `migrateApes` call).
- **Candidate evidence (69ead29; contracts as 186c363).** Forced clean via-IR build 35 min; sizes under EIP-170:
  pool owner 24,069 B (507 B headroom), game 22,392, vault 13,901, token 10,959, hook 7,497, desk 7,193,
  MigrationAuthority 4,862, Sunset 2,387. `forge test --threads 2 --no-match-path 'test/scenario/Throughput.t.sol'`
  on a local anvil fork at 26,337,000: 283/283. Throughput study 12/12 (sim/results/throughput.md). Keeper unit 9/9;
  site typecheck and build pass. Rehearsal end to end on 186c363 (`script/rehearse-anvil.sh`, chain 31337): deploy and
  postflight, FWA relay and pool, market at the fixed tick, 11.2 ETH of opening-hour fees, a real 80-Check sold at the
  bid, activation with 160 prizes, router and FWA draws, board change, two more Checks bought, fee overflow and a
  buyback, postflight again after play, keeper pay 1.10-1.31x real gas, the fee recipient and the migration each
  through the council's 7-day timelock then 72 hours (owner and strangers refused), settlement refused before
  retirement (NotSettled), 3 Checks and the capital handed to the successor exactly. Black formation from 64 real
  singles 8,350,399 gas.

## Next executable action
1. `rc3` candidate: 69ead29 (tagging is the owner's call: rc1 and rc2 were pushed by the owner). Next work only on
   review feedback or an audit's findings.
2. Before any launch: the gates in docs/FOUNDER_REVIEW.md (name, council keys, legal review, human audit, FWA V2
   creation open on the day).

## History before the rebase

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
Approved 2026-10-30: D001, D003, D005, D006, D007, D009 (fee and tick placeholders). Approved 2026-11-03: D012, D013,
D014, D015 (closes D002, D008, D011; supersedes D004, D010 and part of D009). Still owed before deployment: the
modelled coin-market launch values (D013), name and ticker, council and guardian keys, legal review.

## Continuity protocol
After each meaningful increment, update this file with phase, completed work, exact commands and test outcomes, risks,
next action, and relevant commit. Resume from this file in each new agent session.
