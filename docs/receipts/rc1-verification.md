# Release candidate rc1: verification record

Candidate: local tag `rc1`, commit 0aeea0e, branch `dev`. Not pushed, not deployed, not audited.
Toolchain: forge 1.8.1, solc 0.8.28 (via_ir, optimizer 200, evm cancun), node v22.19.0, slither (local install).
Fork: Ethereum mainnet at block 26,302,000 through `https://mainnet.gateway.tenderly.co`. Date: 2026-10-30.
Each broad check ran once on the frozen tree.

| Check | Command | Exit | Result |
| --- | --- | --- | --- |
| Full suite | `CANDIDATE_RUN=1 forge test` | 0 | 55 passed, 0 failed, 12 suites (fork files, Decay fuzz 2 x 256 runs, invariants at the default profile: 32 runs x 50 depth, 1,600 calls, 0 reverts) |
| Strict invariants | `CANDIDATE_RUN=1 FOUNDRY_INVARIANT_FAIL_ON_REVERT=true FOUNDRY_INVARIANT_RUNS=32 FOUNDRY_INVARIANT_DEPTH=100 forge test --match-path test/fork/Invariant.t.sol -vv` | 0 | 4/4 hold; 3,200 calls, 0 handler reverts; every handler entry point called 305-336 times |
| Contract sizes | `forge build --sizes` | 0 | Engine 21,725 bytes runtime (EIP-170 limit 24,576); Burner 2,175 |
| Static analysis | `slither . --filter-paths "lib/\|external/\|test/\|script/" --exclude-informational --exclude-optimization` | 0 | 92 results, same detectors and counts as triaged in docs/review/slither-triage.md; no change required |
| Deploy script (simulation) | `COUNCIL=0x…c001 GUARDIAN=0x…c002 OPERATOR=0x…c003 COIN_NAME="Simulation Coin" COIN_SYMBOL=SIMTEST forge script script/Deploy.s.sol --fork-url https://mainnet.gateway.tenderly.co --fork-block-number 26302000 --sender 0x…d001` | 0 | Postflight passed. No `--broadcast`; nothing sent |
| Local rehearsal | anvil on port 8571 (verified free; node verified at block 26,302,000, chain 1, started by this session and stopped after), `forge script script/Rehearse.s.sol --rpc-url http://127.0.0.1:8571 --broadcast --unlocked --sender <anvil #0>` | 0 | Deploy, FWA pool open, budget funded, postflight, guardian resume: all succeeded on the local node |
| Keeper | `node --test keeper/test/*.test.mjs` | 0 | 7/7 |
| Site | `npx tsc --noEmit`; `npm run build` (in site/) | 0, 0 | Typecheck clean; static export of 6 routes |

## Limits

- Model-based reviews and Slither, not a human audit.
- In the strict campaign, success counts were printed only for the final run (draw 14, reprice 7, compose 1,
  buyEth 7, buyCoin 4, sell 8, relist 1, restock 3). Composition is mostly exercised by the fork tests, not by the
  invariant search.
- VRF words are delivered by impersonating the coordinator; real Chainlink timing and gas dynamics are untested.
- Wallet-connected site writes and most keeper jobs were not run live (contract paths are fork-tested).
- `NextGenControllerMock` in Migration.t.sol is a labelled mock of a future FWA version, not evidence about one.
- Launch values include founder-accepted placeholders (venue fee 1%, opening tick 161,200; docs/FOUNDER_REVIEW.md).
