# Audit scope

Not audited. Not deployed. **Frozen candidate: local tag `rc1`, commit 0aeea0e, branch `dev`.** Verification at
that commit: docs/receipts/rc1-verification.md.

## In scope (1,569 lines of Solidity)

| File | Lines | Role |
| --- | --- | --- |
| src/core/Engine.sol | 654 | UUPS custody and lifecycle: listing, decay, composition, buyouts, standing bid, Shape restock, surplus release, migration, roles |
| src/fwa/FwaV2Controller.sol | 180 | Immutable owner of one FWA V2 pool; O(1) survival derivation (C010) |
| src/venue/VenueHook.sol | 146 | Uniswap v4 hook: flat ETH fee to acquisitions |
| src/venue/VenueLiquidity.sol | 130 | Locks the whole coin supply as single-sided v4 liquidity |
| src/treasury/Burner.sol | 88 | Ownerless capped buy-and-burn of released surplus |
| src/periphery/FwaFeeBuyer.sol | 58 | Buys FWA's pool-creation fee with ETH (deployment helper) |
| src/token/Coin.sol | 37 | Fixed-supply ERC20 with burnFrom |
| src/interfaces/*.sol | 276 | Interfaces to FWA, Checks and controllers |
| script/DeploySystem.sol, script/LaunchConfig.sol | — | The single deployment routine and postflight; launch values |

Out of scope: keeper/ (untrusted, permissionless operator), site/ (static UI), sim/ (model), test/.

## Pinned dependencies

| Dependency | Version | Trust |
| --- | --- | --- |
| OpenZeppelin Contracts | v5.1.0 | TimelockController, UUPSUpgradeable, ERC1967Proxy, Initializable |
| solady | v0.1.26 | ERC20, SafeTransferLib, ReentrancyGuard |
| Uniswap v4-core / v4-periphery | 59d3ecf / 60cd938 | PoolManager (mainnet 0x0000…8A90), BaseHook, HookMiner, LiquidityAmounts |
| FWA V2 factory / clone / VRF service | mainnet, runtime hashes pinned in test/fork/Pins.t.sol | holds listed NFTs and player funds; factory owner controls edge, cooldown, global switches |
| Checks Originals, Editions, Shapes | mainnet, hashes pinned | canonical composition, migration, Shape backing |
| Compiler | solc 0.8.28, via_ir, optimizer 200, evm cancun | |

## Trust model and invariants to check

docs/THREAT_MODEL.md lists actors, powers, attack paths and residual trust. Properties the tests assert and an audit
should try to break:
1. The operator can only halt; no path for the operator, guardian or keepers to move NFTs or ETH to themselves.
2. Every upgrade, controller change, schedule or parameter change needs a council proposal and 7 days.
3. Survival equals prize allocations while listed (listed − withdrawn − FWA `activeListingCount`); nothing else moves it.
4. No maintenance, sale or migration while an FWA draw is unsettled.
5. `address(engine).balance >= acquisitionBudget` always; bids spend only the budget, within a weekly cap.
6. Coin-paid actions burn exactly once and never on failure; coin supply only falls.
7. Venue fees and released surplus reach only the engine's budget and the burner.

## Known limitations (by design, disclosed)

- A council majority can upgrade the engine to anything after 7 days if the guardian does not cancel.
- Prices lag the market by at least the timelock delay (D003); coin buyouts launch disabled (D006).
- Buy-and-burn has no oracle: a sandwich can skim part of one capped chunk per interval (D010).
- The weekly bid cap is epoch-aligned (up to 2× across a boundary), bounded by the budget.
- Keepers are unpaid. NFTs sent to the engine directly are quarantined (no sweep, and keepers do not see them).
- Opening fee curve against launch snipers is not implemented (D009).
- The venue fee (1%) and opening tick (161,200) in `LaunchConfig` are placeholders the founder will finalise before
  deployment; both are immutable once deployed. Compose coin burns, coin buyout prices (0, disabled), bid cap and
  burner values are timelock-settable placeholders.
- Approving a burner trusts the council's check that `Burner.venue()` is the canonical venue.

## Reproducing the evidence

```
git submodule update --init --recursive
forge build
forge test --match-path 'test/fork/*.t.sol'          # mainnet fork at block 26,302,000 via MAINNET_RPC_URL
forge test --match-path test/unit/Decay.t.sol
FOUNDRY_INVARIANT_FAIL_ON_REVERT=true FOUNDRY_INVARIANT_RUNS=16 FOUNDRY_INVARIANT_DEPTH=60 \
  forge test --match-path test/fork/Invariant.t.sol
python3 sim/model.py
```

Prior reviews (independent model-based reviews, not audits): docs/review/phase2-security-review.md,
docs/review/phase4-security-review.md, docs/review/venue-burner-deploy-review.md, docs/review/rc-repairs-review.md.
Static analysis: docs/review/slither-triage.md.
