# Release candidate rc2: verification record

Candidate: local tag `rc2`, commit 6b00eed, branch `dev`: rc1 plus the fixes for the rc1 audit (D011). Not pushed,
not deployed, not re-audited.
Toolchain: forge 1.8.1, solc 0.8.28 (via_ir, optimizer 200, evm cancun), slither (local install).
Fork: Ethereum mainnet at block 26,302,000 through `https://mainnet.gateway.tenderly.co`. Date: 2026-10-30.
Each broad check ran once on the frozen tree.

| Check | Command | Exit | Result |
| --- | --- | --- | --- |
| Full suite | `CANDIDATE_RUN=1 forge test` | 0 | 60 passed, 0 failed, 12 suites (adds 5 audit-fix tests to rc1's 55) |
| Strict invariants | `CANDIDATE_RUN=1 FOUNDRY_INVARIANT_FAIL_ON_REVERT=true FOUNDRY_INVARIANT_RUNS=32 FOUNDRY_INVARIANT_DEPTH=100 forge test --match-path test/fork/Invariant.t.sol -vv` | 0 | 4/4 hold; 3,200 calls, 0 handler reverts; every handler entry point called 284-351 times |
| Contract sizes | `forge build --sizes` | 0 | Engine 21,725 bytes runtime (unchanged); FwaV2Controller 6,612; VenueLiquidity 4,915; Burner 2,175; FwaFeeBuyer 1,882 |
| Static analysis | `slither . --filter-paths "lib/\|external/\|test/\|script/" --exclude-informational --exclude-optimization` | 255 (findings reported) | 92 results in the same 12 detector classes triaged in docs/review/slither-triage.md; none new in the changed code |
| Deploy script (simulation) | `COUNCIL=0x…c001 GUARDIAN=0x…c002 OPERATOR=0x…c003 COIN_NAME="Simulation Coin" COIN_SYMBOL=SIMTEST forge script script/Deploy.s.sol --fork-url https://mainnet.gateway.tenderly.co --fork-block-number 26302000 --sender 0x…d001` | 0 | Postflight passed, including the new coin-name and venue-timelock checks. No `--broadcast`; nothing sent |
| Local rehearsal | anvil on port 8571 (verified free; PID 38200 started by this session, block 26,302,000, chain 1; stopped after, port verified free), `forge script script/Rehearse.s.sol --rpc-url http://127.0.0.1:8571 --broadcast --unlocked --sender <anvil #0>` | 0 | Deploy, FWA pool open with the purchase gate, budget funded, postflight, guardian resume: all succeeded on the local node |

Not rerun: keeper (7/7 at rc1) and site (typecheck and build at rc1). Neither uses an ABI this candidate changed.

## Audit reproductions against the fixes

The rc1 audit's `AuditFork.t.sol` was copied into the tree temporarily, given a non-placeholder coin name, run with
`forge test --match-path test/audit/AuditFork.t.sol`, and removed (not committed). 18 of its exclusion tests still
pass. Its finding tests now fail for the intended reason:
- the three H2 stranding tests revert with FWA's `PurchaseNotAllowed()` (0x24e6a72a);
- `testCouncilCannotLaunchIfDeployerWithholds` fails because the timelock launch succeeds;
- `testPrefundedFeeBuyerCanBeDrainedByCaller` fails because the forced 1 ETH stays in the helper;
- the burner sandwich tests revert with `ChunkTooLarge()` at their 10 ETH chunk and zero interval;
- `testProductionWiringCodeHashes` fails because the coin name was changed for the run.

## Limits

- Model-based fixes and focused fork tests; no independent re-audit of rc2.
- The H1 bound rests on the venue fee being charged in ETH on both legs and on the pool never trading above its
  opening price. A sandwich around a burn was measured unprofitable for front-runs from 0.001 to 400 ETH on a fresh
  pool and after 200 ETH of prior buys. It is not a proof for every pool state or for future hook code.
- The H2 gate refuses five known contracts. A player who names any other address that cannot use an NFT loses only
  their own prize.
- VRF words are delivered by impersonating the coordinator, as at rc1.
- Launch values remain founder-accepted placeholders (docs/FOUNDER_REVIEW.md).
