# Final report: Ape Draw V1 (Collection Games, BAYC)

Date: 2026-10-28 (second review, Draw Packs, revised board, the final economics round and the final pre-audit scope
included, then simplified at the owner's direction: one owner, broad parameters, a simple migration, D57; then the
owner's acquisition and game economics: every Ape in the draw on one decay rule, a board that grows on demand,
Permanent Collection's live bid, gas-plus-fee keeper pay, D59; then an hourly keeper fee, a relative bid ceiling and
bounded player upkeep before the audit freeze, D60; then the simplification pass, D63: keeper pay in the game, no
router, milestone or keeper fund contracts, the Sunset as the built-in end, the fee recipient on its own 72-hour
notice; then the flywheel build, D64: the launch values, the 69% opening curve, play-keyed buybacks with tiered
milestones, and the vault's fee overflow; then D65: the overflow only for ETH the bid cannot use, the play meter
removed, K 3, the secondary model on the launch keeper rule; prepared for independent security review,
docs/AUDIT_SCOPE.md). Repository `ripe0x/collection-games` (private), branch `claude/focused-edison-5n720n`. **No independent
audit has been done. Nothing was broadcast to any live network, no real asset was spent, no production key was
created, nothing was published.** Local anvil forks of mainnet were used for every test and rehearsal.

## 1. What was built

- **Permanent contracts** (src/): `CollectionToken`, `CollectionHook`, `ProtocolLiquidity`, `FundingVault`,
  `CollectionPoolOwner`, `CollectionGame` (which also pays keepers and splits surplus between the vault and the
  burner), `CollectionBurner` (buy-and-burn, holding the milestone reserve), all administered by one owner recorded in
  `Admin` (two-step transfer, renounce; D57); `MigrationAuthority` (one-way migration: owner proposal, 72 hours with
  the successor's code pinned, then anyone runs the steps; the trading-fee recipient alone on the same notice; the
  instant sunset; D63, docs/MIGRATION.md); and `Sunset`, the built-in successor with no owner whose only outflow is the
  burner: every Ape auctioned, every wei of proceeds, capital and fees to buy-and-burn.
- **Draw Packs**: a dedicated `ShapePacks` instance per game (ripe0x/shape-packs, `draw-packs` branch at 3a463f7,
  unmodified, minimum two units); the pool owner mints Packs and Shapes as prizes and lists them; winners own them.
- **Settings, not modules (D63)**: the board pattern (a pattern repeated without end, applied to each row as it is next
  listed), board size (grow only), pricing and keeper pay are owner settings in `CollectionGame`; `SeaportAdapter`
  (marketplace route, fixed at deployment). The live bid for Apes lives in `FundingVault` (D59); the Ape listing rule
  and exposure target in `CollectionPoolOwner`. Surplus: 60% to the vault while it is short of an Ape, the rest to
  buy-and-burn (25% of that locked until an Ape is won).
- **Periphery**: `DrawRouter` (settle waiting draws, draw, then run the game's upkeep and sweep the live bid, passing
  the payments to the player; no privileges), `FwaFeeRelay` (owner's FWA → pool owner despite FWA's transfer lock), `FwaFeeBuyer`, `Lens`.
- **Deployment**: `script/DeploySystem.sol` (one routine shared by scripts and tests, with postflight),
  `LaunchConfig.sol` (BAYC), `Deploy.s.sol`, `FwaFee.s.sol`, `Postflight.s.sol`, `deploy.sh`
  (dry run by default; mainnet broadcast needs `I_AM_THE_OWNER=yes`), `rehearse-anvil.sh`.
- **Keeper** (keeper/): simulate-then-send, primary and backup modes, Dockerfile, unit tests.
- **Site** (site/): Next.js static export: play (prize-first, live odds, draw, Shape outcomes, verified wins, buybacks),
  funding progress, prizes and decay, Shapes, acquisitions (sell flow), coin, books and burns, governance and contracts,
  Terms with first-connect acknowledgement. Built and screenshot-tested locally against the rehearsal deployment
  (`docs/receipts/site/*.png`); **not published**.
- **Studies**: economic simulation (sim/economics.py), player sessions (sim/sessions.py), keeper profitability
  (sim/keepers.py), coin launch (sim/launch.py),
  FWA throughput on the fork (test/scenario/Throughput.t.sol → sim/throughput_table.py).
- **Docs**: ARCHITECTURE, SPEC, ECONOMICS, SECURITY, ADMIN, MIGRATION, RUNBOOK, DEPLOY, LAUNCH_CHECKLIST,
  IMPLEMENTOR_DECISIONS (D1-D63), AUDIT_SCOPE, SHARED_COIN (superseded), external/fwa-v2.md, receipts/.
- **Scope (D56)**: Ape Draw (ADRAW, working name subject to naming and legal clearance) for BAYC only. The 1B coin supply
  is 100% protocol liquidity: no farming, airdrop, emissions, staking or reserve allocation. Any $APESTR goodwill claim
  is outside the protocol (the owner's own purchase into a separate optional contract).

## 2. Reuse decisions (Draw Shapes PR #9 at 0020bea, confirmed unchanged on 2026-10-27)

| Reused | Modified | Replaced / dropped |
| --- | --- | --- |
| FwaGame's request walk, booking at FWA's split, replacement, admission, capital protection (→ CollectionGame) | Governed (two timelocks + floors + guardian); EngineHook (fixed block schedule, one immutable exemption, no policy module); Buyback + EngineBuyer merged into a two-bucket burner; ProtocolLiquidity (single-sided seeding, no addLiquidity) | GenesisFarm, Converter, gate, EngineRenderer, promotions (not needed) |
| KeeperFund (unchanged logic) | FwaFeeBuyer (kept) + new FwaFeeRelay | PrizeVault → FundingVault (fees, contributions, acquisitions, continuity) |
| Fork helpers, Swapper, deploy-and-postflight pattern, FWA source dossier | — | Pool ownership moved out of the game into CollectionPoolOwner (FwaGame was 23.5 KB) |

Provenance per file: NOTICE.md.

## 3. Second review: what changed and why

| Feedback item | What changed | Evidence |
| --- | --- | --- |
| 1. Safe when sync stops | `canPurchase` now reads live FWA state only: in-flight bound assuming a full batch, FWA edge, a Shape floor (half the board) and the exposure cap after every unsettled request plus a batch has removed a listing; listing and decay keep that headroom; cap/limit changes that would close it are refused (D36). Every `sync` step after booking runs in its own `try`; booking and retirement read no module; a failing strategy stops only listing and decay (D39) | `test/fork/Outage.t.sol` (8 tests), invariant 19, `test_revertingModulesBlockNothingEssential` |
| 2. FWA throughput | FWA's gate call carries no batch size: the old limit of 3 allowed 7 in flight. Measured limits 3/4/5/10 × boards 50/75/100 under singles + five-draw batches; launch limit **5** (D25 revised) | sim/results/throughput.md, docs/receipts/throughput/ |
| 3. Ape decay | D28 funded-decay gate removed; settled gameplay advances the committed schedule under the cap and FWA's rules only; odds never worsen | `test_decayFollowsSettledGameplayWithoutReplacement`; ECONOMICS §3 |
| 4. Accounting | Operating allocation frozen per listing (its own cost × its own `opsBps`); revenue booked at the highest admissible edge (lower bound) and trued up to the ETH FWA paid; no module read in booking (D40) | `test_bookingIgnoresChangesBetweenRequestAndBooking`; `assertBooks` exact when caught up |
| 5. Token launch | Analysed 25-250 ETH opening valuations, 0.1-5 ETH opening buys and selling patterns. A seeded ETH position can never be reached (price cannot return above the start) and could never be removed, so `launch` no longer accepts ETH; recommended opening FDV ≈ 100 ETH (D38) | sim/results/launch.md, `test_launchOnlyGuardianAndRefusesEth` |
| 6. Sustainability | Opening board 40 × 0.05, 6 × 0.1, 3 × 0.5, 1 × 1 ETH at the agreed 7.5% markup: return **86.6%** (was 80.4%) with **more** coin surplus (101 vs 87 ETH); operating allocation 3% (D37, D29 revised). Continuity under declining trading quantified; no perpetual availability promised (D31) | ECONOMICS §2, §7 |
| 7. Owner-funded launch | KeeperFund seed 0.5 → **0.05 ETH**; `sync` tops it up from trading fees (D41) | `test_keepersPaidFromEarlyFeesWithMinimalSeed`; rehearsal |
| 8. Verification | Fork, adversarial, invariant, scenario, throughput and unit tests; simulations; anvil rehearsal with the keeper bot (its log scan now works on range-limited RPCs) | section 5 |

## 3a. Draw Packs round: what changed and why

| Request | What changed | Evidence |
| --- | --- | --- |
| Restore Draw Packs, dedicated instance, no extra Pack economics | `ShapePacks` + renderer deployed per game (admin = Safe, `MIN_PACK_VALUE` 0.02 ETH); pool owner holds its address as an immutable; postflight checks it (D43) | `script/DeploySystem.sol`; rehearsal postflight |
| Minting, listing, selection, delivery | The pool owner mints every prize for itself (`mintAndList`: Shape by `mintTo`, Pack by `createPackTo`) with exactly the game's payment and lists it; FWA selects and delivers a Pack like any ERC-721 | `test_winnerOwnsPackAndRedeemsIt`, `test_winnerOpensPackIntoShapes` |
| Replacement, cost accounting | `prizeCost` = backing + one mint fee per Shape; carried as the item's expense; markup and 5% allocation frozen per listing; `Item.isPack` | board test: 100 items, tiers, each Pack's contents, cost and price |
| Refunds, recovery, retirement | A refunded or withdrawn Pack is redeemed for its backing (ETH → game); retirement redeems every Pack held | `test_failedPackDeliveryRecoveredAndRedeemed`, `test_retirementRedeemsEveryPack` |
| Custody and redemption boundary | Only the Pack's owner can open, redeem or unseal; the pool owner accepts Packs only from its own mint or FWA; the Packs admin controls presentation only | `test_packCustodyBoundary`; SECURITY "Draw Packs" |
| Batches, delayed VRF, keeper outage | Five-draw batches and late VRF on the Pack board: 0 refunds; outage suite unchanged and passing | `test_batchesWithLateVrf`, Outage suite, throughput (0 refunds at 100 rows, K 3-10) |
| ≈ 0.02 ETH draw, figures verified | 0.01802 fee + 0.00195 VRF = **0.01997 ETH**; inventory **2.62 ETH**; return **75.9%** | ECONOMICS §2 |
| Gas | Replacement 1.17-1.68M gas per prize; ten draws in one `sync` 6.53M; Pack redeem 191k, open 122k | `docs/receipts/gas-prizes.json`, `gas.json` |
| Found on the way | KeeperFund top-ups from fees had no lifetime bound; at 2 gwei they would have taken ≈ 30 ETH of NFT funds. Capped at 1 ETH (D44) | `test_keeperTopUpsStopAtLifetimeLimit`; ECONOMICS §8 |

## 3b. Revised board round: what changed and why

| Request | What changed | Evidence |
| --- | --- | --- |
| Replace the board with 48/32/7/1/7/1/1/1/1/1 | `LaunchConfig._boardPattern` (D45); Ape separate; markup, allocation, reserve, cap, acquisition, decay, continuity and buybacks unchanged | `test_boardListedAtMarkupOverFullCost` (100 listings, tiers, contents, costs, prices) |
| Fewest Shapes per Pack, exact backing | `CollectionPoolOwner.makeup`: largest denominations first (0.06 = 0.05 + 0.01, 0.15 = 0.1 + 0.05); one mint fee per Shape | `test_packMakeupUsesFewestShapes`, `test_mixedPackWonOpenedAndRedeemed` |
| Verify the estimates | FWA fee + VRF 0.019834 ETH (≤ 0.02 up to 1.08 gwei); 29.9% of prizes worth at least FWA fee + VRF (gas excluded, not a profit chance; D42 had 30.9%, so no improvement on this metric); 23.4% 0.02 Packs; return 76.0%; capital 3.681 ETH | ECONOMICS §2 |
| Sessions of 10 / 20 / 50 draws | rerun with profitable-draw counts, return, Ape and large-prize odds | ECONOMICS §3, sim/results/sessions.md |
| In-flight limit 10, only if safe | kept: 0 refunds at 100 rows, +21% completed draws; gate headroom 14; FWA's 10-awaiting-VRF limit refuses beyond it before any fee (D47) | throughput study, Outage suite, invariants |
| Board changeable/shuffled after deploy | `CollectionGame.setBoard` (48 h then; immediate since D54): matching listings kept, the rest withdrawn once the new rows are listed; `script/SetBoard.s.sol` (D46) | `test/fork/BoardChange.t.sol` (4), rehearsal step 7 |
| Found on the way | settlement exposure `unsettled × costliest prize` would have protected ≈ 14 ETH with a 1 ETH prize at limit 10; now bounded by the inventory (D48) | ECONOMICS §7 |

## 3c. Final round: what changed and why

| Request | What changed | Evidence |
| --- | --- | --- |
| Approvals recorded | D45, D46, D47 approved; 100 ETH FDV single-sided launch, acquisition and continuity, 1 ETH top-up cap, 0.05 ETH seed, 15 / 30 ETH ceilings, retirement and governance kept | IMPLEMENTOR_DECISIONS table |
| Coin identity | **Ape Draw (ADRAW)** in LaunchConfig, mainnet.env and the site; web search found no conflicting project (not a trademark search; repeat on deploy day; name in the legal review) (D9) | AUDIT_SCOPE §9 |
| KeeperFund premium 5%, bounty 0.00025 ETH | set (the premium later replaced by a priority refund, D53); tip cap raised 0.01 → 0.05 ETH so 20-prize listing calls are paid above ~0.65 gwei (D49) | `test/fork/KeeperPay.t.sol` |
| Keeper profitability without unprofitable calls | new time-based model (sim/keepers.py) and the economics model both pay keepers only when a call covers its gas. **Maintenance pays for itself only up to ≈ 1.1 gwei** average basefee; above it the game closes safely until gas falls or KeeperFund is funded (D49) | ECONOMICS §8, sim/results/keepers.md |
| Reporting corrections | 29.9% is not a profit chance (gas excluded; with transaction gas only 6.6% of prizes exceed the ≈ 0.02045 ETH cost); no improvement on D42's 30.9%; distributable surplus (37.5) split into continuity (22.3) and coin buybacks (15.2) (D50) | ECONOMICS §2, §4 |
| Site transparency | play page: ticket, VRF fee, the player's transaction gas and the all-in cost, live odds per tier, a note that a prize above the ticket is not a profit, and a banner for scheduled governance changes; governance page: every scheduled change decoded with its state and executable time | `docs/receipts/site/play.png`, `governance.png` (against the rehearsal deployment) |
| Freeze the game contract | `CollectionGame` 24,445 B (131 B headroom) frozen by `test/unit/Sizes.t.sol` (D51) | Sizes suite |
| Prepare for security review | docs/AUDIT_SCOPE.md: scope, build, properties, focus areas, Slither triage (92 results on the D68 code; every High a false positive or by design), known issues, legal requirements | docs/review/ |

## 3d. Shared coin: what changed and why (D52; superseded by D56)

Superseded: the launch is Ape-only (D56). The attached-game deploy path, `DeployGame.s.sol` and `SharedCoin.t.sol` are
removed; the burner keeps its milestone-reserve registration (compatibility, safe). The table records the round.

| Requirement | What changed | Evidence |
| --- | --- | --- |
| One collection-neutral coin for multiple games; no token launch per game | Coin layer (token, liquidity, hook, burner, timelocks) deployed once; game layer per collection via `DeploySystem._deployAttachedGame` / `script/DeployGame.s.sol`; `postflightAttached`, `postflightRegistered` | `test_secondGameUsesTheSameCoinWithoutALaunch`; rehearsal step 8 |
| Future games send buybacks to the same coin | Every game-layer contract already took the burner as an address; `CollectionBurner` now accepts milestone releases from registered reserves (48-hour timelock, additive) and records ETH per source | `test_secondGameBuybacksBurnTheSameCoin`, `test_secondGameMilestoneOnlyOnItsOwnWin`, `test_milestoneRegistrationGovernedAndAdditive` |
| Shared funding never takes an existing game's protected capital or committed buyback ETH | Trading fees stay with the BAYC vault; later games are capitalized by contributions to their own vaults; no cross-game call path; the burner reimburses its keeper from the slice (≤ 5%) instead of the BAYC KeeperFund | `test_secondGameCapitalIsolated` (BAYC vault, cash, protected cash, books, milestone, router, KeeperFund all unchanged), `test_burnerKeeperPaidFromTheSlice`, `invariant_burnerConservation` |
| Keep new functionality out of `CollectionGame`; preserve the BAYC game | `CollectionGame`, `CollectionPoolOwner`, `FundingVault`, `RevenueRouter`, `MilestoneReserve`, `KeeperFund`, hook, token, liquidity unchanged; game still 24,445 B | every existing suite passing; `test_gameLedgerFrozen` |

## 3e. Keepers and the player path: what changed and why (D53)

| Owner's direction | What changed | Evidence |
| --- | --- | --- |
| Keepers should not do what FWA leaves to users | The keeper no longer settles draws (FWA's callback does; anyone may). It keeps only protocol work: `sync` (booking, owner proceeds, replacements, the next Ape, refunded-prize recovery, payouts), `activate`, burner `process`; routing to the burner waits for a full 0.1 ETH slice | keeper/test (6), keeper/README.md |
| The game must not stall when players do not settle (10-request limit) | `DrawRouter` (periphery, stateless, no privileges): the site's draw settles up to ten waiting draws, then buys for the player in the same transaction, quoted after that settlement; the player pays that gas, no rebate at launch (owner's choice) | `test/fork/DrawRouter.t.sol` (3), rehearsal step 10 |
| FWA-standard buyer actions on the site | withdraw refunded tickets; retry or refund a failed delivery | `site/app/page.tsx` (`YourDraws`) |
| Keeper tips: why a percentage? | The 5% premium on basefee is replaced by a refund of the priority fee actually paid (cap 0.05 gwei) plus the existing age bounty as the keeper's margin; `gasOverhead` 40k → 64k (measured). At today's ≈ 0.1 gwei basefee the old formula kept the game open only 1-41% of the time at 20 draws an hour, and 4-13% at any rate when keepers pay a 0.05 gwei priority fee; the new one keeps it open in every case modelled. Maintenance ceiling unchanged at ≈ 1.1 gwei | `KeeperPay.t.sol` (5), sim/results/keepers.md |
| Closed only at the very beginning; open after an Ape win with no backup | Activation still needs the first Ape; afterwards `_admit` and `canPurchase` need none: Shape and Pack draws continue and fund the continuity reserve; the site says no Ape can be won meanwhile | `Collection.t.sol`, `Outage.t.sol`, `LongRun.t.sol` |
| `CollectionGame` frozen | the change only removed a condition: 24,445 → 24,310 B (266 B headroom) | `test_gameLedgerFrozen` |

## 3f. Final pre-audit scope: what changed and why (D54-D56)

| Owner's direction | What changed | Evidence |
| --- | --- | --- |
| No farming, no airdrop, 100% of 1B in liquidity | Nothing to remove (none was built); confirmed in the docs and launch checklist; $APESTR goodwill stays outside the protocol | docs/LAUNCH_CHECKLIST.md, D56 |
| Ape-only launch | Attached-game path, `DeployGame.s.sol`, `SharedCoin.t.sol`, FUTURE_COLLECTIONS removed; shared-burner registration kept (additive, contracts only, can only deposit) | D56; postflight |
| No mandatory timelock for normal administration | `Governed` rewritten: the Safe holds every role and acts at once; no 48 h / 14 d floors | `test_safeAdministersDirectlyWithinBounds`, Governance.t.sol (9) |
| Instant administration must not reach assets | Each instant power reviewed for indirect extraction (docs/SECURITY.md "Administration without delay"): an **immutable bid ceiling** in the vault (15% of `hardMaxPrice` after each purchase, rising to it over 21 days), so a strategy or adapter swap cannot overpay a colluding seller; a **5% markup floor** in the game (zero markup at maximum exposure returned ≈ 103% to players; the floor holds the worst case at 98.3%); **no revenue destinations** can be added (EngineSink, FwaStakeSink, `addDestination` removed); KeeperFund payer and overflow fixed at wiring, tighter tip caps; tighter burner bounds (slice ≤ 1 ETH, spacing ≥ 10 min, impact ≤ 5%, deviation ≤ 3%) | Governance.t.sol (ZeroPricing, GreedyBid, ceiling, floor, bounds, no route to assets), `test_strategyChangeCappedByTheImmutableCeiling`, `test_noDestinationCanBeAdded` |
| Secure one-way migration without changing the coin | `MigrationAuthority`; hook fee recipient changeable only by it; migrator hooks in the game (`retire`), pool owner (`beginMigration`, `migrateApe`) and vault (`beginMigration`, `migrateCapital`); `MilestoneReserve.releaseRetired`. Safe proposes, independent signer approves the exact code hashes, 24 h, then anyone executes in batches; Apes directly to the successor's custody with their accounting; Shapes and Packs redeemed into capital; committed buyback ETH never moves; fees redirect only after receipts and readiness | `Migration.t.sol` (16), rehearsal step 11, docs/MIGRATION.md |
| `CollectionGame` frozen | `MIN_MARKUP_BPS` clamp and the `migrator` immutable: 24,310 → 24,330 B (246 B headroom) | `test_gameLedgerFrozen` |

## 3g. Simplification: what changed and why (D57; the bid, keeper pay and lead superseded by D59, §3h)

| Owner's direction | What changed | Evidence |
| --- | --- | --- |
| No Safe requirement; one developer; transfer in two steps or renounce | `Admin` (owner, pendingOwner, `transferOwnership`, `acceptOwnership`, `renounceOwnership`); every contract checks `admin.owner()`; roles gone | `test_twoStepTransferAndRenounce`, `test_ownershipTransfersInTwoStepsAndRenounces` |
| Nothing immutable about prices; no max inventory; never overpay, even when the pool fills far past the floor | Standing bid in the vault: restarts at 90% of the price just paid, rises 5% of it a day, only from a level the vault could pay, at most an hour of rise per record (`poke`), with no cap unless the owner sets one; all owner-set. `RisingBidStrategy`, `hardMaxPrice`, the ceiling and `maxInventory` removed. This also fixes a flaw in the old design: its clock ran while the vault could not buy, so the bid could jump to the maximum when a slot reopened | `Bid.t.sol` (5), `test_risingBidAndHolderSale`; rehearsal step 4 (21 days without records: 5.41 ETH, not a jump; hourly records: 6.11 ETH, the funds) |
| Much broader parameters | Markup and allocation 0-100%, fee ≤ 10%, exposure ≤ 50%, in-flight ≤ 50, burner and settings broad; the reserve-covers-twice-the-largest-prize rule kept | `test_markupAndOpsAreBroad`, `test_remainingBounds`, `test_policyBounds` |
| Revenue destinations later, through a swappable splitter | `RevenueRouter.setSplits` (any recipients, ≤ 100% together, forced payments); the rest buys back the coin; none at launch | `test_ownerSetsSplits`, `testFuzz_routerSplitsAddUp` |
| KeeperFund open and uncapped; no 0.05 ETH tip cap; gas only below a maximum; adjustable bounty | No target or overflow; owner `returnToGame` and `setPayer` (removed in D62); no tip above `maxBasefee` (3 gwei); bounty start, max, ramp and items adjustable | `test_keeperTipFormula`, `test_keeperFundIsOpen`, `KeeperPay.t.sol` (6) |
| Upkeep as part of a player's draw | `DrawRouter.draw(..., game, settle, syncCount, ...)` runs `sync` and `poke` after the purchase; the tip goes to the player | `test_drawRunsUpkeepAndPaysThePlayer`; rehearsal step 6 |
| Simpler migration; no code-hash theatre; simple fee switch | Owner proposal, 24 hours, anyone executes; NFTs and capital straight to the successor; `setFeeRecipient` by the owner | `Migration.t.sol` (9), `test_ownerSetsTheFeeRecipient`; rehearsal step 11 |
| `CollectionGame` within its limit | One shared owner check and no markup floor: 24,330 → 24,146 B (430 B headroom) | `test_gameLedgerFrozen` |

## 3h. Acquisition and game economics: what changed and why (D59)

| Owner's direction | What changed | Evidence |
| --- | --- | --- |
| Permanent Collection's live bid, not a time-rising one | `FundingVault` holds one public bid of real ETH: `sweep` (anyone, rewarded 0.5%, ≤ 0.01 ETH) fills it at once to the activation threshold, then 0.05 ETH per 300 blocks; a purchase subtracts its price (the rest stays) and resets the threshold to 75% of the clearing price; holders name a price up to the bid, marketplace fills pay the listing price plus a 0.5% finder fee; optional `maxPrice`; every parameter owner-set. `poke`, `bidLevel` and the time rise removed | `Bid.t.sol` (10); sim/results/bid.md; rehearsal steps 4 and 8 |
| No inventory limit, no listing limit, no excess routed to buybacks | Every Ape held is listed, ten per maintenance call; acquisition continues while the game's capital and the board's growth are covered | `test_noInventoryLimit`, `ManyApes.t.sol` |
| One decay rule, no lead | Opens at 100% of its price, falls 0.1 ETH per ETH of gameplay credited (shared evenly among the Apes in the draw), never below 25%, never raised; `ListingParams` owner-set | `Collection.t.sol` (12 + 1) |
| A board that grows on demand to a 15% exposure target | The pool owner records the rows the target needs (`rowsShort`); the game adds them in the same call (≤ 50) from vault ETH it reserves first (`growthNeed`); owed-row list instead of a 256-row bitmap; no `MAX_BOARD`; linear rebinding; per-listing settlement (`settleListing`). The gate checks a fixed 50% ceiling | `test_targetDefersDecayAndGrowthResumesIt`, `ManyApes.t.sol` (20/50/100 Apes: 128/298/581 rows at price, 528/1,298/2,581 at minimum; largest call 16.9M gas; gate ≤ 9,554 gas) |
| Keeper pay = gas + flat fee | `(gas + 70,000) × min(gas price, 3 gwei) + 0.0003 ETH`, the fee at most once a minute (an hour since D60) and never for an empty call; age bounty, progress scaling, basefee cutoff and priority cap removed; the DrawRouter keeps passing the payment to the player | `KeeperPay.t.sol` (6), `test_keeperPaymentFormula`, `test_flatFeeOncePerInterval`; rehearsal step 10 |
| KeeperFund surplus back to the game | `reserveTarget` 1 ETH; anyone returns the balance above it (`returnToGame`), booked to the game's accounts; credits untouched | `test_surplusReturnsToGame`; rehearsal step 10 |
| Models and opening capital | sim/pool.py funds the first Ape, then the opening board, reserve and KeeperFund before gameplay starts (it previously started play at once); sim/bid.py compares the live bid with the 80/20 time-rising bid; sim/maintenance.py models gas + fee | ECONOMICS §2a, §8 |
| `CollectionGame` within its limit | 24,146 → 23,873 B (703 B headroom): the capital module, bitmap and lead bookkeeping removed | `test_gameLedgerFrozen` |

## 3i. Before the audit freeze: what changed and why (D60)

| Owner's direction | What changed | Evidence |
| --- | --- | --- |
| Flat keeper fee at most once an hour | `feeInterval` 1 hour (was 60 s); every useful call is still reimbursed its gas, capped at 3 gwei; surplus above 1 ETH still returns to the game. Two years at 0.2 gwei with per-draw upkeep: 51.2 ETH back to the game instead of 23.6 | `KeeperPay.t.sol` (`test_noFeeFarming`: gas only within the hour, the fee an hour later); sim/results/maintenance.md |
| Evaluate a relative maximum bid (150% of the last acquisition price) before implementing | Modelled against floors that double or triple (gradually and overnight), crash, months without sellers, a cartel ratchet and volume without sellers (`sim/ceiling.py`). A **hard** ceiling stops acquisitions for good after a floor jump of more than 50% between two acquisitions (and, once renounced, nobody can lift it); it does not stop a ratchet or help in a crash. Implemented instead: the same ceiling, moving with every acquisition, above which the bid climbs at a tenth of the rate (`ceilingBps` 150%, `slowSweepWei` 0.005 ETH per 300 blocks): no permanent stall (≈ 27 days after an overnight doubling), a 30-day drought pays +103% instead of +576%. `slowSweepWei` 0 makes it the hard ceiling; `ceilingBps` 0 removes it | `Bid.t.sol` (`test_ceilingSlowsTheBidAboveIt`, `test_ceilingIsTheOwners`, `test_risingFloorNeedsNoUpdate`); sim/results/ceiling.md; ECONOMICS §2a |
| Player draws must not run unexpectedly expensive maintenance or revert because of it; estimate the real cost | `DrawRouter.draw(..., upkeepGas, ...)`: `sync` gets at most the budget, the sweep and surplus return 100k each, 260k kept back; a gas limit below the budget reverts up front (`UpkeepGas`), so an estimate always includes it; `measureUpkeep` for the site. The site asks for the upkeep only when it measures ≤ 2.5M gas (budget +30%), shows the draw's gas including it and the expected KeeperFund payment (not guaranteed); heavy work is left to keepers | `DrawRouter.t.sol` (`test_measuredUpkeepRunsWithinItsBudget`, `test_heavyUpkeepNeverBreaksTheDraw`, `test_gasLimitMustCoverTheBudget`); `ManyApes.t.sol` site-style draws at 1/20/50/100 Apes; rehearsal step 6 |

## 3j. Gas cap, bid ceiling, name (D61)

| Owner's direction | What changed | Evidence |
| --- | --- | --- |
| Fix transactions above EIP-7825's 16,777,216-gas cap | The board module carries `maxPerCall` (owner, 1-20; 8 at launch), the most prizes one maintenance call lists; the game reads it (never more than 10) and withdraws at most 10 prizes per call. Before, a call listed 20: 24.3M gas on a board of the heaviest Pack and 16.85M with 100 Apes, transactions mainnet would reject. Now the worst measured call is 14.2M (a board change on a heavy board); with 100 Apes 7.3M. The keeper bot books at most 20 draws per call | `test/fork/TxCap.t.sol` (4: heaviest opening board, booking + relisting + Apes, heavy board change, retirement; each under 90% of the cap); `ManyApes.t.sol` asserts the same bound |
| "I'd rather not pay 50% over" | Bid ceiling 120% of the last acquisition price (was 150%), then 0.0025 ETH per 300 blocks (was 0.005): thirty days without sellers pay at most +48% (was +103%); the cost is a slower catch-up after a sudden jump in the floor (≈ 81 days for an overnight doubling). With sellers present every setting pays 0.5-1% over the floor | `Bid.t.sol` (ceiling tests at 120%); sim/results/ceiling.md "Lower ceilings"; ECONOMICS §2a |
| Name | Ape Draw / ADRAW approved, subject to legal clearance | D9, D61 |

## 3k. Trust review follow-up (D62)

| Owner's direction | What changed | Evidence |
| --- | --- | --- |
| Anyone can still give ETH and Apes, no return expected | Unchanged: `FundingVault.contribute()` and plain ETH transfers, `contributeNFT(id)`, `claimStray(id)` for an Ape sent without a call | `test_ethContributionsCountSeparately`, `test_nftContributionUsesConservativeReference`, `test_strayNftRegisteredAsDonation` |
| The owner can sweep NFTs out, but only unrelated collections | `sweepNFT(token, id, to)` on every governed contract; the collection, Shapes and Draw Packs are recorded in `Admin` once at deployment (`protect`, then closed) and are never swept, whatever the token id | `test_ownerSweepsStrayNFTsOnly`; deploy postflight |
| Remove `setPayer` | Only the game can request KeeperFund tips; no payer can be added. Keeper pay and the bid keep no bounds (the owner's choice) | `test_keeperFundIsOpen`, `test_keeperPaymentFormula` |
| No delay on `setFeeRecipient` and `setSplits` | None existed; unchanged | — |
| No multisig requirement | Single owner kept | — |

## 3l. Simplification pass (D63)

| Owner's direction | What changed | Evidence |
| --- | --- | --- |
| Remove plumbing: no router, keeper fund or milestone contracts; settings instead of modules | `RevenueRouter`, `KeeperFund`, `MilestoneReserve`, `BoardPolicy`, `PricingPolicy` and `SetBoard.s.sol` removed. The game splits surplus (60% to the vault while it is short of an Ape at the last price, the rest to the burner); the burner keeps the milestone reserve (25% of the game's ETH, released whole on a verified Ape win); pattern, board size, pricing and keeper pay are owner settings in the game | `Revenue.t.sol` (8), `Pattern.t.sol` (4), `Governance.t.sol`, `invariant_burnerConservation`, `invariant_milestoneOnlyOnWins` |
| Keeper pay: gas plus a small margin so a third-party keeper has a reason to run | The game pays `(gas + 70,000) × min(gas price, 3 gwei) × 110%` within an allowance (0.2 ETH opening, then 5% of each captured prize's cost), never from cash owed to replacements. A paid refill loop found in testing is closed: funding counts as work only when the need was at least a row's cost | `KeeperPay.t.sol` (8, including `test_tooLittleGasNeverSkipsWork`: no gas limit gets a paid call that skips its work), `test_keepersPaidForTheOpeningBoardFromTheAllowance` |
| Sunset successor, instant, proceeds to burn | `MigrationAuthority.sunset()` (owner, instant) into `Sunset`: no owner; every Ape in a 30-day Dutch auction (150% → 25% of cost), every wei of proceeds, the vault's capital and fees to the burner; final: no later successor or fee recipient | `Sunset.t.sol` (6: end to end, finality, retirement pay within the allowance, access) |
| Migration notice 72 hours; the fee recipient changeable without migrating | Proposal → 72 hours → anyone executes, successor code pinned; execution points fees at the successor. `proposeFeeRecipient` / `executeFeeRecipient`, 72 hours, code pinned, game keeps running; the hook accepts a recipient only from the MigrationAuthority | `Migration.t.sol`; rehearsal steps 11-12 |
| Lazy pattern change, grow-only board size | `setPattern` applies to each row when next listed and recosts owed rows; `setBoardSize` grows by up to 50 rows per call when the vault covers it | `Pattern.t.sol`, `Governance.t.sol` |
| Packs are first-party code | Kept; in the audit scope as first-party | docs/AUDIT_SCOPE.md |

## 3m. The flywheel build (D64)

| Owner's decision | What changed | Evidence |
| --- | --- | --- |
| A: launch values | Fees 5% / 5%; the 50-row board; markup 10%; target 20%; K 4 (K 3 since D65); minimum live rows 70%; reserve 1 ETH; continuity 35%; first bid threshold 100% of the reference (a deploy-time value, no owner call) | `Game.t.sol`, `Funding.t.sol`, `Collection.t.sol`; sim/results/pool.md, throughput.md |
| B: 69% on buys and sells, one point less a minute | The hook's fixed time-based curve replaces the block schedule; exact-output buys pay the fee on the gross ETH | `Market.t.sol` (curve by minute, sells, exact output, before launch); sim/results/launch.md |
| C: buybacks keyed to play, tiered milestones | Burner cadence (0.05 ETH + 0.005 a draw + 1% of the backlog; spacing 60 minutes halved every 20 draws; hard bounds 1 ETH / 10 min / 5% / 3%); 75% of buyback ETH locked; a big prize releases 15%, an Ape exit 60% (at least 10%), a second exit within 24 hours the rest, verified from FWA; the game releases at booking | `Units.t.sol` (tiers, bounds), `Revenue.t.sol` (cadence, releases), `Collection.t.sol` (big prize); sim/results/burner.md |
| D: couple fees and the bid to the game | Half the trading fees to buybacks while the bid is full and Apes wait or ten are listed (lazy, at the sweep; capped below the game's needs and the bid); the bid's metered step grows with draws to 4x. D65 replaced the trigger and removed the meter (§3n) | `FlowForkTest`, `FlowGasForkTest`, `invariant_vaultConservation`; sim/results/pool.md |
| Found in review | The router's sweep budget raised to 250,000 gas (a sweep now measures 125,000-210,000); the Ape-exit tier at least 10% so no setting can lock the reserve; the bot retries big-prize releases | `DrawRouter.t.sol`, `Units.t.sol` |

## 3n. The owner's review of the flywheel (D65)

| Owner's decision | What changed | Evidence |
| --- | --- | --- |
| The overflow must never fire while the board could still use an Ape | The rule the owner first asked for (an Ape the target holds back waits in custody) never fires: the board grows within the hour to take every Ape, funded before the bid; 2,849 ETH would sit idle after three years of trading ≫ play. The owner chose the idle-ETH rule: while the bid is full, half the fees go to buybacks, never the game's needs, the board growth, the bid's ETH or one more Ape at the last price. `FlowParams` became one setting, `overflowBps`; the vault no longer reads the pool owner for it | `FlowForkTest` (4), `FlowGasForkTest`; sim/results/pool.md (all four rules compared) |
| Remove the play meter | Removed (`meteredStep`, `drawsSinceSweep`, `lastSweepSeq`, the pool read); the metered step is `maxSweepWei` again. Under heavy play it mattered (sudden popularity: 830 Apes bought without it, 1,106 with); a fixed 0.1 ETH step recovers most of it (1,074), so raising `maxSweepWei` in sustained heavy play is a runbook item | sim/results/pool.md; docs/RUNBOOK.md |
| K 3 for launch | `maxInFlight` 3 (headroom 7); refunds of issued draws 0.3% against 0.9% at K 4 on the fork | sim/results/throughput.md (re-run on the D65 code) |
| The secondary model on the launch keeper rule | `sim/economics.py` now pays keepers gas + 10% within the 5% allowance (router upkeep by default, keepers-only as a sensitivity) instead of the retired KeeperFund rule; its closure artefact at 1 gwei is gone | sim/results/economics.md |
| The site's closed state names the gas threshold | "Draws closed" now says above about 0.6 gwei (1 gwei batched) the allowance does not pay for refills, so a closure is expected | site/app/page.tsx |

## 3o. Fixes from the fresh-discovery audits (D66-D68)

The owner ran a fresh-discovery audit (docs/AUDIT_PROMPT.md) on `004c0a4`; report and path ledger in `audit/`. It is a
bounded review, not the independent audit, which remains a launch requirement.

| Audit item | Fix | Evidence |
| --- | --- | --- |
| F-1: a 1-wei sale or reference rounds the minimum notional to zero; collection maintenance divides by it and stops crediting turnover | `register` values every NFT at least 0.01 ETH (`MIN_REF_COST`) for listing and exposure; the cash cost stays what was paid | `test_tinyReferenceIsFlooredAndMaintenanceKeepsWorking` |
| F-2: ETH sent to the Seaport adapter blocks fills up to its amount, or lowers the price the vault books | The adapter returns exactly what is left of the vault's payment; the vault checks that the adapter's balance did not grow | `test_adapterPrefundCannotBlockOrRepriceAFill` |
| F-3: naming the Packs contract as purchaser strands a Pack in FWA's delivery quarantine through retirement | The purchase gate refuses the Shapes and Packs contracts as purchasers | `test_systemAddressesCannotBePurchasers` |
| R-1: the code-hash pin does not bind a proxy's implementation | Accepted owner procedure, already documented; the runbook now requires a non-upgradeable successor or fee recipient | docs/RUNBOOK.md, docs/SECURITY.md |
| Round 2, N-1/N-2: a system address named as purchaser (the FWA pool, pool owner, game, vault, collection) settles a prize that never moves or cannot be recovered; a pool-self Ape "win" released 60% of the milestone reserve | The gate refuses every system address as purchaser; the burner releases nothing for a pool-self settlement (D67) | `test_systemAddressesCannotBePurchasers`, `test_poolSelfWinReleasesNothing` |
| Round 2, R-1 extended: storage-set payout or refusal also changes behaviour at a stable code hash | Owner procedure: a successor or fee recipient's behaviour must be fixed in code | docs/RUNBOOK.md |
| Round 3, R3-3: a Shapes mint fee change left the replacement debt wrong | Owed rows at today's cost; `sync` recounts them when the fee changes (D68) | `test_mintFeeChangeRecountsWhatTheGameOwes` |
| Round 3, R3-12: a payout triggered inside a Seaport fill lowered the booked price | The vault books what it sent the adapter less what came back (D68) | `test_otherInflowDuringAFillDoesNotLowerThePrice` |
| Round 3, R3-10: a seller-chosen consideration stranded ETH in the pool owner | `flushStray()` sends it to the vault (D68) | `test_strayEthInThePoolOwnerGoesToTheVault` |
| Round 3, R3-1/R3-2/R3-11: other addresses named as purchaser | Accepted: the prize leaves the game as in any win; the payer's own loss (D68) | docs/SECURITY.md |

## 4. Final economics (docs/ECONOMICS.md)

Approved launch (D64 and D65, the owner's flywheel decisions; every value owner-adjustable after launch except the hook's
curve and the burner's hard bounds): the 50-row board (24 x 0.01, 16 x 0.02 Pack, 3 x 0.03 Pack, 1 x 0.04 Pack,
3 x 0.05, 1 x 0.1, 1 x 0.15 Pack, 1 x 0.5; 1.666 ETH at cost), repeated as the board grows; markup 10%; keeper
allowance 5% of each captured prize's cost (0.2 ETH at opening); reserve 1 ETH; every Ape held listed at 100% of its
price, falling 0.1 ETH per ETH of gameplay credited to it to 25%; exposure target 20% with 7 listings of headroom; the
board grows on demand; in-flight limit 3 (D65); minimum live rows 70%; continuity 35% until one Ape at the latest clearing
price, the rest to the burner, 75% of it locked as the milestone reserve (released 15% by a big prize, 60% by an Ape
exit, the rest by a second exit within 24 hours); trading fees 5% / 5% after the opening curve (69% on buys and sells,
one point less a minute, ordinary from minute 64); ≈ 100 ETH opening FDV, single-sided, 0 ETH; the live bid: first
threshold 100% of `REF_PRICE_WEI`, then 75% of each clearing price, 0.05 ETH per 300 blocks, above 120% of the last price
0.0025 ETH; half the trading fees to buybacks while the bid is full, never the bid's ETH or one more Ape at the last
price; buybacks of 0.05 ETH + 0.005 ETH a draw + 1% of the backlog, spaced 60 minutes halved every 20 draws
(at least 10 minutes), released ETH at 1 ETH every 10 minutes; keepers paid gas + 10% within the allowance.

**One draw (sim/results/pool.md, 0.5 gwei).** With no Ape: FWA fee 0.018629 ETH, player return 75.6% of FWA fee + VRF.
One fresh 6 ETH Ape: fee 0.0190, return 75.9%, an Ape 1 in 16,910 draws; at its minimum 81.2% and 1 in 4,228. With 20 or
more Apes the 20% target binds and the board grows: about 1 Ape per 1,400-1,650 draws, return 79% (fresh) to 90%
(decayed). Sessions (sim/results/sessions.md, 1 gwei): a draw costs 0.02095 ETH all-in; 20 draws cost 0.42 ETH and
return a median 0.28 (p10-p90 0.24-0.36); 39.6% of 20-draw sessions see a 0.05 or better, 11.1% a 0.1 or better, 1.41%
a 0.5 or better; 4.0% get back at least the spend before gas.

**Three years (sim/pool.py; trading / play in ETH a day; on demand).**

| Flows | Gameplay from day | Apes bought | won | Player return | Fee overflow | Buybacks (incl. overflow) |
| --- | --- | --- | --- | --- | --- | --- |
| base 10 / 3 | 1 | 125 | 91 | 83.5% | 0.2 | 383.2 ETH |
| trading >> play 150 / 0.5 | 1 | 864 | 17 | 79.2% | 2,916.9 | 3,013.3 ETH |
| play >> trading 0.5 / 30 | 1 | 194 | 193 | 78.8% | 0 | 2,122.7 ETH |
| sudden popularity 10 / 3 then 150 / 40 | 1 | 830 | 823 | 83.9% | 3,750.2 | 8,392.1 ETH |

What each mechanism adds (same file): without the opening curve gameplay opens on day 12 (base) or day 257 (play >>
trading) instead of day 1; without the fee overflow buybacks in the trading-heavy case fall from 3,013 to 146 ETH and
2,849 ETH sits idle in the vault, with 4 more Apes bought; at base flows the overflow hardly triggers and costs no Apes.
The play meter (removed in D65) bought more Apes under heavy play (sudden popularity 1,106 against 830); raising
`maxSweepWei` to 0.1 ETH recovers most of that (1,074).

**The opening hour (sim/results/launch.md).** First-hour fees average 39% if volume comes evenly (19.5 ETH on 50 ETH
traded), 29% if it rises toward minute 60, 12% if traders wait for 15% or less. A 1 ETH buy at minute 0 needs 89 ETH of
later buying to break even (minute 30: 33 ETH; minute 50: 15 ETH); sold a minute later it returns 0.099 ETH. The 69%
sell fee for the first ~20 minutes may get the coin labelled a honeypot by wallet scanners (the owner's accepted risk).

**Buyback cadence (sim/results/burner.md).** With the game's surplus alone the cadence spends 100% of the inflow at
every activity level; with 5 ETH a day of fee overflow and light play (50-150 draws a day) it spends 91-94% and the
backlog settles at about 10-13 ETH (without the 1% backlog term, which D64 added for this, 31-45% and growing). A 1 ETH
slice fits the 3% impact limit from about 67 ETH of pool depth (0.74 ETH at a 50 ETH FDV).

**Keepers (sim/results/keepers.md, maintenance.md).** The allowance carries maintenance up to an average basefee of
about 0.58 gwei when every draw runs its own upkeep through the DrawRouter, 0.9-1.1 gwei in batches of three to ten;
listing the opening board costs 0.006-0.15 ETH of the 0.2 ETH opening allowance at 0.1-3 gwei. Over two years at 150
draws a day the game keeps 15-71 ETH of unspent allowance as profit at today's gas; if gas rises to 2 gwei for good,
players' draws pay 0.00026-0.0011 ETH each for the upkeep the allowance cannot.

**K (sim/results/throughput.md, fork, the 50-row board, re-run on the D65 code).** Refunds of issued draws: K 3 0.3%
(4 of 1,425 issued), K 4 0.9%, K 5 1.2%; completion 39.0% / 40.4% / 42.8% of attempts. Launch K 3 (D65): at launch
volumes the throughput is not needed and a refunded first draw costs the player its VRF fee; raise K when queues form.

`sim/economics.py` (the older single-lead-Ape model, re-run with the D64 values) is reported in docs/ECONOMICS.md;
`sim/pool.py` is the primary model.

## 5. Tests

Pinned fork: Ethereum mainnet block **26,284,000**, served by a local anvil fork (archive data from public gateways).
Real BAYC, Shapes, FWA factory + implementation + VRF service (callbacks through the real service), FWA token and hook,
Uniswap v4 PoolManager, Seaport 1.6. Final run on the D68 code (forge 1.5.1, `docs/receipts/test-run.txt`): 178 tests in the main run, 3 gas receipts, 3 throughput configurations, all passing:

| Suite | Tests | Result |
| --- | --- | --- |
| test/fork/Market.t.sol (launch without ETH, the D64 opening curve (69% falling 1 point a minute, buys and sells, exact-output buys), routes, exemptions, fee governance, ≤ 10%) | 9 | pass |
| test/fork/FwaPool.t.sol (transfer lock, relay, buy route, pool ownership, pre-activation block) | 5 | pass |
| test/fork/Funding.t.sol (prolonged funding, contributions, strays, a holder sale at the live bid, Seaport fill, no piecemeal board, activation check, keepers paid for the opening board from the allowance; D66: an adapter prefund neither blocks nor reprices a fill; D68: other ETH arriving during a fill does not lower the price; stray ETH in the pool owner flushed to the vault) | 14 | pass |
| test/fork/Game.t.sol (the D45 board, Pack contents, costs and prices, booking to the wei, sustained play, in-flight bound, failed delivery, keeper interruption, FWA cooldown/edge, pause, keepers; D68: a Shapes mint fee change recounts the replacement debt) | 12 | pass |
| test/fork/Collection.t.sol (decay by credited gameplay, many Apes, wins, milestone, failed delivery, listing parameters; D64: the 50-row values, the big-prize release; D65: expectations restated for K 3; D66: a 1-wei reference floored, maintenance keeps working; D67: no release for a pool-self win) + growth suite | 14 + 1 | pass |
| test/fork/Bid.t.sol (threshold fill then metered, the relative ceiling, the game's capital first, permissionless rewarded sweep, owner parameters) + flow suite (D65: the fee overflow only once the game is active and the bid full, capped at the budget less the bid and one more Ape, split at the sweep; nothing before activation; the owner's share) | 12 + 5 | pass |
| test/scenario/ManyApes.t.sol (1, 20, 50 and 100 Apes on the real FWA pool; site-style draws; docs/receipts/many-apes-*.json) | 4 | pass |
| test/fork/TxCap.t.sol (every maintenance call under EIP-7825's cap with a 10% margin on a board of the heaviest Pack) | 4 | pass |
| test/fork/Packs.t.sol (redeem, open, mixed Packs, failed delivery recovered, late VRF, retirement redeems every Pack, custody boundary; D66, D67: every system address refused as purchaser) | 9 | pass |
| test/fork/Pattern.t.sol (D63: a new pattern applies to each row when next listed; owed rows recosted; bounds and ownership) | 4 | pass |
| test/fork/Outage.t.sol (no-keeper outage and recovery, delayed VRF, FWA frontend flows, minting broken, a win with minting broken, parameter changes between request and booking) | 7 | pass |
| test/fork/Revenue.t.sol (D63: the vault's share while short of an Ape, the rest to the burner; the milestone reserve locked, released on a verified win (D64: 60% on the first Ape exit, the rest on a second within 24 hours; 15% on a big prize); donations ongoing; bounded slices; same-block manipulation refused) | 8 | pass |
| test/fork/Governance.t.sol (one owner acts at once; two-step transfer and renounce; parameters and bounds; grow-only board size; the fee recipient only via the MigrationAuthority; stray-NFT sweep) | 11 | pass |
| test/fork/Migration.t.sol (D63: 72 hours and the code pin; execution switches fees; the fee recipient alone after its notice; conservation, surviving claims, incomplete settlement, a replacement successor, a successor refusing ETH, a quarantined Ape, the sunset overriding a migration) | 12 | pass |
| test/fork/Sunset.t.sol (D63: the sunset end to end with requests in flight, the auction and every wei to the burner, overpayment refunded, finality, retirement pay within the allowance, access) | 6 | pass |
| test/fork/Lifecycle.t.sol | 1 | pass |
| test/scenario/LongRun.t.sol (zero trading → win → draws continue → recovery; weak fees; 60 gwei) | 3 | pass |
| test/fork/KeeperPay.t.sol (D63: gas + 10% at 1 gwei; a full batch paid in full; above 3 gwei at 3 gwei; priority reimbursed; no work, no pay; no gas limit gets a paid call that skips its work; owner parameters) + allowance suite (no opening allowance: paid only what captures earn) | 7 + 1 | pass |
| test/fork/DrawRouter.t.sol (backlog settlement, plain and batch draws, upkeep paid to the player, guards, the measured upkeep within its budget) | 7 | pass |
| test/invariant/Invariants.t.sol (13 invariants incl. vault conservation (D64), burner conservation, milestone only on wins, surplus only to the vault and burner, the migration lock; adversarial calls; 24 runs × 40 calls) | 13 | pass |
| test/unit/Units.t.sol (two-step transfer and renounce, endless board, burner units; D64: cadence and tier bounds, the 10% exit floor) | 7 | pass |
| test/unit/Sizes.t.sol (EIP-170 for every contract; `CollectionGame` pinned at 24,053 B) | 2 | pass |
| test/fork/Gas.t.sol, test/fork/GasPrizes.t.sol, the flow gas suite in Bid.t.sol (`--isolate`, receipts; a sweep 126,362 gas metered, 211,044 with the overflow split, inside the DrawRouter's 250,000) | 3 | pass |
| test/scenario/Throughput.t.sol (the 50-row board at K 3 / 4 / 5 on the D65 code, docs/receipts/throughput/board-d65/; the D61 run on the D45 board kept) | 3 (+ 12 D61) | pass |

Also: keeper `npm run check` (6 tests); site ABI regeneration and `tsc --noEmit` (D65; `next build` not re-run; the site is not updated for D64 beyond the D65 closed-state message); sim/economics.py, sim/keepers.py,
sim/sessions.py, sim/launch.py, sim/throughput_table.py; Slither 0.11.6 on the D68 code: 92 results, 5 High, all triaged as false positives or by design (docs/AUDIT_SCOPE.md §7).

**Rehearsal** (`script/rehearse-anvil.sh`; summary in `docs/receipts/test-run.txt`, full log in
`docs/receipts/rehearsal.log`), on a fresh local anvil fork (D64 code). The board is enlarged to 160 prizes (≈ 5 ETH of
Shape and Pack backing) so the migration step has a realistic scenario. Steps:
1. Broadcast deployment with postflight (first threshold 6 ETH, 100% of `REF_PRICE_WEI`; the curve constants, cadence,
   tiers, flow and game settings checked; the Sunset and the fixed Seaport adapter wired): passed.
2. The owner's FWA relayed and the FWA pool created, owned by the pool owner.
3. Market launch with no ETH; five round trips in the first minutes pay the opening curve: 1.99 ETH of fees.
4. Simulated funding. After 21 days with nobody sweeping the live bid is still 0; one sweep fills it to the 6 ETH
   threshold; a real BAYC holder sold #1 at the bid. Funding need then 6.403 ETH (160-row board, 1 ETH reserve, 0.2
   ETH opening keeper allowance).
5. The keeper bot listed the 160-prize board (calls under EIP-7825's cap), was paid 0.0027 ETH from the opening
   allowance, and activated the game.
6. Player draws through the DrawRouter the site's way (the upkeep measured first: 0.10M gas with nothing to do, 0.42M
   and 0.30M with bookings) and through FWA, VRF through the real service: 6 fulfilled, 0.109 ETH revenue.
7. The owner sets a new pattern (`setPattern`; a stranger's call refused): 160 prizes live, nothing owed.
8. Two more Apes bought from real holders at the live bid; with the bid full and the vault holding more than the bid
   and one more Ape (19.76 ETH against 6.05 + 6), the next sweep split the trading fees since the last one: 0.0738 ETH
   (half of 0.1476) to buybacks, which the keeper bot's
   buyback job spent at once (718,958 coins burned); three Apes listed, exposure 1.84%.
9. Postflight re-run after play: passed.
10. Keeper pay on real transactions at 1.02 gwei: paid ÷ actual cost 1.245 (1 draw booked), 1.203 (3), 1.177 (10),
    within the allowance.
11. **The trading-fee recipient alone**: a direct change at the hook (even by the owner), a stranger's proposal and
    execution before 72 hours refused; a third party executes after the notice; fees reach the new recipient while
    the game plays on.
12. **The full migration**: a stranger's proposal and execution before 72 hours refused; a third party executes (FWA
    purchases stop; fees switch to the successor); moving NFTs before V1 settled refused; a draw in flight settles and an
    expired one becomes the player's refund credit (0.019 ETH); the keeper unwinds V1; the successor receives the three
    Apes and 26.0856 ETH = vault before 19.7622 + returned by the game 6.3234, **exact**, V1 vault left 0; the burner
    held nothing to move (its bucket had been spent in step 8).

Totals for D63: 166 tests (164 in the main run: fork, scenario, invariant, unit; 2 gas), all pass; the 12 throughput
configurations are the D61 run. The rehearsal completed every step; keeper `npm run check` passes 6 of 6.

Limitations: fork-only (no testnet); VRF callbacks are impersonated; the Seaport adapter is tested with an
on-chain-validated order; FWA staking is a mock.

## 6. Security

Implemented: custody with narrow functions; no withdraw or mint paths; one marketplace adapter fixed at deployment,
bounded by the bid and by custody postconditions; milestone trigger read from FWA with no administration; exposure cap and never-rising
notionals in the custodian; retirement to buybacks only; the purchase gate is safe with no keeper; every sync step is
isolated; booked revenue is a lower bound trued up to ETH received; the launch cannot lock
ETH; Draw Packs custody (only a Pack's owner opens, redeems or unseals it; the pool owner accepts Packs only from its own
mint or FWA; redeemed ETH goes only to the game); a board change reaches no custody; settlement exposure bounded by the
inventory (D48). The bid cannot jump: it rises only from what the vault could pay, at a public rate, and stalls without
records (D57). Migration moves assets only after a public 72-hour notice and only to the proposed successor, whose code is pinned at
proposal; the trading-fee recipient changes only through the same notice; the instant sunset sends everything to
buy-and-burn and nowhere else (D63).

Trust, stated plainly (D57, docs/SECURITY.md "Administration"): one owner changes everything at once: the economics,
how surplus is split between the vault and buybacks, the bid, keeper pay, and unrelated NFTs sent to a contract by
mistake (never the collection, Shapes or Packs); after 72 hours' notice, where future trading fees go, or where the
Apes and treasury go in a migration; and at once, the sunset, whose only destination is buy-and-burn. No administrative call withdraws prizes
in play, game cash or committed buyback ETH directly. Renouncing ownership freezes every parameter. Other residuals: the
gate cannot see the settlement queue; buyback price checks are per block; ShapePacks is first-party code, unaudited, with no
upgrade path (in the audit scope); CollectionGame 23,384 B (1,192 B under the 24,576 B limit), CollectionPoolOwner
20,413 B; no audit.

## 7. Decisions

Approved: D45 board, 5% markup and allocation (now adjustable); D46 board changes (immediate); D47 limit 10; 100 ETH FDV
single-sided launch; continuity mechanics; 0.05 ETH seed; retirement design; Ape-only scope, no farming or airdrop
(D56); DrawRouter and open-without-an-Ape (D53); one owner with broad parameters, the standing bid, the splitter, the
open KeeperFund and the simple migration (D57, the owner's direction); every Ape in the draw on one decay rule, the
board growing on demand to a 15% target, Permanent Collection's live bid, gas-plus-fee keeper pay and KeeperFund's
surplus returned to the game (D59, the owner's direction, launch values chosen from the models); temporary closure above the ≈ 1.1 gwei
maintenance ceiling, with no recurring operator subsidy; D8, D15, D24, D27, D28, D31; the simplification pass, the
Sunset, keeper pay of gas plus 10% and the fee recipient on its own notice (D63); the flywheel items A-D (D64; the site,
E, F and G not built).

Still for you:
1. **D57/D63 review**: the trust it implies (above and docs/SECURITY.md); the 72-hour notice with the code pinned is the
   protection on the Apes, the treasury and the fee recipient; the sunset is instant and ends in buy-and-burn only.
2. **D9 identity**: approved by you on 2026-10-29: Ape Draw / ADRAW, subject to legal clearance (immutable once
   deployed); repeat the on-chain name check on the day.
3. On the day: the bid's reference price from the live floor (`REF_PRICE_WEI`; the first activation threshold is 100%
   of it, so the opening fees buy the first Ape at about that price).
5. **K (D64)**: 4 stays by the agreed rule; on the 50-row board it refunds 0.9% of issued draws in the fork study
   against 0.3% at K 3 (which completes 3.5% fewer). `setMaxInFlight` at any time.
4. **D60/D61 (resolved by the owner's direction)**: the relative bid ceiling
   at 120% of the last price with a slow climb above it (a hard stop would halt buying for good after a jump in the
   floor; §3i, §3j); bounded player upkeep; every transaction under the gas cap. `maxPrice` stays 0 (an absolute brake,
   optional).

Then commission the independent security audit (docs/AUDIT_SCOPE.md) and the legal review. The coin does not launch
before both clear.

## 8. Launch requirements (docs/DEPLOY.md, LAUNCH_CHECKLIST.md)

- The owner address (`OWNER`); deploying wallet with ≈ 0.036-0.047 ETH gas at 1 gwei (deployment 36.2M gas,
  docs/receipts/gas.json); no keeper fund seed (D63).
- ≈ 51,100 FWA in the owner's FWA wallet (or ≈ 0.17 ETH via the buy route) + ≈ 0.01-0.05 ETH gas.
- 0 ETH liquidity; one owner transaction to launch.
- Protocol-funded before activation: first BAYC (at the live bid, 100% of the reference) + about 2.87 ETH (the 1.666
  ETH board, the 1 ETH reserve and the 0.2 ETH opening keeper allowance), from trading fees (the opening curve's first
  hour) or optional contributions.
- Owner signatures: deploy broadcast; FWA relay + `createPool`; `launch`. Nothing else is required to run. Board
  changes later: one owner transaction (`setPattern`), applied to each row as it is next listed.
- The site shows "technically ready" (activation possible) separately from "awaiting the first Ape and capital"; technically
  ready is not launched.
- Decide: the items in §7. Commission the independent security audit (docs/AUDIT_SCOPE.md) and the legal review of the
  paid chance-based game, the Terms, the coin and the name; both are launch requirements.

## 9. Remaining failure modes

- Trading dries up after a win: Shape and Pack draws stay open (D53) but no Ape can be won until the continuity reserve
  and fees fund the next one (§4, ECONOMICS §7, §9).
- **Average gas above ≈ 1.1 gwei**: maintenance does not pay for itself; keepers are paid only what the allowance holds
  and players' draws through the DrawRouter pay the difference; if nobody runs it, won prizes stay off the board until
  the purchase gate closes the game. Safe and solvent, but closed until gas falls or someone runs maintenance unpaid
  (D49, D59, D63).
- **The live bid without sellers or with a crashing floor (D59-D61)**: above 120% of the last price the bid keeps
  rising 0.0025 ETH per 300 blocks while the vault has funds, and the first seller is paid all of it (+48% over the
  floor after 30 days without sellers in the model, +198% after six months; uncapped it was +576% and +3,576%); a floor
  that halves overnight is still bought at the old bid (≈ +52%). After a sudden rise in the floor the bid needs time to
  reach it above the ceiling (≈ 81 days for an overnight doubling). `maxPrice` (0 at launch) is the absolute brake.
- **A heavier board (D61)**: a board whose prizes need more gas per listing than the launch board's heaviest Pack needs
  its `maxPerCall` measured before `setPattern`; a batch above the gas cap would stop restocking until lowered.
- **Player upkeep (D60)**: a draw does the upkeep only when the site's measurement is light (≤ 2.5M gas); if the
  state changes before inclusion and the upkeep needs more than its budget, it fails alone and the player loses that
  gas (at most the budget) without a payment; the draw stands. Heavy work waits for keepers.
- **Many Apes (D59, D64)**: on the 50-row board the 20% target binds from about 10-20 Apes; more decay grows the board
  instead of improving the Ape odds (≈ 1 in 1,400-1,650 per draw). Not a failure, but the site must not suggest the odds
  keep rising.
- **Little trading (D59, D64)**: gameplay starts only once fees fund the first Ape and the opening board; the opening
  curve's first hour does it on day 1 in every modelled scenario (day 257 without it at 0.5 ETH a day of trading).
- **The opening curve (D64)**: a 69% sell fee in the first ~20 minutes may get the coin labelled a honeypot by wallet
  scanners, and cached labels can outlive the curve. Mitigation: the scanner plan in docs/LAUNCH_CHECKLIST.md (publish
  the curve, pre-notify the common checkers, re-check at minute ~70). The owner chose to keep 69% on sells
  (2026-10-30) rather than a lower sell peak (30-40%, which would accept some early dumping). Exact-output buys pay the same share as
  exact-input ones.
- **Refunds (D64, D65)**: at the launch K 3, 0.3% of issued draws in the fork study on the 50-row board (0.9% at K 4;
  heavy demand, a lazy keeper); the player gets the price back and loses the VRF fee.
- **Day-one opening depends on the first hour (D64)**: the game opens on day 1 only if about 50 ETH trades through the
  curve's first hour (an assumption); otherwise the funding bar runs until fees, contributions or the owner fund the
  first Ape. The contributions path stays visible from minute one; the owner has not committed to fund the first Ape and will
  decide as it happens (docs/LAUNCH_CHECKLIST.md item 7).
- **Heavy play without the play meter (D65)**: the bid climbs at the constant 0.05 ETH per 300 blocks; under sustained
  heavy play the owner raises `maxSweepWei` (0.1 ETH recovers most of what the meter added; docs/RUNBOOK.md).
- **Buybacks with a large fee overflow and little play (D64)**: the backlog term spends it, with about 10-13 ETH waiting
  at 5 ETH a day of overflow (sim/results/burner.md).
- **Block builders as keepers (D59)**: a keeper that builds its own block can pay itself priority and be reimbursed up
  to the 3 gwei cap; the cap bounds it.
- A careless or compromised owner key: bad economics at once (including keeper pay up to the allowance); a sunset at
  once (everything to buy-and-burn); and, with 72 hours' public notice, trading fees, or a migration of the Apes and
  treasury, to a contract of its choosing. A fee recipient that refuses ETH makes swaps revert until another is executed
  after its notice. Mitigations: a hardware key or
  multisig as the owner, transfer in two steps, renounce when the system no longer needs changes.
- Nobody sweeps the bid (no draws, no keeper, no waiting seller): the bid stays where it is and no Ape is bought until
  someone does. Safe, not stuck: anyone can `sweep` and is rewarded.
- Migration: FWA unable to settle blocks the hand-over; a mistaken successor can be replaced by a new proposal (72 hours)
  for whatever has not moved.
- FWA changes (edge above 5%, cooldown, global switches): purchases close or settle as FWA allows. FWA's per-transaction
  limit is copied into each pool at creation and has no setter, so the gate's `maxBatch` (read then) stays exact.
- Public RPC limits for keepers: keepers need archive-capable, range-tolerant RPCs (two independent providers).

## 10. Current state

Repository `ripe0x/collection-games`, branch `claude/focused-edison-5n720n`; see the branch head for the final commit.
Not merged; nothing deployed, broadcast, published or spent. The D63 simplification pass and the D64 flywheel build
(items A-D of docs/review/FLYWHEEL_REVIEW.md) are implemented, tested and rehearsed; the site's loop page (H) is not
built, and the site is not updated for D64.
Remaining before mainnet: the decisions in §7; independent security audit; legal review; final `FWA_IN_WEI` and gas quotes on the day; Etherscan verification;
keeper hosting; a decision on publishing the site.
