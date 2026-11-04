# Runbook

How the system runs day to day, who does what, how to recover, and what the owner does. Routine operation needs no
owner wallet: every maintenance call is permissionless, and the game pays whoever calls `sync` (or, after retirement,
`retireStep`) its gas plus a flat fee, within the allowance captures earn (D63, D79).

## Normal operation

| Job | Call | When | Who |
| --- | --- | --- | --- |
| Settle FWA requests | FWA `processAcquisitions(n)` | FWA does it in the VRF callback; anyone can call | anyone (the DrawRouter before each draw; `sync` also tries it) |
| Book, replace, list and reprice Apes, grow the board, admit, fund, distribute | `CollectionGame.sync()` | whenever it does not revert `NoWork` | players' draws through the DrawRouter when the upkeep is light (≤ 2.5M gas measured; unpaid, D77); keepers for heavy calls and as backstop (gas + a flat fee, within the allowance; within `payDelay` of a player's upkeep a paid `sync` of light work does the work unpaid, D82, so the keeper bot skips it unless `UNPAID=1`) |
| Split fees, meter ETH into the live bid | `FundingVault.sweep()`: first sends `pendingOverflow()` (the fee overflow) to the burner, then forwards into the bid | below the activation threshold whenever there is ETH to add; above it once per 300 blocks, 1 ETH a step (0.01 ETH above the 120% ceiling; D82); a sweep with only overflow to send runs at any time | anyone, rewarded its gas plus the flat fee at the game's keeper formula, capped at 0.01 ETH, from the vault's general ETH (D82; nothing for overflow): players' draws (DrawRouter), keepers, sellers |
| Activate | `CollectionGame.activate()` | once, when `ready()` | anyone |
| Distribute surplus | inside `sync`: of each distribution, `continuityShareBps` (35%) to the vault while it is short of one Ape (at most `shortfall()`), the rest to the CollectionBurner (all of it locked in the milestone reserve, D74) | when the distributable amount reaches `minDistribution` (0.01 ETH) | whoever syncs |
| Milestone release | `CollectionBurner.release(listingId)` | the game does it when it books a delivered big prize (a Shape or Pack listed at ≥ 0.5 ETH: 15% of the reserve) or Ape win (60%; a second Ape win within 24 hours of the last: the rest); anyone as backup | anyone (keepers' `release` job covers Ape wins and big prizes) |
| Buy and burn | `CollectionBurner.process(0)` | once `nextSlice()`'s `runAt` has passed and it holds ETH: released milestone ETH first, 1 ETH every 10 minutes (the first slice of a release at once); ongoing slices every 60 minutes when idle, down to every 10 as draws come | keepers (reimbursed from the slice at the game's keeper rate, ≤ 5% of it) |
| Acquire NFTs | `FundingVault.sellToProtocol` (holders), `fillOrder(tokenId, maxSpend, data)` (anyone, through the Seaport adapter fixed at deployment) | when the bid suits a seller | holders / anyone |
| Record an Ape's outcome | `CollectionPoolOwner.settleListing(listingId)` | the game does it while booking; anyone as backup (e.g. a delivery refunded after retirement) | anyone |
| Retirement and hand-over | `CollectionGame.retireStep()`; MigrationAuthority `migrateApes(n)`, `migrateCapital()`; `Sunset.flush()`; `CollectionBurner.releaseRetired()` | only after a migration's execution or the sunset | anyone (keepers do it) |

## Keepers

`keeper/` (Node 22, viem). Run one **primary** (`MODE=primary`, `POLL_SECONDS=12`) and at least one **backup**
(`MODE=backup`, default 6-hour wait or basefee below 1 gwei) on separate infrastructure with separate keys and RPCs.
Each simulates every job first and only sends those that would succeed. Keys are runtime secrets.

Jobs (`keeper/src/policy.mjs`), in order: while the game runs, `sync`, `activate` (once `ready()`), `release` for any
delivered Ape win or big prize the burner has not released (normally the game does it while booking; the bot scans the
pool owner's `CollectionWon` and the game's `Captured` events and releases whatever `qualifies`), `buyback`
(`CollectionBurner.process`, once `nextSlice()`'s `runAt` has passed) and `sweep`. While retiring: FWA `processAcquisitions` and `retireStep`. Once retired:
`retireStep` (late settlements), `migrateApes`, `migrateCapital`, `flushSunset` (`Sunset.flush`), `releaseRetired`
(while the burner holds a milestone reserve) and `buyback`. Keepers do not settle draws: FWA's callback and players (the
site's DrawRouter) do. Players' draws through the DrawRouter also run `sync` and `sweep`, so keepers are a backstop.

**Pay.** `sync` and `retireStep` pay their caller `quoteTip(gasUsed) = (gasUsed + gasOverhead) × min(tx gas price,
maxGasPrice) + flatFee`: at launch 70,000 gas overhead, 3 gwei cap (above it gas is reimbursed at 3 gwei, never
refused; the owner raises `maxGasPrice` if gas stays high) and a 0.0002 ETH flat fee per useful call, with the count per
call fixed by the owner (`bookPerCall`) so a backlog cannot be split into many paid calls, so a third-party
keeper has a reason to run at any gas price. No interval. Within 5 minutes (`payDelay`) of a player's upkeep that did
work, a paid `sync` of light work (under 2.5M gas) does the work and is paid nothing (D82; a no-work call still reverts `NoWork`); the keeper bot skips such light work unless `UNPAID=1`. The game
pays within `keeperAvailable()` (= `keeperAllowance - keeperPaid`): the allowance starts at the 0.2 ETH opening allowance (D82)
(listing the opening board) and grows by each capture's `opsBps` (1%, frozen at listing, D82) of its replacement cost. It
never pays out of cash owed to replacements; during retirement (nothing owed) it may pay from any cash, but still never
above the allowance. A step that fails with less than 1/8 of its starting gas left reverts the whole call (`OutOfGas`):
send enough gas (estimate it) rather than a tight limit. Keeper pay is an expense
(`profit = revenue - prizeExpense - keeperPaid`). A call with nothing to do reverts `NoWork`; refilling the reserve from
the vault counts as work only when it covers the whole need and the need was at least one row's cost (`rowCost`), so
the dust keeper pay itself draws from the reserve never earns the next call a fee. The burner reimburses its own keeper
from each slice with the game's `quoteTip`, at most 5% of the slice.

**Watch**: `keeperAvailable()` (the allowance left), keeper wallet balances, `KeeperPaid` and `StepFailed` events on the
game, and **the basefee**: above about 1 gwei on average the allowance captures earn no longer covers maintenance (D49,
docs/ECONOMICS.md section 8; on the 50-row board with D63's pay, 0.9-1.1 gwei at 3-10 draws per call and 0.58 gwei when
every draw is its own call: sim/results/keepers.md), and above 3 gwei gas is
reimbursed only at 3 gwei. The site's "draws closed" message states the gas price above which the allowance no longer
pays for refills (about 0.6 gwei with per-draw upkeep, about 1 gwei when keepers batch), so a closure in high gas reads
as expected. Below the ceiling the allowance builds up unspent and carries keepers through short gas
spikes. Through a long high-gas period keepers are paid only as far as the allowance reaches: raise `opsBps`
(`setPricing`, for prizes listed from then on) or `maxGasPrice` (`setKeeperParams`) if the game must stay open;
otherwise players' draws carry the upkeep, and if nobody does it the game closes safely when about 20 prizes are
missing (half the 50-row board must stay in play plus a full batch) and reopens as gas falls.

Cadence matters little for safety: the purchase gate reads FWA directly and closes on its own when the board runs low or
exposure nears the cap. It matters for availability: replacements list only when nothing is in flight, so a keeper
that syncs every block or two keeps the board full (ECONOMICS §4). K is 10 at launch (D82), FWA's own per-pool limit (3 in D65): on the 50-row board the fork
streams refunded 4 of 1,425 issued draws at K 3 (0.3%), 0.9% at K 4 and 1.2% at K 5, completing 39.0% / 40.4% / 42.8%
(sim/results/throughput.md; receipts docs/receipts/throughput/board-d65/). The launch worst case was re-measured at K 10 (`test_launchInFlightBoundWorstCaseDrift`): 2 of 10 refunded, none at K 3. A refunded first-time player loses the VRF
fee; lower K (`setMaxInFlight`) if refunds matter more than throughput.

## Launch hour

`ProtocolLiquidity.launch` initialises the pool and starts the opening curve (`CollectionHook.launchedAt`). From then on
every buy and sell (any router; only the burner is exempt) pays `max(ordinary fee, 69% − 1 point a minute)`, falling
linearly per second: 59% at minute 10, 39% at minute 30, 19% at minute 50, and the ordinary 5% from minute 64. The curve
is immutable and cannot return. Read `openingFee()` (buy and sell fee now, seconds until both are ordinary),
`currentFeeBps(isBuy)` and `curveBps()`. Exact-output buys pay the same share of the gross ETH as exact-input buys;
exact-output sells revert (`ExactOutputSellUnsupported`). `setFees` during the curve changes only the floor it falls to
(at 10% it ends at minute 59).

- **Fees.** Every fee goes to the vault in ETH. sim/results/launch.md, first hour: a 39% average fee if volume comes
  evenly (19.5 ETH on 50 ETH traded), 29% if it rises toward minute 60, 12% if traders wait for ≤ 15%. Early buying is
  a descending auction: a 1 ETH buy at minute 0 needs about 28 ETH of later buying to break even (opening FDV 30.7 ETH;
  89 ETH at 100 ETH FDV); expect the volume to gather around minutes 50-64.
- **Scanners.** A sell fee above about 49% (the first ~20 minutes) is likely to get the coin labelled a honeypot by
  wallet and token-safety scanners, and cached labels can outlive the curve; the owner accepted this risk (D64). After
  minute 64 the fees are the ordinary 5% / 5%; a stale label is a matter for the scanner, not for the contracts. The
  owner's plan (publish the curve, pre-notify scanners and wallet security vendors, re-check and request re-scans at
  minute ~70): docs/LAUNCH_CHECKLIST.md item 6.
- **The first Ape.** The first activation threshold is 100% of the reference price (`REF_PRICE_WEI`), so the first sweeps
  after fees arrive fill the bid to the floor at once (no cooldown below the threshold) and a holder can sell into it
  (`sellToProtocol`); after that purchase the threshold is 75% of the funding reference. Then the vault funds the 50-row board
  (1.666 ETH), the 0.5 ETH reserve and the opening keeper pay (within the 0.2 ETH allowance, D82); keepers list the board in about 7 `sync`
  calls (sim/results/keepers.md) and any keeper activates. The game opens on day one only if the first hour trades
  about 50 ETH through the curve; otherwise the day-one fallback the owner chose applies (contributions visible from
  minute one; docs/LAUNCH_CHECKLIST.md item 7).
- **The overflow at launch.** Nothing overflows until the game is active: through funding mode every fee stays capital
  (the first Ape, the board, the reserve, the opening allowance). Once active, fees overflow only while the bid is at
  its fill target and the vault holds more than the bid and one more Ape at the funding reference.

## Buybacks (CollectionBurner)

Three balances: `reserve` (all of the game's ETH to the burner, locked, D74), the milestone bucket (released reserve) and the
ongoing bucket (the rest of the game's ETH, the vault's fee overflow, the Sunset, donations). `nextSlice()` returns
`(amount, milestone, runAt)`; `process` reverts `TooSoon` before `runAt` and `NoWork` with nothing to spend.

- **Ongoing cadence.** With `n` = FWA draws issued since the last slice (`drawsSinceLastRun()`), a slice is
  `0.05 ETH + 0.005 ETH × n + 1% of the ongoing bucket`, at most 1 ETH and the bucket, and may run
  `60 minutes × 20 / (20 + n)` after the last, never sooner than 10 minutes: idle, 0.05 ETH an hour; 20 draws, 0.15 ETH
  after 30 minutes; 100 draws, 0.55 ETH after 10 minutes (sim/results/burner.md). The 1% term spends a fee-overflow
  backlog when play is light.
- **Milestone bursts.** A release (`Released`) resets `lastRunAt`, so the first slice of it may run at once (in practice
  the keeper's next tick, not the booking transaction); then 1 ETH every 10 minutes until the bucket is empty: 9 ETH
  takes 80 minutes after the first slice. A slice larger than the impact limit (3%) allows fills only up to it and the
  rest waits for the next: at an opening FDV of 50 ETH a 1 ETH slice is cut to about 0.74 ETH (sim/results/burner.md).
  Releases: `releaseBps(listingId)` (0 = does not qualify), counters `releases` and `exitReleases`, `lastExitAt` (a
  second Ape exit before `lastExitAt + 24 hours` releases the rest).
- **Backlog.** Watch `ongoingBalance()`. With 5 ETH a day of fee overflow the 30-day model leaves 13.2 ETH waiting at 50
  draws a day and 2.7 ETH at 500 (sim/results/burner.md). A backlog is not a fault: every wei is spent eventually. If
  it should go faster, raise `backlogBps` or `baseSliceWei` (`setCadence`).
- **Stuck slices.** `PriceMoved`: someone moved the price this block, try the next. `TooSoon`: read `runAt`. A slice that
  keeps buying little: the pool is shallow for the slice size (impact limit); nothing to do.

## The vault: fee overflow

- **Fee overflow** (D65). Fees are counted as they arrive (`unsplitFees`) and split at the next `sweep`: while the live
  bid is at its fill target (the activation threshold, or the ceiling or `maxPrice` when lower), `overflowBps` (0 at launch, D72) of
  them go to the burner's ongoing bucket, never more than the acquisition budget holds beyond the bid and one more Ape
  at the funding reference (`referencePrice`, D83): never the game's capital need, the board growth, the bid's ETH or the next Ape.
  Otherwise they stay as capital. The bid is rate-limited, so fees that outrun Ape purchases would otherwise sit idle;
  the next Ape is always funded first, so acquisitions are not slowed. Custody and listing counts play no part. Read
  `pendingOverflow()` (what the next sweep sends), `overflowOut()` (the total); event `Overflow(amount)`. Unsplit fees
  that do not qualify at a sweep stay capital for good.
- **Metered step.** Above the threshold a sweep forwards at most `maxSweepWei` (1 ETH at launch, D82; ~24 ETH a day) per 300 blocks, and
  `slowSweepWei` (0.01 ETH, D82; ~0.24 ETH a day) above the 120% ceiling (D64's play meter was removed in D65): a constant step.
- **Owner item: the step size.** `maxSweepWei` is 1 ETH at launch (D82, the owner's choice over D59's 0.05), so above the threshold the bid climbs about 24 ETH a day; raise or lower it with `setBidParams` as trading and play change. Model (sim/results/pool.md, docs/ECONOMICS.md §10b, 3 years; measured at the old fixed steps): under sudden popularity (150 ETH a
  day of trading, 40 of play) a play meter had bought 1,106 Apes (1,067 won) against 830 (823) at a fixed 0.05 ETH; a
  fixed 0.1 ETH recovers most of that (1,074 bought, 1,044 won) and changes nothing at base flows (125 Apes, 90 won),
  but with trading far above play it buys about 233 more Apes that are barely played and halves the fee overflow
  (1,444 ETH against 2,917).
- **Conservation.** `balance + acquisitionSpend + finderFees + sweepRewards + gameCapitalSent + migratedOut +
  overflowOut == tradingFees + contributions + surplusIn + returnedFromGame` (an invariant test); a difference is an
  incident.

## Conditions that pause new draws (and what to do)

| Condition | Effect | Recovery |
| --- | --- | --- |
| No collection NFT in the draw (all won, or the last one's delivery is pending) | draws stay open for Shapes and Packs (D53); the site says no Ape can be won meanwhile | the next NFT joins the draw when the vault buys or receives one; to hasten: sweep the bid, correct its threshold if the floor moved far (`setActivationThreshold`, owner) or contribute |
| ≥ 10 requests unsettled (`maxInFlight`, 10 at launch = FWA's own per-pool VRF limit; D82) | `canPurchase` false: for a few seconds while randomness arrives; if draws are Ready but unsettled (randomness out of order, a restock while draws were in flight) until someone settles them | the next draw through the site's DrawRouter settles them first (D53); anyone may call FWA `processAcquisitions` |
| Shapes in the draw below half the board after every in-flight request, or collection exposure would pass its 50% ceiling | `canPurchase` false (live, no keeper needed) | a `sync` (keeper, or the DrawRouter with `count` 0) restocks; if Shapes cannot be restocked (cash, a failing mint or FWA call) the game stays closed safely |
| Board below 70% fill (more than 15 of 50 rows waiting) | admission closed | `sync` restocks once every request has settled (D82: it no longer lists while any FWA request is unsettled, even below the fill; purchases are closed then anyway); if cash is short the vault funds the game at the next sync |
| FWA edge > 5% or cooldown > 30 days | admission closed | wait for FWA, or accept by `setSettings` (owner) |
| FWA global switches off / withdraw-only | FWA refuses purchases | none needed; settlement and refunds continue |
| Owner pause | admission closed | `setPaused(false)` (owner) |

Distributions pause while profit is below what was distributed (a carried loss), or cash is below
`replacementsOwed + reserve + unsettled × largest prize`. Nothing to do: they resume on their own.

## Stalls and recovery

- **Keepers stopped**: FWA still settles; players still get prizes; players' draws through the DrawRouter keep syncing.
  Direct FWA purchases continue until the live gate closes them (about 20 draws on the 50-row launch board with no
  restock).
  When keepers return, `sync()` catches up in bounded batches without double booking, trues revenue up to what FWA
  paid, restocks and reopens (`test/fork/Outage.t.sol`).
- **A step keeps failing** (`StepFailed("maintenance" | "collection" | "admission" | "distribution" | "proceeds" |
  "recover")`): every other step keeps working. A board that cannot be restocked runs down and the gate closes it.
- **VRF word missing**: the request expires after 30 blocks at its ordered turn; the player withdraws the refund from
  FWA (`withdrawAcquisitionRefund`). Booked as expired.
- **Delivery failed** (`DeliveryPending`): anyone may `retryNFTDelivery` within 7 days; after that only the player can
  `refundFailedDelivery`. The game vacates and replaces a Shape or Draw Pack row meanwhile (the recovered Pack is redeemed for its backing); a collection NFT leaves the draw until
  resolved, then returns to custody and is relisted no higher than before (`test_failedApeDeliveryReturnsToCustodyWithoutRelease`).
- **Vault cannot fund the reserve after expensive wins**: the game keeps settling; rows wait; admission closes below 70%
  fill; trading fees refill. Nothing to do.
- **Ape decay or listing waiting** (`rowsShort() > 0`, Apes in custody): the 20% target holds them until the board grows.
  The game grows it at the next maintenance once the vault's ETH covers the rows (the vault keeps that cost before
  bidding again: `growthNeed()`); then the rows are listed and the Apes follow. Nothing to do (the owner may also grow it
  at once: `setBoardSize`). Decay also waits for gameplay: it is credited only as draws settle.
- **Bid not rising**: nobody has swept it (`nextSweepBlock()` passed, `liveBid()` below what the vault could add), or the
  vault has nothing beyond the game's capital need (`acquisitionBudget()`). Anyone calls `FundingVault.sweep()` (it is
  rewarded); players' draws and the keeper bot do it too. While the bid is at its fill target, half the fees beyond the
  bid and the next Ape go to buybacks instead (`overflowOut()`): intended, since the bid cannot use them yet.
- **Buyback `PriceMoved`** or `TooSoon`: see "Buybacks" above.
- **Swaps reverting after a fee-recipient change**: the recipient does not accept ETH from the PoolManager. Only the
  MigrationAuthority can change it: a new `proposeFeeRecipient` (72 hours), a migration's execution, or the sunset (at
  once). Check the recipient before proposing it.

## Owner procedures

Owner calls take effect at once, except migration and fee-recipient proposals (72-hour notice, code pinned; D63);
docs/ADMIN.md lists each with its bounds. Announce material changes (board, fees, markup, keeper pay, surplus split,
bid) before making them. Each emits an event that the site's Governance page shows.

- **Transfer administration**: `Admin.transferOwnership(next)`, then `next` calls `Admin.acceptOwnership()`. One
  transfer moves every contract. Until it is accepted the current owner keeps every power;
  `transferOwnership(address(0))` cancels. Check `Admin.owner()` and `pendingOwner()`.
- **Renounce**: `Admin.renounceOwnership()`. Irreversible: every owner-only function of every contract becomes
  uncallable (bid, fee overflow and meter, board pattern and size, pricing, keeper pay, settings, pause, fees, burner
  cadence, tiers and milestone share, migration and
  fee-recipient proposals, the sunset); the game keeps running on its last settings. Before renouncing, set everything
  as it should stay for good and cancel any pending proposal (`propose(address(0))`, `proposeFeeRecipient(address(0))`):
  anyone can still execute one afterwards.
- **Draw Packs presentation admin**: a plain address (the owner at deploy), separate from `Admin`. When transferring
  ownership, transfer it too through ShapePacks' own admin transfer.
- **The live bid**: nothing routine. `FundingVault.setBidParams((thresholdBps, maxSweepWei, minBlocksBetweenSweeps,
  maxPrice, ceilingBps, slowSweepWei, maxDropBps))` changes how fast ETH is metered in above the threshold and above the relative
  ceiling, 120% of the funding reference (adjust `maxSweepWei` and `slowSweepWei` as Ape prices and demand change: the steps
  are absolute amounts; launch 1 ETH and 0.01 ETH, D82, "The metered step" above); `maxDropBps` bounds how far one acquisition may lower the funding reference (100-10,000 bps; launch 2,500 = 25%, D83); the ETH already in the bid stays. After a sudden jump in the floor the bid reaches it slowly
  above the ceiling (≈ 20 days for an overnight doubling at the launch 0.01 ETH slow step, D82; ≈ 80 days at D59's 0.0025): optionally raise `ceilingBps` or `slowSweepWei` for a while; nothing
  stops if you do not. `setActivationThreshold(wei)` corrects the threshold
  (before the first Ape it is 100% of the deploy-time reference; after each acquisition 75% of the funding reference); the next
  acquisition re-syncs it. `maxPrice` is an emergency brake (0 = none). Read `liveBid()`, `bidBalance()`,
  `activationThreshold()`, `lastPrice()`, `referencePrice()`, `bidCeiling()`, `nextSweepBlock()`.
- **Fee overflow**: `FundingVault.setOverflowBps(bps)`: the share of fees sent to buybacks while the bid is at its fill
  target (0-10,000 bps; 0 turns it off; above 10,000 `OutOfBounds`). At 100% every fee beyond the game's capital, the
  board growth, the bid and one more Ape at the funding reference goes to buybacks; it never takes the game's capital or the
  next Ape. From the next sweep. Launch: 0 (off, D72); turn it on once the vault is deep. Read `overflowBps()`, `pendingOverflow()`, `overflowOut()`;
  event `OverflowBpsSet`.
- **Trading fees**: `CollectionHook.setFees(buyBps, sellBps)`, each ≤ 10%; launch 5% / 5%. The opening curve is fixed and
  rides above whatever is set until it falls below it.
- **Buyback cadence**: `CollectionBurner.setCadence((baseSliceWei, perDrawWei, backlogBps, maxSliceWei, idleSpacing,
  minSpacing, drawsToHalve, maxImpactBps, maxDeviationBps))`. Hard bounds no owner passes (`OutOfBounds`): slice
  ≤ 1 ETH (`baseSliceWei` and `perDrawWei` at most `maxSliceWei`), `minSpacing` ≥ 10 minutes, `idleSpacing` between it
  and 30 days, `backlogBps` ≤ 10%, impact ≤ 5%, deviation ≤ 3%. Launch: 0.05 ETH, 0.005 ETH, 1%, 1 ETH, 60 minutes,
  10 minutes, 20, 3%, 2%. Applies to the next slice. Read `cadence()`.
- **Milestone tiers**: `CollectionBurner.setTiers((bigPrizeWei, bigPrizeBps, firstExitBps, exitWindow))`: each share
  0-100%, window ≤ 7 days, `bigPrizeWei` > 0. Launch: 0.5 ETH, 0%, 100%, 24 hours (D74: only an Ape pull releases, all of it). Every release still ends in buybacks,
  so the tiers change only timing. Applies to the next release; the game asks `bigPrizeWei()` before releasing a prize.
  Read `tiers()`.
- **Ape listings**: `CollectionPoolOwner.setListingParams((startBps, minNotionalWei, decayBps, stepBps, targetBps, dailyDecayBps))`: opening
  notional, the absolute ETH floor (`minNotionalWei`, 0.01-100 ETH, 1 ETH at launch, D82: a cheaper Ape opens at the floor), decay per ETH credited, reprice step, exposure target, time decay. Applies to every Ape from its next
  update; never raises a published notional (a floor raised above a published notional leaves it there). A lower target defers decay and listing until the board grows.
- **Keeper pay**: `CollectionGame.setKeeperParams((maxGasPrice, gasOverhead, flatFee, payDelay))` (flat fee ≤ 0.1 ETH,
  delay ≤ 1 hour); the
  allowance rate is `opsBps` in `setPricing(markupBps, opsBps)`, frozen into each prize at listing. Read
  `keeperParams()`, `keeperAllowance()`, `keeperPaid()`, `keeperAvailable()`.
- **Surplus split**: `continuityShareBps` in `CollectionGame.setSettings` (the vault's share of each distribution while it
  is short of one Ape at the funding reference; once it can buy one, everything goes to the burner);
  `CollectionBurner.setMilestoneBps(bps)` (the share of what the burner receives from the game that is locked in the
  reserve until big prizes and Ape wins release it; launch 75%). Both apply from the next distribution.
- **Board pattern**: `CollectionGame.setPattern(backings)`, one transaction, no script. Each backing must be a prize the
  pool owner can mint (a Shapes denomination is one Shape; any other value a Draw Pack of the fewest Shapes adding up to
  it; `CollectionPoolOwner.prizeCost` reverts otherwise), and `reserveTarget` must cover the largest backing
  (raise it with `setSettings` first if needed). Nothing is withdrawn: each row takes its new backing the next time it
  is listed (after its prize is won, or when the row is new), so the board turns over as play goes on; rows already
  owed are recosted at once. Read `rowAt(r)`, `patternLength()`, `maxBacking()`. Before a pattern with heavier prizes,
  measure the heaviest call with `test/fork/TxCap.t.sol` and lower `maxPerCall` (`setBoardParams`) if needed (D61).
  Tested in `test/fork/Pattern.t.sol`.
- **Board size**: `CollectionGame.setBoardSize(to)`: grow only, at most 50 rows per call, refused unless the vault holds
  the new rows' cost on top of the game's capital need. The rows are listed like replacements.
- **Fee recipient** (e.g. a splitter that also funds another buy-and-burn), without migrating the game:
  1. Deploy and review the recipient. It must be a contract and accept ETH from the PoolManager in the middle of a swap,
     cheaply, or every swap reverts until it is changed again. Its behaviour must be fixed in its code (as for a
     successor, below: no proxy, no admin-settable payout or refusal; the code hash pins only the address's own code,
     not its storage).
  2. `MigrationAuthority.proposeFeeRecipient(recipient)`; publish it. Its code hash is pinned; `feeExecutableAt()` is
     72 hours later; `proposeFeeRecipient(address(0))` cancels; a new proposal restarts the 72 hours. Refused
     (`Started`) once a migration or the sunset has started.
  3. Anyone, after the 72 hours: `executeFeeRecipient()` (refused with `CodeChanged` if the code changed). Every
     later trading fee goes to the recipient; the game keeps running. The vault then receives no more trading fees:
     its income is the game's surplus share and contributions.
  The owner cannot call `CollectionHook.setFeeRecipient` (`NotMigrator`). A migration's execution or the sunset points
  fees at its successor automatically and cancels a pending fee-recipient proposal; from then on fees follow the
  successor (only a later successor proposal, outside a sunset, moves them).
- **Parameters**: the setter on the contract (docs/ADMIN.md). Tested in `test/fork/Governance.t.sol`.

## Sunset (permanent; buy-and-burn only)

Owner: `MigrationAuthority.sunset()`. At once: the successor becomes the built-in `Sunset` contract, pending proposals
are cancelled, the game retires (no new draws, direct FWA purchases included) and trading fees go to the Sunset. Then,
anyone (the keeper bot does each once the game qualifies):

1. FWA `processAcquisitions` and `CollectionGame.retireStep()` until `retired()`: requests in flight settle, Shapes and
   Packs are redeemed, Apes withdrawn into custody, all game ETH returned to the vault.
2. `migrateApes(n)` until it moves none, and `migrateCapital()`: the Apes and the vault's ETH go to the Sunset.
3. `Sunset.flush()`: the Sunset sends every wei it holds (the vault's capital, trading fees) to the CollectionBurner,
   and starts the auction clock if nobody has. Repeat as fees arrive.
4. The auction: each Ape sells to whoever pays `Sunset.auctionPrice(tokenId)` through `Sunset.buy(tokenId)`: 150% of
   its recorded cost, falling linearly to 25% over 30 days, then 25%. The clock starts with `Sunset.start()` (anyone,
   once the game has retired), the first `buy` or the first `flush`. The auction price goes to the burner in the same
   call; anything paid above it is refunded to the buyer.
5. `CollectionBurner.releaseRetired()` releases the milestone reserve; `process` keeps buying and burning.

The Sunset has no owner; its only ETH outflow is the burner (and a buyer's overpayment back to that buyer). Players keep every refund and pending delivery right.
Irreversible. It can follow a migration that has started, for whatever has not moved yet (`test/fork/Sunset.t.sol`,
`test_sunsetTakesWhatAMigrationHasNotMoved`). Final: afterwards no migration (`SunsetFinal`) and no fee-recipient
change (`Started`) can be proposed, so everything still on its way to the Sunset can only reach the burner
(`test_sunsetIsFinal`). Keeper pay while it unwinds never exceeds the game's remaining keeper allowance.

## Migration (docs/MIGRATION.md)

1. The successor system is deployed and reviewed separately. It must be a contract that accepts ERC-721
   `transferFrom` and plain ETH, and, since trading fees follow it at execution, ETH from the PoolManager mid-swap.
   No interface is required. **What it does with what it receives must be fixed in its code**: no proxy or
   `delegatecall` to a settable target (EIP-1967, beacon, diamond), and no admin-settable payout address, forwarding
   target, pause or refusal switch, unless whoever controls them is as trusted as the owner. The pinned code hash
   covers only the address's own code, not its storage, so a proxy's controller or a storage setting could change
   where the ETH and Apes go during or after the 72 hours (audits R-1, round 2). Check this before proposing, and
   reviewers check it during the notice.
2. Owner: `MigrationAuthority.propose(successor)`; publish it. Its code hash is pinned; `executableAt()` is 72 hours
   later; `propose(address(0))` cancels.
3. Anyone, after the 72 hours: `execute()` (refused with `CodeChanged` if the successor's code changed). New draws stop
   for good and trading fees go to the successor at once (a pending fee-recipient proposal is cancelled). Keepers (or anyone) run FWA `processAcquisitions` and
   `CollectionGame.retireStep` until `retired()` (requests in flight settle; Shapes and Packs are redeemed; all game ETH
   returns to the vault).
4. Anyone: `migrateApes(n)` until it moves none; `migrateCapital()`. The Apes and the vault's ETH go straight to the
   successor.
5. Afterwards: `CollectionBurner.releaseRetired()` and burner slices as usual (committed buyback ETH never moves);
   `retireStep` + `migrateCapital()` for late remainders; `migrateApes` again if a winner later refunds a failed Ape
   delivery.
`migrateApes` and `migrateCapital` revert until V1 has retired; nothing moves before. A later proposal (again 72 hours,
then `execute()`) replaces the successor for whatever has not moved yet; the sunset can take it over at any time, and
after it nothing more can be proposed.

## Monitoring checklist

- Lens `funding/books/buybacks/quote` (site pages read these).
- Events: `Captured`, `CollectionWon`, `Distributed(toVault, toBurner)`, `KeeperPaid`, `StepFailed`, `BoardGrown`,
  `Released`, `Bought`, `SurplusReceived`, `Acquired`, `Swept`, `Overflow`, `Admission`, administrative events
  (`OwnershipTransferStarted`, `OwnershipTransferred`, `BidParamsSet`, `OverflowBpsSet`, `PatternSet`, `PricingSet`,
  `BoardParamsSet`, `KeeperParamsSet`, `SettingsSet`, `MilestoneBpsSet`, `CadenceSet`, `TiersSet`, `FeesSet`, `Paused`,
  …), MigrationAuthority `Proposed` / `Executed` / `FeeRecipientProposed` / `FeeRecipientExecuted` / `Sunset`, and the
  hook's `FeeRecipientSet`.
- Burner: `nextSlice()` (a `runAt` more than an hour past with ETH to spend means no keeper is buying), `reserve()`,
  `milestoneBalance()`, `ongoingBalance()` (backlog), `totalBurned()`. Vault: `pendingOverflow()`, `overflowOut()`,
  `unsplitFees()`. Hook, first hour: `openingFee()`.
- Alerts: admission closed > 1 h; `keeperAvailable()` near 0 while work waits; `capitalNeed > 0` for > 1 h after
  activation; the bid not swept for hours while it could rise; a buyback overdue (`runAt` passed > 1 h with ETH to
  spend) or a milestone bucket not draining after a `Released`; any owner call (most take effect at once); any migration
  or fee-recipient proposal (72 hours to react); a sunset.

## Launch values (script/LaunchConfig.sol)

Fees 5% / 5% (opening curve 69%, −1 point a minute, fixed in the hook). Board: the 50-row pattern, interleaved
(24 × 0.01 Shape, 16 × 0.02 Pack, 3 × 0.03 Pack, 1 × 0.04 Pack, 3 × 0.05 Shape, 1 × 0.1 Shape, 1 × 0.15 Pack,
1 × 0.5 Shape: 1.59 ETH of backing, 76 Shapes, 1.666 ETH at cost). Markup 10%, keeper allowance 1% of each capture's
cost (D82), opening allowance 0.2 ETH (D82). Settings: reserve 0.5 ETH, `minLiveBps` 70%, continuity share 35%, `maxOutstanding` 10,
`maxEdgeBps` 5%, `maxCooldown` 30 days (D82), `minDistribution` 0.01 ETH. `maxInFlight` (K) 10 (D82). Ape listings: open 100%,
floor `minNotionalWei` 1 ETH (D82), decay 0.1 per ETH of gameplay, no time decay (D78), step 5%, target 20%. Bid: first threshold 100% of the reference, then 75% of
the funding reference, 1 ETH per 300 blocks (D82), ceiling 120%, slow rate 0.01 ETH (D82), `maxDropBps` 25% (D83). Fee overflow (`overflowBps`) 0%, off (D72).
Burner: milestone 100% (D74); tiers 0.5 ETH / 0% / 100% / 24 hours; cadence as in
"Buybacks" above (impact 3%, deviation 2%). Keeper pay: gas up to 3 gwei, 70,000 overhead, 0.0002 ETH flat fee; within `payDelay` of a player's upkeep a paid `sync` of light work does the work unpaid (D82).
