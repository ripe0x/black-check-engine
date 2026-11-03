# Independent security review: scope and package

Prepared for an external auditor. **No independent audit has been performed.** Nothing has been deployed to any live
network, no real funds have been spent, and nothing has been published. A separate **legal review of the paid,
chance-based game, the coin and the naming** is a launch requirement (section 9).

## 1. Review target

| | |
| --- | --- |
| Repository | `ripe0x/collection-games` (private), branch `claude/focused-edison-5n720n` |
| Review commit | the branch head at the time of hand-off (record the hash in the engagement letter) |
| Earlier review | Three agent audit rounds (not an independent audit firm): round 1 on `004c0a4` (`audit/REPORT.md`), round 2 on `f44ab9f` (`audit/round2/`), round 3 on `6d9f949` (partial). Their findings were fixed in D66, D67 and D68 or accepted with reasons (docs/SECURITY.md "Fresh-discovery audit"); round 3 left 15 Game/PoolOwner reentrancy detector paths and dynamic callback variants open. The independent audit remains a launch requirement |
| First-party code in scope | `src/` and Draw Packs: `lib/shape-packs` (ripe0x/shape-packs, branch `draw-packs`) at **3a463f7**, files `src/ShapePacks.sol`, `src/ShapePackRenderer.sol` (+ their imports), used unmodified and built through `src/vendor/PacksBuild.sol`. Draw Packs is the project's own code, reviewed as such, not a third-party dependency |
| Compiler | solc 0.8.28, EVM `cancun`, optimizer 200 runs, `via_ir = false`, `bytecode_hash = none`, no CBOR metadata; Draw Packs compiled via-IR with 20 runs (`packs` profile in `foundry.toml`), as in its own repository |
| Toolchain | Foundry 1.5.1 (`forge`, `anvil`), Node 22 (keeper and site) |
| Configuration reviewed | `script/LaunchConfig.sol` (BAYC launch) and `script/DeploySystem.sol` (deploy order, wiring, postflight) |

**Final pre-audit scope (D54-D57).** One Ape-specific coin (ApeBall, APEBALL; D69) and its game; no farming, airdrop or
token reserve (100% of the supply in protocol liquidity); the multi-game deploy path is removed. D57 (owner's direction,
before the audit) simplified administration: one owner in the `Admin` contract (two-step transfer, renounce) replaces
the Safe and its roles, and acts at once within broad bounds; the vault's standing bid replaced `RisingBidStrategy`;
upkeep runs through the DrawRouter after a player's draw.

**D63 (owner's decisions, before the audit): the simplification pass.** Most of the code around the game was plumbing
between contracts; it was removed and the scope grew around `CollectionGame` instead (docs/IMPLEMENTOR_DECISIONS.md
D63):

- Removed: `KeeperFund`, `RevenueRouter`, `MilestoneReserve`, the board and pricing policy modules
  (`src/modules/Policies.sol`), `script/SetBoard.s.sol`, the owner's separate `game.retire()`, the pool owner's
  retirement auction and `beginMigration`, the vault's continuity bucket and owner-settable adapter, the DrawRouter's
  KeeperFund call.
- In the game: keeper pay (gas at the transaction's price, capped, plus a flat fee, within an allowance earned from
  captures), the surplus split (a share to the vault while it is short of one Ape, the rest to the burner), the board
  pattern and size as owner settings (`setPattern`, lazy; `setBoardSize`, grow only).
- In the burner: the milestone reserve (`release` on a verified Ape win, `releaseRetired`).
- New: `Sunset`, the built-in end of the game (no owner; every Ape in a 30-day Dutch auction, the price to the burner),
  triggered at once by the owner (`MigrationAuthority.sunset`) and final.
- Changed: a migration needs 72 hours' notice (was 24) and pins the successor's code hash; the trading-fee recipient
  changes only through the MigrationAuthority, on its own 72-hour notice with the code pinned; the vault's Seaport
  adapter is fixed at wiring.

**D64 (owner's go, before the audit): the flywheel build, items A-D of docs/review/FLYWHEEL_REVIEW.md**
(docs/IMPLEMENTOR_DECISIONS.md D64; E, F, G and the site item are not built):

- Launch values (`script/LaunchConfig.sol`): fees 5% / 5%, the 50-row board, markup 10%, exposure target 20%,
  `maxInFlight` 10 (D82; 4 in D64, 3 in D65), minimum live rows 70%, reserve 0.5 ETH (D79), continuity share 35%; the first bid threshold
  is 100% of the reference price (new vault constructor argument `firstThresholdBps`).
- Hook: the block-based launch schedule is replaced by an immutable, time-based opening curve on buys and sells
  (69%, one point less a minute, to the ordinary fee; `launchedAt`, `curveBps`, `currentFeeBps`, `openingFee`); 69% is
  also the hook's clamp. Exact-output buys pay the fee on the gross ETH (`net × f / (1 − f)`).
- Burner: 75% of the game's buyback ETH locked; tiered releases verified from FWA (`Tiers`: a big prize 15%, an Ape
  exit 60%, a second exit within 24 hours the rest; `releaseBps`, `setTiers`); a play-keyed cadence (`Cadence`,
  `nextSlice`, `drawsSinceLastRun`, `setCadence`) inside hard bounds (constants: slice ≤ 1 ETH, spacing 10 minutes to
  30 days, impact ≤ 5%, deviation ≤ 3%, backlog ≤ 10%); a release's first slice may run at once. `setParams` is gone.
- Vault: the fee overflow (fees counted as they arrive, `unsplitFees`; at the next `sweep` `overflowBps` of them to the
  burner; `pendingOverflow`, `overflowOut`). D65 replaced its trigger and removed D64's play meter (see below).
- Game: asks the burner to `release` a Shape or Pack capture listed at `bigPrizeWei` or more, as well as every Ape win.

**D65 (owner's go): the fee-overflow trigger and K** (docs/IMPLEMENTOR_DECISIONS.md D65):

- Vault: the play meter is gone (no `meteredStep`, `drawsSinceSweep`, `lastSweepSeq`); above the threshold a sweep
  forwards at most `maxSweepWei` per `minBlocksBetweenSweeps` again (`slowSweepWei` above the ceiling). `FlowParams`,
  `setFlowParams` and `flowParams()` are replaced by one setting, `overflowBps` (`setOverflowBps`, 0-100%,
  `OverflowBpsSet`; constructor `overflowBps_`). The overflow now runs while the live bid is at its fill target (the
  threshold, or the ceiling or `maxPrice` when lower), capped at what the acquisition budget holds beyond the bid and
  one more Ape at the funding reference (`referencePrice`, D83); it no longer reads custody or listing counts (`overflowMinListed` is gone).
- Launch values: `maxInFlight` 3 (was 4), so the purchase gate keeps 3 − 1 + 5 = 7 listings of headroom. (D82 later raised it to 10, FWA's own per-pool limit: 10 − 1 + 5 = 14 listings of headroom.)

**Size guard.** `CollectionGame` is 24,182 bytes of runtime code, 394 bytes under EIP-170. It is **no longer frozen**:
D63 changed it (24,409 → 23,384 B with keeper pay, the surplus split and the pattern moved in, and board rebinding
removed), D64 (the big-prize release call) brought it to 23,598 B, D68 (the owed-cost recount) to 24,053 B, and D77 (`upkeep`) to 24,182 B. `test/unit/Sizes.t.sol` pins its current size
(`test_gameLedgerSizePinned`) so that any growth is deliberate and reviewed, and checks every contract against EIP-170 (`test_everyContractWithinEip170`).

## 2. Contracts in scope

Runtime sizes from `forge build --sizes`: on the D64 code for `CollectionGame`, `FundingVault`, `CollectionBurner` and
`CollectionHook` (the contracts D64 changed); the others from the D63 build (their source is unchanged by D64).

| Contract | File | Runtime size | Role | Holds |
| --- | --- | --- | --- | --- |
| `CollectionGame` | src/game/CollectionGame.sol (1061 lines) | 24,536 B | ledger: books every FWA request once, prices and pays for replacement prizes (markup and keeper allowance rate 0-100%), the board pattern (`setPattern`, applied to each row when next listed; owed rows recosted), owed rows and board growth (on demand from `rowsShort`, or `setBoardSize`, grow only), admission, activation, keeper pay (`quoteTip`, `keeperAllowance`), distributions (vault share capped at its shortfall, the rest to the burner), the burner `release` call for an Ape win or a big prize (listed at `bigPrizeWei` or more), retirement (`retire` from the MigrationAuthority only; `retireStep`) | game ETH |
| `CollectionPoolOwner` | src/core/CollectionPoolOwner.sol (897) | 22,541 B | permanent FWA pool owner and purchase operator (`canPurchase`, 50% exposure ceiling), mints prizes (Shapes, Draw Packs) and lists them, collection-NFT custody (states None, Custody, Listed, Won, Migrated; source bought or donated); lists every NFT held in batches, shared gameplay credit and one decay rule (gameplay, plus the decay clock: D78, off at launch), the exposure target and `rowsShort`, `settleListing`; retirement withdrawal and the hand-over of NFTs (`migrateApe`, MigrationAuthority only) | NFTs |
| `FundingVault` | src/core/FundingVault.sol (619) | 13,794 B | trading fees, contributions, the game's surplus share, NFT acquisitions (the live bid: the first threshold `firstThresholdBps` of the reference, metered sweeps of at most `maxSweepWei` per cooldown, threshold reset to 75% of the funding reference, which follows each clearing price but falls by at most `maxDropBps` and never below the Ape floor, D83, holder-named price, marketplace fills through the adapter fixed at wiring at the listing's price plus a finder fee, optional `maxPrice` (none at launch)), the fee overflow to the burner (`unsplitFees`, `pendingOverflow`, split at `sweep`, `overflowBps`), game capital (`fundGame`, `shortfall`), capital hand-over once the game has retired (`migrateCapital`, MigrationAuthority only). One balance | ETH |
| `CollectionHook` | src/token/CollectionHook.sol (241) | 7,396 B | Uniswap v4 hook: fees (each ≤ 10%), the immutable opening curve (69% on buys and sells, one point less a minute, from the single initialisation), exact-output buys charged on the gross, one exempt sender; fee recipient (the vault at launch) changed only by the MigrationAuthority (`NotMigrator`) | — |
| `CollectionToken` | src/token/CollectionToken.sol (315) | 10,038 B | fixed-supply ERC-20 | — |
| `ProtocolLiquidity` | src/token/ProtocolLiquidity.sol (116) | 5,464 B | single-sided launch position, no removal | v4 position |
| `CollectionBurner` | src/treasury/CollectionBurner.sol (397) | 11,656 B | buy-and-burn in slices with impact and deviation limits; the cadence follows FWA draws since the last slice (`nextSlice`; owner `setCadence` within constant hard bounds: slice ≤ 1 ETH, spacing 10 minutes to 30 days, impact ≤ 5%, deviation ≤ 3%, backlog ≤ 10%); the milestone reserve (`milestoneBps` of the game's ETH locked, released in tiers by `release` on a delivered win verified from FWA: a big prize, an Ape exit, a second exit within the window; owner `setTiers`; all of it by `releaseRetired`; milestone spent first, a release's first slice at once); keeper paid at the game's `quoteTip`, ≤ 5% of a slice | ETH |
| `MigrationAuthority` | src/migration/MigrationAuthority.sol (213) | 4,677 B | the only way the game ends or moves and the only way trading fees change destination: `propose` / `execute` (72 h, successor a contract, code hash pinned), `sunset` (owner, at once and final, into `Sunset`), `proposeFeeRecipient` / `executeFeeRecipient` (72 h, code pinned; only before any migration has started), then batched `migrateApes` and `migrateCapital` once V1 has retired; holds nothing | — |
| `Sunset` | src/migration/Sunset.sol (100) | 2,458 B | the built-in successor, no owner: Dutch auction of each Ape from 150% to 25% of its recorded cost over 30 days (`start`, `buy`), the price to the burner in the same call and any excess back to the buyer; `flush` (which also starts the clock if nobody has) sends everything else it holds (capital, fees) to the burner | Apes, ETH in transit |
| `Admin` | src/core/Admin.sol (71) | 1,283 B | the one owner of every contract: two-step transfer, renounce (D57); the protected collections, recorded once at deployment (D62) | — |
| `Governed` | src/core/Governed.sol (70) | — | `onlyOwner` through one shared `_checkOwner` reading `admin.owner()`; one-shot wiring; the owner's `sweepNFT` of unrelated ERC-721s (D62) | stray NFTs |
| `SeaportAdapter` | src/periphery/SeaportAdapter.sol (142) | 3,613 B | the vault's marketplace route, fixed at wiring (Seaport 1.6 at launch) | transient |
| `LayerTap` | src/periphery/LayerTap.sol | | collects the hook's $LAYER share and forwards it to artcoins' burn router (D90) | ETH in transit |
| `FwaFeeRelay`, `FwaFeeBuyer` | src/periphery/FwaFeeRoutes.sol (114) | | deploy-time FWA fee routes | stateless |
| `Lens` | src/periphery/Lens.sol (280) | 10,460 B | read-only aggregation | — |
| `DrawRouter` | src/periphery/DrawRouter.sol (216) | 4,525 B | player entry point: settle waiting draws, buy for the caller, then run `game.upkeep` (unpaid, D77) within the caller's gas budget and the vault's `sweep`; `measureUpkeep` for the site; `redeemAndDraw` redeems the caller's won Shapes and Packs (caller's approval) and draws with the ETH (D75); returns all change to the caller and the sweep reward to the vault (D76, D77); no owner, no state (D53, D59, D60) | transient (one call) |
| `ShapePacks`, `ShapePackRenderer` | lib/shape-packs/src (788, 351), built from src/vendor/PacksBuild.sol | 17,715 / 9,301 B | Draw Packs instance (second custody contract); first-party | Shapes |

Out of scope (trusted, pinned, verified against mainnet at block 26,284,000; see docs/external/fwa-v2.md and
docs/IMPLEMENTOR_DECISIONS.md "Live verification"): FWA V2 factory `0xF5A3…300c` and clone implementation `0xEaa4…eb31`
(including its VRF service), Shapes `0x6fe9…6faf0`, Uniswap v4 PoolManager, Seaport 1.6, BAYC, solady. The keeper bot (`keeper/`) and the site (`site/`) are off-chain and hold no keys or
funds; their review is optional.

## 3. How to build and test

```
git submodule update --init --recursive
forge build --sizes
anvil --fork-url <archive mainnet RPC> --fork-block-number 26284000 --port 8545    # separate terminal
MAINNET_RPC_URL=http://127.0.0.1:8545 forge test --no-match-path test/scenario/Throughput.t.sol --no-match-contract Gas
MAINNET_RPC_URL=http://127.0.0.1:8545 forge test --match-contract '^Gas' --isolate         # gas receipts
MAINNET_RPC_URL=http://127.0.0.1:8545 forge test --match-path test/scenario/Throughput.t.sol  # ~1 h
FORK_URL=http://127.0.0.1:8545 bash script/rehearse-anvil.sh                              # deploy-to-play rehearsal
```

The recorded run in docs/receipts/test-run.txt is from the D63 code (public RPC timeouts passed on rerun;
docs/IMPLEMENTOR_DECISIONS.md D63) and predates D64's changes and tests. Re-record the receipt on the hand-off commit.

Tests added or rewritten for D64: the opening curve and the exact-output basis (`test/fork/Market.t.sol`:
`test_openingCurveOnBuysThenOrdinary`, `test_openingCurveOnSells`,
`test_exactOutputBuyPaysFeeOfTheGrossAndExactOutputSellIsUnsupported`, `test_curveIsFixedAndOnlyAfterLaunch`,
`test_feeGovernanceByTheOwnerAndCapped`); the fee overflow (`FlowForkTest` in `test/fork/Bid.t.sol`, rewritten for
D65: `test_noOverflowWhileTheBidCanUseTheEth`, `test_noOverflowBeforeActivation`, `test_feesOverflowBeyondTheNextApe`, `test_overflowStopsAtTheNextApe`,
`test_overflowShareIsTheOwners`; its sweep gas, `FlowGasForkTest`); the burner's tiers and hard bounds
(`test/unit/Units.t.sol`: `test_burnerHardBounds`, `test_milestoneTiersOnlyOnDeliveredWinsOnce`,
`test_burnerSplitsTheGamesSurplus`); the cadence and release slices (`test/fork/Revenue.t.sol`:
`test_ongoingBuybacksFollowPlay`, `test_milestoneBuybackExecutesInSlicesAndTwoWinsAccountedApart`); the big-prize
release at booking (`test/fork/Collection.t.sol`: `test_smallPrizeNeverReleasesBigPrizeReleasesItsTier`); and
`invariant_vaultConservation`. `test_tooLittleGasNeverSkipsWork` (`test/fork/KeeperPay.t.sol`) stays: the game's new
`release` call is an isolated step under the same `_gasCheck`. Unit
tests that need no fork: `forge test --match-path 'test/unit/*'`. Public RPCs rate-limit archive reads; a local anvil
fork avoids it.

## 4. Architecture and trust model (read first)

docs/ARCHITECTURE.md (contracts, asset flows, every outflow's single destination), docs/SPEC.md (exact rules),
docs/SECURITY.md (the sunset guarantee, assets, invariants, administration and each owner power's worst case,
migration and the sunset, Draw Packs boundary review, the board pattern, residual risks), docs/ADMIN.md,
docs/MIGRATION.md, docs/IMPLEMENTOR_DECISIONS.md (every decision with its rationale; D57-D65 are the most recent),
docs/review/FLYWHEEL_REVIEW.md (the analysis behind D64).

Administration: one owner, recorded in `Admin`, administers every contract and acts at once on parameters (D57): the
economics, the board pattern and size, keeper pay, the surplus split and milestone share, the bid, the fee overflow
share, the buyback cadence and milestone tiers (within the burner's hard bounds; timing only), pause.
The opening fee curve and the burner's hard bounds are constants. It can end the game at once and for good into the Sunset, whose only destination is buybacks. After a public
72-hour notice, with the destination's code pinned, it can migrate the Apes and the vault's ETH to a successor contract
of its choice, or, before any migration has started, point future trading fees at a contract of its choice. No administrative function withdraws prizes in play, game
cash, vault ETH or committed buyback ETH directly, retires the game or redirects fees at the hook; custody, capital and
fee functions answer only to the game, the vault and the MigrationAuthority. Renouncing freezes every parameter and
removes the migration and the sunset. The deployer loses every power at the end of the deploy script (checked by the
postflight). Nobody can mint coins or remove liquidity.

## 5. Properties to verify

Tested (test/invariant/Invariants.t.sol and the fork suites); the auditor is asked to confirm or break them:

1. Coin supply never increases; all supply is in protocol liquidity or launched.
2. Books reconcile to the wei: game cash + FWA owner proceeds = capital in + revenue − inventory − prize expense −
   keeper pay − distributed − returned (`assertBooks`); distributions never exceed realised profit
   (`profit = revenue − prizeExpense − keeperPaid`).
3. Booked revenue never exceeds what FWA paid (booking at the highest admissible edge, true-up to collected proceeds).
4. Every distribution goes only to the vault (`continuityShareBps`, at most its `shortfall`) or the burner; once the
   vault can buy an Ape at the funding reference, all of it goes to the burner.
5. The milestone reserve is released only after a delivered win (FWA `Settled` to a purchaser other than the pool
   owner): an Ape exit (`firstExitBps`; a second exit within `exitWindow` of the last, the rest) or a big prize listed
   at `bigPrizeWei` or more (`bigPrizeBps`); at most once per listing; or, all of it, once the game has retired. A
   Shape or Pack listed below `bigPrizeWei`, a refunded or pending delivery and a withdrawn listing never release.
6. Every collection NFT is in exactly one place: custody, the FWA pool, a winner, the migration successor or the Sunset
   contract (then its auction buyer).
7. Collection exposure never exceeds the target after a listing or reprice, and never exceeds the 50% ceiling after
   every request the purchase gate admitted has settled (no keeper needed; batches included).
8. A listed collection NFT's notional never rises.
9. Nothing reaches the owner through play or an outsider's call (the invariant handler does not exercise the owner's
   parameter powers; their reach is in docs/SECURITY.md); the burner keeps no coins; the Sunset contract holds nothing
   while the game runs.
10. The FWA pool owner never changes.
11. A won Shape or Draw Pack belongs to its winner; only its owner can open, redeem or unseal a Pack.
12. A pattern change touches no custody and no listing; each row takes the new backing when next listed; owed rows are
    recosted at once (`replacementsOwed`); the books reconcile throughout. `setBoardSize` only grows, by ≤ 50 rows, and
    only when the vault covers the rows and the game's need.
13. Keeper pay: a call with no work reverts (`NoWork`); a payment is at most
    `(gasUsed + gasOverhead) × min(tx.gasprice, maxGasPrice) + flatFee`, always within `keeperAvailable()`
    (retirement included) and never out of cash owed to replacements while the game runs; a step that fails with less
    than 1/8 of its starting gas left reverts the whole call (`OutOfGas`), so a low gas limit cannot skip work and be
    paid; funding the game counts as work only when it covers the whole need and the need was at least `rowCost`.
14. Burner conservation: reserve in + ongoing in = reserve + ongoing + milestone + spent on the coin + keeper
    reimbursement (≤ 5% per slice); its balance equals the reserve and its buckets. No slice exceeds 1 ETH, runs
    before `nextSlice().runAt` (at least 10 minutes after the last slice, except a release's first) or moves the price
    more than 5% (3% at launch); no owner setting passes these bounds (D64).
15. The DrawRouter keeps nothing between calls and grants nothing: every purchase it makes is for its caller, under the
    same purchase gate and FWA guards as a direct purchase; upkeep runs after the purchase; every wei left (change) is
    returned to the caller and the sweep reward to the vault; the game's `upkeep` pays nobody (D53, D59, D76, D77). `redeemAndDraw` moves only `msg.sender`'s own
    Shapes and Packs, only on the game's own contracts (`game.poolOwner()`), and redeems them in the same call (D75).
16. The Sunset contract: an Ape's price is `refCost × (15,000 − 12,500 × min(t, 30 days) / 30 days) / 10,000`, `t` from
    the first `start` (or `buy`, or `flush`) after the game retired; the price paid and everything flushed goes to the
    burner, an overpayment back to its buyer; nothing else leaves it.
17. No administrative call moves custody NFTs, prizes in play, game cash, vault ETH or committed buyback ETH directly,
    retires the game or sets the fee recipient; custody, capital and fee functions answer only to the game, the vault
    and the MigrationAuthority (D57, D63).
18. The live bid never exceeds `maxPrice` (when set) or the acquisition budget (the game's capital and growth need come
    first); it grows only by ETH actually swept (fast to the threshold, then at most `maxSweepWei` per
    `minBlocksBetweenSweeps`, and `slowSweepWei` above the ceiling); an acquisition subtracts what it paid and resets the threshold to `thresholdBps` of the
    funding reference (the reference follows the price paid but falls by at most `maxDropBps` and never below the Ape
    floor, D83); a direct sale pays the price the holder named (≤ the bid), a fill the listing's price plus the finder fee
    (together ≤ the bid) (D59).
19. A migration executes only after the owner's proposal, 72 hours and with the successor's code unchanged; a fee
    recipient changes only the same way; the sunset only into the immutable Sunset contract. Apes (records kept) and
    vault capital move only to the successor and only after V1 has retired; committed buyback ETH and player claims
    never move. Without an executed migration or the sunset nothing migrates, and fees go to the vault until a
    fee-recipient change executes; once a migration or the sunset has started no fee-recipient change can be proposed
    and fees follow the successor (D55, D57, D63).
20. The sunset cancels pending proposals, can follow a started migration for whatever has not moved, and is final: no
    proposal of either kind afterwards (`SunsetFinal`, `Started`).
21. Only the pending owner completes an ownership transfer; after `renounceOwnership` no `onlyOwner` function of any
    contract can be called (D57).
22. Vault conservation: balance + acquisition spend + finder fees + sweep rewards + game capital sent + migrated out +
    fee overflow = trading fees + contributions + surplus in + returned from the game (`invariant_vaultConservation`).
    The fee overflow goes only to the burner, only while the live bid is at its fill target (the activation threshold,
    or the ceiling or `maxPrice` when lower), and never out of the game's capital need, the board growth, the bid's ETH
    or one more Ape at the funding reference (`referencePrice`, D83) (D64, D65).
23. Every non-exempt swap pays `max(ordinary fee, curve)`, with the curve `max(0, 6,900 − 100 × minutes since the
    pool's initialisation)` bps, pro rata per second, never above 69%; exact-input and exact-output buys pay the same
    share of the gross ETH; exact-output sells revert; the curve cannot restart (D64).

## 6. Suggested focus (highest consequence first; 2, 3, 7, 8, 9, 12, 13 and 15 changed in D63; 2, 6, 8, 11, 12 and 16 in D64; 6, 12 and 16 in D65)

1. **`CollectionPoolOwner.canPurchase`** (FWA's purchase operator, called once per transaction inside a 100,000-gas
   staticcall, without the purchase count): its assumptions about FWA's ordering, the batch size read at pool
   creation, the running `exposureSum`, the Shape floor, the 50% ceiling, gas bounds (independent of the number of
   NFTs). Since D53 it no longer requires a collection NFT in the draw: confirm nothing in booking, exposure or decay
   assumed one is always present after activation.
1a. **Collection listings with many NFTs** (D59): `processCollection` (`_listBatch`, `_decayBatch`, the credit
   accumulator, `notionalOf`, the back-dated `creditStart` of a relisted NFT, `rowsShort` and its counting as work),
   `settleListing` (idempotent, permissionless: confirm it can only follow FWA's state), `_close` / `_listedIndex`,
   `withdrawCollection` batching, and the exposure arithmetic (`_termOf` rounding, `_fits` with `gateHeadroom`).
2. **Booking in `CollectionGame`** (`_advance`, `_see`, `_resolveOpen`, `_tryResolve`, `_bookCapture`, `_trueUp`): exactly
   once per request across delivery failures, refunds, expiries, quarantine and recovery; the lower-bound booking and
   true-up; per-listing frozen markup and allowance rate; `exposure()` bounded by the inventory (D48); the allowance
   credit per capture (a prize's `opsBps` of its cost; a collection capture's last `opsBps` of its base price); the
   burner `release` call on a collection win and, since D64, on a Shape or Pack capture whose listed price
   (`cost × (1 + markupBps)` frozen at listing) is at least `burner.bigPrizeWei()`: that the game's price matches the
   price FWA holds (the burner checks FWA's), and that a reverting or gas-starved `release` can neither block booking
   nor be skipped quietly (`_gasCheck`).
3. **Keeper pay and its work counting** (D63): `quoteTip` (`tx.gasprice` capped at `maxGasPrice`; overhead; flat fee
   ≤ 0.1 ETH), `_tip` (the `NoWork` revert, the allowance always, retirement included; cash owed to replacements excluded
   while running, any cash within the allowance during retirement), `_gasCheck` (after any isolated step fails with
   less than 1/8 of its starting gas left the whole call reverts `OutOfGas`; a deterministic failure still fails alone
   given enough gas; `test_tooLittleGasNeverSkipsWork`), and every place `work` is incremented in `sync` and
   `retireStep`. In particular the funding rule (counts only when `fundGame` covers the whole need and the need was at
   least `rowCost`), which closes a paid refill loop found in testing (keeper pay draws the reserve down, and refilling it must not earn the next call a
   fee); `activate()` drawing the opening refill itself and `ready()`'s `capitalNeed() <= vault.generalBalance()`.
   Look for any other state a paid call can create that the next call is paid to undo.
4. **The board pattern and growth** (D63): `setPattern` (each backing checked with `prizeCost`; the reserve re-checked
   through `_setSettings`; `replacementsOwed` recomputed over owed rows) and its lazy application in `_vacate` /
   `_restock` / `_grow` via `rowAt`; `setBoardSize` (grow only, ≤ 50 rows, refused while retiring, the vault's
   balance must cover the new rows plus `capitalNeed()`) and `_maybeGrow` / `rowCost` / `growthNeed`: that every row in
   play is either live or owed exactly once and that `replacementsOwed` always matches the owed rows' cost at the
   current pattern.
5. **Prize minting and custody**: `mintAndList` exact-payment check, `makeup` (fewest Shapes, exact backing),
   `createPackTo` / `_safeMint` callback into `onERC721Received` (operator and sender rules), `_cashOut` balance
   deltas on burn/redeem, `recoverShape`.
6. **The live bid and `FundingVault`** (D59, D64, D65): `sweep` (fast fill clamped to the threshold without a cooldown, metered
   forwards with the cooldown, the reward (gas plus the flat fee at `quoteTip`, capped at 0.01 ETH, D82) taken from the vault's general ETH or carved off the forward, the clamp to the budget and
   `maxPrice`), `liveBid`, `sellToProtocol` (holder-named price), `fillOrder` (finder fee, adapter custody postcondition,
   unspent ETH returned), `_book` (bid debit, funding-reference move floored by `maxDropBps` and the Ape floor, threshold reset, D83): confirm no sequence (funds arriving in one step, the
   budget falling below `bidBalance`, `fundGame` or a surplus share between sweeps, a purchase, a parameter or
   threshold change) lets an acquisition pay more than the live bid or touch the game's protected capital; then
   `fundGame`, `receiveSurplus` / `shortfall` and the budget during retirement (0). D64: the first threshold
   (`firstThresholdBps` of the reference) and the budget before activation; the **fee overflow** (`receive` counts
   `unsplitFees`, the one write added to the swap path; D65: `pendingOverflow` only once the game is active and while the live bid is at its fill
   target, capped at the budget less the bid and one more Ape at the funding reference (`referencePrice`, D83); `sweep` clears the count, sends the
   overflow to the immutable burner, then meters at most `maxSweepWei`; a sweep that only overflows returns 0 with no
   reward): confirm it never sends the game's capital need, the growth need, the bid's ETH or the next Ape, that the
   lazy accounting (the condition read at the sweep, not when a fee arrived) only moves fees between capital and
   buybacks, and what a caller gains by timing sweeps (e.g. just before or after an acquisition moves the funding reference and
   the threshold); and `invariant_vaultConservation`.
7. **The surplus split** (D63): `_pay` (the vault's share capped at `shortfall()`, the rest to the burner with
   `safeTransferETH`), run inside `payStep`'s `try`, and the burner's `receive` split (`milestoneBps` from the game
   only; everything else ongoing).
8. **Burner tiers, cadence and slices** (D63, D64): `releaseBps` / `qualifies` / `release` (anyone; FWA `Settled`,
   purchaser neither zero nor the pool owner, `released[listingId]` once; then the tier: one of the pool owner's
   collection listings releases `firstExitBps`, or all that is left within `exitWindow` of `lastExitAt`; any other
   listing releases `bigPrizeBps` when FWA's listed price is at least `bigPrizeWei`; `lastExitAt` and `exitReleases`
   move only for an exit; `lastRunAt` reset so the first slice may run at once, even when the reserve is empty),
   `releaseRetired` (after `game.retired()`), and that no small prize, refunded or pending delivery, withdrawal or
   migrated Ape can release; then the cadence state machine (`nextSlice`: milestone first at `maxSliceWei` every
   `minSpacing`; ongoing `baseSliceWei + perDrawWei × n + backlogBps` of the bucket, capped, spaced
   `idleSpacing × drawsToHalve / (drawsToHalve + n)`; `drawsSinceLastRun` from FWA's `lastIssuedSequence`, `lastRunSeq`
   updated after each slice), `setCadence` / `setTiers` bounds (the constants), the partial fill at the impact limit
   (`spent` < the slice), MEV around a release's announced first slice (deviation since the block opened plus impact),
   and the keeper reimbursement (`quoteTip`, capped at 5% of the slice and at the bucket).
9. **Retirement** (D63): `retire` (MigrationAuthority only), `retireStep` (settle, withdraw prizes and Apes, return to
   the vault; late settlements after `retired`), prizes stuck in FWA quarantine, keeper pay from any cash while
   retiring but never above the allowance left (so raised keeper parameters cannot reach the cash a sunset hands over;
   `test_retirementPayWithinTheAllowance`).
10. **Draw Packs** (first-party, unaudited): the boundaries listed in docs/SECURITY.md "Draw Packs".
11. **Hook and launch**: fee accounting and exemption; the opening curve (D64: `curveBps` from `launchedAt`, set once
    in `_beforeInitialize`; `currentFeeBps`; `openingFee`'s `secondsToBase` rounding; the 69% clamp) and the
    exact-output buy fee `net × f / (BPS − f)` taken in `afterSwap` from the pool's delta (that it equals `f` of the
    gross ETH and cannot be undercut by splitting, partial fills or a price limit); the exact-output sell revert; the
    transient-storage hand-off of the fee rate from `beforeSwap` to `afterSwap`; the single-sided launch that
    accepts no ETH (initialisation and liquidity in one `launch` call); `blockOpenPrice` used by the burner
    (same-block manipulation bounds); `setFeeRecipient` reachable only from the MigrationAuthority.
12. **DrawRouter** (D53, D59, D60, D63, D64, D65): `draw` calls `game.sync{gas: upkeepGas}` and `game.vault().sweep()`
    (250,000 gas) on a caller-supplied `game` (any address, each in a `try`), after checking the gas left covers the
    budget and `TAIL_GAS`, and then forwards its whole balance to the caller (`measureUpkeep` likewise): the gas
    accounting (63/64 rule, the up-front `UpkeepGas` check), reentrancy through FWA's refund, a hostile `pool` or
    `game`, the keeper pay and the sweep reward pushed into the router mid-call, the swallowed settlement and upkeep
    failures, `quote` called in a transaction (it settles for real, which anyone may do anyway), stray ETH. Since D64
    the vault's `sweep` may also send the fee overflow to the burner: `SWEEP_GAS` is 250,000; a metered sweep and an
    overflow sweep both stay well inside it (D65 code, isolated fork measurement `FlowGasForkTest`: 126,362 and 211,044 gas);
    confirm the margin, and that a failure there only defers the sweep to the next caller.
13. **MigrationAuthority, the fee-recipient notice and the migration hooks** (D55, D57, D63): the 72-hour delay
    (`propose` restarts it; `execute` checks it for a replacement proposal too), the code-hash pin (`successor.code` must
    be non-empty at proposal; `codehash` compared at execution, `CodeChanged`) for both the successor and the fee
    recipient; `proposeFeeRecipient` / `executeFeeRecipient` (game keeps running; refused with `Started` once a
    migration or the sunset has started); the first execution's sequence (`game.retire` once, then
    `hook.setFeeRecipient` on every execution, a pending fee-recipient proposal cancelled), `sunset` (instant, cancels
    both pending proposals, can follow a started migration, final: `propose` then reverts `SunsetFinal`;
    `test_sunsetIsFinal`); `_ready` (nothing moves before the game
    has retired); the pool owner's `migrateApe` (state updated before a plain `transferFrom`; refunds recovered later
    through `settleListing`) and the vault's `migrateCapital` (forced ETH, `bidBalance` reset); that these hooks answer
    only to the authority.
14. **Sunset auction math** (D63): `auctionPrice` (`refCost` read from the pool owner's `nfts`, the linear fall from
    15,000 to 2,500 bps over `AUCTION_DURATION`, rounding, before and after the clock starts), `start` (once, only after
    `retired`), `buy` (held check, `msg.value ≥ price`, exactly the price forced to the burner, the excess refunded to
    the buyer; `auctionProceeds` counts the price), `flush` (starts the clock if the game has retired and nobody has), and the burner's treatment of both as ongoing ETH. Also: Apes arriving after the clock has
    run (quarantine) and a donated Ape's `refCost`.
15. **`Admin` and `Governed`** (D57, D62): the two-step transfer (only `pendingOwner` accepts; address(0) cancels),
    renounce, and `Governed._checkOwner` (also rejects `msg.sender == address(0)`, so a renounced owner matches nobody);
    that every owner-only function uses it. `sweepNFT` (D62): that no call through it can move the collection, Shapes
    or Draw Packs, or act through a contract the governed contract owns or operates (the FWA pool, the v4
    PoolManager); that `Admin.protect` runs once, from the deployer, during wiring.
16. **Administration** (D57, D63, D64, D65): for each owner-callable function, confirm the worst case stated in docs/SECURITY.md
    "Administration" and look for a worse one, especially the indirect routes to value (the bid, keeper parameters
    with unbounded gas-price cap and overhead, the allowance rate, the surplus split, the burner's cadence and tiers
    within their hard bounds (a stalled reserve: tiers at 0 keep it locked until the game retires, for good after a
    renounce), the fee overflow share (`setOverflowBps`), the markup's effect on which prizes are big, a successor or fee
    recipient behind a proxy).

## 7. Static analysis (Slither 0.11.6)

`slither . --foundry-compile-all --filter-paths "lib/|test/|script/|audit/" --exclude-informational --exclude-low`: 92 results: 5 High, 85 Medium, 2 Optimization (`--json` export, docs/review/slither-output.json; counts below from it). Run on the D68 code (the round-3 audit fixes), 2026-10-30: nothing new from the fixes; the uninitialised-local and unused-return results of `setPattern`'s loop moved with it into `_recountOwed`; `FundingVault.fillOrder` is no longer reported as arbitrary-send-eth now that it books the price from what the adapter returns (its row below is kept). Two strict equalities in `CollectionBurner.process` (`amount == 0`, a call with nothing to buy; `out == 0 || out < minOut`, the slippage guard) are reported in some runs and not others on unchanged code; both intended;
text output in docs/review/slither-output.txt. Triage of every High and of each Medium class:

| Finding | Location | Assessment |
| --- | --- | --- |
| arbitrary-send-erc20 (High) | `FwaFeeRelay.unlockCallback` | False positive: the callback only runs for an `unlock` this contract itself started in `relay`, with `payer = msg.sender` of `relay`; the PoolManager calls back only the unlocker and the callback checks `msg.sender == poolManager`. |
| arbitrary-send-eth (High) | `CollectionPoolOwner._mintPrize` | False positive: ETH goes only to the immutable Shapes contract (`mintTo`) and Packs contract (`createPackTo`), exactly the prize cost; `mintAndList` requires the total to equal `msg.value` from the game. |
| arbitrary-send-eth (High) | `FundingVault.fundGame` | False positive: ETH goes only to the game wired once at deployment (`receiveCapital`), at most its `capitalNeed()`; refused while it retires. |
| arbitrary-send-eth (High; not reported on the D68 code) | `FundingVault.fillOrder` | False positive: ETH goes only to the Seaport adapter fixed at wiring, at most the current bid; see the reentrancy row. |
| reentrancy-eth (High) | `CollectionGame.maintainStep` | Self-call only (`msg.sender == address(this)`), reached only from `sync`, which is `nonReentrant`; callee is the immutable pool owner. |
| reentrancy-eth (High) | `FundingVault.fillOrder` | `nonReentrant`; the adapter is fixed at wiring (D63); spend ≤ the current bid (rate-limited, ≤ `maxPrice` when set and the acquisition budget); custody and unspent ETH are checked after the call. |
| reentrancy-no-eth (17, Medium) | game booking, pool owner refresh/decay/listing, vault `sellToProtocol`, burner, the migration paths (the run's `MigrationAuthority.finalize` no longer exists), `CollectionPoolOwner.migrateApe` | Calls go to the pinned FWA clone, the immutable pool owner, BAYC or the PoolManager; entry points are `nonReentrant` or self-call-only. The migration paths make no call to the successor: `migrateApe` is migrator-only, updates state first and uses BAYC's `transferFrom` (no receiver callback); `migrateCapital` is a forced ETH transfer; the authority's and the Sunset's entry points are `nonReentrant`. Reviewer: confirm FWA's callbacks cannot re-enter a state-changing path mid-booking. |
| incorrect-equality (11, Medium, 13 in some runs; e.g. vault `migrateCapital`, `fundGame`, `fillOrder`, the Sunset's `start`/`flush`/`auctionPrice`, the hook's `curveBps` and `blockOpenPrice`, the burner's `process`, all zero checks) | `== 0` balance/state checks | Intended exact checks. Force-sent ETH (selfdestruct) raises the game's `cash()` (its balance) but never booked profit, so it cannot raise distributions above realised profit. Reviewer: confirm the same for the vault and the burner's buckets. |
| uninitialized-local (12, Medium) | accumulators | Intended zero defaults. |
| divide-before-multiply (2, Medium) | `_bookCapture` base, `makeup` | Rounding is in the conservative direction (booking is a lower bound, trued up later); `makeup`'s division is integer decomposition by design. |
| unused-return (43, Medium) | FWA/PoolManager calls whose results are not needed (e.g. `DrawRouter`'s `processAcquisitions`, whose settled count the router does not need; since D59 also its `sync` and `sweep` calls, which are tried and may fail; since D64 the burner's `releaseBps`, which reads only some fields of the FWA listing, and the game's `_release`, which does not need the amount released and isolates a failure in `try`) | Reviewer: confirm none hides a failure that should revert. |

## 8. Known issues and accepted risks (details in docs/SECURITY.md)

- One owner administers everything **at once** on parameters (no notice): it can change keeper pay (the gas-price cap
  and overhead are unbounded: whoever calls first takes the unpaid allowance, retirement included, but never more),
  the surplus split and milestone share, the bid (overpaying a colluding seller up to `maxPrice`, which it also sets),
  the fee overflow share (`setOverflowBps`, 0-100%: at 100% every trading fee beyond the game's capital, the board
  growth, the bid and one more Ape at the funding reference goes to buybacks; never the game's capital or the next Ape),
  the buyback cadence and milestone tiers (timing only, within hard bounds no
  owner can pass; at the slow extreme the reserve stays locked until the game retires), make the economics unfavourable, change the board pattern or grow the board, and pause. It
  can end the game at once and for good into the Sunset (everything to buybacks). After a public 72-hour notice, with
  the code pinned, it can migrate the Apes and the vault's ETH, or (before any migration starts) point future trading
  fees, at a contract of its choice; nothing on chain judges that contract (docs/MIGRATION.md "Trust"). Each power's worst case: docs/SECURITY.md
  "Administration". The site lists every change as it happens. Renouncing ownership freezes every parameter and
  removes the migration and the sunset.
- The purchase gate cannot see FWA's settlement queue: a purchase can settle after the last collection NFT was won (the
  player gets an ordinary prize). Stale records make the gate refuse more, never less.
- Buyback price checks are per block (same-block manipulation is bounded by slice and impact limits, not prevented).
  A release announces its first slice (it may run at once), so keepers should send buybacks privately.
- The opening curve's 69% sell fee in the first minutes will likely get the coin labelled a honeypot by wallet and
  token scanners, and cached labels can outlive the curve: the owner's accepted choice (D64).
- The fee overflow is accounted lazily: the condition at each sweep (the bid at its fill target, the budget beyond the
  bid and the next Ape) decides for every fee since the last, so whoever times sweeps moves fees between capital and
  buybacks, never elsewhere.
- **Keeper economics:** keepers are paid gas (capped at 3 gwei) plus a 0.0002 ETH flat fee (D79) within an allowance of 1% of each captured
  prize's cost (D82 cut `opsBps` from 5% to 1%; the break-even figures below were measured at 5% and are now lower). Whether that covers upkeep depends on gas: on the 50-row board the allowance breaks even at about
  0.58 gwei average basefee when every draw runs its own upkeep and about 0.9-1.1 gwei in batches of three to ten
  (sim/results/keepers.md, re-run for D64). Above it rational keepers stop once the allowance is spent,
  prizes are not replaced, and the purchase gate closes the game until someone runs the upkeep (safe, but closed).
- `ShapePacks` (first-party) has no audit yet and no upgrade path; a fault in it affects delivered Packs.
- Contract-size headroom: 394 bytes on `CollectionGame` (size pinned by `test_gameLedgerSizePinned`).
- Testing is fork-only (no public testnet); VRF callbacks are impersonated through FWA's real VRF service contract.

## 9. Launch requirements outside the code

- **Independent security audit** of everything in section 2.
- **Legal review** before any paid gameplay: the paid, chance-based draw (gambling, lottery and sweepstakes law in
  every jurisdiction the site serves; age and geography restrictions), whether the site needs Terms (the site has none
  since the owner removed them, D69), the coin (securities and consumer law; the coin confers no rights to prizes or
  revenue), consumer disclosures (odds, costs, that a prize worth more than the ticket is not a profit after gas), tax
  reporting, and **naming/trademark**: the coin identity "ApeBall" (APEBALL, D69) is independent of Yuga Labs, but
  "Ape" and a BAYC prize sit close to Yuga's marks and ApeCoin; confirm no implied affiliation. The 2026-10-28 conflict
  search covered the earlier working name (Ape Draw, ADRAW) only; search "ApeBall" and "APEBALL" (web and on-chain
  tokens) before deployment and again on deployment day. This is not a trademark search.
- Owner decisions still open: the bid's reference price and cap on the day, from the live floor (`REF_PRICE_WEI`,
  `MAX_PRICE_WEI`); review of D57 itself (marked "Needs owner review"); the owner address and its key security (one
  address administers everything); final naming and legal clearance of ApeBall.
