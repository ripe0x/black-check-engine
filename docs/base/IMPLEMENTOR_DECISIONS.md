# Implementor decisions

A running record of every decision the build brief left open or that departs from it. Numbering is stable; an entry
that was later changed is marked **Revised** and keeps its number. Each entry gives: what was decided, why,
alternatives, trade-offs, reversibility, where it is enforced (permanent code vs adjustable governance) and any owner
action.

Abbreviations: **P** = enforced by permanent code (changing it means a new deployment); **G48** / **G14** = in entries
written before D54, adjustable by the 48-hour parameter / 14-day module timelock; since D54 both are **the owner Safe,
at once**, within the same permanent bounds; **Deploy** = a deploy-time value.

## Needs owner review

These are irreversible, economically material, or likely to be controversial. Everything else below is routine.

| # | Decision | Owner action |
| --- | --- | --- |
| D7 / D38 | Market opens with **single-sided coin liquidity, 0 ETH**; `launch` now refuses ETH (it could never be reached nor removed). The opening tick sets the opening valuation: **recommended 161,200 ≈ 100 ETH FDV** (a 5 ETH buy takes 4.6% of supply; a block-0 sniper roughly breaks even, versus +13-16% at 50 ETH FDV) | approved: tick 161,200 (≈ 100 ETH FDV), single-sided, 0 ETH |
| D8 | 100% of the 1B supply to protocol liquidity; no other allocation | approved |
| D9 (revised by D56) | Coin identity: **Ape Draw (ADRAW)**, an Ape-specific coin for the Ape game (the owner reversed the collection-neutral direction of D52). No conflict found for ADRAW by web search; not a trademark search. **Approved by the owner 2026-10-29** | legal clearance before deployment (immutable once deployed); repeat the conflict check on the day |
| D15 | Collection captures book their FWA proceeds as game revenue and the NFT's cost is **not** charged to game profit (paid by fees/contributions, or by the continuity reserve which was itself a distribution) | approved |
| D16 | The game ledger (`CollectionGame`) is **permanent**; replaceable logic is in view-only modules | approved (governance design kept) |
| D19 | Retirement sells collection NFTs by a 30-day descending auction (150% → 25% of reference cost); proceeds and the vault's balance fund buybacks | approved (retirement design kept) |
| D21 (superseded by D57) | `maxPrice` 15 ETH and immutable `hardMaxPrice` 30 ETH. Replaced by the standing bid's owner-set reference price (the live floor on the day, 6 ETH placeholder) and cap (12 ETH placeholder); nothing about the bid is immutable | set `REF_PRICE_WEI` and `MAX_PRICE_WEI` on the day |
| D24 | The owner's FWA reaches the pool owner via a sell-then-buy round trip on FWA's pool (2.02% measured: 51,015 FWA in → 50,000 out) because FWA blocks wallet-to-contract transfers | approved; provide ~51,100 FWA (or ≈ 0.17 ETH via the buy route) |
| D25 / **D47** | In-flight limit **10** at launch (was 5): the gate assumes every purchase may be a 5-draw batch, so up to 14 requests can be unsettled. On the D45 board at 100 rows: 0 refunds at 3, 4, 5 and 10, and 21% more completed draws at 10 than at 5; FWA's VRF layer separately caps 10 requests awaiting a word per pool (a batch beyond it reverts before any fee). Lower it (G48) if the board is ever cut to ~50 rows (0.8% refunds there; 1.3% in the D59 re-run) | approved |
| D28 (removed) | The funded-decay gate is **removed** as requested: settled gameplay alone advances the lead's schedule (cap and FWA rules still apply). Cost in the model: availability 91% → 87% at 1× trading, 81% → 75% at 0.5×; first win p50 101 → 88 ETH; wins 8.0 → 8.5 per 1,000 ETH | approved |
| D29 (revised twice) | Operating allocation **5% of each captured prize's own cost** (frozen at listing), approved with D45. ≈ 0.00080 ETH per draw; it pays for maintenance only up to ≈ 1.1 gwei (D49). 3% would not pay for it even at 1 gwei. Now owner-adjustable 0-100% at any time (D57) | approved |
| D31 (revised by D53) | With **zero or declining trading volume** no new NFT is funded after a win; the game now stays open for Shapes and Packs meanwhile (D53). Under the original closed rule: on the D45 board availability 2% at 0×, 28% at 0.25×, 50% at 0.5×, 78% at 1× | approved |
| D27 | Demand-driven board growth (every 100 ETH, up to 100 rows) in addition to exposure-driven growth | approved as configured: no demand growth beyond the 100-row opening board (`demandMaxBoard` = 100); rows are added only when the exposure policy calls for them and the vault funds them in full |
| **D45** | **Opening board (approved)**: 100 prizes, 48 × 0.01 Shape, 32 × 0.02 Pack, 7 × 0.03 Pack, 1 × 0.04 Pack, 7 × 0.05 Shape, 1 × 0.06 Pack, 1 × 0.1 Shape, 1 × 0.15 Pack, 1 × 0.5 Shape, 1 × 1 ETH Shape; Packs of the fewest Shapes; markup 5%, operating allocation 5%. FWA fee + VRF **0.019834 ETH** at 1 gwei (≈ 0.02045 with the player's transaction gas); **29.9%** of draws return a prize worth at least FWA fee + VRF (gas excluded; not a profit chance; not an improvement on D42's 30.9%); return **76.0%**; opening board **3.681 ETH**; per 1,000 ETH: distributable surplus 37.5 → 22.3 continuity + **15.2 coin buybacks** | approved |
| **D46** (revised by D54) | **The board can be changed or shuffled after deployment**: `CollectionGame.setBoard` by the owner Safe, at once (was the 48-hour timelock). Matching listings are kept, the rest replaced at the next windows with only their mint fees written off | approved |
| **D49** (premium revised by D53) | **KeeperFund premium 5% (replaced by a priority-fee refund, D53), max age bounty 0.00025 ETH (approved); tip cap raised 0.01 → 0.05 ETH (new, needed to list 20 prizes in one call above ~0.65 gwei).** Maintenance pays for itself only up to ≈ **1.1 gwei** average basefee; above it the game closes (safely) until gas falls or KeeperFund is funded | approved: tip cap 0.05 ETH; temporary closure above the ≈ 1.1 gwei ceiling accepted; no recurring operator subsidy |
| D42 (superseded) | The first Draw Packs board (47 × 0.01, 28 × 0.02, 16 × 0.03, 7 × 0.05, 1 × 0.1, 1 × 0.5) is replaced by D45 | none |
| D37 (superseded) | The 0.05 ETH board (40 × 0.05, 6 × 0.1, 3 × 0.5, 1 × 1) is replaced by D42 | none |
| **D44** | **KeeperFund top-ups from trading fees capped at 1 ETH over the vault's life** (`KEEPER_TOP_UP_LIMIT`, permanent). Without it, at 2 gwei the fees paid ≈ 30 ETH to keepers and availability fell from 82% to 52%; with it, 79% | approved |
| D41 | KeeperFund seed **0.05 ETH** (was 0.5); keepers are paid from trading fees topped up by `sync` (≤ 0.15 ETH balance target from fees, ≤ 1 ETH in total, D44; both owner-adjustable since D57) | approved |
| D52 (superseded by D56) | The shared-coin layer for further collection games is **not** part of the launch: the attached-game deploy path and its tests are removed; only the burner's deposit-only milestone-reserve registration remains | none |
| **D53** | **Keepers do only what the protocol must** (owner's direction): settling draws is left to FWA's callback and to players (a stateless `DrawRouter` settles waiting draws before each draw, no tip); KeeperFund refunds gas at basefee **plus the priority fee actually paid, up to 0.05 gwei**, instead of a 5% premium (which at today's ~0.1 gwei basefee would not cover a keeper's priority fee and left the game closed most of the time in the model); the game opens with its first Ape and **stays open for Shapes and Packs when no Ape is in the draw**. Removed the collection check from `CollectionGame._admit` (24,445 → 24,310 B) | review; set `priorityCap` from live fees before deployment |
| **D54** (superseded by D57) | **Administration without a timelock** (owner's direction): the owner Safe holds every administrative role and acts at once within the permanent bounds. Indirect extraction paths closed for it: flexible revenue destinations removed (100% to buybacks; no destination can be added), KeeperFund payers and overflow fixed at wiring, a vault-enforced immutable bid ceiling (15% of `hardMaxPrice` after each purchase, rising to it over 21 days) whatever the strategy, a 5% markup floor in the game, tighter keeper and burner bounds | review the custody analysis (docs/SECURITY.md "Administration without delay") |
| **D55** (simplified by D57) | **Secure one-way migration** off FWA V2 (owner's requirement): owner proposal, independent signer approval of exact code, 24 hours, permissionless batched retryable execution; Apes and treasury capital straight to the approved successor; committed buyback ETH untouched; fees redirected only after receipts and readiness (docs/MIGRATION.md) | appoint the independent security signer (`MIGRATION_SIGNER`); accept the remaining trust assumptions (docs/MIGRATION.md) |
| **D57** | **Simplification (owner's direction): one owner, broad parameters, a new bid, a simple migration.** One `Admin` contract names the owner of every contract (two-step transfer, renounce); the Safe and role model is gone. Every parameter is owner-adjustable with broad bounds (markup and allocation 0-100%, fee ≤ 10%, exposure ≤ 50%, ...). The bid is a standing offer that restarts at 90% of the last price paid and rises 5% of it a day, only from a level the vault could pay, and stalls without updates; no `hardMaxPrice`, ceiling or inventory limit. The router is a splitter (owner-set splits, today none: 100% buybacks). KeeperFund has no cap or automatic overflow; the owner moves surplus to the game and sets payers; no tip above `maxBasefee` (3 gwei), no tip cap, bounty start/max/ramp adjustable. The DrawRouter runs the upkeep after a player's draw and passes the tip to the player. Migration: owner proposal, 24 hours, plain transfers to the successor; the owner sets the hook's fee recipient directly. Removed: the independent signer, code-hash binding, receipt and readiness checks, the immutable bid ceiling, the 5% markup floor, the fixed KeeperFund payer and overflow, the 90% router minimum and freeze, `RisingBidStrategy` | review; set the bid's reference price and cap on the day |
| **D58** | **Autonomy review** (owner's goal: run for six months untended): fixed now: no bid cap by default (`maxPrice` 0 = none), buyback slices route the router first, sell-page bid recording. **Proposed, not implemented**: A, buy only to keep one Ape waiting and send vault ETH above a buffer to buybacks, bid 80% / +20% a day; B, keeper pay indexed to gas (cutoff follows the 30-day average, allocation = upkeep gas); C, KeeperFund returns its own surplus (docs/AUTONOMY_REVIEW.md) | approve or reject A, B, C |
| **D56** | **Ape-specific launch only**: no farming, no airdrop, no token reserve (100% of the 1B supply in protocol liquidity, as before; none of it was ever implemented); no multi-game layer; no ENGINE or FWA-staking destinations; Ape Draw (ADRAW) kept as the working identity | a goodwill claim for $APESTR holders, if any, stays outside the protocol (owner-funded, separate optional contract) |
| **D59** | **Acquisition and game economics** (owner's decisions): every Ape in the draw on one decay rule, the board growing on demand to a 15% exposure target, Permanent Collection's live bid, keeper pay = gas + flat fee, KeeperFund surplus back to the game | approved |
| **D60** | **Before the audit freeze**: flat keeper fee at most once an hour; a relative bid ceiling (150% of the last price) above which the bid climbs at a tenth of the rate rather than stopping (a hard ceiling stalls for good when the floor jumps; `slowSweepWei` 0 makes it hard); player upkeep bounded by a gas budget the site sets from a measurement, heavy work left to keepers | approved (owner's direction; the ceiling's slow climb chosen from the model, flagged) |
| **D61** | **Gas cap, ceiling, name**: every maintenance call under EIP-7825's 16,777,216-gas cap (the board's `maxPerCall`, 8 at launch; withdrawals 10 per call; worst cases measured on a board of the heaviest Pack); bid ceiling 120% of the last price, then 0.0025 ETH per 300 blocks (the owner did not want to pay 50% over); Ape Draw / ADRAW approved | approved |
| **D62** | **Trust review follow-up**: `setPayer` removed (only the game requests KeeperFund tips); an owner `sweepNFT` on every governed contract for unrelated ERC-721s, never the collection, Shapes or Draw Packs (recorded once at deployment); donations of ETH and Apes unchanged; no delay on fee recipient or splits; no bounds added to keeper pay or the bid; single owner kept | approved |

Decisions D36, D39, D40 (live purchase gate, isolated sync steps, booking lower bound with true-up) D43 (Draw Packs
as ordinary prizes, minted by the pool owner) and D48 (settlement exposure bounded by the inventory) are safety, accounting and integration decisions with no economic choice
in them; they are listed below.

## Reference review and reuse

**D1. New repository, selective reuse.** The work is in `ripe0x/collection-games` (private, verified through the
GitHub API: `"private": true`), branch `claude/focused-edison-5n720n`. Draw Shapes was not modified. Reference
commit confirmed: PR #9 head is still `0020bea6bdf330cdd2b79b0a669b01573e2f5285` on 2026-10-27, no later changes.
Reused with provenance (NOTICE.md): the FWA walk/booking/admission/capital logic, the hook fee placement and block-open
price, the buyback protections, KeeperFund, FwaFeeBuyer, the deploy-and-postflight pattern, the fork-test helpers.
Not reused: GenesisFarm, Converter, EngineRenderer, SwapPolicy (gate), PrizeVault (replaced by FundingVault), the
promotion machinery, the conversion bonus. Alternative: fork the whole repo — rejected (brief preference; ENGINE's
farm/gate/conversion would be dead code in custody contracts).

**D2. FwaGame split.** FwaGame was 23.5 KB. Pool ownership and NFT custody moved to `CollectionPoolOwner`; the game
ledger stays in `CollectionGame` (21.4 KB, 3.2 KB headroom). Collection listing rules live in the pool owner because it
owns the NFTs and must enforce the exposure cap and commitments itself.

## Live verification (fork block 26,284,000; live reads 2026-10-27)

**D3. External state.** FWA factory `0xf5a3…300c`, implementation `0xeaa4…eb31` (unchanged since Draw Shapes),
creation fee 50,000 FWA, `inventoryChangeCooldown` 0 (read live everywhere, never hardcoded), `edgeBps` 500,
`selectionSlippageBps` 1,000, `maxAcquisitionsPerTx` 5, `maxOutstandingRequestsPerPool` 10, `betaAccess` **false**
(changed since Draw Shapes: no FWAIR PFP needed), `maxPoolsPerWallet` 1 (the pool owner contract can create exactly
one pool), `poolCreationEnabled` true. Shapes mint fee 0.001 ETH. BAYC `0xBC4C…f13D` (10,000 tokens). Seaport 1.6 at
`0x0000…eB395` has code. Uniswap v4 PoolManager `0x0000…8A90`.

## Coin and market

**D4. Hook fees.** 3%/3% ordinary (G48, hard cap 5% in the hook, P). Anti-sniper schedule immutable in the hook,
block based from the initialisation block: 15% / 10% / 5% for blocks 0-4 / 5-14 / 15-34, buys only (P, values from the
deploy config bounded at ≤ 20% and ≤ 100 blocks). It can never return: it is keyed to the one-time initialisation.
No separate swap-policy module: the brief's "replaceable fee policy" is the bounded timelocked setter, and the caps are
enforced in the hook regardless. Alternative: keep Draw Shapes' policy module — rejected as one more contract with no
power the setter lacks.

**D5. Exemptions.** Fixed at wiring to exactly one sender: the CollectionBurner, which calls `PoolManager.swap`
itself (P). ProtocolLiquidity never swaps, so it is not exempt. No router can ever be exempt.

**D6. Exact-output sells unsupported.** The fee is charged in ETH; an exact-ETH-output sell cannot pay an ETH fee
without breaking its exact output. Such swaps revert `ExactOutputSellUnsupported`. Supported: exact-in buys,
exact-out buys, exact-in sells (tested). Aggregators that route exact-output sells must fall back to exact input.

**D7. Single-sided launch (Needs owner review).** `ProtocolLiquidity.launch(startTick)` puts the whole coin supply in
one position over `[MIN, startTick)`; any ETH sent is placed as a separate ETH-only position just above the start
(bid depth for sellers below the launch price). The market therefore opens with **zero ETH**: buyers' ETH is what
pairs the position. Depth equals a full-range pool holding ETH equal to the opening fully diluted value: e.g. at an
opening FDV of 50 ETH, a 1 ETH buy moves price about 4%. This is the minimum practical initial liquidity; the brief
said not to conceal the ETH requirement, so the trade-off is stated plainly: a token-only launch has no ETH bid until
someone buys, so early sellers can only sell what was bought. Alternative: a two-sided full-range seed (Draw Shapes)
needs ETH ≈ FDV. Not reversible after launch. **Revised by D38**: the optional ETH position was removed, because it
could never be used (see D38).

**D8. Supply 1,000,000,000 (18 decimals), 100% to protocol liquidity.** No farm, no team, no presale: committing all
of it to the permanent position leaves no discretionary inventory. Rounding dust is burned at launch. (P)

**D9. Identity.** **Ape Draw / ADRAW**, approved by the owner on 2026-10-29 (subject to legal clearance) (`script/LaunchConfig.sol`, `script/env/mainnet.env`, site default). A web search on 2026-10-28 found no token or project named "ADRAW" or "Ape Draw" (nearest: ARAW, KrypDraw's DRAW, ADreward's AD). That is not a trademark search: "Ape" next to a BAYC prize sits close to Yuga Labs' marks and ApeCoin, so the name is part of the legal review, and an on-chain token search (Etherscan, CoinGecko) is repeated on deployment day.

## Governance

**D10. Two timelocks plus guardian.** OpenZeppelin `TimelockController` ×2 (48 hours: bounded parameters; 14 days:
modules, adapters, destinations, retirement), both proposed and executed by the owner Safe; nobody administers them.
`Governed` checks on every call that the calling timelock's current delay is at least the floor, so lowering a delay
disables that timelock's powers rather than shortening notice (P). The guardian (Safe) can only pause/resume new
purchases and launch the market. The deployer's one-shot `wire` rights end at wiring (postflight checks).

## Custody and modules

**D11. Permanent contracts.** CollectionToken, CollectionHook, ProtocolLiquidity, FundingVault, CollectionPoolOwner,
CollectionGame, RevenueRouter, CollectionBurner, MilestoneReserve, KeeperFund. Replaceable (14 days):
BoardPolicy, PricingPolicy, CollectionListingStrategy, CapitalPolicy, RisingBidStrategy, marketplace adapters,
flexible revenue destinations. Modules are views (adapters execute only inside vault postconditions).

**D12. Purchase gate.** The pool owner is FWA's purchase operator: `canPurchase` returns true only while a collection
NFT is Active in the draw (lead first, at most three FWA reads to stay inside FWA's 100,000-gas stipend; fails closed).
This binds direct FWA purchases atomically at request time. It cannot see requests ahead in the settlement queue, so
a purchase admitted while the last NFT is in the draw can still settle after it is won (documented, not claimed atomic).
`setBool(ACQUISITIONS_ENABLED)` is additionally driven by `sync` for the ordinary admission rules (fill, outstanding,
edge, cooldown, pause), as in Draw Shapes.

**D13. Exposure cap enforced at action time against FWA's active listing count.** `exposure = Σ refCost_i/notional_i
/ activeListingCount` (verified on fork: 3.92% for one 6-ETH Ape at 3 ETH with 50 Shapes, as the brief computes). Every
listing and every reprice made by the pool owner keeps it ≤ cap (≤ 8%, P). Between actions, Shape captures reduce the
count and raise exposure transiently (by at most 1/minFill, 25% at the 80% fill rule) until replacements list.

**D14. Lead opening defers, extras open higher.** A lead lists only at its opening notional (50% of cost); if the board
is too small for that under the cap it waits. Additional NFTs list at 2× cost or higher if the cap requires. No extra
lists while there is no lead. (Found by the first fork run: listing the Ape before the board published a 75 ETH
notional.)

## Accounting

**D15. Collection captures (Needs owner review).** See the table above. Rationale: the brief's
`ordinaryOperatingMargin = proceeds − ordinaryPrizeCost − mintFees − ops` and "do not charge the same expenditure
twice". Consequence: the share of each ticket attributable to the collection listing (its notional's share of FWA's
base price, ~1/N of the base per listed NFT) is earned gameplay revenue, just as a TokenWorks strategy's resale
proceeds are; the acquisition principal itself never becomes revenue or reaches buybacks. When an NFT is bought with
the continuity reserve, its cost already reduced distributions when the reserve was funded. Alternative: charge each
won NFT's cost to game profit — rejected because fee-funded acquisitions would then double count and the game would
show losses that are actually funded subsidies.

**D16. Permanent game contract.** Replacing the game would let a new contract redirect proceeds and Shape backing; a
permanent game with view-only modules keeps that trust surface closed. Trade-off: a game bug needs retirement and a
new deployment (new FWA pool, another 50,000 FWA).

**D17. Continuity reserve.** Held in the vault as a separate bucket; target = one NFT at the strategy's `maxPrice`
(capped by the immutable `hardMaxPrice`). Each distribution sends `min(60%, deficit)` there (60% is a hard cap in the
game, P), so buybacks always receive at least 40% of every distribution and all of it once the reserve is full.

## Acquisition

**D18. Rising bid, budget-capped.** Effective bid = `min(schedule, maxPrice, hardMaxPrice, budget)`. Before activation
the budget is everything the vault holds until the first NFT is bought, then zero until activation; after activation it
is what the game does not need as capital, while inventory is below `maxInventory`. In funding mode the bid therefore
rises with the funds. Direct sells and marketplace fills use the same bid. No oracle.

## Lifecycle

**D19. Retirement (Needs owner review).** 14-day notice. FWA pool retired; settlement continues; Shapes are
withdrawn and burned; game cash returns to the vault; collection NFTs are withdrawn into custody and sold by a
descending auction whose ETH goes to the burner; 30 days after retirement the vault sends everything to the burner.
Nothing can reach the owner.

**D20. Maintenance before activation.** Inventory batching rules apply only once players can buy; before activation
the board fills as fast as `listBatch` allows. Vault funding is requested at the start of `sync` so new capital is
listed in the same call.

## The 50-item board (brief section 8 "Critical 50-item board test")

**D25. The agreed 50-item board is kept, with an atomic in-flight bound (Needs owner review).** Evidence:
`test/scenario/Board50Settlement.t.sol` on the fork (real FWA pool and VRF service), seeded random arrival streams over
900 blocks each; receipts in `docs/receipts/board50*.json`. Without a bound (FWA's own limit of 10 outstanding), the
50-item board refunded 2.6% of requests in steady play, **16-21% under bursts of nine requests on one quote**, 24%
with delayed VRF words and 23% under heavy demand; a 100-item board refunded 0-2% in the same streams. A refund
returns the ticket but costs the player FWA's VRF fee. Cause: FWA settles requests in order against the live pool and
refunds a request whose fee rose more than 10% after it was quoted; on 50 items each cheap capture raises the fee
~2%, and far more once the cheap Shapes are depleted. Implemented alternative (smallest change, economics untouched):
- `CollectionPoolOwner.canPurchase` (FWA's purchase operator, atomic at request time, direct FWA purchases included)
  refuses a purchase while `maxInFlight` (launch **3**, G48, 1-10) requests are unsettled. A refused purchase reverts
  before paying anything.
- Replacements list only when nothing is in flight (D26), in small batches as soon as 3 rows are waiting.
Result on the 50-item board, launch configuration, active keeper: **0 refunds** in steady, burst, FWA-cooldown-5-min
and delayed/missing-VRF streams; 3.1% / 3.8% under sustained heavy demand (~4 pulls a minute, ~150 ETH a day);
0.5% with a lazy keeper (every 5 minutes). Cost: requests refused at request time under bursts (e.g. 104 of 252 in the
burst stream), which a player retries a few seconds later; throughput ceiling ~1 pull per block, far above realistic
demand. `maxInFlight` 4 gave 0-4% (delayed VRF 4.1%), so 3 was chosen. Reversible (G48).
**Revised (second review).** FWA asks the purchase operator once per transaction and does not pass the batch size, so
with `maxInFlight` 3 a five-draw batch arriving with two requests in flight made seven unsettled; the earlier study only
used three-draw batches and missed it. The gate now assumes every purchase is a full batch (`maxBatch`, read from FWA at
pool creation: 5): at most `maxInFlight − 1 + 5` can be unsettled, and listing and decay keep that headroom under the
exposure cap. `test/scenario/Throughput.t.sol` measured limits 3/4/5/10 × boards 50/75/100 under six seeded streams
mixing singles and five-draw batches (sim/results/throughput.md). On the original board refunds were 9-22% at 50 rows
(0.2-4% at 100). On the launch board (D37: no 0.01 ETH Shapes, so a capture barely moves the fee) refunds were 0-1 in
every configuration, and completed draws rose with the limit (50 rows: 1,334 at 3, 1,598 at 5, 1,730 at 10). At 10 on
50 rows, heavy demand with FWA's 5-minute cooldown completed fewer draws (restocks wait for an idle pool). Launch: **5**.
**Draw Packs board (D42).** Re-measured on the 100-prize board: at 100 rows, 0 refunds at every limit (3/4/5/10) and in
every stream, delayed VRF included; completed 1,715 / 1,786 / 1,870 / 2,258. On its 50-row prefix, 2-4 refunds at 3-5
and 26 (1.4%) at 10. Launch stays **5**.

**D26. Replacement cadence.** `maintenanceInterval` 5 minutes and a `listBatch` threshold of 3 rows (was 30 minutes /
20 in Draw Shapes); a restock lists up to FWA's batch maximum of 20 in one call; once activated, replacements list
only when no request is unsettled (unless the board is below the admission fill), because a listing made while
requests are in flight is staged by FWA and activated just before a later request settles. If FWA raises its
inventory cooldown the window stretches to six cooldowns (read live), so purchases stay open ≥ 5/6 of the time.
Cost: more inventory changes; each invalidates quotes of transactions still in the mempool (they revert, gas only).
Found while measuring: `listBatch` had been both the trigger and the per-call cap; it is now only the trigger.

**D27. Demand-driven board growth.** In addition to growth when the exposure cap holds back decay, the capital policy
grows the board by 25 rows after every 100 ETH of settled gameplay since the last growth (G48), up to 200 rows, if
the vault's fee/contribution ETH can fund it. Under sustained heavy demand a 100-item board keeps refunds near zero.

## Later entries

**D21. Acquisition prices are deploy-time placeholders (Needs owner review).** `maxPrice` 15 ETH (G48) and the
immutable `hardMaxPrice` 30 ETH. No oracle is used; the bid is a schedule capped by these and by the spendable budget.
Set them from the live floor on deployment day. The continuity target equals `maxPrice`, so an inflated `maxPrice`
diverts more margin from buybacks (bounded by the 60% share).

**D22. Seaport adapter scope.** Only FULL_OPEN Seaport 1.6 orders for exactly one ERC-721 of the collection, paid
entirely in native ETH, through `fulfillAdvancedOrder` with the pool owner as recipient. Royalties are whatever the order
includes. Tested on the fork with an on-chain validated order. Not registered at launch (G14 to register). Other
marketplaces need their own adapter.

**D23. Keeper.** Node/viem, simulate-then-send, primary and backup modes. KeeperFund formula unchanged from Draw
Shapes. Keepers are tipped up to a 30 gwei basefee.

**D24. FWA fee route (Needs owner review).** See table. Verified from FWA token and hook source and on the fork:
`test/fork/FwaPool.t.sol`. If FWA's hook rules change, use the buy route (`FwaFeeBuyer`, ETH).

**D28. Funded-decay gate (Needs owner review).** The economic model showed the binding constraint is funding the next
NFT, not solvency: without a gate the lead decays even when its win would leave nothing to replace it. The pool owner
now decays the lead only while another collection NFT is held or `vault.acquisitionBudget() ≥ lead refCost`; the
schedule is not reset, so once funded the notional catches up with its line. Board growth also never spends that
replacement reserve. Availability at 1× trading: 78% → 89%; at 0.5×: 58% → 76%; wins per 1,000 ETH 8.5 → 7.6. P, frozen
for all listings (a commitment stated at listing). Alternative: cap-only deferral (the brief's minimum).
**Removed (second review, at the owner's request).** `_decay` no longer checks `replacementSecured()`; cumulative settled
gameplay ETH advances the committed schedule, held only by the exposure cap (with the gate's headroom) and FWA's
repricing rule (Active, nothing unsettled). Odds never worsen (a notional never rises). Modelled cost on the launch
configuration: availability 91% → 87% at 1× trading and 81% → 75% at 0.5×; wins per 1,000 ETH 8.0 → 8.5; first win
p50 101 → 88 ETH. `replacementSecured()` remains a view (site, growth).

**D29. Operating allocation (Needs owner review).** Fork gas: a sync booking and replacing one draw costs ~695k gas.
At 3% (Draw Shapes) keepers were short above ~1 gwei with a sync per draw; at 5% they are covered to ~1.5 gwei. Excess
returns to the game as profit (KeeperFund keeps 0.5 ETH). Cost: ~0.00045 ETH (1.8% of the ticket) less margin per draw, partly returned as overflow.
**Revised (second review).** The allocation is now `opsBps` × the captured Shape's own cost, frozen at listing (D40), and
the launch value is **3%**: on the launch board's ≈ 0.068 ETH ticket that is ≈ 0.0018 ETH per draw against a ≈ 0.0009 ETH
sync at 1 gwei. Modelled: no shortfall at 1 gwei; 0.79 ETH over 1,000 ETH of gameplay at 2 gwei; large at 5 gwei
(5% would cover 2 gwei). Above that keepers batch; nothing depends on a sync per draw for safety (D36).
**Revised (Draw Packs, D42).** 5% of each captured prize's cost, the owner's value for the Pack board: ≈ 0.00081 ETH per
draw against 0.00079 for keepers batching ten draws per call at 1 gwei (6.53M gas for ten, measured) and ≈ 0.0016 for
a sync per draw (1.34M gas weighted over the board). Keepers took 43.3 of 44.6 ETH allocated over 1,000 ETH of gameplay.

**D30. Hook exemption immutable, no hook wiring.** Found while preparing the broadcast: CREATE2 through the deterministic
proxy makes the proxy the `msg.sender`, so a wiring step on the hook could never run. The single exempt sender (the
burner, deployed before the hook) is now a constructor immutable. Also: the hook-salt search uses plain `keccak256`
because `vm.computeCreate2Address` in a loop stalls `forge script` on a fork.

**D31. Zero trading volume (Needs owner review). Revised by D53:** draws now stay open for Shapes and Packs while no
collection NFT is in the draw; the text below describes the original closed rule. The brief requires closing new draws when no collection prize is
left. With no trading fees the margin earned before the first win (~4 ETH of continuity at the reference point) does not
buy a 6 ETH replacement, so the game waits closed. Solvency, settlement and refunds are unaffected. Mitigations:
contributions; a cheaper collection; lower `maxPrice`. Modelled: availability 17% at 0× trading.
**Second review.** On the launch configuration without D28: availability 21% at 0×, 59% at 0.25×, 75% at 0.5×, 87% at
1×, 96% at 2×. Trading that starts at 2× and halves every 100 / 250 / 500 ETH of gameplay gives 55% / 83% / 94%.
Investigated levers for continuity when trading declines: a longer decay distance (12× / 16×) adds 2-4 points at low
trading and costs ~10% of wins; the continuity share is already at the brief's 60% maximum; holding a second NFT
(`maxInventory` 3, the default) is what carries the game across a win. None makes the game self-sustaining at zero
trading: margin alone (≈ 3 ETH of continuity per 100 ETH played) does not replace a 6 ETH NFT before the lead is won.
No perpetual availability is promised.

**D32. Simulation model.** Python, standard library, seeded; time unit is one ETH of attempted demand, trading volume a
multiple of it (trading continues while the game is closed). Restocking is modelled as immediate (the fork settlement
study covers its timing). Keeper cost assumes a sync per draw (worst case).

**D33. Frontend.** Next.js static export reading the chain directly (Lens + contracts), wallet via injected
connector, first-connect Terms acknowledgement stored per wallet in the browser. Built and typechecked locally; not
published. Collection images come from the collection's own `tokenURI` through a public IPFS gateway.

**D34. Notice periods enforced in code.** See D10. Also: the guardian can open the market; that was a choice for
convenience (the Safe supplies any ETH), not a safety requirement.

**D35. Tests.** Foundry fork tests against a local anvil fork of mainnet at block 26,284,000 (Tenderly public archive
gateway). Invariants run 8-24 runs × 40 depth on the fork (slow: each run deploys and launches a full system).

## Second review (implementation feedback)

**D36. Purchase gate on live FWA state (safety when sync stops).** `CollectionPoolOwner.canPurchase` (FWA's purchase
operator, called by FWA for every purchase, the official FWA frontend's included) now reads only live FWA state and the
pool owner's own conservative totals, never the game ledger: in-flight bound with a full batch assumed; FWA's edge within
the game's `maxEdgeBps`; at least half the board's Shapes left after every unsettled request plus a full batch removed
one; collection exposure within the cap after the same removals; a collection NFT Active (removed by D53: draws stay
open without one). The exposure total is a running
sum maintained at listing, decay and closure; while stale it only overstates. Listing and decay leave the same headroom,
and `setExposureCap` / `setMaxInFlight` refuse values the published listings would breach, so the gate never closes on a
listing the protocol made. Measured: with no keeper, direct FWA draws stop after ~21 on the launch board, the board
still above half and exposure within the cap; a returning keeper books everything once and reopens
(`test/fork/Outage.t.sol`); invariant 19 (`invariant_liveExposureAfterInFlightSettle`). Gas ~52k cold, 46k since D53 (FWA allows
100k); before D53 the fallback check read one extra listing (worst case ~68k).

**D37. Opening board (superseded by D42).** Shapes mints only fixed denominations (0.01, 0.05, 0.1, 0.5, 1 ETH, …).
On the brief's board, 80% of draws capture a 0.01 ETH Shape whose 0.001 ETH mint fee is 9% of its backing, and FWA's
VRF fee (≈ 0.002 ETH at 1 gwei) is 8% of a 0.025 ETH ticket: the player loses ~17 points to fees that neither the coin
nor the game receives. Dropping the 0.01 tier (40 × 0.05, 6 × 0.1, 3 × 0.5, 1 × 1) cuts both to ~2-3%. Modelled at the
agreed 7.5% markup, 1 gwei: return all-in 86.6% (realised 87.1%) vs 80.4%; surplus 101 ETH vs 87 (same rules, old
board); wins and availability equal or better; opening board 5.15 ETH vs 4.35. At 5% markup: 88.5% and 78 ETH. A milder
option (10 × 0.01, 30 × 0.05, …) gives 83.5% / 89 ETH. Costs: a ≈ 0.068 ETH ticket (2.7×), fewer prizes above the ticket
(7.8% vs 20%). Settlement drift also falls to ~0 (D25). Reversible for future rows only (a board module must keep rows
in play); the opening board is a deploy value.

**D38. Launch without ETH; opening valuation (Needs owner review).** With the whole supply in one position below the
start price, the pool never holds more coins than at the start, so the price can never return above it: an ETH
position placed there (the old optional "bid depth") can never be reached by a seller nor removed. `launch` is no longer
payable. Exit liquidity is exactly the ETH buyers (and coin buybacks) put in; a round trip costs the two 3% fees only.
The depth a buyer meets equals the opening FDV (constant product on virtual reserves), so the valuation is the one
lever: at 50 ETH a 5 ETH buy takes 8.8% of supply and a block-0 sniper nets +13-16% after the 15% launch fee once 10 ETH
of buying follows; at 100 ETH, 4.6% and −1 to −2%. Recommended tick 161,200 (≈ 100 ETH FDV). sim/launch.py.

**D39. Independent recovery.** `sync` runs maintenance, collection processing, admission, distribution, proceeds
collection, Shape recovery and keeper tips each in their own `try` (`StepFailed` event); booking reads no module; a
failing listing strategy stops listing and decay but not win/return recording; the continuity share falls back to its
maximum if the capital module fails. Retirement uses no module. Tested with every module reverting
(`test_revertingModulesBlockNothingEssential`, `test_collectionWinWithModulesBroken`).

**D40. Booking that cannot be moved by configuration.** FWA fixes each request's base price at request time and deletes
it after settlement. The game books proceeds at `bookingEdgeBps` (the highest `maxEdgeBps` ever set; the gate refuses
purchases above the current one), a lower bound, and once every issued request is booked and FWA holds no owner
proceeds, books the difference to the ETH FWA actually paid (`proceedsCollected`). The operating allocation is the
listing's own frozen `opsBps` × its cost. A markup, ops, edge or settings change between listing, request and booking
cannot create profit (`test_bookingIgnoresChangesBetweenRequestAndBooking`). Other reviewed assumptions: Shape cost and
backing are per listing; `reserveTarget` changes only what is protected, never profit; continuity share is capped in
the game; growth never spends the replacement reserve.

**D41. KeeperFund funded from early fees (Needs owner review).** The deploy seed drops to 0.05 ETH (the maintenance floor
only retirement steps may spend). `sync` asks the vault to top the fund up to floor + 0.1 ETH from its general bucket
(trading fees, contributions; never continuity) whenever it holds less than 0.1 ETH, before funding the game, so the
keepers listing the opening board are paid from the first fees (`test_keepersPaidFromEarlyFeesWithMinimalSeed`).
Activation needs 0.1 ETH more from fees. Bound: because top-ups only replace what tips spent, at most ≈ 0.15 ETH of fee
capital can ever reach game profit through KeeperFund's overflow. **Revised (D44):** the lifetime total of top-ups is capped at 1 ETH.


## Draw Packs (third review)

**D43. Draw Packs as ordinary prizes; minting moves into the pool owner (P).** The owner's decision restores Draw
Packs. Reused, unmodified: `ShapePacks` and `ShapePackRenderer` from ripe0x/shape-packs, `draw-packs` branch at
3a463f7 (submodule `lib/shape-packs`, compiled via-IR with 20 optimizer runs as in its own repository). Each game deploys
its **own** instance (admin = owner Safe, `MIN_PACK_VALUE` = 2 units = 0.02 ETH); the address is a constructor
immutable of the pool owner and checked by the postflight. No token conversion, farming or Pack economics beyond
"a Pack holds 0.01 ETH Shapes and its owner can open or redeem it".
- **Who mints.** The pool owner now mints every prize for itself (`mintAndList`, game-only, payable): a Shapes
  denomination through `Shapes.mintTo`, any other multiple of 0.01 ETH at or above the Pack minimum through
  `ShapePacks.createPackTo` with `counts[0] = backing / 0.01`. It requires the ETH spent to equal the game's payment
  exactly and lists everything in one FWA call. The game computes prices from `poolOwner.prizeCost(backing)` (backing +
  one Shapes mint fee per Shape, read live) and pays exactly that. Alternative considered: the game mints and transfers
  to the pool owner (the old path). Rejected: Packs are `_safeMint`ed, so the custodian would have had to accept unsolicited
  ERC-721 transfers from the game; with minting in the custodian, `onERC721Received` accepts Shapes and Packs only when
  the operator is the pool owner itself or the FWA pool.
- **Delivery and ownership.** FWA delivers a Pack by `transferFrom` like any listed ERC-721; the winner owns it outright
  and alone can `open` (Shapes out), `redeem` (ETH out through Shapes' `redeemBatchTo`) or `unseal` it. Nothing in the
  game, pool owner or governance can touch a delivered Pack.
- **Cash-out paths.** Withdrawal at retirement, a stale row, or a refunded delivery: a Shape is burned, a Pack
  redeemed; the pool owner forwards the balance delta to the game. Retirement redeems every Pack it holds
  (`test_retirementRedeemsEveryPack`).
- **Accounting.** Unchanged: an item's cost (backing + mint fees) is carried as its expense; markup and operating
  allocation frozen at listing; `Item.isPack` is informational (Lens, site).
- Sizes: CollectionPoolOwner 22,323 B, CollectionGame 23,130 B, ShapePacks 17,715 B (limit 24,576). The pool owner
  constructor takes a struct (`Init`) to avoid a stack-too-deep in ABI decoding.
- Security review and audit scope: docs/SECURITY.md "Draw Packs".
Reversible only by a new deployment (permanent custody code); the board pattern decides whether Packs are used at all.

**D42. The Draw Packs board (Needs owner review; the owner's decision).** Opening board of 100 prizes: 47 × 0.01 ETH
Shape, 28 × 0.02 ETH Draw Pack (two 0.01 Shapes), 16 × 0.03 ETH Draw Pack (three), 7 × 0.05 Shape, 1 × 0.1 Shape,
1 × 0.5 Shape; the collection NFT listed separately; markup 5%, operating allocation 5%; reserve 3 ETH, exposure cap
8%, in-flight limit 5 unchanged. `LaunchConfig._boardPattern` interleaves the rows (each type spread evenly, so any
prefix and any 25-row growth step keeps the mix; 25 rows ≈ 0.52 ETH); the pattern is repeated twice for growth to 200.
Verified (sim/sessions.py, sim/economics.py, fork): FWA fee 0.01802 ETH, **0.01997 ETH per draw** with VRF at 1 gwei;
inventory cost **2.62 ETH** (2.46 backing + 160 Shapes × 0.001 mint fee); **expected return 75.9%** (Shapes and Packs
74.2%, collection reference 1.7%), realised 77.9% over 1,000 ETH. Outcomes per draw: 69.14% 0.01, 20.59% 0.02, 7.85%
0.03, 2.22% 0.05, 0.16% 0.1, 0.032% 0.5, 0.0057% the collection NFT at opening. 30.9% of draws return a prize worth at
least FWA fee + VRF (the 0.02 Pack exceeds it by only 0.00003 ETH; gas excluded, so not a profit chance; D50); 10.3%
return 0.03 or more. Reference model (1×
trading, 6 ETH NFTs, 1 gwei): distributable surplus 40 ETH per 1,000 ETH (32-47; of which coin buybacks 12.2 ongoing / 4.1 milestone), 7.7 wins,
first win p50 91 ETH, availability 81%, no negative cash. Against the superseded 0.05 ETH board (D37): a quarter of the
price per draw, 30.9% of draws above the draw cost instead of 7.8% (most only just), 10.7 points less return, 60% less surplus. Keepers take
43 of 44.6 ETH of allocation at 1 gwei (ECONOMICS §8). A deploy value for the opening rows; future rows by a 14-day
board module.

**D44. Lifetime limit on KeeperFund top-ups (Needs owner review).** Found by the Pack-board simulation: at a small
ticket, keeper gas can exceed the 5% allocation (above ~1 gwei with batching, at 1 gwei with a sync per draw). D41's
top-up then refilled the fund from trading fees indefinitely: at 2 gwei it spent ≈ 30 ETH of fees on keepers over 1,000
ETH of gameplay, starving NFT acquisitions (availability 82% → 52%). `FundingVault.KEEPER_TOP_UP_LIMIT` = 1 ETH now
bounds the lifetime total (permanent): enough to pay for listing the opening board at up to ~10 gwei (≈ 71M gas). After
it, keepers live on the allocation; if that is short they sync less often, which batches more draws per call. Nothing
safety-relevant depends on keepers (D36). Modelled with the limit: availability 79% at 2 gwei and with a sync per draw
at 1 gwei. Test: `test_keeperTopUpsStopAtLifetimeLimit`. Alternatives: raise the allocation (5% is the owner's value);
a top-up rate tied to fees (more code, same effect). P.

## Revised board (fourth review)

**D45. The revised 100-prize board (Needs owner review; the owner's decision).** 48 × 0.01 Shape, 32 × 0.02 Pack,
7 × 0.03 Pack, 1 × 0.04 Pack, 7 × 0.05 Shape, 1 × 0.06 Pack, 1 × 0.1 Shape, 1 × 0.15 Pack, 1 × 0.5 Shape, 1 × 1 ETH
Shape; Ape listed separately; markup 5%, operating allocation 5%, reserve 3 ETH (≥ 2 × the 1 ETH prize), cap 8%,
acquisition, decay, continuity and buybacks unchanged. **Packs use the fewest Shapes**: `CollectionPoolOwner.makeup`
decomposes a backing into Shapes denominations largest first (exact for Shapes' 1-5-10 series): 0.02 / 0.03 / 0.04 are
2 / 3 / 4 × 0.01 (nothing smaller than 0.05 fits), 0.06 is 0.05 + 0.01, 0.15 is 0.1 + 0.05; the Pack's redeemable value
is exactly its backing (`test_boardListedAtMarkupOverFullCost`, `test_packMakeupUsesFewestShapes`,
`test_mixedPackWonOpenedAndRedeemed`). 151 Shapes in all. **Verification of the owner's estimates** (FWA's rule and the
actual mint costs, confirmed on the fork): FWA fee + VRF 0.019834 ETH (est. ≈ 0.01984); prize ≥ FWA fee + VRF 29.9% (≈ 30%;
not a profit chance and no better than D42's 30.9%, D50);
0.02 Packs 23.4% (≈ 23%); return 76.0% (≈ 76%); capital 3.681 ETH (≈ 3.7). No material discrepancy, one caveat: the 30%
holds only while the draw costs ≤ 0.02 ETH, i.e. gas ≤ 1.08 gwei (the 0.02 Pack clears 0.019834 by 0.00017 ETH); above it
6.6% of draws reach it. Model (1× trading, 6 ETH NFTs, 1 gwei; final run with the D49 keeper model): distributable surplus
37.5 ETH per 1,000 ETH, of which 22.3 to continuity and 15.2 to coin buybacks (11.4 ongoing / 3.8 milestone); 7.8
wins; availability 77.6%; worst cash 0.32 ETH; no negative cash. Sessions: a prize ≥ 0.1 in 14.9% of 50-draw
sessions (D42: 9.5%). `LaunchConfig._boardPattern` interleaves the rows; 25 rows of growth ≈ 0.49 ETH.

**D46. Changing or shuffling the board after deployment (Needs owner review).** Requested by the owner. Previously a
new board had to keep every row in play at the same backing. Now `CollectionGame.setBoard(module)` (48-hour parameter
timelock, like markup; `setModule("board")` on the 14-day timelock does the same) accepts any `BoardPolicy` that covers
every row in play with valid Shapes or Packs, provided the reserve still covers twice its largest prize. In the same
call `_rebind` keeps every listed prize on a row asking for its backing (its own first; a pure shuffle keeps all of
them), marks the rest stale, and recomputes `replacementsOwed`; it touches nothing in FWA. Stale prizes stay in the draw
(winnable, their rows not owed again) until a maintenance window with nothing in flight lists the new rows and then
withdraws them (Shapes burned, Packs redeemed; only mint fees written off). Meanwhile collection decay holds at the
turnover of the change (stale listings inflate the listing count the exposure cap is measured on) and growth waits.
`script/SetBoard.s.sol` deploys the new module and prints the two Safe transactions; the rehearsal runs a shuffle through
the timelock end to end. Gas: a 100-row shuffle 1.45M. Tests: `test/fork/BoardChange.t.sol` (4). Cost: CollectionGame is
now 24,445 B, 131 B under EIP-170.

**D47. In-flight limit 10 (Needs owner review).** The owner proposed 10, to keep only if safe. Measured on the D45 board
(100 rows, six streams, singles and batches): 2,258 completed at 10 vs 1,870 at 5, 0 refunds at every limit, max 13
unsettled. Safety at 10: the gate keeps headroom for 14 removals (exposure cap and Shape floor hold after all of them;
`test_batchAfterSinglesAndBatchLimit` reaches 14 unsettled, `invariant_liveExposureAfterInFlightSettle`); settlement
exposure is bounded by the inventory (D48), so the larger bound does not pull capital from the vault; FWA's own limit of
10 requests awaiting VRF per pool refuses a batch beyond it before any fee (tested). On a 50-row board 10 refunded 0.8% (1.3% in the D59 re-run),
so reduce it if the board shrinks. Kept: **10**.

**D48. Settlement exposure bounded by the inventory (P).** `exposure()` (protected before distributions and asked of the
vault through `capitalNeed`) was `unsettled × the costliest prize`. With a 1 ETH prize and up to 14 unsettled requests
that is ≈ 14 ETH, which the vault would have moved into the game from the NFT budget whenever requests were in flight.
It is now `min(unsettled × costliest, inventoryCost)`: still an upper bound (requests cannot win more than every prize
held or listed), ≈ 3.7 ETH at launch.

## Final round

**D49. KeeperFund parameters and the maintenance ceiling (Needs owner review). Revised by D53:** the 5% premium is
replaced by a refund of the priority fee paid (cap 0.05 gwei) and `gasOverhead` is 64,000; the ceiling is unchanged. Owner's values: premium **5%** (was
20%), maximum age bounty **0.00025 ETH** (was 0.002); markup stays 5%. Routine change made with them: **tipCap 0.01 →
0.05 ETH** (the contract's maximum). With 0.01 a call that lists 20 prizes (~15M gas, needed for the opening board and
after any stall) is paid less than its gas above ~0.65 gwei, so rational keepers would not list the opening board at
1 gwei; with 0.05 it is paid up to ~3.2 gwei. A tip is still only gas × basefee × 1.05 plus the bounty; the cap only
stops underpayment. Analysis (sim/keepers.py → sim/results/keepers.md; fork: test/fork/KeeperPay.t.sol), with the
contract's exact tip formula, fork-measured gas per batch (1 draw 1.32M, 3: 2.83M, 5: 3.70M, 10: 6.89M, 20: 14.29M), a
0.02 gwei priority fee, and **no call assumed unless it pays the keeper**:
- The 5% allocation is 0.000805 ETH per draw. Replacing a draw costs the fund, per draw, 1.36M gas alone, 0.96M in a
  batch of 3, 0.75M of 5, 0.69M of 10, 0.72M of 20 (× basefee × 1.05). **The allocation pays for maintenance up to a
  basefee of 0.39 / 0.72 / 0.96 / 1.07 / 1.05 gwei** for those batch sizes. No batch size sustains it above ~1.1 gwei.
- Keepers compete: whoever calls first is paid, so while KeeperFund holds a buffer they sync after every draw (the
  most expensive pattern) and drain it, the vault's lifetime 1 ETH of top-ups included. At its floor a call is paid only
  from the allocation it books itself, so keepers wait for enough draws: steady state at 1 gwei ≈ 5 draws per call.
- Steady state (30 days, top-ups spent), every activity level from 0.25 to 20 draws per hour: **open 100% up to
  1.1 gwei** (at most ~10 prizes waiting for replacement); **from ~1.25 gwei maintenance cannot be sustained**: the
  board runs down until the purchase gate closes the game (45 prizes off the board), and it reopens only as far as the
  booked allocation pays for relisting. At 2 gwei it is open 0-42% of the time depending on activity.
- Fork check: at 1 gwei a 10-draw call used 6.46M gas and was paid 0.00678 ETH (covers its gas); at 2 gwei with the fund
  at its floor the same call would be paid 0.00915 ETH (its own allocation) against 0.0127 ETH of gas: not made.
- Recovery: when gas falls, the unbooked draws' allocation pays the first syncs; anyone can also send ETH straight to
  KeeperFund (it accepts plain transfers) to restart maintenance. Nothing safety-relevant depends on keepers (D36).
**This is a launch constraint, stated explicitly: the game as configured can sustain its own maintenance only while
the average basefee stays at or below about 1.1 gwei.** Above it the game closes safely (no funds at risk, draws in
flight settle) and reopens when gas falls or someone funds KeeperFund. Levers if this is unacceptable: a higher markup
or operating allocation (the allocation is capped at 5% in permanent code), or planned contributions to KeeperFund.
Reversible: all three KeeperFund values are G48 parameters.

**D50. Reporting corrections.** (1) "29.9% of draws" counts prizes worth at least the FWA fee plus FWA's VRF fee at
1 gwei; it excludes the player's own transaction gas (~620k gas, ≈ 0.0006 ETH at 1 gwei) and redemption gas, so it is
not a chance of net profit; counting the transaction gas the draw costs ≈ 0.02045 ETH and only prizes of 0.03 ETH or
more (6.6% of draws) are worth more. (2) The first Draw Packs board (D42) already modelled 30.9% by the same measure;
the revised board (D45) does not improve that metric. (3) "Surplus" is distributable surplus, not buybacks: of ≈ 37 ETH
per 1,000 ETH played, ≈ 22 ETH funds the continuity reserve (the next collection NFT) and ≈ 15 ETH goes to coin
buybacks (≈ 11 ongoing, ≈ 4 milestone). The site now shows the full cost of a draw including transaction gas and says
that a prize above the ticket is not a profit.

**D51. Code freeze for review.** `CollectionGame` (24,445 B, 131 B under EIP-170) is frozen; `test/unit/Sizes.t.sol`
fails on any growth. Any feature found necessary later goes into a separate contract. Review package:
docs/AUDIT_SCOPE.md (scope, build, properties, focus areas, Slither triage, known issues, legal requirements).

## Shared coin (architecture change before the audit)

**D52. One collection-neutral coin, several collection games (Needs owner review; the owner's requirement).** The BAYC
game stays the only game deployed at launch and is unchanged. Delta (docs/SHARED_COIN.md):
- Layers: the coin (token, liquidity, hook, burner, timelocks) is deployed once; each collection deploys a game layer
  (vault, pool owner, game, router, milestone reserve, KeeperFund, Packs, modules) against it
  (`DeploySystem._deployAttachedGame`, `script/DeployGame.s.sol`, `postflightAttached` / `postflightRegistered`). All
  game-layer contracts already took the burner as a constructor address, so none of them changed.
- `CollectionBurner` (coin layer): milestone deposits from any **registered** reserve (the first wired at deploy; more
  by `addMilestoneReserve` on the 48-hour timelock, additive, contracts only); ETH received recorded per source; and
  `process` now reimburses its keeper **from the slice** (KeeperFund's `quoteTip` formula, at most 5% of the slice)
  instead of calling the BAYC KeeperFund, so no game's operating allocation pays for another game's buyback
  processing. The burner is no longer a KeeperFund payer. Cost to buybacks ≈ 0.3% of each 0.1 ETH slice at 1 gwei
  (307k gas); the BAYC KeeperFund saves the same.
- Funding boundary: trading fees stay with the hook's immutable recipient, the BAYC vault. Later games are capitalized
  by contributions to their own vaults; no mechanism moves fee ETH or capital between games. A fee split among games
  would be a separate design (not part of this change).
- Alternatives rejected: a burner per game (each would pay the hook's 3% fee, since the hook has one immutable exempt
  sender, and would need its own market); permissionless milestone deposits (anyone could jump the milestone queue and
  mislabel donations as verified wins); a game registry or factory (more permanent code for no safety gain).
- Tests: `test/fork/SharedCoin.t.sol` (6), `invariant_burnerConservation`, rehearsal step 8 (a second game deployed on the
  same coin by `DeployGame.s.sol`, its reserve registered through the timelock, the first game still active). The old
  `test/fork/SecondCollection.t.sol` (a second coin per collection) is removed.
- Naming: the coin is now collection-neutral; the working name "Ape Draw" (D9) names one collection and needs a
  neutral replacement before deployment.

## Keepers and the player path (owner's direction, before the audit)

**D53. Keepers do only what the protocol must; players settle; priority refunded; open without an Ape (Needs owner
review).** The owner asked what the keeper does that FWA's own pools leave to users, and to follow FWA's standard
instead of smoothing it over. FWA's docs (fwa.fun/docs) and its clone code: draws settle in the randomness callback
(`_tryProcessCallbackHead`, the head of the queue only, and not when a listing batch is reserved for it); anyone may
call `processAcquisitions`; buyers withdraw refund credit and retry or refund failed deliveries themselves; listing,
restocking, `withdrawOwnerProceeds` and `recoverRefundedNFT` are owner-only. FWA runs no keeper for community pools.
- **Kept as keeper work** (owner-only on FWA, or the protocol's own books): `sync` (book draws, collect owner proceeds,
  replace prizes, list the next Ape, recover refunded prizes, pay the operating allocation and distributions; the only
  tipped job), `activate`, burner `process` (reimbursed from the slice, D52). Booking and paying surplus to the router
  are steps inside `sync`, not separate calls. `distribute` (router → burner) and the fallback milestone `release` are
  untipped; the bot now routes only once a full 0.1 ETH burner slice is waiting (`ROUTE_MIN_ETH`).
- **Dropped from the keeper**: its own `processAcquisitions` job (`sync` still tries it first). Settlement backlogs
  matter because unsettled requests count against the 10-request in-flight limit (`canPurchase` closes at 10): they
  build up when randomness arrives out of order or when a restock was staged while draws were in flight, since the
  callback then cannot settle them. **`DrawRouter`** (src/periphery, 1.5 KB, stateless, no owner, wired into nothing):
  the site's draw first settles up to ten waiting draws, then buys for the caller in the same transaction, and returns
  all change; `quote` gives the price after that settlement (settling removes prizes and moves the ticket: on the fork a
  10-draw backlog raised it 3%, so a pre-settlement quote would revert on FWA's fee ceiling). The player pays the
  settlement gas (≈ 240k per waiting draw; a plain router draw is 635k vs 596k for a direct `acquire`) and is not
  reimbursed: the owner chose no restock or settlement rebate at launch. A router that also ran `sync` with a rebate
  would be a new periphery contract later; nothing is wired to this one, so replacing it needs no governance. The
  site also gets FWA's buyer buttons (withdraw refunded tickets, retry or refund a failed delivery).
- **Tip formula.** Was `(gas + 40k) × basefee × 1.05 + bounty`. Mainnet in Oct 2026: basefee ≈ 0.11 gwei, median
  priority paid ≈ 0.02 gwei (1,024 blocks of `eth_feeHistory`). 5% of 0.11 gwei is 0.006 gwei, so a keeper's priority
  fee was not covered; only the age bounty could pay it, and slowly. Model (sim/keepers.py, 14 days): at 0.1 gwei and
  4 draws an hour the old formula kept the game open 97% with a 0.02 gwei priority fee and **4% with 0.05 gwei**; at 20
  draws an hour 1-41%. Now `tip = min(tipCap, (gas + gasOverhead) × (min(basefee, basefeeCap) + min(priority paid,
  priorityCap))) + bounty`: the gas is refunded at what it cost and the bounty (age-ramped, per unit of work) is the
  keeper's margin, the "minimum a bot will take" found by the ramp rather than guessed. Open 100% in every low-gas case
  modelled. Alternatives: a flat per-call fee (pays the same for a 1-draw and a 20-draw call, so it rewards splitting
  work, and must be guessed); a per-gas priority allowance paid whatever the keeper paid (costs the cap on every call;
  the refund costs at most the cap, and only when keepers compete). Risk: competing keepers can bid priority up to the
  cap at no cost to themselves, so the fund pays up to 0.05 gwei × gas per call (≈ 4% of the allocation at 10 draws a
  call); a builder-keeper can pocket at most the same. `priorityCap` G48, ≤ 2 gwei (`MAX_PRIORITY_CAP`).
- **`gasOverhead` 40k → 64k.** With an exact refund the overhead must cover the gas the game cannot measure
  (intrinsic 21,000, calldata, KeeperFund's reads, the tip transfer): ≈ 62k measured from the fork (`KeeperPay`).
  Storage refunds are not counted, so real calls are refunded somewhat more than they cost: on real anvil transactions
  (rehearsal step 10) a 1-draw `sync` paid 1.055× its cost with the 52k tried first. The maintenance ceiling is
  unchanged at ≈ 1.1 gwei (sim/results/keepers.md).
- **Open without an Ape.** `ready()` still requires a collection NFT, so the game opens only with its first Ape. After
  that, `CollectionGame._admit` and `CollectionPoolOwner.canPurchase` no longer require one: after a win with no
  replacement, draws continue for Shapes and Packs, and their margin keeps funding the continuity reserve toward the
  next Ape. The site says plainly that no Ape can be won meanwhile. This supersedes the brief's "close new draws when
  no collection prize is left" (D31, D36) at the owner's direction. It removed code from the frozen game (no addition;
  135 bytes smaller). Exposure, decay and booking need no collection NFT (exposure is zero without one).
  Model (sim/economics.py, `apeless_share` = the share of demand that still plays with no Ape in the draw, an
  assumption): per 1,000 ETH played, closed (old rule) / 25% / 100% still playing gives 7.15 / 7.02 / 5.90 wins and
  38.2 / 36.4 / 33.7 ETH of distributable surplus; but reaching 1,000 ETH played takes 1,303 / 1,239 / 1,000 ETH of
  demand, so per ETH of demand the surplus is 2.93% / 2.94% / 3.37% (the run is counted in gameplay, and trading fees,
  which buy the next Ape, follow demand). The draws played without an Ape add margin; they do not speed up the next Ape
  per ETH played.
- Tests: `test/fork/DrawRouter.t.sol` (3: an out-of-order backlog closes the gate, a direct purchase reverts, a router
  draw settles and buys in one transaction at the post-settlement quote; plain and batch draws; the gate, pause and
  FWA guards still apply), `KeeperPay.t.sol` (5: priority refunded at low basefee, refunded only up to the cap),
  `Collection.t.sol` / `Outage.t.sol` / `LongRun.t.sol` updated (open with no Ape, Shape-only draws, continuity
  accumulating, the next Ape joining), rehearsal step 10 (real transactions: router draws, keeper pay).

## Final pre-audit scope (owner's corrections)

**D54. Administration without a timelock; custody review (Needs owner review).** The owner asked for no mandatory
delay on ordinary administration: the owner Safe adjusts bounded parameters, replaces supported policy modules and
pauses or resumes gameplay at once. `Governed` keeps its three role slots (`paramGov`, `moduleGov`, `guardian`), all
the Safe; the 48-hour and 14-day floors and the TimelockControllers are gone (every governed contract shrank;
`CollectionGame` 24,330 B with the migrator and markup floor below). With no notice period, a bad change can no longer
be seen and exited before it takes effect, so every indirect route by which an administrative change could move
protected assets toward the operator was reviewed and closed:
- **Flexible revenue destinations** (router): `addDestination` removed; destinations exist only if wired at deployment,
  and the launch wires none (100% of distributions to buybacks; ENGINE was inactive, so no economic change). `EngineSink`
  (whose `setTarget` could name any contract) and `FwaStakeSink` are deleted.
- **Keeper permissions** (KeeperFund): `setPayer` and `setOverflow` removed: an added payer could claim tips for work it
  never did. Payers (the game) and overflow (the game) are fixed at wiring. Bounds tightened so an owner-run keeper earns
  no more than any keeper: bounty ≤ 0.001 ETH, ramp ≥ 1 hour, priority cap ≤ 0.5 gwei, overhead ≤ 100k gas.
- **Acquisition strategy and `maxPrice`**: a replaced strategy (or `maxPrice` raised to the 30 ETH hard maximum) could
  make the bid jump, letting the owner sell its own Ape at up to 30 ETH in the same transaction. The vault now caps any
  bid by an **immutable ceiling**: 15% of `hardMaxPrice` after each acquisition, rising linearly to it over 21 days
  (with the launch schedule, 4.5 ETH + 1.43 ETH a day against the schedule's 4.5 + 0.5, so it never binds normal
  operation). A bid that only rises at a fixed public rate cannot be exploited: holders sell as soon as it reaches
  their price. Adapters spend at most the current bid, so the same bound covers them.
- **Pricing module**: with markup 0 and collection exposure at its 8% maximum, a board of large prizes could return
  more than a draw costs (up to ≈ 103% when mint fees are negligible), so the owner could profit by playing. The game now clamps the markup to at
  least 5% (`MIN_MARKUP_BPS`; `PricingPolicy` refuses less too): `(0.952 + 0.08) / 1.05 ≈ 98.3% < 100%` worst case.
- **Burner**: hook fees can now be set to 0 at once, which would make sandwiching a buyback cheaper. Slices are capped
  at 1 ETH, impact at 5% and same-block deviation at 3%, and slices are spaced at least 10 minutes apart.
- **Listing strategy, board, capital policy, settings**: already bounded by permanent code (exposure cap ≤ 8% and
  floor in the pool owner, board rows in play, reserve ≥ 2 × the largest prize, continuity share ≤ 60%); none reaches an
  asset. Permanent retirement remains a Safe action and still liquidates only to buybacks.
Tests: `test/fork/Governance.t.sol` (9), `Revenue.t.sol` (`test_noDestinationCanBeAdded`, `test_allRevenueGoesToBuybacks`),
`Funding.t.sol` (`test_strategyChangeCappedByTheImmutableCeiling`), `Units.t.sol`.

**D55. Secure one-way migration (Needs owner review; the owner's requirement).** docs/MIGRATION.md. New
`MigrationAuthority` (non-custodial; 8.0 KB). Changed: the hook's fee recipient is storage, changeable only by the
authority; `CollectionGame.retire` also accepts the authority; the pool owner gains `beginMigration` / `migrateApe`
and blocks the retirement auction while migrating; the vault gains `beginMigration` / `migrateCapital` and blocks
`shutdown` while migrating; `MilestoneReserve.releaseRetired` and `KeeperFund.sweep` let committed and operating ETH
leave a finished V1 (to the burner, and to the vault and then the successor). Alternatives rejected: a timelock with
the owner alone (no independent check of the successor's code); a universal pool adapter or an FWA V3 implementation
(speculative, out of scope); migration through retirement (assets would be sold for buybacks instead of continuing the
game); an authority that holds assets in transit (custody risk for no benefit). Tests: `test/fork/Migration.t.sol`
(16); rehearsal step 11.

**D56. Ape-specific launch scope.** The owner corrected the direction: one Ape-specific coin and its game. No farming
period, rewards distributor, token reserve, emissions or staking: none was ever implemented, and 100% of the fixed 1B
supply stays in protocol liquidity. Any goodwill claim for $APESTR holders would be bought on the market after launch
by the owner personally and run through a separate optional contract, outside this protocol. Removed for scope: the
attached-game deploy path (`_deployAttachedGame`, `DeployGame.s.sol`, `postflightAttached`), `test/fork/SharedCoin.t.sol`
and the rehearsal's second-game step, `EngineSink` and `FwaStakeSink`. Kept because it is safe and costs nothing: the
burner's registered milestone reserves (deposit-only). The coin is not a generic ecosystem token; D9 is revised
accordingly.

## Simplification (owner's direction, before the audit)

**D57. One owner, broad parameters, a standing bid, a simple migration (Needs owner review).** The owner's direction:
the project has one developer, so the Safe requirement goes; administration must be transferable in two steps and
renounceable; parameters must be flexible on a new system; the bid must avoid overpaying however funds arrive; there is
no inventory limit; markup bounds much broader; revenue destinations available later through a swappable splitter;
KeeperFund open and uncapped; no tip cap; migration and the fee switch simple. "Each one of these is a potential bug or
attack vector."

- **Administration.** `Admin` (new, 0.6 KB) holds `owner` and `pendingOwner`: `transferOwnership` (step one, or
  address(0) to cancel), `acceptOwnership` (step two), `renounceOwnership`. `Governed` now reads `admin.owner()` for one
  `onlyOwner` check (a shared internal function, which also took `CollectionGame` from 24,330 to 24,146 B). One transfer
  moves every contract; a renounce freezes all of them. Roles (`paramGov`, `moduleGov`, `guardian`) are gone.
- **The bid** (`FundingVault`, replacing `RisingBidStrategy`, the vault's immutable ceiling and `hardMaxPrice`). From
  first principles, the protocol overpays only when its offer jumps above what holders would accept: when it restarts
  too high, rises too fast, or rises while nobody could take it and then becomes payable all at once (funds arriving
  fast, a slot reopening after idle time: the flaw the old clock had). So the offer: restarts after every purchase at
  `startBps` (90%) of the price just paid, the last price the market accepted (`refPrice`, owner-settable for the first
  Ape and for big moves); rises `riseBpsPerDay` (5%) of that price a day; rises only from `bidLevel`, the last level
  recorded, which is never above what the vault could pay at that moment; credits at most `maxStep` (1 hour) of rise
  per record, so without records it stalls instead of jumping; is capped by `maxPrice`. `poke()` records it: a waiting
  seller has every reason to, and the DrawRouter and the keeper bot do. Fail-safe: if nobody acts, the bid stays low.
  Funds arriving far above the floor are spent one Ape at a time at the market price, not at once at a high price.
  There is no inventory limit: with funds, the vault keeps buying, each purchase becoming the next reference. The
  continuity target is one NFT at the reference price; a donated NFT's reference value is the same.
- **Parameters.** Markup and operating allocation 0-100% (game and module); continuity share 0-100%; trading fee
  ≤ 10%; exposure cap ≤ 50%; in-flight limit ≤ 50; up to 16 Apes listed; listing floor ≥ 0.01 ETH; settings broadened
  (fill, outstanding, edge, cooldown, intervals); burner slice uncapped, spacing ≤ 30 days, impact and deviation ≤ 50%;
  milestone share 0-100%. Kept because they protect solvency or the code's own limits: the reserve covers twice the
  largest prize; the board must cover the rows in play; listing batches of 20; the board's 200 rows.
- **Revenue.** `RevenueRouter` is the splitter: `setSplits` (any recipients, together ≤ 100%); the rest buys back the coin.
  Payments are forced, so a refusing recipient cannot stall a distribution. Launch: no splits. A different splitter later
  is one split at 100%. The 90% minimum, the destination table and `freeze` are gone.
- **KeeperFund.** No target and no automatic overflow: it keeps everything it receives. `returnToGame(amount)` moves ETH to
  the game's cash (owner at any time, anyone once the game has retired). `setPayer` is the owner's (removed in D62). Tip: nothing above
  `maxBasefee` (3 gwei); otherwise the gas at its cost (basefee + priority up to `priorityCap`) plus a bounty rising from
  `bountyStart` to `bountyMax` over `bountyRamp`, scaled by progress up to `bountyItems`. No tip cap. The vault's top-up
  from trading fees is `keeperTopUpTarget` (0.15 ETH) with a lifetime `keeperTopUpLimit` (1 ETH), both owner-set.
  Economic consequence: the operating allocation that keepers do not spend now stays in KeeperFund until the owner
  returns it, where before anything above 0.5 ETH went back to the game automatically (and on into surplus). The
  economics model assumes the owner returns it.
- **Players do the upkeep.** `DrawRouter.draw(pool, game, settle, syncCount, count, ...)` settles, buys, then (if
  `syncCount` > 0) runs `game.sync` and `vault.poke`; the game's tip arrives at the router and goes to the player with
  the change. Upkeep runs after the purchase so a listing it adds cannot invalidate the player's quoted inventory version.
  `count` 0 is upkeep only.
- **Migration.** `MigrationAuthority`: the owner proposes a successor address; 24 hours later anyone executes; the first
  execution stops V1 exactly as before; after V1 has retired, `migrateApes` and `migrateCapital` send the NFTs and all
  the vault's ETH straight to the successor (forced ETH transfer; plain NFT transfer), repeatable. A later proposal
  replaces the successor for what has not moved. The pool owner keeps every NFT's record readable. Removed: the
  independent signer (one developer), code-hash binding (an upgradeable proxy keeps its hash, so binding proved little),
  the successor interface, receipt and readiness checks, stages and the fee-only redirect. A shared custody contract
  across pool systems was considered and not built: every pool system needs its own pool-owning contract anyway, so it
  would add a contract and a cross-contract call to every purchase and listing to save a one-time transfer of a few NFTs.
- **Fee switch.** `CollectionHook.setFeeRecipient` is the owner's, any non-zero address, at once. The hook keeps its
  address (it is part of the pool's identity), so the market never changes.
- **Trust, stated plainly.** The owner can now direct future trading fees and surplus anywhere, add KeeperFund payers,
  register adapters and set the bid; and, after a public 24-hour notice, migrate the Apes and treasury to any address.
  Prizes in play, game cash and committed buyback ETH have no direct administrative path. Tests: `test/fork/Bid.t.sol`
  (5), `Governance.t.sol` (11), `Migration.t.sol` (9), `Revenue.t.sol`, `DrawRouter.t.sol`, `KeeperPay.t.sol`,
  `Units.t.sol` (two-step transfer, renounce, tip formula, router splits), invariants (12); rehearsal steps 4, 6 and 11.

## Autonomy review (owner's direction)

**D58. Minimal operator decisions (Needs owner review).** The owner's goal: an autonomous system that keeps running for
six months untended, with administration for exceptions only. docs/AUTONOMY_REVIEW.md records the review, the models
(`sim/acquisition.py`, `sim/maintenance.py`) and the findings. Made now, because each removes a routine decision with no
economic choice: the bid has no cap by default (`maxPrice` 0 means none; it stays available as an emergency brake), so a
rising floor needs no update (`test_risingFloorNeedsNoUpdate`); `CollectionBurner.process` routes the router's ETH first,
so buybacks need no separate untipped call (`test_buybackJobRoutesSurplus`); the site's sell page records the bid; the
post-play postflight accepts a moved reference price. Proposed for the owner's approval (economic changes): A, demand-
linked acquisition ("keep one Ape waiting"), vault ETH above a buffer to buybacks, bid 80% / +20% a day; B, gas-indexed
keeper pay (tip cutoff max(setting, 2 × 30-day average basefee), operating allocation = 120% of upkeep gas at that
average, through a replacement PricingPolicy); C, KeeperFund's surplus above an owner-set ceiling returnable by anyone.


## Acquisition and game economics (owner's decisions)

**D59. Every Ape in the draw, one decay rule, a growing board, Permanent Collection's live bid, gas-plus-fee keeper
pay (owner-approved design; launch values chosen from the models).** The owner's goal: trading fees acquire as many Apes
as the protocol can afford, every Ape enters the draw, gameplay gradually improves their odds, game revenue supports
buybacks; a growing pool of 20, 50 or 100+ Apes is intended. Proposal A (inventory restriction, excess to buybacks) was
not adopted; proposal C was approved; proposal B was replaced by gas + flat fee. Models: `sim/pool.py`, `sim/bid.py`,
`sim/maintenance.py` (results in sim/results/); fork: `test/scenario/ManyApes.t.sol` (20, 50, 100 Apes),
`test/fork/Collection.t.sol`, `Bid.t.sol`, `KeeperPay.t.sol`.

- **No lead Ape.** `CollectionListingStrategy`, the lead, promotion, per-listing schedules, `maxListed` and the 1 ETH
  floor are removed. Every NFT held is listed by `processCollection`, ten per call in one FWA batch (FWA's limit is
  20), most recent first; one that does not fit waits in custody and is listed at a later maintenance.
- **One decay rule, shared gameplay.** `creditPerApe` grows by each new unit of settled turnover divided by the NFTs in
  the draw. An NFT's notional is `max(min, start − credit × decay)`, never above what it already published, with
  `startBps` 100% and `minBps` 25% of its price and `decayBps` 0.1 ETH per ETH credited (`ListingParams`, owner,
  applying to every NFT from its next update). Repricing: ten per call from a rotating cursor, in 5% steps, only with
  nothing unsettled (FWA's rule); a pass stops at the first NFT the target holds back so the shortage stays recorded.
- **One target, a board that grows on demand.** The 8% exposure cap became `targetBps` (15%, owner, ≤ 50%): listing and
  decay keep `Σ price / notional` within it at `activeListings − gateHeadroom`; anything that would exceed it waits and
  `rowsShort` asks for the rows that would let it proceed. The game grows the board by those rows in the same
  maintenance call (≤ 50 a call), from the vault's general ETH on top of its capital need, and lists them like
  replacements; the vault keeps that cost (`growthNeed`) before bidding again. The purchase gate checks the fixed 50%
  ceiling instead of the target, so neither decay nor an owner change to the target can close it. Sizing the board for
  every Ape's eventual minimum up front was modelled and rejected (16% of each Ape's price in idle rows when trading
  outruns play; fewer Apes bought in every scenario). Observation recorded for the site and docs: from about 20 Apes the
  target binds and further decay mostly grows the board, so the chance of some Ape per draw stays near 1 in 2,100-2,400.
- **The game scales.** The 256-row bitmap became a list of owed rows (`owedCount`); `MAX_BOARD` (200), `CapitalPolicy`
  (its demand growth and step) and `turnoverAtBoardChange` are gone; the continuity share moved into `Settings`; the
  board is an endless pattern (`BoardPolicy(pattern, listBatch)`, `maxBacking`); a row index is 24 bits (the `live` flag,
  unused, made room in the same slot). Board changes rebind in linear time (each listing keeps its row, else takes an
  owed row asking for its backing, matched once per distinct backing). Outcomes of collection listings are recorded per
  listing (`settleListing`, called by the game while booking, or by anyone), so no step loops over every NFT; retirement
  withdraws NFTs 20 per call. `CollectionGame` is 23,873 B (703 B of headroom).
- **The live bid** (`FundingVault`), Permanent Collection's model adapted: one public bid of real ETH (`bidBalance`,
  accounted inside the vault); `sweep` (anyone, rewarded 0.5% of the forward, ≤ 0.01 ETH) fills it at once to the
  activation threshold, then forwards at most `maxSweepWei` (0.05 ETH) per `minBlocksBetweenSweeps` (300 blocks); an
  acquisition subtracts its price (the rest stays) and resets the threshold to `thresholdBps` (75%) of the clearing
  price; the holder names its price up to the bid (`sellToProtocol(id, price)`); a marketplace fill pays the listing's
  price plus a finder fee (0.5%, ≤ 0.01 ETH); `maxPrice` an optional brake; `setActivationThreshold` a correction until
  the next acquisition. Deviations from $111, each for a reason: ETH stays in the vault (one treasury; the game's
  capital comes first, so the bid is clamped to the acquisition budget); a fill also resets the threshold (it is a real
  clearing price at or below the bid); 0.05 ETH per 300 blocks instead of 2 ETH per 150 (Apes cost ~6 ETH: $111's step
  would overshoot by up to a third of an Ape). Removed: `poke`, `bidLevel`, the time-based rise, `refPrice`/`startBps`/
  `riseBpsPerDay`/`maxStep`.
- **Keepers.** KeeperFund pays `(gas + 70,000) × min(tx gas price, maxGasPrice 3 gwei) + flatFee 0.0003 ETH` (the fee at
  most once per `feeInterval`, 60 s, an hour since D60; nothing for a call with no work, which the game reverts). The age bounty, progress
  scaling, the basefee cutoff and the priority cap are gone. Anti-farming: funding the game counts as work only when it
  covers the whole need (a dust contribution earns nothing); a repeated call within the interval is paid its gas only; a
  maintenance pass counts a newly found row shortage as work, never an unchanged one. `gasOverhead` rose from 64,000 to
  70,000 (the interval adds a storage write; the rehearsal measures it). A keeper that builds blocks can raise its own
  reimbursement up to the cap by paying itself priority; the cap bounds it.
- **KeeperFund surplus (C).** `reserveTarget` 1 ETH (owner): anyone returns the available balance above it to the
  game's accounts (`returnToGame`, booked as operating allocation returned); the owner any amount; anyone everything once
  retired; credited tips never move. The DrawRouter does it after every draw; the keeper bot when there is a surplus.
- **Tradeoffs flagged, not changed:** (1) per-draw upkeep through the DrawRouter earns the flat fee on every draw (37% of
  the operating allocation): a rebate to players at low gas, less KeeperFund surplus for buybacks, players paying part
  of the upkeep at moderate gas; a longer `feeInterval` or batched keeper upkeep keeps more (docs/ECONOMICS.md
  section 8); (2) with no sellers for a long time the live bid keeps rising 0.05 ETH per 300 blocks while funded, and
  the first seller takes all of it; a halving floor is hit at the old bid: `maxPrice` is the only brake (section 2a);
  (3) with very little trading, gameplay starts late (the first Ape and the opening capital come from fees).

**D60. Final adjustments before the audit freeze: an hourly flat fee, a relative bid ceiling, bounded player
upkeep (owner's direction; the ceiling's form chosen from the model).**

- **Keeper flat fee at most once an hour** (`feeInterval` 1 hour, was 60 s; owner-adjustable). Every useful call is
  still reimbursed its gas (capped at 3 gwei per gas); the 0.0003 ETH fee is paid at most once an hour whoever earns it;
  KeeperFund's surplus above 1 ETH still returns to the game automatically. Two years at 0.2 gwei with per-draw upkeep:
  51.2 ETH returned to the game instead of 23.6 (sim/results/maintenance.md; docs/ECONOMICS.md section 8).
- **Relative bid ceiling, with a slow climb above it.** The owner asked to evaluate a maximum bid of 150% of the last
  acquisition price, moving with every acquisition, against floors that double, triple or crash, months without
  sellers, a ratchet of purchases and volume without selling (`sim/ceiling.py` → sim/results/ceiling.md). A **hard**
  ceiling (150% or 200%) stops acquisitions for good when the floor rises more than 50% (100%) between two acquisitions
  (nothing but an acquisition or the owner can lift it; after renouncing, nothing), it does not stop a ratchet by a
  supply-controlling cartel (each purchase at the ceiling raises the next one by half) and does nothing for a crash.
  Adopted instead, as the simpler alternative within the same mechanism: above `ceilingBps` (150%) of `lastPrice` a
  sweep forwards only `slowSweepWei` (0.005 ETH per 300 blocks, a tenth of the normal rate). The bid still reaches any
  floor (an overnight doubling ≈ 27 days, a tripling ≈ 76, against 5 and 8 uncapped), and a windfall after a long
  drought is bounded by time (+103% after 30 days without sellers, +403% after six months, against +576% and +3,576%).
  `slowSweepWei` 0 makes it the hard ceiling the owner first described; `ceilingBps` 0 removes it; `maxPrice` stays the
  absolute brake. `bidCeiling()` reports it. No oracle, no new governance, nothing to manage routinely.
- **Bounded player upkeep.** `DrawRouter.draw` takes `upkeepGas`: `sync` runs with at most that much gas, the sweep and
  the surplus return with 100,000 each, and 260,000 gas (`TAIL_GAS`) is kept back for them and the change, so an upkeep
  that needs more fails alone and the draw stands. The router reverts `UpkeepGas` up front when the transaction's gas
  limit leaves less than the budget: an `eth_estimateGas` therefore always includes it (with a try/catch alone an
  estimate would silently leave the upkeep out). `measureUpkeep(game, syncCount)` (for `eth_call`) reports whether
  `sync` would do anything and its gas; the site asks for the upkeep only when it is at most 2.5M gas (budget 30% above
  the measurement), shows the draw's gas including it, the expected KeeperFund payment and that the payment depends on
  KeeperFund's funds, and leaves heavier work (full listing batches, board growth, repricing) to keepers' own calls.
  Verified at 1, 20, 50 and 100 Apes (`test/scenario/ManyApes.t.sol`) and in `test/fork/DrawRouter.t.sol`. The router
  is periphery and replaceable; the game and the pool owner are unchanged.

**D61. Every transaction under EIP-7825's gas cap; a 120% bid ceiling; the name approved.**

- **Gas cap.** Since Fusaka (EIP-7825) mainnet rejects a transaction above 2^24 = 16,777,216 gas, whatever the block
  limit. The board's prizes were listed 20 per call: on a board of the heaviest prize (the 0.04 ETH Pack, four Shapes
  minted and packed per listing) one call used 24.3M gas and a call that also booked wins and listed Apes 27.1M; the
  20-, 50- and 100-Ape runs peaked at 16.85M. Those transactions would always fail, and the board would never be
  relisted. Fixed: the board module carries `maxPerCall` (owner, 1-20; 8 at launch), the most prizes one maintenance
  call lists; the game reads it (never more than its own `MAX_LIST_BATCH`, now 10, which also bounds prize withdrawals
  per call, in retirement and after a board change, where no module is read). Measured worst cases with a board of
  0.04 Packs only (`test/fork/TxCap.t.sol`): listing the opening board 10.3M gas per call; booking 25 wins, relisting
  8 Packs and listing 10 Apes in one call 14.0M; a board change to another heavy board 14.2M; retirement 2.3M. Each is
  asserted under 90% of the cap. The keeper bot books at most 20 draws per call (`SYNC_MAX_COUNT`). A board with heavier
  Packs needs its `maxPerCall` measured the same way before `setBoard`. `CollectionGame` was then 24,026 B (550 B headroom).
- **Bid ceiling 120%.** The owner does not want to pay 50% over the floor. With sellers present every variant pays
  0.5-1% over it; the ceiling and the slow rate decide only what a drought pays and how fast a genuine jump in the
  floor is caught. Launch: `ceilingBps` 12,000, `slowSweepWei` 0.0025 ETH per 300 blocks: thirty days without sellers
  pay at most +48% (+103% at 150%), six months +198%; an overnight doubling of the floor is caught in ≈ 81 days (27 at
  150%); gradual rises are followed because each purchase moves the ceiling (sim/results/ceiling.md, "Lower
  ceilings"). Never paying more than a fixed share over the last price would need the hard ceiling (`slowSweepWei` 0),
  which stops buying for good after a jump above it until the owner lifts it.
- **Name.** Ape Draw / ADRAW approved by the owner (D9), subject to legal clearance.

**D62. Trust review follow-up (the owner's answers, 2026-10-29).**

- **Donations stay.** Anyone may give ETH (`FundingVault.contribute()` or a plain transfer) or an Ape
  (`contributeNFT`, or `claimStray` for one sent without a call), with no return. Unchanged.
- **`setPayer` removed.** It let the owner name other contracts that could request KeeperFund tips; such a contract
  could claim pay for work that never happened. It was unrelated to donations or sweeping. Now only the game, wired at
  deployment, can request tips. Keeper pay (`setParams`) and the bid keep no bounds: the owner chose to remove only
  `setPayer`. The 0.0003 ETH flat fee is a launch value, not a cap.
- **Owner sweep of stray NFTs.** `Governed.sweepNFT(token, id, to)` (owner only) sends out an ERC-721 a governed contract
  holds by mistake, with `safeTransferFrom`. The collection, Shapes and Draw Packs are never swept, whatever the token
  id: the deployer records them in `Admin.protect` once during wiring, which closes the list for good
  (`Admin.deployer` becomes zero). Covers the game, pool owner, vault, keeper fund, burner, router, hook, liquidity,
  migration authority and both policies. ERC-1155 tokens cannot arrive (no governed contract accepts them). The token's
  own `Transfer` event records a sweep (no extra event: `CollectionGame` has 167 B of headroom, 24,409 B). The FWA pool
  implementation has no `safeTransferFrom`, so a sweep cannot be pointed at it to act as the pool's owner.
- **No delay** on `setFeeRecipient` or `setSplits` (none existed). **No multisig** requirement.

## D63: simplification pass (owner's answers, 2026-10-29)

**D63. Fewer contracts and fewer owner levers; the Sunset as the built-in end; the fee recipient on its own notice.**
The flywheel review (docs/review/FLYWHEEL_REVIEW.md) found that most of the code around the game was plumbing between
contracts, not the game. The owner approved removing it (`CollectionGame` unfrozen; audit scope grows around it).

- **Removed:** KeeperFund, RevenueRouter, MilestoneReserve, the board and pricing modules (`src/modules/Policies.sol`),
  `script/SetBoard.s.sol`, the vault's continuity bucket and owner-settable adapter, the pool owner's auction and
  `beginMigration`, DrawRouter `returnToGame`, and the owner's separate `game.retire()`. Net: five contracts
  (two in `Policies.sol`) and one script fewer, one added (Sunset, 2,255 B).
- **Keeper pay in the game (owner: "the simplified version", plus a margin).** `sync` and `retireStep` pay the caller
  `(gasUsed + gasOverhead) × min(tx.gasprice, maxGasPrice) × (1 + marginBps)`: launch 3 gwei, 70,000, 10%. The owner
  asked for gas plus about 10% so that a third-party keeper has a reason to exist; gas-only would leave only the
  project's own bot. No flat fee, no interval. Pay comes from game cash within an allowance: the opening allowance
  (0.2 ETH, funded with the board) plus each capture's `opsBps` of its replacement cost; never from cash owed to
  replacements. It is an expense in `profit`. The burner pays its own keeper with the game's quote.
  Found while testing: keeper pay draws the operating reserve down by the tip, and the next `sync` refilled it from the
  vault and counted that as work, so two calls could pay each other until the allowance ran out. Funding now counts as
  work only when it covers the whole need and the need was at least one row's cost; `activate()` draws the refill of the
  opening reserve itself (`ready()` checks the vault can cover it).
- **Surplus split in the game.** Of each distribution, `continuityShareBps` (60%) goes to the vault while it is short of
  one Ape at the last price (capped at the shortfall), the rest to the burner. The vault's share is ordinary capital:
  with one balance, it also funds board growth (the growth test now sets the share to 0 to keep the vault short).
- **Milestone in the burner.** The burner locks `milestoneBps` (25%) of the game's ETH in `reserve`; `release(listingId)`
  (anyone; the game calls it on booking an Ape win) moves the whole reserve to the milestone bucket when FWA shows that
  listing settled to a player; `releaseRetired()` after retirement. Donations are ongoing ETH, never the reserve.
- **Settings instead of modules.** The pattern is stored in the game (`setPattern`) and applied lazily: each row takes its
  new backing the next time it is listed, and rows already owed are recosted at once. No stale rows, no rebind sweep.
  `setBoardSize` grows only, at most 50 rows per call, and only when the vault covers the rows and the game's need
  (a shrink would have to withdraw live prizes; not built).
- **Sunset successor (owner: "yes; instant trigger is fine because the only destination is buybacks").**
  `MigrationAuthority.sunset()` (owner, no notice) retires the game into the immutable `Sunset` contract and points
  trading fees at it. It has no owner and one outflow, the burner: every Ape is sold in a public Dutch auction from 150%
  to 25% of its recorded cost over 30 days, every wei paid goes to the burner in the same call, and the vault's capital
  and any fees are flushed there. This is the guarantee holders read in README, SECURITY and MIGRATION.
- **Migration: 72 hours and a code pin.** A migration to any other successor needs the owner's proposal, 72 hours (was
  24), and execution by anyone; the successor must be a contract and its code hash is pinned at proposal and checked at
  execution. Execution points trading fees at the successor (no separate owner step). No holder veto, no separate
  renounce (owner's decisions in the flywheel review).
- **Fee recipient on its own notice (owner: "if i want to add an $ENGINE buy and burn later … i shouldn't have to migrate
  the whole game for that").** `proposeFeeRecipient` / `executeFeeRecipient` on the MigrationAuthority: 72 hours, code
  pinned, the game keeps running. The hook accepts a new recipient only from the MigrationAuthority, so the owner
  cannot redirect fees without the notice.
- **Found and fixed in the review of this pass:**
  - *Paid work skipped with a low gas limit.* `sync` isolates each step in a `try`; with a limit too small for
    maintenance, the step failed inside its `try`, the vault refill still counted as work, and the call was paid. Gas
    estimates landed on that degraded path, so the rehearsal's keeper transactions ran out of gas. Now, when an
    isolated step fails with less than 1/8 of its gas left (it ran out somewhere down its call chain), the whole call
    reverts. Every limit from 20% to 98% of a full call reverts or does all the work (`test_tooLittleGasNeverSkipsWork`).
    A step that fails on its own still fails alone, given enough gas.
  - *The sunset was not final.* After `sunset()` the owner could still propose another successor or fee recipient and,
    72 hours later, redirect what had not yet reached the Sunset. Now `propose` is refused after a sunset, no fee
    recipient can be proposed once a migration or the sunset has started, and starting either cancels a pending one
    (fees follow the successor) (`test_sunsetIsFinal`).
  - *Keeper pay during retirement was limited only by the game's cash*, so raising the keeper parameters before a
    sunset could take the cash meant for it. Keeper pay is now always within the allowance
    (`test_retirementPayWithinTheAllowance`).
  - *Sunset:* `buy` refunds what is sent above the price; `flush` (a keeper job, sent only when ETH is waiting or the
    clock has not started) starts the auction clock, so it cannot stall at 150%.
  - Postflight accepts a fee recipient executed after its notice; stale interface and comment entries removed.
- **Fixed Seaport adapter.** The vault's marketplace adapter is set once at wiring.
- **Packs kept (owner: "they're first-party code; put them in the audit scope as such").**
- **Measured:** full suite 164 of 164, gas receipts 2 of 2, keeper 6 of 6, the anvil rehearsal every step (docs/receipts/test-run.txt); Slither 92 results, 6 High, all false positives or by design;
  syncs 50,000-110,000 gas cheaper than before (no external KeeperFund call; docs/receipts/gas.json); `CollectionGame`
  23,384 B (1,192 B headroom).

## D64: the flywheel build, items A-D (owner's go, 2026-10-29)

**D64. Launch values, the opening curve, play-keyed buybacks with tiered milestones, and the vault's fee overflow and
play meter.** The owner approved items A-D of docs/review/FLYWHEEL_REVIEW.md ("Skip the site. Do the rest"); E, F, G
and the site (H) are not built. Each value is owner-adjustable after launch except the hook's curve and the burner's
hard bounds.

- **A (LaunchConfig).** Fees 5% / 5%; the 50-row board (24 x 0.01, 16 x 0.02 Pack, 3 x 0.03 Pack, 1 x 0.04 Pack,
  3 x 0.05, 1 x 0.1, 1 x 0.15 Pack, 1 x 0.5: 1.666 ETH at cost); markup 10%; target 20%; K 4 (headroom 8); minimum live
  rows 70%; reserve 1 ETH; continuity 35%. The first bid threshold is 100% of the reference price (a new vault
  constructor argument, so no owner call is needed after deploy); after each purchase it is 75% of the price paid, as
  before. Activation needs the first Ape plus about 2.87 ETH (board, reserve, the 0.2 ETH opening keeper allowance).
- **B (CollectionHook).** The block schedule (15/10/5% on buys) is replaced by the owner's curve: buys and sells pay
  max(ordinary fee, 69% - one point a minute), linear per second from the pool's initialisation, ending at minute 64 at
  5%. Fixed in the hook, it can never return. Exact-output buys now pay the fee on the gross ETH (`net x f / (1 - f)`);
  before, they paid it on the net, which at 69% would have been 40.8% of the gross. The scanner risk (a 69% sell fee can
  get the coin labelled a honeypot) is the owner's accepted choice.
- **C (CollectionBurner, game).** 75% of the game's buyback ETH is locked in the milestone reserve. Releases are tiered
  and verified from FWA, no owner involved: a big prize (a Shape or Pack listed at 0.5 ETH or more) releases 15%, an Ape
  exit 60%, a second Ape exit within 24 hours the rest; the game asks at booking. Released ETH goes 1 ETH every 10
  minutes, the first slice at once (the keeper's next call: FWA settles wins without calling the protocol, and a swap
  inside the game's booking would put MEV on the keeper's sync). Ongoing slices follow play: 0.05 ETH + 0.005 ETH per
  draw since the last slice, the spacing 60 minutes halved every 20 draws down to 10 minutes. Hard bounds no owner can
  pass: a slice at most 1 ETH, spacing at least 10 minutes, impact at most 5%, deviation at most 3%.
  - *Added in implementation:* + 1% of the ongoing bucket per slice. The cadence model (sim/burner.py) showed that with
    the fee overflow (D) and light play the draw-keyed cadence spent only 31-45% of the inflow and the bucket grew
    without bound; with the term it spends 91-100% and the backlog stays at about 10-13 ETH with 5 ETH a day of overflow.
- **D (FundingVault).** Fee overflow: fees are counted in the swap path (one write) and split at the next sweep; while
  the bid is at its threshold and an Ape waits in custody or ten are listed, half go to the burner, never more than the
  vault holds beyond the game's capital, its growth and the bid. Play meter: the metered step is 0.05 ETH x min(4, 1 +
  draws since the last metered sweep / 50); the slow rate above the 120% ceiling is unchanged.
- **Verified.** New tests: the curve and exact-output basis (Market.t.sol), the overflow and meter (FlowForkTest),
  tiers and hard bounds (Units.t.sol), the cadence (Revenue.t.sol), big-prize release at booking (Collection.t.sol),
  and a vault conservation invariant. Sims re-run: pool.py (three years: gameplay opens on day 1 in every scenario; base
  10 / 3: 112 Apes bought, 87 won, 434.6 ETH of buybacks; trading >> play: 3,299 ETH of buybacks, of which 3,203 from the
  overflow, against 146 without it), launch.py (first-hour fees 39% on average with even volume; a minute-0 buyer of 1
  ETH needs 89 ETH of later buying to break even), keepers.py and maintenance.py (keeper pay of D63 on the 50-row board:
  the allowance carries maintenance up to about 0.6 gwei when every draw runs its own upkeep, about 0.9-1.1 gwei in batches
  of three to ten), sessions.py, burner.py (new). `CollectionGame` 23,598 B (978 B headroom).
- **K after the fork re-run (sim/results/throughput.md, the 50-row board on the D64 code).** Refunds of issued draws:
  K 3 0.3%, K 4 0.9%, K 5 1.2%; completion 39.0% / 40.4% / 42.8% of attempts (six streams, three hours each). None is 0,
  so by the rule agreed in the review K stays 4. The refunds come from heavy demand (listings staged while draws are in
  flight: 1 / 9 / 12) and a lazy keeper (3 at every K); a refunded player gets the price back and loses the VRF fee
  (0.019 / 0.041 / 0.051 ETH in the study at 1 gwei). The old board's 50-row prefix refunded 0.1% at K 4: the 70%
  minimum live rows lists more often while draws are in flight. K 3 is the option if refunds matter more than the 3.5%
  completion it costs (`setMaxInFlight`, at once).
- **Found in review and fixed:** the DrawRouter's fixed sweep budget (100,000 gas) no longer covered a sweep (a
  metered step now measures about 125,000, one that also splits the fee overflow about 210,000): raised to 250,000;
  router sweeps would otherwise have failed silently. An owner could set the Ape-exit tier to 0% and then renounce,
  locking the milestone reserve for good: the tier is now at least 10%. A release of an empty reserve no longer resets
  the burner's spacing. The overflow's "bid is full" test now uses the bid's actual fill target (the threshold, or the
  ceiling or `maxPrice` when lower). The keeper bot also retries big-prize releases (the game's `Captured` events).
- **Final verification (docs/receipts/test-run.txt).** Main run 170 / 170; gas receipts 3 / 3 (a sweep measures 145,645
  gas metered and 229,820 with the overflow split, inside the router's 250,000); throughput 3 / 3 on the 50-row board;
  keeper bot 6 / 6; the anvil rehearsal end to end (fee overflow 0.0738 ETH sent to buybacks and spent; migration capital
  exact); Slither on the D64 code: 93 results, the same six Highs at the same functions as on D63, all triaged
  (docs/AUDIT_SCOPE.md §7).

## D65: the owner's review of the flywheel (2026-10-29)

The owner took the milestone tiers (with the 10% floor), the opening curve on both sides, the 50-row board at 10%
markup and the first threshold at 100% as built, and asked for: an overflow that never fires while the board could
still use an Ape (and switches off once a waiting Ape is listed); K 3 for launch; the play meter removed (new audit
surface for little effect at expected volumes); the secondary model on the launch keeper rule; the throughput study
re-run on the 50-row board; the gas threshold on the site's closed state; a token-scanner plan; and a day-one fallback.

- **The overflow trigger (owner's choice after the model).** The rule first asked for, "an Ape waits in custody because
  the exposure target held it back", was built (a pool-owner counter of Apes deferred at the last listing pass) and
  modelled, and never fires: the game grows the board by the rows a held-back Ape needs, funded before the bid, within
  about an hour, so no Ape waits in any scenario (sim/results/pool.md "most queued" 0) and, with trading at 150 ETH a
  day against 0.5 of play, 2,849 ETH sat idle in the vault after three years because the bid is rate-limited. A
  "board has no room for one more Ape" rule sent 484 ETH; D64's rule (an Ape waiting or 10 listed) sent 3,277 but
  fired while the board could take Apes and slowed buying at base flows (112 Apes against 125). The owner chose the
  idle-ETH rule: while the game is active and the bid is at its fill target, `overflowBps` (50%) of the fees since the
  last sweep go to the burner, never more than the acquisition budget holds beyond the bid and one more Ape at
  `lastPrice`. Result: base flows 0.2 ETH of overflow and the same 125 Apes; trading ≫ play 2,917 ETH to buybacks and
  864 Apes (868 without); sudden popularity 3,750 ETH with the same Apes and wins. The vault no longer reads the pool
  owner for the overflow; the custody counter was removed again. `FlowParams` became `overflowBps` with
  `setOverflowBps` (0-100%).
- **Not before activation (found in the docs review).** Before activation the acquisition budget is the whole balance,
  so the rule as first written would have sent about half the opening hour's fees beyond two Apes' worth to buybacks
  before the game opened. `pendingOverflow` now returns 0 until the game is active, as the model always assumed
  (`test_noOverflowBeforeActivation`).
- **Play meter removed.** `meteredStep`, `drawsSinceSweep`, `lastSweepSeq` and the FWA sequence read are gone; above
  the threshold a sweep forwards `maxSweepWei`. Correction to D64's "changes little": that was measured on three
  scenarios. Under sustained heavy play (sudden popularity, 150 / 40 ETH a day) the meter bought 1,106 Apes and won
  1,067 against 830 and 823 without it. A fixed `maxSweepWei` of 0.1 ETH recovers most of it (1,074 / 1,044), leaves
  base flows unchanged (125 / 90) and in trading ≫ play buys 233 more barely played Apes and halves the overflow, so the
  launch step stays 0.05 ETH and raising it under heavy play is a runbook item.
- **K 3.** `maxInFlight` 3 (headroom 7). Fork re-run on the D65 code (receipts docs/receipts/throughput/board-d65/):
  refunds of issued draws 0.3% / 0.9% / 1.2% at K 3 / 4 / 5, completion 39.0% / 40.4% / 42.8%. Two Collection tests
  whose expectations were tied to headroom 8 were restated (the listing loop runs until the target binds; decay stops
  within one window's decay of the target's bound).
- **The secondary model on the launch keeper rule.** sim/economics.py pays gas + 70,000 × min(price, 3 gwei) × 1.1
  within the allowance (opening 0.2 ETH less listing the board), with router upkeep per draw by default (prizes always
  replaced; players pay what is not reimbursed) and a keepers-only variant. Reference (1 gwei): an Ape available for
  94.1% of demand, 7.88 wins, 87.0 ETH of surplus, players paying 0.0004 ETH a draw beyond the reimbursement; keepers
  only: open to 1.0 gwei (90%), 61% at 1.1, closed from 1.25, matching keepers.md's break-even. The D64 closure at 1
  gwei was the retired rule's artefact.
- **Site.** The "draws closed" message states the gas now and that above about 0.6 gwei (1 gwei batched) the allowance
  does not pay for refills, so a closure is expected and nothing is at risk.
- **Owner items written into docs/LAUNCH_CHECKLIST.md:** the scanner plan for keeping 69% on sells (publish the curve,
  pre-notify the checkers, re-check at minute ~70; a 30-40% sell peak is the unbuilt alternative), and the day-one
  fallback (contributions visible from minute one; buy the first Ape on day two or let the bar run up to a week: open).
- **docs/AUDIT_PROMPT.md:** the owner's fresh-discovery audit directions, with how they apply to an undeployed system
  (deploy with the repository's script on a pinned fork; what not to read).
- **Verification (docs/receipts/test-run.txt).** Main run 171 / 171; gas receipts 3 / 3 (a sweep measures 126,362 gas
  metered and 211,044 with the overflow split, inside the router's 250,000); throughput 3 / 3 on the 50-row board;
  keeper bot 6 / 6; site ABI and typecheck; the anvil rehearsal end to end (the overflow sent 0.0738 ETH to buybacks
  with the bid and one more Ape kept; migration capital exact); Slither on the D65 code: 95 results, the same six
  Highs at the same functions, two newly reported strict equalities in the unchanged `CollectionBurner.process`, both
  intended zero checks (docs/AUDIT_SCOPE.md §7).

## D66: fixes from the fresh-discovery audit (2026-10-30)

The owner ran the fresh-discovery audit (docs/AUDIT_PROMPT.md) on `004c0a4`; its report and ledger are in `audit/`
(commit 3886fb6). Each reproduced path was checked against the code and reproduced again in the project's own tests.

- **F-1, tiny reference price.** `sellToProtocol` takes any price from 1 wei, a donation takes `lastPrice` as its
  reference, and a reference under 4 wei rounds the 25% minimum notional to zero, so `_termOf` divides by zero and
  collection maintenance fails until the owner changes `minBps`. Fix: `CollectionPoolOwner.register` records any
  reference below `MIN_REF_COST` (0.01 ETH) as 0.01 ETH; the cash cost stays what was paid. Chosen over refusing small
  prices so that a bargain acquisition is never refused. Sunset prices from the reference, so its 25% floor is now at
  least 0.0025 ETH rather than zero.
- **F-2, adapter prefund.** The adapter returned its whole balance, so ETH anyone sent it beforehand came back mixed
  with the vault's change: at or above the order price `fillOrder` underflowed; below it the vault booked too low a
  price. Fix: the adapter returns exactly `msg.value − spent`, and the vault requires only that the adapter's balance
  did not grow. Stray ETH stays in the adapter, inert.
- **F-3, Pack stranded in delivery quarantine.** Naming the Packs contract as purchaser left a Pack prize undeliverable
  (the contract refuses its own Packs; Shapes refuses its own Shapes the same way), with only that contract able to
  claim the refund. Fix: `canPurchase` refuses the Shapes and Packs contracts as purchasers. FWA delivers with
  `transferFrom`, so no other launch token rejects delivery this way. Two comparisons against immutables; the gate
  stays far inside FWA's 100,000 gas stipend.
- **R-1, proxy nominee.** Already an accepted limit (SECURITY, MIGRATION): the code-hash pin covers only the address's
  own code. The runbook now makes "not upgradeable, no settable delegatecall" an explicit check for a successor or fee
  recipient.
- **Deployment gate.** `OWNER=0` in `script/env/mainnet.env` is the unfilled owner input; the deploy refuses it by
  design.
- Tests: `test_tinyReferenceIsFlooredAndMaintenanceKeepsWorking` (Collection), `test_adapterPrefundCannotBlockOrRepriceAFill`
  (Funding; the Seaport listing setup is now a shared helper), `test_shapesAndPacksCannotBePurchasers` (Packs).
- **Verification (docs/receipts/test-run.txt).** Main run 174 tests: 169 passed at once and the five invariants that
  failed to set up (the public RPC behind the fork timing out, HTTP 408) passed on re-run, all 13; gas receipts 3 / 3
  (`canPurchase` 44,099 gas with the new check, inside FWA's 100,000 stipend; sweeps 126,362 / 211,044); keeper bot
  6 / 6; the anvil rehearsal end to end (postflight before and after play, migration capital exact); Slither on the D66
  code: 93 results, nothing new from the fixes.
- **Owner decision (2026-10-30): keep 69% on sells.** The opening curve stays symmetric; the scanner plan in
  docs/LAUNCH_CHECKLIST.md item 6 is the mitigation.
- **Owner decision (2026-10-30): no day-one commitment.** If the first hour does not fund the first Ape and the
  opening capital, the game stays in funding mode with contributions open; the owner will judge whether to step in.

## D67: fixes from the round-2 audit (2026-10-30)

Round 2 (docs/AUDIT_PROMPT_2.md) audited `f44ab9f` on the round-1 block: the D66 fixes held under their reproductions and
new variants; two new paths were reproduced.

- **N-1 and N-2, system addresses as purchaser.** FWA lets the payer name any purchaser, and the D66 gate refused only
  Shapes and Packs. Naming the FWA pool settles a win without moving the prize (a self-transfer); for the collection
  NFT the game books a win and the burner releases 60% of the milestone reserve for an Ape that never left. Naming the
  pool owner, game, vault or collection contract delivers the prize where no first-party route recovers it. Fix:
  `canPurchase` refuses the FWA pool, the pool owner itself, the game, the vault, the migration authority, the
  collection, Shapes and Packs. A denylist of system addresses rather than refusing every contract, so smart-contract
  wallets keep playing; any other contract a payer names receives the prize like any winner. Defence in depth: the
  burner's `releaseBps` returns 0 for a listing settled to the pool itself. The gate's extra comparisons stay far
  inside FWA's 100,000 gas stipend.
- **R-1, extended.** Round 2 showed the same limit for a plain contract whose payout or refusal lives in storage.
  The runbook now requires a successor or fee recipient whose behaviour is fixed in code (no proxy, no admin-settable
  payout, forwarding or refusal) unless its controller is as trusted as the owner. The code-hash pin is unchanged.
- Tests: `test_systemAddressesCannotBePurchasers` (Packs; replaces the D66 test), `test_poolSelfWinReleasesNothing`
  (Collection).
- **Verification (docs/receipts/test-run.txt).** Main run 175 / 175 at once; gas receipts 3 / 3 (`canPurchase` 44,558
  gas, inside FWA's 100,000 stipend); keeper bot 6 / 6; the anvil rehearsal end to end (real draws admitted, postflight
  before and after play, migration capital exact); Slither on the D67 code: 95 results, nothing new from the fixes.

## D68: fixes from the round-3 audit (2026-10-30)

Round 3 (docs/AUDIT_PROMPT_3.md) re-tested `6d9f949` with both earlier rounds' outputs; it is a partial report. The D66
and D67 fixes held against both rounds' reproductions.

- **R3-1, R3-2, R3-11 (other addresses as purchaser): accepted, no code.** Fourteen more system and dependency
  addresses can be named as purchaser, and FWA delivers the prize there (or credits a refund there). Unlike round 2's
  pool-self case, where the prize never moved yet counted as won, here the prize really leaves the game exactly as in
  any win, and the burner's exit release matches a real exit: the payer won it and gave it to an address that cannot
  use it, at the payer's own cost. Any contract a payer names can be such an address, so no denylist can be complete;
  D67's list stays because it blocks the false-settlement cases and the self-custody quarantine.
- **R3-3 (Shapes mint fee change).** The game recorded owed rows at the cost when they were vacated (the listed
  prize's cost, with the fee at listing) and subtracted today's cost at restock, so a fee change made `replacementsOwed`
  wrong until the owner re-set the pattern: a payout before a costlier restock, or a phantom debt. Fix: a won row is
  owed at its current cost, and `sync` first recounts every owed row when Shapes' fee differs from `owedFee` (the fee
  the count was made at), before booking or paying out; `setPattern` shares the same recount. To keep booking cheap,
  a prize listed at today's fee (FWA numbers listings in order, `nextListingId`; the recount records where today's fee
  begins) whose row still asks for the same backing is owed at its own recorded cost, and only older prizes are priced
  again. Pricing every vacated row again cost about 30,000 gas a booked draw; this way a sync costs about 6,000 gas more
  (the fee check), and the keeper break-evens (0.58 / 0.99 / 0.91 / 1.09 gwei) are unchanged. The pool owner exposes
  `mintFee()`. `CollectionGame` is 24,053 B (523 B under EIP-170).
- **R3-12 (callback lowers the booked price).** `fillOrder` measured the price as the vault's balance change, so ETH
  arriving during the fill (a game payout a seller-chosen consideration recipient triggered by calling `Game.sync`)
  lowered it. Fix: the vault counts what the adapter returns during the call (transient storage) and books
  `cap − returned`; anything else that arrives is booked as what it is.
- **R3-10 (ETH stranded in the pool owner).** A seller-chosen consideration could pay the pool owner, which had no way
  to pass it on. Fix: `flushStray()` (anyone, non-reentrant) sends the pool owner's balance to the vault, where it is a
  contribution. Every legitimate ETH flow through the pool owner is forwarded in the same call.
- **Left open by round 3:** 15 Game/PoolOwner reentrancy detector paths and the dynamic FWA, Seaport and nominee
  callback variants; they go to the independent audit.
- Tests: `test_mintFeeChangeRecountsWhatTheGameOwes` (Game), `test_otherInflowDuringAFillDoesNotLowerThePrice` and
  `test_strayEthInThePoolOwnerGoesToTheVault` (Funding).
- **Verification (docs/receipts/test-run.txt).** Main run 178 tests: 173 passed at once and the five that hit the
  public RPC's storage and account timeouts (three invariants, the 50- and 100-Ape scenarios) passed on re-run; gas
  receipts 3 / 3 (a sync costs about 6,000 gas more than on D67, for the fee check; keeper break-evens unchanged);
  keeper bot 6 / 6; the anvil rehearsal end to end (postflight before and after play, migration capital exact);
  Slither on the D68 code: 92 results, nothing new from the fixes.


## D69: final-audit candidate (2026-10-30)

- **Coin identity: ApeBall (APEBALL).** The site launched under the owner's ticker `$APEBALL`, so the mainnet
  configuration now matches it (`script/LaunchConfig.sol`, `script/env/mainnet.env`). Name and symbol are constructor
  strings, not code: the runtime bytecode is unchanged. The earlier conflict search covered Ape Draw / ADRAW only;
  ApeBall needs its own search and legal clearance before deployment (docs/AUDIT_SCOPE.md section 9).
- **Site without Terms.** The owner removed the Terms page and its acceptance gate from the site; whether the paid
  game needs Terms is now a question for the legal review.
- **One branch.** The site, the local dev chain (`script/local.sh`, `keeper/src/local-vrf.mjs`) and round 3's audit
  outputs (`audit/round3/`) merge into `claude/focused-edison-5n720n`, the audit target. Final audit prompt:
  docs/AUDIT_PROMPT_FINAL.md.

## D70: final audit repairs, first batch (2026-10-31)

The final audit (Part A blind `567bf57`, Part B informed `1fb5e9e`, both on candidate `2e01202`) found two
permissionless paths and several site, owner and dependency limits. This batch fixes what is a bug under the existing
requirements; the rest waits on owner decisions listed below.

- **F1, F2, B-F1 (Seaport fill pays or books more than the seller's price).** Seaport 1.6 accepts consideration items a
  fulfiller appends past the seller's signed ones. Any caller could pay itself from the vault's cap (F1: 1.98 ETH on a
  4 ETH order) or pay the vault back, which the vault booked as a contribution while the fill booked it as spent (F2).
  A seller-signed item paying custody did the same through the public `flushStray` (B-F1). Fix in `SeaportAdapter`:
  the order must carry exactly `totalOriginalConsiderationItems` items, no item may pay the vault or custody, and
  CONTRACT orders are refused, since their offerer's `generateOrder` rather than a signature sets what Seaport pays
  (`BadOrder`; the last from the independent review of this batch). The Game accepts ETH only from the pool owner, so it cannot be a recipient. Marketplace fees and
  royalties a seller signs stay part of the price, as before.
- **B-F4 (draw paid to a fake pool).** `DrawRouter.draw` took the pool from the caller, and the site read it over RPC.
  Fix: `draw` requires `pool == game.pool()` (`WrongPool`); `game` comes from the site's bundled deployment record.
  `quote` and `measureUpkeep` stay unchecked (simulation only, no value).
- **B-F5 (swap for a counterfeit token).** The site read the coin's v4 pool key over RPC. Fix: the key is built from
  the bundled record (ETH, coin, fee 0, tick spacing 200, hook), mirroring `ProtocolLiquidity.poolKey`. A pool with
  the hook but other terms cannot exist: the hook only lets ProtocolLiquidity initialize its own pool.
- **B-F6 (harmful launch tick).** `launch(startTick)` accepted any in-range tick, and the highest sold 55.955% of the
  supply for 1 wei. The owner approved tick 161,200 (≈ 100 ETH FDV) in D38, so the tick is now fixed at deployment:
  `ProtocolLiquidity` takes it in its constructor (`startTick`, immutable, range-checked), `launch()` takes no
  argument, `LaunchConfig` sets it (not an environment value), and the postflight checks it. The owner chooses only
  when the market opens. ProtocolLiquidity 5,278 B.
- **Opening valuation lowered (owner, supersedes D38's 100 ETH).** The owner expected about a $69k opening market
  cap. Tick **173,000**: ≈ 32.6M coins per ETH, ≈ 30.7 ETH FDV, about $68.8k at the Chainlink ETH price on
  2026-10-31 ($2,242). The valuation is fixed in ETH, so its dollar value moves with ETH until launch. Depth equals
  the opening FDV, so the market is about 3.3× thinner than at 100 ETH (sim/launch.py, after the opening curve): a
  1 ETH buy takes 3.0% of supply and moves the price +6.3% (100 ETH: 0.9%, +1.9%); a 5 ETH buy takes 13.4% (+33%).
  The opening curve still makes minute-0 buying a loss: a 1 ETH buy at minute 0 needs about 28 ETH of later buying to
  break even (89 ETH at 100 ETH FDV), so early buying moves toward the end of the curve sooner.
- **Smaller.** The site keys a stored draw by game as well as chain and wallet. `script/rehearse-anvil.sh` and
  `ForkBase` default to `https://mainnet.gateway.tenderly.co`.
- **Sizes.** SeaportAdapter 3,817 B, DrawRouter 2,651 B; CollectionGame unchanged at 24,053 B (523 B margin).
- **Tests.** `test_adapterRejectsTipsAndProtocolRecipients` (Funding), `test_onlyTheGamesPool` (DrawRouter); Funding
  15/15, DrawRouter 8/8, Bid 18/18, Gas 1/1, ManyApes 4/4, Sizes 2/2 on the Tenderly fork. Gas receipts refreshed
  (a router draw costs about 1,700 gas more, for the pool check).

- **Opening curve kept (owner).** Reviewed against the lower valuation: 69% falling one point a minute to 5% at about
  minute 64 stays. A shorter curve (2 points a minute) would halve the time the sell fee sits above 49%, when wallet
  scanners may label the coin a honeypot, without changing the minute-0 break-even (about 28 ETH); the owner keeps
  64 minutes. Recorded alongside: fee-free side pools are a documented risk (docs/SECURITY.md item 11), and the
  ordinary fee (5% each way, owner-adjustable up to 10%) can be lowered after launch if volume is thin.
- **Heaviest keeper call back inside the margin.** `TxCap.test_heaviestCombinedCallsFitTheCap` failed on the audited
  candidate `2e01202`: booking 20 wins, restocking 8 Packs (each minting three Shapes) and listing 10 Apes in one
  call used 15,279,479 gas against the test's 15,099,494 (90% of EIP-7825's 16,777,216). Fixes in
  `CollectionPoolOwner`: Shapes' denominations (`pure` in Shapes) are read once per call instead of once per lookup,
  and a Pack prize no longer runs its makeup twice; a call that minted Packs lists at most `LIST_BATCH_AFTER_PACKS`
  (5) Apes (a transient flag), the rest on the next call. Now 12,609,653 gas. CollectionPoolOwner 21,589 B,
  CollectionGame unchanged.
- **Toolchain note, open.** Four `KeeperPay` tests fail identically on `2e01202`, `b17f777` and here: keeper pay
  exceeds the test's ceiling of measured gas plus overhead. Foundry is now 1.8.1; D68's receipt used 1.5.1, and on
  identical code `test_tenDrawCallPaidAtOneGwei` measured 10.6M gas then and 17.0M now. The gas the tests measure
  changed with the toolchain, not the contracts; this likely also inflated the TxCap figure. To confirm by rerunning
  under forge 1.5.1 before the release candidate.

**Waiting on owner decisions (not changed):**

1. F3: keeper pay may draw on the operating reserve and settlement exposure (only replacements owed are held back),
   capped by the keeper allowance. Accept and document, or hold back `protectedCash()` and risk unpaid keepers near
   the reserve.
2. B-F2: between an external Shapes mint-fee rise and the next `sync`, the vault sees the old need (tested shortfall
   0.000045 ETH). Accept, or recount on every vault read (Game has 523 B left).
3. B-F3: a board grown past about 500 owed rows makes a fee recount exceed EIP-7825's 16,777,216-gas cap. Cap board
   growth, or accept with an operating limit.
4. F4–F6, F8, F9: successor and fee-recipient nominees may be upgradeable or active contracts the owner or a third
   party controls. Decide who may control and benefit from a nominee.
5. F10: `renounceOwnership` with no proposal pending removes the retirement route. Block it, or accept.
6. F11: owner `sweepNFT` of unprotected NFTs to any address. Restrict the recipient, or accept.
7. F7, B-F7 and the Sunset 25% auction of a false-win BAYC: external FWA owner power and accepted D68 risks; confirm
   disclosure wording.

## D71: the coin trades only in its pool (2026-10-31)

- **Owner decision.** The coin launches transfer-restricted, as the owner's CC coin does (artcoins
  `ArtCoinsTokenV2`), and the ordinary fee stays 5% each way. Reason: an unrestricted coin can be traded in a
  fee-free side pool, and that volume funds neither the vault nor buybacks (SECURITY.md item 11).
- **Mechanism.** `CollectionToken._beforeTokenTransfer` (Solady calls it on every transfer path): while
  `restricted`, a transfer between two holders reverts; a transfer to or from the PoolManager passes up to a transient
  allowance and uses it up; ProtocolLiquidity may send (it seeds the pool once); mint and burn always pass.
  `CollectionHook._afterSwap` grants the allowance, `|delta.amount1()|`, the exact coin the trader settles or takes
  (the fee is all ETH). The hook serves one pool only (`beforeInitialize`), so an allowance only follows a canonical
  swap. Simplified from artcoins: no editable allowlist, no allowlist lock; the Admin owner's `unrestrict()` lifts the
  rule once and for good.
- **URC-5.** The token implements `IVenuePolicy` (Uniswap URC-5, Token Venue Policy, a Discussion draft): `Enforced`
  with the one canonical pool while restricted, `Preferred` after `unrestrict`, ERC-165, and refusals revert
  `VenueNotAllowed`. Declaration only; kept for routers and for visibility as an early adopter. If the draft changes,
  only these views go stale.
- **Accepted limits.** Coin credited inside the PoolManager by a fee-paid canonical swap can circulate there (a
  hookless v4 pool, ERC-6909 claims) without an ERC-20 transfer; a wallet balance in or out still needs a canonical
  swap. Renouncing the owner before `unrestrict` keeps the coin restricted for good. While restricted: no wallet
  transfers, no aggregators that route through their own contracts, no exchange deposits, and scanners may flag it.
- **Sizes.** CollectionToken 5,116 B, CollectionHook 7,561 B; CollectionGame unchanged.
- **Verification.** Market 12/12 on the Tenderly fork (restriction, side-pool settle refused, `unrestrict` and the
  URC-5 views, a buy and a Permit2 sell through Uniswap's real Universal Router with the site's encoding); unit tests;
  Revenue, Sunset, Lifecycle, Migration, Funding, Gas, DrawRouter, FwaPool, Governance and Outage 74/74; mainnet
  deploy simulation postflight passed, with a new check that the coin starts restricted and is wired to the Admin,
  ProtocolLiquidity and the PoolManager. Independent review: no high or critical finding; its low findings are the
  accepted limits above, and its one cosmetic URC-5 note (announce the canonical pool at construction) is applied.

## D72: fee overflow off at launch (2026-10-31)

- **Owner decision.** `overflowBps` launches at 0 (was 5,000, D64): every trading fee stays in the vault for Apes. The
  owner turns it on (`FundingVault.setOverflowBps`, 0-100%, from the next sweep, no notice) once the vault is deep.
- **Why.** In a hot start that cools, the 50% overflow sent the peak's fees to buybacks and left the vault only the bid
  and one more Ape for the quiet months. sim/pool.py, three years, hot 90 days (150 / 40 ETH a day of trading /
  gameplay) then cool (2 / 1): 50% overflow bought 97 Apes and 88 were won (800 ETH of buybacks, 323 from the
  overflow); 0% bought 141 and 95 were won (601 ETH of buybacks). In the steady base (10 / 3) the overflow barely
  triggers (0.2 ETH), so the change costs nothing there. Hot then dead: 113 Apes bought against 72, the same 67 won;
  the rest are held in custody. Trade-off: less buyback support during a hot period, when buybacks would buy the coin
  near its highs.
- **Unchanged.** The game's surplus split (35% to the vault while it is short of an Ape, the rest to buybacks); the
  overflow mechanism and its caps. The Bid tests exercise it at an owner-set 50%; the rehearsal turns it on before its
  overflow step.

## D73: opening keeper allowance 0.1 ETH (2026-10-31)

- **Owner decision.** `openingAllowance` is 0.1 ETH (was 0.2). It is keeper pay available before any capture,
  mainly for listing the opening board; it comes out of the game's cash, so it is part of what trading fees must fund
  before draws open: now the first Ape + about 2.77 ETH (1.666 board, 1 ETH reserve, 0.1 ETH).
- **Why it is enough.** Listing the 50-row board is about 7 keeper calls, roughly 45M gas: 0.05 ETH at 1 gwei, about
  0.15 ETH at the game's 3 gwei reimbursement cap. Unused allowance is not spent. If gas is high and the allowance runs
  out mid-listing, keepers go unpaid for the rest; the primary keeper bot acts on work whenever the basefee is at most
  3 gwei whether or not it is paid, so activation does not stall (the operator absorbs at most about 0.05 ETH of gas).
  Captures add 5% of each prize's cost to the allowance after that.
- sim/pool.py keeps 0.2 (its results predate this); the difference to activation timing is 0.1 ETH of fees.

## D74: all gameplay buybacks wait for a win (2026-10-31)

- **Owner decision.** `milestoneBps` launches at 100% (was 75%): everything the game's surplus sends to the burner is
  locked in its milestone reserve, so gameplay's buy-and-burn builds up and fires on wins instead of dripping out.
  Owner-adjustable (`setMilestoneBps`, `setTiers`).
- **Only an Ape, and all of it (owner, same day).** The tiers launch at `bigPrizeBps` 0 and `firstExitBps` 100%: a big
  Shape or Pack releases nothing, and an Ape pull releases the whole pot. The second-exit window no longer matters
  (the first exit already takes everything). Tests of the D64 tiers set them as an owner would.
- **What a release looks like.** Released ETH is spent 1 ETH every 10 minutes at most (hard caps), each slice moving
  the price at most 3%, the first at once: a 5 ETH release burns over about 50 minutes, which a single market buy
  could not do without being front-run.
- **What else changes.** Between wins, gameplay adds no buy pressure. The ongoing bucket now holds only the sunset's
  proceeds, donations and the vault's fee overflow (0% at launch, D72). Before the vault can afford the next Ape, 35%
  of each distribution still goes to the vault first (continuity share).

## D75: pay with winnings in one transaction (2026-10-31)

- **Owner decision.** "Pay with my winnings" (redeem the Shapes and Packs a draw won and draw again with the ETH) is one
  transaction on any wallet, not a sequence of redeems and a draw. The site's EIP-5792 batch gave one confirmation only
  on smart wallets; others needed one per Packs redeem plus the Shapes and the draw.
- **How.** `DrawRouter.redeemAndDraw(params, shapeIds, packIds)`: it takes the caller's Shapes and Packs
  (`transferFrom(msg.sender, router, id)`), redeems them (Shapes `redeemBatch`, each Pack `redeem`; both pay their
  owner, the router), then draws as `draw` does with that ETH plus any attached ETH, for the caller. FWA keeps the
  draws' cost; the rest returns to the caller with the change. `count` 0 only redeems. One transaction, so it is all
  or nothing: a failed draw leaves the prizes with the player.
- **What it asks of the player.** A one-time `setApprovalForAll(router)` on Shapes and on Packs (a batching wallet folds
  them into the first redeem-and-draw). The router moves only `msg.sender`'s tokens and only on the game's own Shapes
  and Packs contracts (read from `game.poolOwner()`), holds nothing after the transaction, and keeps `draw`'s pool
  check. A new router (it is replaceable) means approving again.
- **Why the router, not the game.** It is periphery: no state, no owner, wired into nothing; the game and the pool
  owner are untouched. Fork tests: `test/fork/DrawRouter.t.sol` (paying with a Shape and a Pack, change returned,
  redeem only, someone else's prizes, no approval, a fake pool).

## D76: players do the upkeep unpaid (2026-10-31)

- **Owner decision.** A player's draw through the DrawRouter still runs the game's upkeep (`sync`, then the vault's
  `sweep`) at the player's own gas cost, but the player is no longer paid for it. Keeper pay is for keepers.
- **How.** The router measures what arrives during the upkeep (the game's tip from the keeper allowance, the vault's
  sweep reward) and sends it to the vault, where it counts as a contribution to the Ape fund. The player gets back only
  FWA's change. Keepers calling `game.sync` and `vault.sweep` directly are paid as before; the keeper bot does.
- **What it changes.** A draw that runs upkeep costs the player its gas (≈ 0.2-0.9M gas when the site asks for it, at
  most 2.5M by the site's limit). The tip still counts against the keeper allowance, as before; it now ends in the vault
  instead of a player's wallet. The modelled figures in docs/ECONOMICS.md ("upkeep gas players pay beyond the
  reimbursement") assumed the old reimbursement and understate what players now pay.
- **Tests.** `test_drawRunsUpkeepUnpaid` (the player pays exactly the draw; the tip and the reward reach the vault).

## D77: the game's upkeep without keeper pay (2026-10-31)

- **Owner decision.** When a player's draw does the game's upkeep, the game pays nothing for it: no tip leaves the game
  and no keeper allowance is spent. Supersedes D76's routing of the tip to the vault (the sweep reward still goes back
  to the vault, which is the vault keeping it).
- **How.** `CollectionGame.upkeep(maxCount)`: `sync`'s work (`sync` now runs the same internal `_sync`, then pays its
  caller as before), paid to nobody, and returning 0 instead of reverting `NoWork` when there is nothing to do. Anyone
  may call it; nobody gains by it. The DrawRouter calls `upkeep` for a player's draw; keepers call `sync`.
- **What it changes.** The ETH a player-run upkeep used to cost the game stays in it and leaves as ordinary surplus;
  the keeper allowance is spent only on keepers. `CollectionGame` grows 129 B to 24,182 B (394 B under EIP-170).
- **Tests.** `test_upkeepDoesTheWorkUnpaid` (the same booking and listings as `sync` from the same state, no allowance
  spent, nobody paid), `test_upkeepWithNothingToDo`, and the DrawRouter upkeep tests (the game pays nothing for a
  player's draw).

## D78: a daily Ape decay, off at launch (2026-11-01)

- **Owner decision.** Add a time component to the Ape decay, set to 0 at launch, for the owner to switch on later, so
  an Ape in an idle game can still fall toward its minimum.
- **How.** `ListingParams.dailyDecayBps`: the notional falls by that share of the Ape's reference cost for each day it
  is in the draw, on top of the gameplay decay, never below `minBps`, never raising a published notional. A global
  decay clock (`decayClock()`, WAD-scaled bps of cost) runs at the rate and is checkpointed in `setListingParams`, so a
  rate switched on later counts from that moment (not from launch), a changed rate applies forward, and 0 stops it.
  Each listing records the clock when listed (`CListing.clockStart`, packed into the slot of `open`); a relisted Ape's
  drop so far is back-dated on the gameplay credit first and the rest on the clock, so it resumes without a jump or a
  pause (if the owner lowers either rate before a relist, the lower rates cannot rebuild the whole drop and decay
  waits at the published notional until they catch up, as it already did for `decayBps`). Bounds: at most 100% a day. Repricing is unchanged: the decay pass reprices once the drop reaches the 5% step
  (or the minimum), within the exposure target, at maintenance windows, which run on their interval even with no
  draws, so keepers do the time steps as paid work.
- **What it changes.** `CollectionPoolOwner` grows to 22,125 B (868 lines); `listingParams()` and `cListings()` each
  return one more field (site ABI regenerated). With the rate at 0 every notional is what it was before.
- **Tests.** `test_timeDecayStartsOffAndRunsFromSwitchOn` (off at launch, 30 idle days not counted, 0.06 ETH a day at
  1%, adds to gameplay decay, repriced with no gameplay, stops when off, the floor, the bound),
  `test_relistedApeResumesTimeDecay` and `test_relistedApeResumesBothDecays` (no jump, no pause; the second fails if
  the clock back-dating is removed). Collection, Governance, Funding, Lifecycle, Migration, TxCap and Sizes pass.

## D79: final audit round 2 fixes and owner decisions (2026-11-01)

The round 2 audit (`audit/final2/`, candidate `d56a28c`) reported its findings against that code; this entry records
what changed and what the owner decided for each.

- **Coin relay (Part A F1), fixed.** The coin's transient swap allowance is now one signed net counter: the hook passes
  each canonical swap's coin delta from the trader's side (positive: the trader may take coin out of the PoolManager;
  negative: the trader settles coin in), and a transfer out of the PoolManager uses up a positive balance, a transfer in
  a negative one. A buy and a sell that cancel inside one unlock leave nothing, so they can no longer carry a
  holder-to-holder transfer (`sync`, `transferFrom` in, `settle`, `take` out). `allowSwapTransfer(int256)`.
  `test_roundTripCannotRelayAHolderTransfer` fails on the old code; `test_netOfSeveralSwapsInOneUnlockSettles` keeps
  several swaps in one unlock working; the audit's `HookGate` proofs now revert with `VenueNotAllowed`.
- **Router game (Part A F2), fixed.** `DrawRouter` is bound to its game at deployment (`game()`); `draw` and
  `redeemAndDraw` refuse any other (`WrongGame`) before a token or wei moves, then check the pool as before. The audit's
  `RouterIdentity` proof now reverts with `WrongGame`; `test_onlyTheRoutersGame`.
- **Postflight (B6), widened.** It now checks the whole buyback cadence and tiers, all eight game settings, the opening
  keeper allowance (until keepers draw on it), every launch board row (until activation), the router's game, the
  Admin's coin, and that the configured opening tick is within sense (138,000-208,000: an opening value of the whole
  supply of about 1 to 1,000 ETH) before comparing it. `test/fork/Postflight.t.sol` changes each value and expects
  the postflight to name it.
- **Renounce (D71 accepted limit), fixed per owner.** `Admin.renounceOwnership` reverts `CoinRestricted` while the coin
  is restricted (`protect` records the coin once at deployment), so a renounce cannot leave holder transfers blocked
  forever.
- **Keeper gas limit (B6), fixed.** The keeper never acts above `GAS_PRICE_LIMIT_GWEI` (10), however old the work, and
  caps `maxFeePerGas` there.
- **Players' draws do light upkeep first (owner).** Within `KeeperParams.payDelay` (5 minutes at launch; the owner sets
  it with `setKeeperParams`, 0 to 1 hour, 0 turns it off) of an `upkeep` that did
  work, the game refuses a paid `sync` that used less than `PLAYER_UPKEEP_GAS` (2.5M, what a draw takes on through the
  DrawRouter): `LeftToPlayers`, so the next draw does it unpaid and the allowance is spent only when players are quiet
  or the work is heavy (listing batches, board growth: always paid, or busy periods would thin the board). Only an
  upkeep that did work starts the delay, so nobody blocks keeper pay without doing the work. `DrawRouter.measureUpkeep`
  now simulates `upkeep` (it simulated `sync`, which this would refuse). The 2.5M gas line is a constant. `test_lightSyncLeftToPlayersAfterTheirUpkeep`, `test_heavySyncPaidWhilePlayersDraw`.
- **Opening keeper allowance 1 ETH (owner: "set total cap to be high to start").** Was 0.1 ETH (D73). The allowance is
  a limit on pay, not money set aside: pay comes out of game cash as it is earned and the vault refills it, so a higher
  limit costs nothing until keepers earn it. Later the owner raises or lowers the rate captures add (`opsBps` in
  `setPricing`, 0-100%, frozen into each prize at listing); there is deliberately no instant top-up, because the
  allowance is what keeps an owner who also runs a keeper from paying itself the reserve.
- **Pack flag (TxCap note), kept.** The flag that shrinks a listing batch after Packs were minted is per transaction on
  purpose: the gas cap it keeps under is the transaction's.
- **Suite (B3).** The three DrawRouter failures came from `--fork-url` taking the forked chain's gas price (FWA's
  randomness fee depends on it): `ForkBase` pins it. The four KeeperPay ceilings now allow the game's pre-refund gas
  measurement up to 5/4 of the outer reading (EIP-3529's refund cap). Gas and LongRun run the buyback after the Ape win
  that releases the reserve (D74).
- **Keeper pay: gas plus a flat fee (owner).** `quoteTip = (gasUsed + gasOverhead) × min(tx.gasprice, maxGasPrice) +
  flatFee`; the 10% margin (D63) is gone. Launch flat fee 0.0002 ETH per useful call, bound 0.1 ETH; `maxGasPrice` and
  `gasOverhead` stay unbounded, so the owner can raise the cap if gas stays high. Why: at a 0.1 gwei basefee 10% of a
  1M-gas sync was about 0.00001 ETH, no reason for a third party to run. No hourly limit (D60's guard against splitting
  calls): every call must do work, the allowance caps the total, and light work goes to players while they draw. An
  exhausted allowance pays 0 and does not revert, so work never stops. The burner's keeper is paid by the same quote
  (within its 5% of the slice). Found while fixing KeeperPay: the game measures gas before refunds and a keeper pays after
  them, so the gas part runs about 6% over cost on the rehearsal's real transactions; kept.
- **Operating reserve 0.5 ETH (owner).** The reserve is a buffer, not solvency: won prizes are backed NFTs, and
  `replacementsOwed` and `exposure()` protect restocking and every draw in flight apart. It absorbs keeper pay, a Shapes
  fee rise before a recount, and booking timing; running short pauses purchases (the board falls below `minLiveBps`)
  until cash refills, and loses no player's prize or refund. The bound is now the largest prize (`reserveTarget >=
  maxBacking`, was twice it), and launch uses 0.5 ETH: activation needs about 2.27 ETH after the first Ape (was 2.77).
- **Owner decisions, accepted as they are.** Ape pricing bounds stay as coded (launch: 100% of cost, floor 25%); a
  near-zero Ape sale needs no minimum price (the owner can lift the ceiling and set the threshold to refill the bid);
  the buyback impact bound stays at 5% (300 at launch); fee recipient and successor stay owner-chosen after 72 hours'
  notice; a draw bought for a non-player purchaser is that purchaser's choice; coin claims traded inside the
  PoolManager are outside the coin's reach; no minimum ordinary fee; an Ape's recorded cost is the gross signed sale
  price (a seller's later contribution is separate); FWA's administrator can pause new draws; Shapes fee timing; the
  board size cap stays as coded.

## D80: round 3 focused re-audit fixes (2026-11-02)

The round 3 focused re-audit (`audit/final3/REPORT.md`) reported its findings against the keeper-pay code; this entry
records what changed and what the owner decided for each.

- **Flat fee per call (F1), fixed.** The round 2 flat fee (D79) let a caller split a backlog into many `sync(1)` calls
  and collect the fee on each. `sync` and `retireStep` take no argument: each settles, resolves and books up to
  `bookPerCall` requests (each of FWA `processAcquisitions`, open-request resolution and new sequences), an owner
  setting, 20 at launch. The caller no longer chooses the count, so the fee is paid once per useful call, not per split.
  `upkeep(maxCount)` (unpaid, the players' path through the DrawRouter) keeps its count. The requirement "a flat fee per
  useful call" now reads "a flat fee per useful call, with the count per call fixed by the owner".
- **Keeper pay may use the cash held for draws in flight (I1), accepted.** `_tip` pays from cash above
  `replacementsOwed`, so with the vault unable to refill it can spend the reserve and the in-flight `exposure()` buffer
  (within the allowance). A floor at `replacementsOwed + exposure()` was tried and dropped: right after launch the vault
  is near empty and `exposure()` is a worst case (every request in flight winning the costliest prize), so it often
  exceeds the game's cash (a router test: cash 0.694 ETH, exposure 1.503 ETH) and keepers would be paid nothing when
  maintenance matters most. What the buffer protects is restock speed, not players: a win is already listed and paid by
  FWA, and an unfunded replacement waits for the vault.
- **Bot paid calls that pay 0 (I2), fixed in the bot.** The keeper skips a paid `sync` once `keeperAvailable` is 0
  (it reads cash before the call, so a cash check would skip calls that collect proceeds or funding first); `retireStep`
  is always sent, so retirement finishes. `UNPAID=1` sends `sync` anyway. `SYNC_MAX_COUNT` is gone (the game fixes the count).
- **`maxPerCall` ceiling raised to 20 (owner; superseded by D81: ceilings 10 and 50, measured under the gas cap).** `setBoardParams(listBatch, maxPerCall, bookPerCall)`: `listBatch` 1-20,
  `maxPerCall` 1-20 (ceiling raised from 10; launch 8), `bookPerCall` 1-100 (launch 20). The higher ceiling lets the
  owner raise the restock batch later without a new contract. Withdrawals per retirement step stay 10 (fixed). Measure
  with `test/fork/TxCap.t.sol` before raising `maxPerCall` or `bookPerCall`: a call above EIP-7825's 16,777,216-gas cap
  cannot be sent until they are lowered. Postflight checks `bookPerCall` with the other board params.

## D81: round 4 final audit fixes (2026-11-02)
Final audit round 4 (`audit/final4/`, candidate `355cbc2`) found no unprivileged theft; the owner approved these fixes,
and kept every D79 accepted risk (owner pricing and markup, any successor, outside purchasers, FWA and Shapes
administration).

- **System contracts refused as purchasers (G3), fixed.** A payer could name the burner as a draw's purchaser: a won
  Ape landed there, the game booked the win and released buyback reserve, and nothing (not even the sunset) moved it
  again. `CollectionPoolOwner.wire(game, system)` records the rest of the system once (`isSystem`: the burner, the
  hook, ProtocolLiquidity, the coin, Admin, the Sunset, the adapter, Lens, the DrawRouter, the Draw Packs renderer) and `canPurchase` refuses
  them, adding one storage read to FWA's 100,000-gas check. Outside contracts stay admitted (R3-1, D68): no list of
  them can be complete. Postflight checks every entry.
- **Board-parameter ceilings measured under the gas cap (T1), fixed.** D80's `maxPerCall` ceiling of 20 let the owner
  choose settings whose maintenance call exceeds EIP-7825's 16,777,216-gas cap (24.6M at 20/20 on a board of
  four-Shape Packs), stalling upkeep until lowered. Measured on that board (block 26,284,000), each `maxPerCall` step
  costs about 1.0M gas (8: 12.60M, 10: 14.60M, 11: 15.61M, 12: 16.61M) and each booking about 56k (71 waiting wins:
  `bookPerCall` 20 12.38M, 50 14.07M, 100 15.25M). Ceilings are now `maxPerCall` 10 and `bookPerCall` 50, the highest
  within the repository's 90% margin (15,099,494 gas); `test/fork/TxCap.t.sol` checks the opening, combined and
  booking-backlog calls at them. Launch values unchanged (8 and 20). A pattern of heavier Packs (five or more Shapes)
  still needs measuring before it is set.
- **Site rounding (B6), fixed.** Amounts a user pays (draw price, cost per draw, the part of a redeem-and-draw paid from
  the wallet) round up and swap minimums round down, at the same two decimals (`ethUp`, `amtUp`, `ethDown`, `numDown`
  in `site/app/lib/format.ts`), so the screen never shows a lower charge or a higher guarantee than the transaction.
- **Deployment guards and readbacks (B6), fixed.** `Deploy` requires `DEPLOY_ENV=mainnet` exactly when connected to
  chain 1 (mainnet values cannot reach a fork, nor fork values mainnet); `deploy.sh` asks for `I_AM_THE_OWNER=yes`
  whenever the connected chain is 1, whatever the env name. Postflight now also checks the opening board size exactly
  (until activation), the pool owner's FWA approvals for the collection, Shapes and Packs, the coin and Packs names and
  symbols, the Packs renderer, and the purchaser exclusions; `Postflight.s.sol` loads Lens and the DrawRouter.
- **Wording.** The launch burns rounding dust (258 wei tested), so supply starts a few wei below 1,000,000,000; the
  owner rule names its exceptions (a fee recipient or successor after notice, `sweepNFT` of unrelated NFTs); Shapes'
  admin is the owner's address (E1 is an owner-key power); the Draw Packs admin powers are listed in ADMIN.md.
- **Kept as accepted.** The keeper bot's 10 gwei limit above the 3 gwei reimbursement (a backup keeper pays the
  difference to keep the game live); several paid `sync` calls in one transaction (70k overhead each, 0.00014 ETH for
  three); the router's caller-chosen measurement and stray balance (no player loss); the 553-row and 2,776-entry gas
  thresholds (owner growth or unreachable states); the five-minute listing delay after a Pack win.

## D82: the owner's rulebook review (2026-11-02)
The owner reviewed every launch rule in one pass (the ApeBall Rulebook: every rule read from the code, each marked
Keep, Change or Ask) and an asset-identity audit pass (`audit/identity-assurance/REPORT.md`, revision `50bda67`).
These are the owner's changes; everything marked Keep stays as it was.

- **An absolute Ape floor (owner).** The owner's rule: an Ape's notional stops at a fixed ETH amount, 1 ETH at launch,
  whatever it cost, not at a share of its cost. D59 had replaced the earlier fixed 1 ETH floor with `minBps` (25% of
  each Ape's cost) as one clause of a larger change; it was never put to the owner on its own. `ListingParams.minBps`
  becomes `minNotionalWei` (owner, 0.01-100 ETH). An Ape opens at `max(startBps x refCost, minNotionalWei)`, so one
  bought for 1 wei or 0.5 ETH opens at 1 ETH (it listed at 0.01 ETH before: the audit's cheap-seller path, at a
  hundredth of the odds now); its cash cost stays what was paid. Gameplay and time decay stop at the floor. A
  published notional never rises: a floor raised above one leaves it where it is; a lower floor lets Apes fall further,
  within the exposure target. `refCost` (the exposure reference and the sunset auction's basis) is unchanged, still at
  least `MIN_REF_COST` 0.01 ETH, so the sunset stays cost-based (owner) and a cheap Ape adds the exposure its cost
  implies. Relisting (a refunded delivery) back-dates decay from the same opening; BAYC delivery cannot fail under
  FWA's `transferFrom`, so that path is checked by inspection, not on the fork.
- **Unpaid light work instead of a refusal (owner).** A paid `sync` of light work (under `PLAYER_UPKEEP_GAS`) within
  `payDelay` of a player's upkeep now does the work and pays nothing; D79's `LeftToPlayers` revert is removed (the owner:
  "if someone wants to sync we should let them, just not pay them yet"). The keeper bot skips that case unless `UNPAID=1`.
- **No relisting over draws in flight (owner).** `_restock` lists only with nothing unsettled, even below the admission
  fill; purchases are closed there, so the wait is until requests in flight settle or expire (about 30 blocks). A listing
  staged over a request in flight could move its fee after the quote and refund it.
- **Sweep reward at the keeper formula (owner).** The sweep reward was 0.5% of what it forwards (0.005 ETH a sweep at
  the new metering); it is now `game.quoteTip(gas)` (gas at the capped gas price plus the flat fee), at most 0.01 ETH.
  The Seaport finder fee stays 0.5% of the bid (a bounty for finding an Ape listed below the bid, not a gas refund).
- **Renounce while restricted (owner).** `renounceOwnership` no longer requires the coin's restriction lifted (D79's
  guard is removed, with `Admin.coin`). Renouncing first makes the restriction permanent: the coin then moves only
  through swaps in its canonical pool.
- **Launch values (owner).** `maxInFlight` 10, FWA's own per-pool limit (D65 had 3; at 10 the worst case of ten
  requests on one quote all taking the cheapest prize had 2 refunded by FWA's slippage check,
  `test_launchInFlightBoundWorstCaseDrift`; at 3 none); `maxCooldown` 30 days (an FWA cooldown alone never closes
  purchases; FWA's own maximum is 7 days; the live-rows rule covers a slow relist); bid metering 1 ETH per 300 blocks
  (D59 had 0.05: the bid can rise about 24 ETH a day above its threshold) and 0.01 ETH per 300 blocks above the 120%
  ceiling (D61 had 0.0025); opening keeper allowance 0.2 ETH (D79 had 1 ETH) and 1% of each capture (`opsBps`, was 5%);
  Draw Packs "Balls" / BALLS (the template's "Collection Game Packs" had not been overridden for BAYC).
- **Kept after the owner's questions.** The burner's 5% tip cap (it pays from the slice, with no allowance, so the
  cap protects small slices; at 1 gwei a tip is about 1% of a 0.05 ETH slice); the 50% exposure ceiling (a backstop
  behind the 20% target); the 70% live-rows gate (odds are always the live ones; it protects the game's cash).
- **Open: the vault's funding reference.** `FundingVault._book` sets `lastPrice` to the price paid, so a consenting
  1-wei sale sets the next bid threshold to 0, the ceiling to 1 wei and `shortfall` to 0, and the Ape floor does not
  change that. A rule is proposed to the owner and not built.

## D83: the vault's funding reference (2026-11-02)
- **The problem** (`audit/identity-assurance/REPORT.md`). `FundingVault._book` set `lastPrice` to the price paid, and
  `lastPrice` set the next bid's threshold (75%) and ceiling (120%), the vault's `shortfall` (which caps the game's
  continuity share), the fee overflow's reserve for the next Ape and a donation's reference. A consenting 1-wei sale
  therefore set the threshold to 0, the ceiling to 1 wei and `shortfall` to 0: the bid could climb back only at the slow
  rate (weeks), and the game stopped sending the vault its share. D82's Ape floor did not touch this.
- **The rule (owner, the recommended option).** `lastPrice` stays the exact price paid. A new `referencePrice` takes
  over every consumer above. Each acquisition at price `p` sets it to `max(p, previous x (1 - maxDropBps), the Ape
  floor)`, the floor being `CollectionPoolOwner.minNotionalWei` read live (1 ETH). `BidParams.maxDropBps` is the owner's
  (1-100%; 25% at launch; 100% is the floor-only rule). Cash cost and acquisition spend stay the exact price.
- **Effect** (`test/fork/FundingReference.t.sol`, 9 tests). After a 6 ETH reference, a 1-wei sale leaves the reference at
  4.5 ETH (threshold 3.375, ceiling 5.4) and the bid back at 6 ETH in about 60 hours; repeated 1-wei sales walk it 25% a
  step down to the 1 ETH floor. A genuine fall 6, 5, 4, 3 ETH is followed exactly; a crash 6 to 3 ETH in one purchase
  is followed over two more (4.5, 3.375, 3); a rise is followed at once. Lens returns `referencePrice`; postflight checks
  it and `maxDropBps`. The considered alternative, floor only, would have left about 20 days of recovery after one cheap
  sale.

## D84: an allowlist for the restricted coin (2026-11-02)
- **Owner decision.** "We need an allowlist like FWA distributors." D71's restriction had no exemptions beyond the
  canonical pool's swaps, ProtocolLiquidity's one-time seeding, mint and burn (earlier today the owner had kept it
  that way; this reverses it).
- **The rule.** `CollectionToken.setAllowed(account, allowed)`, the Admin owner only. While the coin is restricted, a
  transfer from or to an allowed address passes, as FWA lets a distributor send and receive. A transfer through the
  PoolManager always takes the existing swap rule, allowed or not, and the PoolManager (and the zero address) can never
  be allowed: otherwise an allowed contract could move coin through Uniswap without a canonical swap, or a hookless pool
  could settle. At most 50 addresses (`MAX_ALLOWED`), so the URC-5 `externalVenues` list stays complete; `allowedList()`
  returns them. Empty at launch (postflight checks it). After a renounce the list is frozen as it stands.
- **The power it adds.** The owner can let chosen addresses hold and pass on the coin while holders cannot; an allowed
  exchange or pool contract could host trading that pays no fee to the vault. Recorded in SECURITY.md as an owner power.
- **Tests.** `test/fork/CoinAllowlist.t.sol` (7): only the owner sets it; an allowed contract receives and sends;
  holders still cannot; removal closes it; the PoolManager and zero are refused; an allowed address sending straight to
  the PoolManager still reverts; URC-5 reports the list; the cap holds; a renounce freezes it.

## D85: round 5 audit fixes (2026-11-02)
`audit/final5/REPORT.md` (candidate `0a7229b`) found five requirement violations; the owner asked for all five fixed plus
a code limit on Pack size.

- **F1, one booking budget.** `_advance` gave `_resolveOpen` and `_see` each the full count, so one call could book twice
  `bookPerCall` (the audit: ten open plus fifty new at 10/50 cost 17.17M gas, over EIP-7825's cap). They now share one
  budget, and `upkeep(maxCount)` is capped at `bookPerCall` (a caller's large count was unbounded: 17.75M). Measured
  again on the audit's own cases with the shared budget: at `bookPerCall` 50 still 16.52M, at 30 15.39M, both over the
  90% margin (15,099,494); at 20, 14.83M (ten open plus new bookings) and 14.80M (`upkeep(1000)`). `MAX_BOOK_PER_CALL` is
  now 20, the launch value. `test/fork/TxCap.t.sol` adds both cases at the ceilings.
- **Pack limit (owner).** No Draw Pack prize may hold more than four Shapes (`CollectionPoolOwner.MAX_PACK_SHAPES`):
  `prizeCost` refuses it, so `setPattern` does. The audit measured five-Shape Packs at 15.94M at the ceilings (over the
  margin, even at `bookPerCall` 30, since that call is driven by relisting) and six at 17.41M (over the cap); four-Shape
  Packs, the launch board's heaviest, are what every ceiling is measured with.
- **F2 and F3, exact display rounding.** The directional formatters (`ethUp`, `ethDown`, `amtUp`, `amtDown`, `numDown`) now
  round with integer arithmetic on the wei amount, so no browser's `Intl` support changes the direction; refunds,
  withdrawals, prize backing and redeem change (amounts received) round down; the refunded-ticket total too.
- **F4, the owner's affirmation in the script.** `Deploy.run` refuses a real broadcast on chain 1 without
  `I_AM_THE_OWNER=yes` (`vm.isContext(ScriptBroadcast)`), so a direct `forge script --broadcast` cannot skip the shell's
  check. Checked against a local chain reporting id 1: the broadcast stopped before any transaction.
- **F5, the fee route.** Postflight requires the vault as the fee recipient until a fee-recipient proposal or a
  migration or the sunset has started (`feeProposedAt`, `started`); then any contract.

## D86: the coin's metadata, as artcoins (2026-11-02)
- **What was missing.** The coin had only a name, symbol and decimals: the scaffold (`aaa396c`, 2026-10-27) took Draw
  Shapes' `EngineToken` "without the renderer", and D71 took only artcoins' transfer restriction. The owner expected
  artcoins' metadata system.
- **The port** (from `artcoins/contracts/artcoins/src/ArtCoinsToken.sol`). `contractURI()` (ERC-7572) and `tokenURI()`
  return `{"name","symbol","description","image"}` as a base64 JSON data URI, built from `metadata()` and `imageUrl()`, or
  the whole URI from `IMetadataRenderer(renderer).contractURI(token)` when the Admin owner has set one
  (`setMetadataRenderer`; zero: the built-in default; an address without code is refused). `updateImage` and
  `updateMetadata` (Admin owner) change the stored values; every change emits `ContractURIUpdated` (and `UpdateImage`,
  `UpdateMetadata`, `MetadataRendererUpdated`). Strings are JSON-escaped. After a renounce nothing can change.
- **Launch values.** `COIN_IMAGE` and `COIN_DESCRIPTION` in `mainnet.env` (empty allowed; the owner may set them later);
  postflight checks them and that no renderer is set. Name and symbol stay fixed at deploy.
- **Limits.** Most wallets and Uniswap do not read an ERC-20's `contractURI` today; the logo still comes from Etherscan,
  CoinGecko and token-list submissions. Tests: `test/fork/CoinMetadata.t.sol` (7). CollectionToken 10,038 B.

## D87: a $LAYER share, as artcoins' coins (2026-11-02)
- **Owner decision.** Keep artcoins' pattern of sending a small share to buy and burn $LAYER, although ApeBall does not
  launch from artcoins' deployer: **0.1% of the trading fees**, and only from fees received after the launch fee curve
  has ended.
- **Mechanism.** The vault records trading fees as they arrive (`unsplitFees`); from the first fee after the hook's
  `openingFee()` reports no seconds left to the ordinary fee (about minute 64), it also counts them in `layerFees`
  (`layerStarted` set once, then no more hook reads). Each sweep sends `layerBps` (10, owner 0-500) of `layerFees`,
  never more than the vault holds, to artcoins' live $LAYER BurnRouter `0x2eDBdF011768d8cd4Ef537658b41440900C52000`
  (for $LAYER `0xb7287e4A5b605aB92A8589C62af8A4ebD347E6c9`), off the top before the fee overflow. That router has no
  withdrawal: anyone may make it buy and burn $LAYER once it holds 0.01 ETH (its own threshold), for a 0.5% reward.
  The owner can replace the router only with one reporting the same `layerToken`, as artcoins' fee controller does.
- **Effect.** 0.1% of fees is 0.005% of volume at the 5% fee; the router's 0.01 ETH minimum then takes about 10 ETH of
  ApeBall fees (about 200 ETH of volume) per burn, and the share waits in the router meanwhile.
- **Wiring.** The vault learns the hook at wiring (`wire` gains the hook and the router); postflight checks the share,
  router, token and hook. Tests: `test/fork/LayerShare.t.sol` (6), including a real buy-and-burn on the fork; the
  vault conservation invariant counts `layerOut`. FundingVault 13,794 B.

## D88: round 6 audit fixes, and a 1% $LAYER share (2026-11-02)
`audit/final6/REPORT.md` (candidate `febf575`) found eight issues; the owner asked for the recommended batch, and raised
the $LAYER share from 0.1% to 1% of the trading fees after the launch curve.

- **F6-1, the share took protected ETH.** `pendingLayer` was capped only at the vault's whole balance, so a fee spent on
  the game's capital before a sweep left its share counted, and a later contribution the game still needed paid it.
  The share is now capped at what the vault may spend beyond the live bid (`acquisitionBudget` less the bid, which
  already keeps the game's capital and growth), as the fee overflow is; the overflow keeps room for the share. A share
  that does not fit is not carried over (as the overflow). `test/fork/LayerShare.t.sol::test_shareNeverTakesTheGamesCapital`
  replays the audit's sequence with a real canonical swap.
- **F6-8, router replacement removed.** `setLayerBurner` let the owner swap in any contract reporting the same token,
  which could keep the share. The router is now fixed at wiring; the owner can only change `layerBps` (0 stops it).
- **The share: 1% of the fees** (`layerBps` 100; was 10). On a 0.1 ETH trade at the 5% fee: 0.00005 ETH to $LAYER,
  0.00495 ETH to the game. The router's 0.01 ETH minimum then takes about 1 ETH of fees (about 20 ETH of volume) per
  burn. It stays in the vault and goes at each sweep, not from the hook on every swap (owner, 2026-11-02): a transfer per
  swap would cost about 12,000 gas, more than the share on trades under about 0.024 ETH at 1 gwei, and would put the
  router in every trade's path.
- **F6-6, the postflight fee route.** The later-state branch (any contract after a proposal) was unreachable, since the
  migration checks above it refuse a pending proposal or a started migration or sunset, and weak where it applied.
  Postflight now requires the vault as the fee recipient.
- **F6-2, a draw retry could charge more than shown.** A draw is prepared only while neither the ticket nor the
  randomness fee is above the price shown (otherwise the price is refreshed and nothing is sent), and the retry after an
  inventory-version mismatch is simulated too.
- **F6-3, the swap receipt.** The confirmation rounds what arrived down.
- **F6-4, redeem change.** "Pay with my winnings" counts the change and the wallet's part against the most the draw can
  take (the randomness fee with its 30% margin) and says "at least"; it holds while the wallet keeps the gas price the
  site sets.
- **F6-5, a late draw after "Stop waiting".** The receipt is still watched; a draw mined later while the page is open is
  followed again (unless another draw was sent since). After a reload a stopped draw is not shown; its draws count.
- **F6-7, invalid metadata bytes: accepted.** The Admin owner can store bytes that are not UTF-8 as the description or
  image, which makes the default JSON invalid. Owner input only; no contract reads it. The owner should set plain text.
- **External, not ours.** At the audit's pin FWA's factory had `poolCreationEnabled` false (true at the test block
  26,284,000): a launch needs FWA's factory open, or FWA's new contracts.

FundingVault 13,546 B (was 13,794).

## D89: stay on FWA V2 (2026-11-02)
- **What happened.** FWA deployed new community pool contracts (factory `0x8919…477C`, block 26,328,828) and switched
  off pool creation on the V2 factory `0xF5A3…300c` at block 26,329,277 (19:46:59 UTC). Existing V2 pools keep running
  (purchases on, randomness not paused).
- **Tested, not used.** ApeBall works on the community pools with two changes (a `createPool` without the fee
  argument, and booking the base price as the owner's proceeds), 264 of 274 tests passing on a fork with FWA's launch
  switches opened locally. But a community pool pays the owner the base price only and FWA keeps the whole 5% edge
  (a V2 pool pays the owner half): the game's margin falls from about 11% to about 8.7% of every ticket, for no benefit
  we need (no creation fee, a fixed edge). That work is kept on branch `claude/fwa-community-pools` (`72d5179`), not
  merged.
- **Owner decision.** Stay on V2. FWA's founder will switch V2 pool creation back on for our deploy. The deploy must
  check `poolCreationEnabled()` on the V2 factory first (docs/DEPLOY.md).

## D90: the $LAYER share taken at the hook (2026-11-02)
- **Owner decision.** The vault's $LAYER share (D87, D88) had become a tally paid from whatever ETH was free at a
  sweep: skipped when none was, paid from donations when they made some free, and stuck behind the sweep reward (round 7
  F7-1). The owner wants it to be a trading fee, taken at the hook, at 1%, adjustable later, with the destination
  updatable.
- **Mechanism.** `CollectionHook._payFee`: once the opening curve is down to that side's ordinary fee, `layerBps` (100,
  owner 0-500) of each fee goes to `layerTap`, the rest to the fee recipient (the vault), in the same swap. The
  `LayerTap` (new, no owner) forwards everything it holds to artcoins' $LAYER BurnRouter `0x2eDB…2000`, fixed in it: by
  itself in the swap that brings it to the router's 0.01 ETH minimum (a 30,000-gas stipend, failure ignored), or when
  anyone calls `flush`. A router that refuses ETH never blocks a swap; the ETH waits in the tap. The owner sets the
  share and the tap together (`setLayer(tap, bps)`; a tap must be a contract; tap 0 with share 0 turns it off). The tap
  is on the system purchaser deny-list (round 4 G3); postflight checks the share, the tap, its router and token.
- **Accepted owner power.** The owner can point the share at any contract: with a compromised key, up to 5% of each
  later trading fee (round 6 F6-8's concern, accepted for upgradability). A tap that refuses ETH would make swaps revert
  until it is changed: point the hook only at LayerTaps.
- **The vault.** Every $LAYER line is removed (back to its D86 form): no fee tally, no hook read during swaps, no share
  at the sweep, no router. FundingVault 11,963 B (was 13,546). Round 7 F7-1's cause stays fixed for the overflow: a
  sweep whose overflow was its work ends unpaid instead of reverting when the bid's room cannot cover the reward.
- **A 0.1 ETH swap after the launch curve** (5% fee): 0.005 ETH fee, of which 0.00005 ETH (1%) to $LAYER and 0.00495 ETH
  to the vault; 0.095 ETH is swapped. The share's transfer adds about 6,200 gas to the swap (measured, warm), about
  0.0000019 ETH at 0.3 gwei, paid by the trader. During the curve the whole fee goes to the vault.
- **Round 7 site fixes.** F7-3: a sped-up transaction is followed only while its draw is still the one followed, so a
  newer draw sent after "Stop waiting" stays. F7-2: the redeem line says "about" the change, since FWA can raise its
  randomness fee before the transaction lands (the router does not cap what it forwards to FWA).
- **Sizes.** CollectionHook 8,025 B; LayerTap 596 B.

## D91: the market opens only after the FWA pool exists (2026-11-02)
- **Owner decision.** The coin must not trade before everything else is in place, so a failure anywhere in the
  deployment leaves nothing tradable. The coin contract exists from the deployment (every coin in ProtocolLiquidity,
  transfers restricted, no pool), but `ProtocolLiquidity.launch()` now reverts `NoFwaPool` until the game's pool owner
  has created its FWA pool, the deployment's last step before opening (docs/DEPLOY.md, steps 6 and 8).
- **Mechanism.** ProtocolLiquidity learns the pool owner at wiring (`wire(hook, poolOwner)`); postflight checks it.
  Tests: `test/fork/Market.t.sol::test_launchWaitsForTheFwaPool`; the fork base creates the FWA pool before opening the
  market when a test has not.


## D92: round 8 observations accepted; docs corrected (2026-11-02)
- **Owner decision.** Round 8 (candidate 06f9be5, code = bcd60bb) found no violation of D90/D91. Both observations are
  kept as accepted risks; no code changes.
- **The redeem change is an estimate.** If FWA raises its randomness fee between the site's quote and inclusion, the
  change returned can be well below the "about" figure (round 8 fixture: 0.03 ETH quoted, 0.011105 ETH returned). The
  wallet never pays more than the prepared maximum; the router does not cap FWA's fee. Kept: a cap would guard a rare
  external change at the cost of failed draws.
- **The $LAYER share outlives the fee route.** A migration, a new fee recipient or the sunset changes where the rest of
  each fee goes; the share keeps going to the owner's tap, and `setLayer` changes it at once, without the 72-hour
  notice, at any stage (D90's accepted owner power, up to 5% of each later fee, or swaps reverting with a refusing tap).
- **Docs corrected.** SPEC: vault conservation drops the removed `layerOut`; the ordinary-fee row and section 8 state
  the share and the immediate `setLayer` power. ADMIN and MIGRATION: the fee-route rows, "what no call does" and
  "what the owner can steer" name the share. DEPLOY: gas is the dry run's ≈ 54.4M estimate (block 26,330,569; ≈ 0.054
  ETH at 1 gwei), and the deploy order and record list include the LayerTap and `layerTap`.
