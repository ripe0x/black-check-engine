# Specification (as implemented)

Values are the BAYC launch configuration (`script/LaunchConfig.sol`). P = permanent code; Deploy = constructor/immutable;
Owner = changeable by the owner at once, within the stated bounds. One owner administers every contract (D57): the
`Admin` contract records it (`owner`, two-step `transferOwnership` / `acceptOwnership`, `renounceOwnership`) and every
governed contract checks `admin.owner()`. There are no roles and no timelock. The only delayed operations are a
migration and a change of the trading-fee recipient (72 hours' public notice, section 8); the sunset, whose only
destination is buybacks, is instant (sections 8 and 9). Every owner function: docs/ADMIN.md.

## 1. Coin and market

| Item | Value | Where |
| --- | --- | --- |
| Supply | 1,000,000,000 × 10^18, all to ProtocolLiquidity, minted once; the launch burns its rounding dust (258 wei in the tested configuration), so circulating supply starts a few wei below it | Deploy / P |
| Mint after deploy | impossible (no function) | P |
| Ordinary fees | buy 5%, sell 5%, paid in ETH to the fee recipient (the vault at launch), less the $LAYER share after the opening curve (D90, below) | Owner, each ≤ 10% (`MAX_FEE_BPS`, P) |
| Fee recipient | `setFeeRecipient(addr)`: callable only by the MigrationAuthority (`NotMigrator` otherwise), non-zero: a recipient the owner proposed, after 72 hours; a migration successor, on execution; the Sunset, at once. It must accept ETH from the PoolManager or swaps revert until it is changed | MigrationAuthority (section 8) |
| Opening curve (buys and sells) | from the pool's one initialisation (`launchedAt`, a timestamp; 0 before), a non-exempt swap pays `max(ordinary fee, curveBps())`, `curveBps() = LAUNCH_FEE_BPS (69%) − LAUNCH_DECAY_BPS_PER_MINUTE (1 percentage point) × seconds elapsed / 60`, floored at 0: linear per second, back at a 5% ordinary fee from minute 64. It starts only at initialisation, so it cannot return | P |
| Fee views | `curveBps()`; `currentFeeBps(isBuy)` (what a non-exempt buy or sell pays now); `openingFee() returns (buyBps, sellBps, secondsToBase)` (both fees now and the seconds until both are back at the ordinary fees; 0 once they are) | P |
| Fee clamp | `LAUNCH_FEE_BPS` (69%) is also the hook's absolute ceiling on any fee it charges | P |
| Fee basis | buy, exact input: taken out of the ETH input; buy, exact output: `net × f / (1 − f)` added to the ETH paid, i.e. `f` of the gross ETH paid, as on an exact-input buy (so exact output cannot pay less during the curve); sell, exact input: taken out of the ETH output | P |
| Exempt sender | CollectionBurner only | Deploy / P |
| Exact-output sell | reverts `ExactOutputSellUnsupported` | P |
| Pool | ETH/coin, LP fee 0, tick spacing 200, hook = CollectionHook | P |
| Launch | `launch()` by the owner once, only after the game's FWA pool exists (D91), at `startTick` fixed at deployment: 173,000 (≈ 32.6M coins per ETH, ≈ 30.7 ETH FDV, about $69k at $2,242 ETH; D70); all coins in `[MIN, startTick)`; no ETH accepted (D38); leftover coin dust burned | P / Owner |
| Liquidity removal | none | P |
| Metadata | ERC-7572 `contractURI()` and `tokenURI()` (D86, as artcoins' coins): JSON with name, symbol, description and image, built from the stored `metadata()` and `imageUrl()` (`COIN_DESCRIPTION`, `COIN_IMAGE` at deploy; empty allowed) or by an owner-set renderer (`setMetadataRenderer`, `IMetadataRenderer.contractURI(token)`; zero: the built-in default). Each change emits `ContractURIUpdated`. Name, symbol and decimals are fixed | Deploy / Owner |
| Transfer restriction | at launch the coin moves only through the canonical pool (D71): holder-to-holder transfers revert `VenueNotAllowed`; a transfer to or from the PoolManager passes up to the allowance the hook grants for the coin side of each swap (transient, this transaction); ProtocolLiquidity may send; mint and burn always pass. The Admin owner's allowlist (`setAllowed`, at most 50 addresses, D84, like FWA's distributors) lets a transfer from or to an allowed address pass, except through the PoolManager, which always takes the swap rule and can never be allowed. The Admin owner's `unrestrict()` lifts it for good. Declared under URC-5 (`IVenuePolicy`: `Enforced`, one canonical pool) | P / Owner |

The curve is the owner's accepted trade-off (D64): a sell fee near 69% in the first ~20 minutes may get the coin
flagged as a honeypot by wallet scanners, and a cached label can outlive the curve. First-hour fees and early buyers'
returns: sim/results/launch.md.

## 2. Funding vault

- Inflows: PoolManager → `tradingFees` and `unsplitFees` (while the vault is the fee recipient; the next `sweep`
  splits them, below); anyone → `contributions` (`contribute`, plain transfer); game → `surplusIn` (`receiveSurplus`:
  its surplus share while the vault is short, section 4) and `returnedFromGame` (`receiveReturn`: retirement). Unspent
  ETH the adapter returns inside `fillOrder` is the vault's own and counts as neither. NFT contributions (`contributeNFT`, `claimStray`) are registered with reference value =
  `referencePrice` (the funding reference, what one more Ape is taken to cost; never a value the donor chooses), cash cost 0; excluded token IDs are refused.
- One balance: `generalBalance()` is everything the vault holds. The surplus share is ordinary capital (it funds the
  game, board growth and the bid alike); the live bid's ETH (`bidBalance`) is accounted inside it, not a second bucket.
- `acquisitionBudget`: 0 while the game is retiring/retired; before activation the whole balance until the first NFT
  is held, then 0; after activation `max(0, balance − game.capitalNeed() − game.growthNeed())`: the game's protected
  capital and the board growth the held NFTs are waiting for come first. No inventory limit.
- `shortfall() = max(0, referencePrice − acquisitionBudget())`: how far the vault is from one NFT at the funding
  reference. The game's surplus share is capped at it; at 0 every distribution goes to the burner (section 4).
- Every acquisition is recorded by source, registers the NFT with `refCost = cashCost = price`, takes the price out of
  the bid and moves the funding reference and the threshold (below). `maxPrice`, if set, caps every acquisition.
- `fundGame()` (anyone; the game calls it from `sync` and `activate`): refused while the game is retiring or retired;
  sends `min(game.capitalNeed(), balance)` (`NothingToSend` if 0); before activation only if an NFT is held and
  `balance ≥ capitalNeed` (no piecemeal board).
- Migration (MigrationAuthority only, `NotMigrator`): `migrateCapital(successor)` once the game has retired: the whole
  balance to `successor` (forced ETH transfer), `bidBalance` set to 0, repeatable (later returns, fees and contributions
  follow). After a sunset the successor is the Sunset contract, which sends it to the burner (section 9). There is no
  other end-of-life path.
- The $LAYER share (D90): the hook takes `layerBps` (1% at launch, owner 0-5%) of each trading fee once the opening curve is down to the ordinary fee and pays it to the LayerTap; the rest of the fee goes to the vault. The LayerTap forwards to artcoins' $LAYER burn router (`0x2eDB…2000`, which can only buy and burn $LAYER), fixed in the tap: by itself in the swap that brings it to the router's 0.01 ETH minimum (fixed gas stipend, failure ignored), or when anyone calls `flush`. The owner may point the hook at another tap (`setLayer`). The vault holds no $LAYER code.
- Outflows besides acquisitions, `fundGame` and `migrateCapital`: the sweep reward, the finder fee and the fee
  overflow (to the CollectionBurner only, below). Conservation: `balance + acquisitionSpend + finderFees +
  sweepRewards + gameCapitalSent + migratedOut + overflowOut = tradingFees + contributions + surplusIn +
  returnedFromGame`.
- Constructor: `(admin, poolManager, collection, burner, migrator, bid_, overflowBps_, refPrice, firstThresholdBps)`;
  `refPrice > 0`, `firstThresholdBps ≤ 100%`.
- Wiring (deployer, once): `wire(game, poolOwner, adapter)`; the one marketplace adapter (Seaport) is fixed there
  (address(0): none).
- Owner: `setBidParams`, `setOverflowBps`, `setActivationThreshold`, `setExcluded(id, bool)`. No withdraw.

### The bid

One public live bid funded with real ETH, after Permanent Collection's live bid (D59;
https://111.ripe.wtf/docs/guides/accept-the-live-bid), adapted to this vault's accounting. Parameters (`BidParams`,
Owner via `setBidParams`):

| Parameter | Meaning | Launch | Bounds |
| --- | --- | --- | --- |
| `thresholdBps` | after an acquisition the activation threshold is this share of the funding reference | 75% | ≤ 100% |
| `maxSweepWei` | above the threshold, the most one sweep forwards (the metered step) | 1 ETH (D82; ~24 ETH a day) | > 0, ≤ 100 ETH |
| `minBlocksBetweenSweeps` | above the threshold, blocks between two sweeps | 300 (~1 hour) | 1-7,200 |
| `maxPrice` | optional emergency cap on any acquisition and on the bid (0 = none) | 0 (`MAX_PRICE_WEI`) | — |
| `ceilingBps` | relative ceiling: above this share of `referencePrice` a sweep forwards only `slowSweepWei` (0 = none; D60, D61) | 120% | 0, or 100-1,000% |
| `slowSweepWei` | above the ceiling, the most one sweep forwards (0 = a hard stop until the next acquisition) | 0.01 ETH (D82; ~0.24 ETH a day) | ≤ `maxSweepWei` |
| `maxDropBps` | the most one acquisition may lower the funding reference below the previous reference (D83) | 2,500 (25%) | 100-10,000 bps |

State: `bidBalance` (ETH metered into the bid), `activationThreshold`, `lastPrice` (the exact price of the last
acquisition, display and accounting only), `referencePrice` (the funding reference, what one more Ape is taken to
cost; it drives the threshold, the ceiling, `shortfall`, the overflow reserve and a donation's reference value),
`lastSweepBlock`, `unsplitFees`. At deploy both `lastPrice` and `referencePrice` equal `refPrice` (`REF_PRICE_WEI`: the
live floor on the day, 6 ETH placeholder) and the threshold is the constructor's `firstThresholdBps` of it (100% at
launch: 6 ETH, so the opening fees can buy the first NFT at once, D64); after each acquisition it is `thresholdBps` of
the funding reference.

- `liveBid = min(bidBalance, acquisitionBudget, maxPrice if set)`; `bidCeiling = ceilingBps × referencePrice` (unbounded
  when `ceilingBps` is 0). The ceiling moves with every acquisition; it limits only how fast ETH is metered in, not the
  bid or a sale.
- `sweep()` (anyone): first splits the unsplit trading fees (the fee overflow, below), then, with `bid =
  min(bidBalance, budget)`, `room = budget − bid` and `fill = min(threshold, ceiling)`: below `fill`, forwards
  `min(room, fill − bid)` at once (clamped to land at it; no cooldown, `lastSweepBlock` unchanged);
  at or above it, before `lastSweepBlock + minBlocksBetweenSweeps` forwards nothing, else forwards `min(room,
  maxSweepWei, ceiling − bid)` below the ceiling or `min(room, slowSweepWei)` at or above it, and records the block. A forward that would pass `maxPrice` is clamped. A sweep that only
  overflows (the cooldown not over, or nothing to forward) succeeds and returns 0; one that would neither overflow nor
  forward reverts `SweepTooEarly(next)` (cooldown) or `NothingToSend`. The caller is rewarded `min(game.quoteTip(gasUsed),
  0.01 ETH)` (its gas at the game's keeper formula plus the flat fee, D82) from the vault's general ETH (carved off the forward when the room is too small); an overflow
  alone earns nothing. Nothing rises with time alone.
- `sellToProtocol(id, price)`: the holder names its price, `0 < price ≤ liveBid` (a rational seller names the whole
  bid); reverts `AboveBid(bid)` otherwise, or if `id` is excluded or not the caller's. NFT `transferFrom` caller → pool
  owner; registered; the seller is paid exactly `price` (forced ETH).
- `fillOrder(id, maxSpend, data)` (anyone): through the adapter fixed at wiring (`NotAllowed` if none, or if the NFT is
  already in custody); sends at most `min(liveBid − fee, maxSpend)` (`OverBudget` if 0), `fee = min(0.5% of liveBid,
  0.01 ETH)`; the call must end with the NFT owned by the pool owner (`NotDelivered`), the adapter holding no more ETH
  than before the call (`AdapterKeptFunds`; the adapter returns exactly what is left of the vault's payment, so ETH
  anyone else sent it stays there and cannot block a fill or lower the booked price, D66) and spend ≤ cap. The price
  booked is what the vault sent the adapter less what the adapter returned (D68): other ETH the vault receives during
  the fill (a game payout triggered from inside the order) is booked as what it is and never lowers the price. The
  adapter fills only signed orders (no Seaport CONTRACT orders) and only their signed consideration items (no
  fulfiller-added tips), and refuses any item paying the vault or custody, whose ETH would come back as a contribution
  while booked as spent (`BadOrder`; final audit F1, F2, B-F1, D70). The vault pays the listing's actual price; the
  caller is paid the finder fee (taken out of the bid).
- An acquisition sets `bidBalance −= price` (and the finder fee), keeping the rest of the bid, and `lastPrice = price`
  (the exact price). The funding reference follows the price but is floored: `referencePrice = max(price, previous
  referencePrice × (1 − maxDropBps), poolOwner.minNotionalWei())`, so one cheap or mistaken sale cannot collapse the
  bid (D83); a real fall is followed over successive purchases, a rise at once. The threshold becomes
  `activationThreshold = thresholdBps × referencePrice`. Permanent Collection resets the threshold on direct sales
  only; here a marketplace fill resets it too (it is a real clearing price at or below the bid).
  `setActivationThreshold` (Owner, ≤ 1,000 ETH) corrects it until the next acquisition. Donations do not move it.
- The game's capital comes first: when the game's need grows, `liveBid` falls with the budget and a sweep clamps
  `bidBalance` to it; nothing metered is lost from the vault, it only stops being offered.
- Who sweeps: the DrawRouter after every player's draw (the reward goes to the player), the keeper bot, and any seller.

### The fee overflow (D64; trigger D65)

Trading fees feed the bid and, once the bid cannot use them, the burner. One parameter, `overflowBps` (constructor
`overflowBps_`, Owner via `setOverflowBps(bps)`, `OutOfBounds` above 10,000, event `OverflowBpsSet(bps)`): the share of
the unsplit trading fees a sweep sends to the burner while the condition holds; launch 5,000 (50%); 0 turns it off.

- Fees are counted as they arrive (`unsplitFees`; the swap path adds one storage write) and split at the next `sweep`.
- `pendingOverflow()` is 0 until the game is active (`game.activated()`), and 0 unless the live bid is at its fill target, `liveBid ≥ min(activationThreshold, bidCeiling,
  maxPrice if set)`; otherwise it is `unsplitFees × overflowBps`, capped at `acquisitionBudget − (min(bidBalance,
  acquisitionBudget) + referencePrice)` (0 when the budget holds no more than that). So it never takes the game's capital
  need, the board growth its NFTs wait for, the bid's ETH or one more NFT at the funding reference: the next NFT is always
  funded and acquisitions are never slowed. It reads no custody or listing counts.
- Why: the bid is rate-limited (`maxSweepWei` per cooldown), so fees that outrun NFT purchases would otherwise sit idle
  in the vault. Model (sim/results/pool.md, 3 years): base flows (10 / 3 ETH a day) about 0.2 ETH overflows and the
  same 125 Apes are bought as without it; trading far above play (150 / 0.5) 2,917 ETH goes to buybacks, 864 Apes
  against 868 without, and 5 ETH sits idle in the vault at the end against 2,849; sudden popularity 3,750 ETH to
  buybacks with the same Apes and wins.
- The sweep sends it to the CollectionBurner, which books it as ongoing (`overflowOut`, `Overflow(amount)`), and resets
  `unsplitFees` either way: fees that do not overflow stay as capital.
- The metered step above the threshold is `maxSweepWei` per `minBlocksBetweenSweeps` (D64's play meter was removed in
  D65); the slow rate above the ceiling is unchanged, so the D61 drought bound holds.

## 3. FWA pool owner

- `createPool(salt)` (anyone, once, needs ≥ 50,000 FWA held): creates the pool with the pinned implementation, approves
  Shapes, Draw Packs and the collection to it, sets itself as purchase operator, burns leftover FWA.
- `prizeCost(backing)` (view): a Shapes denomination costs backing + one mint fee; any other amount the Shapes
  denominations add up to exactly, at or above the Pack minimum (2 units), is a Draw Pack of the fewest Shapes adding up
  to it (`makeup`, largest denomination first: 0.03 = three 0.01, 0.15 = 0.1 + 0.05) and costs backing + one mint fee
  per Shape; anything else reverts `BadPrize`.
- Game-only: `mintAndList(prizes)` (payable; mints each prize to itself, a Shape through `Shapes.mintTo`, a Pack through
  `ShapePacks.createPackTo`, requires the ETH spent to equal the payment exactly, then lists all at their prices in one
  FWA call), `withdrawShapes` (a Shape is burned, a Pack redeemed; the ETH received → game), `recoverShape` (same, for a
  refunded delivery), `setAcquisitions`, `collectProceeds` (→ game), `retirePool`, `processCollection(turnover)`,
  `withdrawCollection` (during retirement, at most FWA's batch of 20 per call; returns the listings not yet examined).
- Anyone: `flushStray()` sends any ETH the pool owner holds to the vault (a contribution there; D68). Every ETH flow
  through the pool owner is forwarded in the same call, so a balance between calls is only ETH someone else sent.
- Vault-only: `register(tokenId, refCost, cashCost, source)` (NFT must be held here, never registered before). A
  `refCost` below `MIN_REF_COST` (0.01 ETH) is recorded as 0.01 ETH (D66), so no exposure term divides by a dust
  reference; `cashCost` stays what was paid. The listing floor is the absolute `minNotionalWei` (D82), not a share of `refCost`.
  Each record (`nfts(tokenId)`) holds `refCost`, `cashCost`, `lastNotional`, `source` (0 bought, 1 donated) and the
  state: None, Custody, Listed, Won, Migrated.
- Anyone: `settleListing(listingId)`: records a collection listing's outcome from FWA's own state: `Settled` → won;
  `DeliveryRefunded` → recovered into custody (relisted later); `DeliveryPending` → out of the draw (and out of the
  exposure total). Idempotent. The game calls it for every request it books that drew a collection listing; anyone may.
- `canPurchase` (FWA's purchase operator; FWA calls it once per transaction, without the count, inside a 100,000 gas
  stipend; ~9-46k gas measured, independent of the number of NFTs and rows). Reads live FWA state and the pool owner's
  own conservative totals only, never the game ledger. The purchaser may not be a system address (D66, D67, D81): the FWA pool (its own
  "win" settles without moving the prize), this contract, the game, the vault, the migration authority, the
  collection or any contract recorded at wiring (`isSystem`: the burner, the hook, ProtocolLiquidity, the coin, Admin,
  the Sunset, the adapter, Lens, the DrawRouter, the Draw Packs renderer) (a prize sent to any of them is beyond every recovery route), or Shapes or Packs (each refuses its own
  tokens, leaving the prize in FWA's delivery quarantine with no one able to claim the refund). Any other purchaser,
  contract wallets included, is admitted. True only if all hold (D36):
  - `u = unsettledAcquisitionCount < maxInFlight` (10 at launch, D82; Owner 1-50); with a batch, up to `maxInFlight − 1 + maxBatch`
    can be unsettled (`maxBatch` = FWA's per-transaction limit, 5, read from FWA at pool creation);
  - FWA `edgeBps ≤ game.maxEdgeBps` (5%);
  - `activeListingCount ≥ u + maxBatch + openCollection + boardSize/2` (Shape floor);
  - `exposureSum × BPS ≤ MAX_EXPOSURE_BPS (50%) × (activeListingCount − u − maxBatch) × 1e18` (the ceiling after every
    in-flight and admitted request has removed a listing). Listing and decay keep exposure within the lower target
    (below), so neither they nor an owner change to the target can close the gate.
  No collection NFT need be Active (D53). `exposureSum` (`Σ refCost × 1e18 / notional` over listings marked open) and
  `openCollection` only overstate while stale. Fails closed.

### Collection listings (D59)

Parameters (`ListingParams`, Owner via `setListingParams`; they apply to every NFT from its next update and never raise
a published notional):

| Parameter | Meaning | Launch | Bounds |
| --- | --- | --- | --- |
| `startBps` | opening notional, share of the NFT's price (`refCost`), but never below `minNotionalWei` | 100% | ≤ 1,000% |
| `minNotionalWei` | lowest notional of any NFT, an absolute ETH floor whatever the NFT cost (D82) | 1 ETH | `MIN_FLOOR` 0.01 - `MAX_FLOOR` 100 ETH |
| `decayBps` | notional drop per ETH of gameplay credited to the NFT | 10% (0.1 ETH per ETH) | ≤ 10,000% |
| `stepBps` | smallest drop worth an FWA reprice, share of the current notional | 5% | ≤ 100% |
| `targetBps` | collection exposure target | 20% | 1 bp - 50% |
| `dailyDecayBps` | notional drop per day in the draw, share of its price (the decay clock, D78) | 0 (off) | ≤ 100% |

- Every NFT held is listed: `processCollection` (the game's maintenance) lists up to `LIST_BATCH` (10) custody NFTs per
  call in one FWA batch (FWA takes up to 20), `LIST_BATCH_AFTER_PACKS` (5) when the same transaction minted Packs
  (D70: keeps the heaviest call inside the gas cap's 10% margin), most recently registered first, at `max(refCost × startBps, minNotionalWei)` (a returned NFT
  never above its last published notional; a cheap NFT opens at the floor, D82), stopping at the first that does not fit the target. An NFT that does not fit
  stays in custody and is listed at a later maintenance; nothing is abandoned.
- Gameplay credit: `creditPerApe += (turnover − creditedTurnover) / openCollection` at each maintenance: settled
  gameplay is shared evenly among the NFTs in the draw (k NFTs decay k times slower than one).
- Notional rule (`notionalOf`): `min(published, max(minNotionalWei, refCost × startBps − (creditPerApe − creditStart)
  × decayBps − refCost × (decayClock − clockStart)))`; `creditStart` and `clockStart` are `creditPerApe` and
  `decayClock()` when listed (back-dated for a relisted NFT so its decay resumes where its notional left it: on the
  credit first, the rest on the clock).
- Decay clock (D78): `decayClock()` grows by `dailyDecayBps` a day and is checkpointed whenever the listing parameters
  change, so a rate switched on later counts from then, never from launch, and a rate switched off stops it.
- Repricing: up to `DECAY_BATCH` (10) listed NFTs per call from a rotating cursor, each when its notional has fallen at
  least `stepBps` (or reached its minimum), the NFT is Active and nothing is unsettled (FWA's rule). All listing and
  repricing happens only while no FWA request is unsettled.
- Target: after any listing or reprice made here, `Σ refCost_i / notional_i ≤ targetBps × (activeListingCount −
  gateHeadroom)`, `gateHeadroom = maxInFlight − 1 + maxBatch` (10 − 1 + 5 = 14 at launch, D82): the target holds after every request
  the gate can admit has removed a listing. A listing or reprice that would exceed it waits, and `rowsShort` records
  how many more active listings would let every deferred action in the pass proceed; the game grows the board by it
  (section 4) and the deferred work resumes automatically at a later maintenance.
- Because every NFT is in the draw, the chance of winning some NFT per draw is `Σ(1/notional) / Σ(1/price)`; once the
  target binds (on the 50-row board, from between 10 and 20 fresh NFTs, fewer as they decay; sim/results/pool.md),
  further decay mostly grows the board and that chance stays near `target × EV / refCost` (docs/ECONOMICS.md section 2).
- `onERC721Received` accepts Shapes and Draw Packs only when the operator is itself (its own mint) or the FWA pool
  (withdrawals, refunded deliveries), and collection NFTs only from the FWA pool.
- Migration (MigrationAuthority only, `NotMigrator`): `migrateApe(to)` once the game has retired (`NotRetired`):
  transfers the last custody NFT straight to `to` (a migration's successor, or the Sunset, which auctions it; section 9)
  and marks it Migrated; its record (`nfts(tokenId)`) stays readable (the Sunset prices its auction from `refCost`).
  Returns `(false, 0)` when custody is empty. A delivery refunded after retirement returns to custody through
  `settleListing` (the game's `retireStep` or anyone) and is then migrated. The pool owner sells nothing itself.

## 4. Game ledger

- Board: rows `[0, boardSize)` of the pattern stored in the game, repeated without end (D59): row `r` asks for
  `rowAt(r) = pattern[r % patternLength()]`. Opening 50 rows (D64: D45 halved, without the 1 ETH Shape and the 0.06
  Pack) = 24 × 0.01 Shape, 16 × 0.02 Pack, 3 × 0.03 Pack, 1 × 0.04 Pack, 3 × 0.05 Shape, 1 × 0.1 Shape, 1 × 0.15 Pack,
  1 × 0.5 Shape: 1.59 ETH backing, 76 Shapes, 1.666 ETH at cost. Rows are interleaved so any prefix keeps the mix. No upper limit on rows (a
  row index is 24 bits: 16.7M rows).
- Owed rows: rows in play without a live listing are kept in a list (`owedCount`); a win or a pending delivery adds its
  row, growth adds the new rows, `_restock` lists them (last first). Live rows = `boardSize − owedCount`.
- `setPattern(uint256[] pattern)` (Owner): 1-1,000 backings, each a prize the pool owner can mint (`prizeCost`, else
  `BadPrize`), and the reserve must stay ≥ 2 × the new largest (`maxBacking`), else `OutOfBounds`. Lazy: a row takes its
  new backing the next time it is listed (a vacated row is owed the backing the pattern asks for then); prizes already
  listed stay until they are won. `replacementsOwed` is recomputed for the rows already owed. No FWA call, no
  withdrawal.
- `setBoardSize(to)` (Owner): grows only, `boardSize < to ≤ boardSize + 50`, not while retiring, and only if the vault's
  balance covers the new rows' cost plus `capitalNeed()`; otherwise `OutOfBounds`. The new rows are owed and listed like
  replacements. (The board also grows on demand, below.)
- Prize cost = `poolOwner.prizeCost(backing)` (Shapes mint fee 0.001 ETH read live, once per Shape inside a Pack);
  FWA price = cost × (1 + markup), markup 10%; a Pack's Shapes are its `makeup`, the fewest denominations adding up to
  its backing; markup and keeper allowance rate are frozen per listing. Each item records whether it is a Pack; a
  winner receives the Pack itself and may open or redeem it.
- `setPricing(markupBps, opsBps)` (Owner): each ≤ 100% (`MAX_MARKUP_BPS`, `MAX_OPS_BPS`, P). There is no markup floor.
  `opsBps` (1% at launch, D82) is the keeper allowance a capture earns (section 6).
- `setBoardParams(listBatch, maxPerCall, bookPerCall)` (Owner): `listBatch` 1-20 (rows waiting that make a window due; 3 at launch),
  `maxPerCall` 1-10 (prizes one maintenance call lists; 8 at launch; D61), `bookPerCall` 1-20 (requests one `sync` or
  `retireStep` settles, resolves and books, each; 20 at launch; D80). Every call at the ceilings fits EIP-7825's gas cap
  on a board of four-Shape Packs (D81, D85). One call books at most `bookPerCall` requests in all (resolving and seeing share it), and `upkeep(maxCount)` is capped at `bookPerCall` (D85). No Draw Pack prize may hold more than four Shapes (`MAX_PACK_SHAPES`): `setPattern` refuses a heavier one.
- `sync()` (anyone, paid, section 6; `Retiring` while retiring): books up to `bookPerCall` requests; FWA `processAcquisitions`; resolve open
  requests (a request that drew a collection listing has the pool owner record its outcome, `settleListing`, in a
  `try`); see new sequences; collect proceeds; true-up; pay distributions (`payStep`); request vault capital when
  `capitalNeed() > 0` (counted as work only when it covers the whole need and the need was at least `rowCost`: keeper
  pay draws the reserve down, and refilling that dust must not earn the next call a fee); at a maintenance window
  restock, run `processCollection` (its own `try`) and grow the board; admission. Every step after booking runs in its
  own `try` and emits `StepFailed(step)` on failure; a step that failed with less than 1/8 of its starting gas left
  (most likely out of gas somewhere down its call chain) reverts the whole call `OutOfGas`, so a caller cannot skip work
  by sending too little gas and still be paid, and a gas estimate covers every step. Reverts `NoWork` when nothing was
  done.
- Maintenance window due: always before activation or below 70% fill (`minLiveBps`); else when `max(5 min, 6 × FWA cooldown)` passed,
  or ≥ `listBatch` (3) rows waiting and FWA cooldown is 0. Restock (up to `maxPerCall`, 8 at launch, never more than
  20; D61) only when nothing is unsettled, even below the admission fill (D82: purchases are closed then anyway, so it waits for requests in flight to settle or expire).
- Growth on demand (D59): at a maintenance window, by `rowsShort − owedCount` rows (the rows the collection NFTs are
  waiting for, less rows already owed), at most 50 per window, only after activation, and only if the vault's balance
  covers the estimated cost (`rows × rowCost`, the average cost of the last growth) plus the game's capital need. The
  new rows are owed (`replacementsOwed`), funded by `fundGame` and listed like replacements. The board never shrinks.
  `growthNeed()` (view) is that estimate for the rows still waiting; the vault keeps it before bidding (section 2).
- Admission (`setBool`): activated, not paused, not retiring, FWA edge ≤ 5%, cooldown ≤ 30 days (`maxCooldown`, D82: an FWA cooldown alone never closes purchases), fill ≥ 70%, unsettled ≤
  10 (`maxOutstanding`). A collection NFT is not required once activated (D53).
- Settings (`setSettings`, Owner): reserve ≥ the largest prize and ≤ 1,000 ETH (D79); maintenance interval and cooldown
  ≤ 30 days; fill 0-100%; outstanding 1-10,000; edge ≤ 100%; minimum distribution ≤ 100 ETH; continuity share 0-100%
  (35% at launch: the vault's share of each distribution while it is short of one NFT).
- `ready()` / `activate()` (anyone, once): pool exists, not retiring, every row in play live, unsettled 0, more active
  FWA listings than rows and a collection NFT in the draw, `capitalNeed() ≤ vault.generalBalance()`, admissible.
  `activate` first draws from the vault the reserve the opening keeper pay took (`fundGame`), then requires
  `cash ≥ reserveTarget`. The game therefore opens only with its first collection NFT in the draw.
- Retirement: `retire()` only by the MigrationAuthority (a migration's first execution, or the sunset; section 8)
  retires the FWA pool. There is no other way to end the game. `retireStep()` (anyone, paid) settles and books up to `bookPerCall` requests;
  once caught up (nothing unsettled, every issued request seen) withdraws prizes (Shapes burned, Packs redeemed) and
  collection NFTs into custody, then returns all ETH to the vault (`receiveReturn`) and sets `retired`. Prizes are
  withdrawn ten per call and collection NFTs 20 per call (FWA's batch); `retireStep` repeats until none is left, and
  later calls pass late settlements on to the vault.

### Accounting

- Booking (once per request): `Fulfilled` → turnover += paid; proceeds = `paid − (paid − paid/(1+E))/2` with
  `E = bookingEdgeBps`, the highest `maxEdgeBps` ever set (a lower bound: the gate admits no request above the current
  `maxEdgeBps`); once every issued request is booked and FWA holds no owner proceeds, revenue is trued up to the ETH FWA
  actually paid (`proceedsCollected`); keeper allowance += the captured prize's `opsBps` (1%, frozen at listing) × its
  carried cost (its replacement cost), or `lastOpsBps × base` (`base = paid/(1+E)`) for a collection capture; Shape or
  Pack: expense += carried cost, and if its listed price (`cost × (1 + its frozen markup)`) is at least
  `burner.bigPrizeWei()` (0.5 ETH) `burner.release(listingId)` is attempted (a big prize); collection: no expense,
  `burner.release(listingId)` attempted for every win (section 5). Each attempt is a `try`; anyone may release later.
  `DeliveryPending` Shape → row vacated, stays open. `DeliveryRefunded` prize → recovered, burned (a Pack redeemed),
  mint fees written off (if recovery fails the request stays open and is retried). `Refunded`/`Expired`/`TimedOut` →
  counted, no revenue (D40).
- `profit = revenue − prizeExpense − keeperPaid` (signed, cumulative). Keeper pay is an expense when it is paid.
- `protectedCash = replacementsOwed + reserveTarget (0.5 ETH, the largest prize; D79) + min(unsettled × maxItemCost, inventoryCost)`.
- `replacementsOwed` is the cost of the owed rows at today's backings and Shapes mint fee (D68): a won prize's row is
  owed at its current cost (its own recorded cost if it was listed at today's fee and the row's backing is unchanged,
  otherwise priced again), and `sync` first recounts every owed row when Shapes' mint fee (set by Shapes' own admin)
  differs from `owedFee`, the fee the count was made at, before booking or paying out.
- `distributable = min(profit − distributed, cash − protectedCash)` when activated and not retiring; paid when ≥
  `minDistribution` (0.01 ETH): to the vault `v = min(distributable × continuityShareBps (35%), vault.shortfall())`
  (`receiveSurplus`), the rest to the CollectionBurner, which locks its milestone share (section 5). Once the vault can
  buy an NFT at the funding reference (`shortfall` 0), all surplus goes to the burner. `Distributed(toVault, toBurner)`;
  counters `distributed`, `toVault`, `toBurner`.
- `capitalNeed = max(0, protectedCash − cash)`; 0 while retiring or retired.

## 5. Buybacks

- CollectionBurner `receive`: from the game, `milestoneBps` (100% at launch, D74; Owner `setMilestoneBps`, 0-100%) is locked
  in `reserve` and the rest is the ongoing bucket (`SurplusReceived`); ETH from anyone else (the vault's fee overflow,
  the Sunset, a donation) is ongoing (`OngoingReceived`). Counters `reserveIn`, `ongoingIn`, `milestoneIn`.
- Constructor: `(admin, poolManager, token, cadence_, tiers_, milestoneBps)`; wiring (deployer, once): `wire(hook, game,
  poolOwner)`.

### Milestone releases (tiers)

Parameters (`Tiers`, Owner via `setTiers`; `tiers()` and `bigPrizeWei()` views; every release still ends in buybacks,
so these change only the timing):

| Parameter | Meaning | Launch | Bounds |
| --- | --- | --- | --- |
| `bigPrizeWei` | a Shape or Pack listed at this FWA price or more is a big prize | 0.5 ETH | > 0 |
| `bigPrizeBps` | share of the reserve a big prize releases | 0% (D74) | ≤ 100% |
| `firstExitBps` | share of the reserve an Ape exit releases | 100% (D74) | 10-100% |
| `exitWindow` | an Ape exit within this of the last one (`lastExitAt`) releases the rest | 24 hours | ≤ 7 days (`MAX_EXIT_WINDOW`) |

- `releaseBps(listingId)` (view), verified from FWA's own records: 0 if the listing has released before (`released`)
  or FWA does not show it `Settled` to a purchaser other than the pool owner; for one of the pool owner's collection
  listings (an Ape exit, `isCollectionListing`), 100% if an earlier exit released within `exitWindow` (`lastExitAt != 0`
  and `now ≤ lastExitAt + exitWindow`), else `firstExitBps`; for any other listing (only the pool owner lists in its
  pool, so a Shape or Pack), `bigPrizeBps` if its FWA price is at least `bigPrizeWei`, else 0. `qualifies(listingId)` =
  `releaseBps != 0`.
- `release(listingId)` (anyone; the game calls it in a `try` when it books a big prize or any collection win, section
  4): `AlreadyReleased` if released before, `NotQualifying` if `releaseBps` is 0; marks the listing released, moves
  `reserve × releaseBps` to the milestone bucket (`milestoneBalance`), counts `releases` (and `exitReleases` and sets
  `lastExitAt` for an Ape exit), and resets `lastRunAt` so the release's first slice may run at once (in practice the
  keeper's next tick: FWA settles wins without calling the protocol, and a swap inside the game's booking would add
  MEV exposure to `sync`). `Released(listingId, winner, amount)`. A small prize, a refunded or pending delivery or a
  withdrawn listing never qualifies. No owner involvement.
- `releaseRetired()` (anyone, repeatable): once the game has retired (`NotRetired`), the whole reserve moves to the
  milestone bucket.

### Cadence

Parameters (`Cadence`, Owner via `setCadence`; `cadence()` view):

| Parameter | Meaning | Launch | Bounds |
| --- | --- | --- | --- |
| `baseSliceWei` | an ongoing slice with no draws since the last | 0.05 ETH | > 0, ≤ `maxSliceWei` |
| `perDrawWei` | added per FWA draw issued since the last slice | 0.005 ETH | ≤ `maxSliceWei` |
| `backlogBps` | added: this share of the ongoing bucket, so a backlog (fee overflow) is spent when play is light | 1% | ≤ 10% |
| `maxSliceWei` | the largest slice, and every milestone slice | 1 ETH | > 0, ≤ 1 ETH (`MAX_SLICE_WEI`) |
| `idleSpacing` | spacing with no draws | 60 minutes | ≥ `minSpacing`, ≤ 30 days (`MAX_SPACING`) |
| `minSpacing` | the shortest spacing, and the milestone cadence | 10 minutes | ≥ 10 minutes (`MIN_SPACING`) |
| `drawsToHalve` | draws that halve the spacing | 20 | 1-1,000,000 |
| `maxImpactBps` | price move one slice may cause | 3% | 1 bp-5% (`MAX_IMPACT_BPS`) |
| `maxDeviationBps` | price move against the buyer since the block opened that stops a slice | 2% | 1 bp-3% (`MAX_DEVIATION_BPS`) |

The bounds in capitals are constants: no owner can pass them.

- `nextSlice() returns (amount, milestone, runAt)`: milestone ETH first: `amount = min(milestoneBalance, maxSliceWei)`,
  `runAt = lastRunAt + minSpacing`; otherwise ongoing, with `n = drawsSinceLastRun()` (FWA's `lastIssuedSequence` since
  `lastRunSeq`, recorded at each slice; 0 before the pool exists): `amount = min(maxSliceWei, ongoingBalance,
  baseSliceWei + perDrawWei × n + ongoingBalance × backlogBps)` and `runAt = lastRunAt + max(minSpacing, idleSpacing ×
  drawsToHalve / (drawsToHalve + n))`. At launch: 0.05 ETH an hour when idle, 0.15 ETH every 30 minutes after 20 draws,
  every 10 minutes from 100 draws, 1 ETH from 190 (plus 1% of the bucket; sim/results/burner.md).
- `process(minOut)` (anyone): reverts `TooSoon` before `runAt`, `NoWork` on an empty slice, `PriceMoved` if the price
  has moved more than `maxDeviationBps` against the buyer since the block opened (`priceOk()`, from the hook's
  `blockOpenPrice`); swaps with a price limit of `maxImpactBps` (a larger slice is filled only up to the limit, the rest
  stays in its bucket); `InsufficientOutput` below `minOut`; burns every coin bought; records `lastRunAt` and
  `lastRunSeq`; then reimburses the caller from the same bucket: `min(game.quoteTip(gasUsed), 5% of the ETH spent
  (MAX_TIP_BPS), the bucket's balance)` (`keeperPaid`).
- Conservation: `reserveIn + ongoingIn = reserve + ongoingBalance + milestoneBalance + ongoingSpent + milestoneSpent +
  keeperPaid`.
- Committed buyback ETH has no outflow besides the swap and the slice's keeper; it never moves in a migration. Sending
  part of the trading fees elsewhere (for example to a second buy-and-burn) is a fee-recipient change (section 8).

## 6. Keepers

The game pays the caller of `sync` and `retireStep` (D63):

- `NoWork` revert if the call did nothing;
- otherwise `quoteTip(gasUsed) = (gasUsed + gasOverhead) × min(tx.gasprice, maxGasPrice) + flatFee` (D79), with
  `gasUsed` measured by the game from entry to the payment.

The first factor reimburses the call's gas at the price the caller paid for it, capped per gas but never refused above
the cap; the flat fee gives a third-party keeper a reason to run at any gas price. No interval. Launch (Owner,
`setKeeperParams((maxGasPrice, gasOverhead, flatFee, payDelay))`, flat fee ≤ 0.1 ETH and delay ≤ 1 hour, else
`OutOfBounds`; the others unbounded): `maxGasPrice` 3 gwei, `gasOverhead` 70,000 (the gas outside the game's own
measurement: intrinsic, calldata, the payment), `flatFee` 0.0002 ETH, `payDelay` 5 minutes (within it of an `upkeep`
that did work, a paid `sync` of light work (under `PLAYER_UPKEEP_GAS`, 2.5M gas) does the work and is paid nothing (D82); a no-work call still reverts `NoWork`). A keeper that also builds blocks can raise its own pay up to the cap by paying itself
priority; the cap bounds it.

Paid by forced ETH transfer (`KeeperPaid`), always within `keeperAvailable() = keeperAllowance − keeperPaid`
(retirement included) and never out of cash owed to replacements (`cash − replacementsOwed`); while retiring nothing is
owed, so it may come from any cash, still never above the allowance. Keeper parameters raised before a sunset can
therefore reach only the allowance left, never the cash handed to the Sunset.
The allowance starts at `openingAllowance` (0.2 ETH at launch, D82, a limit rather than a deposit: listing the opening board and the first NFTs) and grows
by each capture's `opsBps` × its replacement cost (section 4). Keeper pay is an expense in `profit`. The burner
reimburses its own keepers from the buyback slice (D52) with `game.quoteTip`, at most 5% of the slice. Measured costs:
docs/receipts/gas.json.

Keeper jobs (keeper/): `sync` (book, replace prizes, list and reprice collection NFTs, grow the board, pay out; paid by
the game), `activate` once, `release` as a fallback for a collection win not yet released (unpaid), `buyback`
(`burner.process` once `nextSlice().runAt` has passed, reimbursed from the slice), `sweep` on the vault when it can forward (rewarded by the vault); while
retiring `processAcquisitions` and `retireStep`; after retirement `retireStep` (late settlements), `migrateApes`,
`migrateCapital`, `flushSunset` (`Sunset.flush`), `releaseRetired` and `buyback`. Settling draws is not a keeper job:
FWA's randomness callback settles them, and anyone may settle the rest. Players' draws through the DrawRouter also run
`sync` and `sweep` (section 7).

## 7. Player entry point

`DrawRouter` (periphery, stateless, no owner, no privileges, wired into nothing; D53, D57, D60): `draw(pool, game,
settle, syncCount, upkeepGas, count, maxFee, minWeightedValue, maxSlippageBps, expectedInventoryVersion, deadline)`:

0. `pool` must be `game.pool()` (`WrongPool`, D70), so a site whose read RPC lies about the pool cannot have a player
   pay another contract;
1. settles up to `settle` draws waiting in FWA's queue (`processAcquisitions`, failure ignored);
2. `acquire` / `acquireBatch` of `count` draws for `msg.sender` (NFTs, refund credit and delivery rights to the
   caller) under FWA's own guards; `count` 0 skips the purchase (upkeep only, e.g. when a booking backlog has closed
   purchases);
3. if `syncCount` and `upkeepGas` > 0: reverts `UpkeepGas` unless `gasleft() ≥ upkeepGas + upkeepGas/63 + TAIL_GAS`
   (310,000: the sweep and the change; so an estimated gas limit always includes the budget), then
   `game.sync{gas: upkeepGas}(syncCount)` and the vault's `sweep{gas: SWEEP_GAS (250,000; a metered sweep and
   one that also splits the fee overflow both stay well inside it: 126,362 and 211,044 gas measured on the fork)}()` (the vault read from
   `game.vault()`), each tried on its own (failure ignored: an upkeep that needs more than its budget fails alone, the
   draw stands). Upkeep runs after the purchase so a listing it adds cannot invalidate the player's quoted inventory
   version;
4. returns every wei left to the caller: FWA's change, the game's `sync` payment and the vault's sweep reward.

`quote(pool, settle, count)` gives the price after that settlement (for `eth_call`). `measureUpkeep(game, syncCount)`
returns whether `sync` would do anything and the gas it uses (for `eth_call`); the site asks for the upkeep only when
it is at most 2.5M gas, with `upkeepGas` 30% above the measurement plus 50,000, and leaves heavier work to keepers. FWA's own buyer actions (withdraw
refund credit, retry or refund a failed delivery) are called on FWA directly.

## 8. Migration, fee recipient and sunset (D55, D57, D63; docs/MIGRATION.md)

`MigrationAuthority` (holds nothing; administered by the owner through `Admin`): the only way the game ends or moves,
and the only caller of `CollectionHook.setFeeRecipient`. `wire(game, poolOwner, vault, hook, sunset)` once by the
deployer (the sunset must be a contract). `DELAY` = 72 hours (P).

- `propose(successor)` (owner): a contract (`NotAContract`); its code hash is pinned; replaces any pending proposal and
  restarts the delay; `propose(0)` cancels. `executableAt()` shows when. Refused once the successor is the Sunset
  (`SunsetFinal`).
- `execute()` (anyone, ≥ 72 h after the proposal; `NothingPending`, `TooEarly`; `CodeChanged` if the successor's code
  hash differs from the pinned one): the pending address becomes `successor` and the hook's fee recipient, and a
  pending fee-recipient proposal is cancelled. The first execution (or the sunset) calls `game.retire()`: no new draws;
  settlement, delivery and refunds continue. A later execution (outside a sunset) only replaces the successor (and the
  fee recipient) for whatever has not moved; once a migration has started that is the only way to move the fees.
- `sunset()` (owner, at once): cancels the pending migration and fee-recipient proposals; the successor and the fee
  recipient become the immutable `Sunset` contract (`sunsetter`, section 9); retires the game if no migration has
  started. Instant because its only destination is buybacks. It can follow a migration that has started, for whatever
  has not moved yet. Final: afterwards `propose` reverts `SunsetFinal` and `proposeFeeRecipient` reverts `Started`, so
  whatever the Sunset was handed, everything still to reach it and every later trading fee go to buybacks.
- The $LAYER share (D90) sits outside this route: a migration, a new fee recipient or the sunset changes where the
  rest of each fee goes, never the share. It keeps going to the tap the owner set, and the owner can change the share
  (0-5%) or the tap at once with `CollectionHook.setLayer`, without the 72-hour notice, also after a migration or the
  sunset has started; renouncing ownership freezes the setting as it stands.
- `CollectionGame.retireStep` (anyone, paid, batched) settles, redeems every Shape and Pack, withdraws collection NFTs
  into custody and returns all game ETH to the vault.
- `migrateApes(max)` (anyone, repeatable; once started and `game.retired`, else `NotStarted` / `NotSettled`): up to
  `max` × `poolOwner.migrateApe(successor)`, each a plain `transferFrom` of a custody NFT straight to the successor.
- `migrateCapital()` (anyone, repeatable; same conditions): `vault.migrateCapital(successor)`, the vault's whole
  balance by forced ETH transfer.
- `proposeFeeRecipient(recipient)` (owner; refused with `Started` once a migration or the sunset has started): a
  contract, code hash pinned, `0` cancels; `executeFeeRecipient()` (anyone,
  ≥ 72 h after; `CodeChanged` as above) points the hook's trading fees at it while the game keeps running (for example
  a splitter that also funds another buy-and-burn). `feeExecutableAt()` shows when. The recipient must accept ETH from
  the PoolManager in the middle of a swap, cheaply, or swaps revert until it is changed.
- Committed buyback ETH (the burner) never moves; its locked reserve goes to its milestone bucket (`releaseRetired`).
- No holder veto and no separate renounce: `Admin.renounceOwnership` ends `propose`, `proposeFeeRecipient` and
  `sunset` with every other owner function.

## 9. Sunset

`Sunset` (no owner, no administration; `collection`, `burner`, `poolOwner` and `game` immutable): the built-in successor
`MigrationAuthority.sunset()` hands everything to. ETH leaves only to the CollectionBurner (which books it as ongoing
and spends it buying and burning the coin), apart from a buyer's own overpayment, which is refunded; NFTs leave only to
auction buyers.

- `receive`: accepts ETH from anyone: the vault's capital (`migrateCapital`), trading fees (it is the fee recipient
  after a sunset), anything else. Held until `flush`.
- `start()` (anyone): once the game has retired (`NotRetired`), starts the auction clock (`startedAt`, set once).
- `auctionPrice(tokenId) = refCost × (15,000 − 12,500 × min(t, 30 days) / 30 days) / 10,000`, `t` since `startedAt`
  (0 before it): 150% of the NFT's recorded cost (`poolOwner.nfts(tokenId).refCost`) falling linearly to 25% over
  30 days (`AUCTION_DURATION`), then 25%.
- `buy(tokenId)` (anyone, payable): starts the clock if needed; the NFT must be held here (`NotHeld`) and `msg.value ≥
  auctionPrice` (`Underpaid`); the NFT goes to the caller (`transferFrom`), exactly the auction price to the burner in
  the same call (`auctionProceeds` counts the price) and any excess back to the buyer.
- `flush()` (anyone): starts the auction clock if the game has retired and nobody has (so the clock cannot stall; the
  keeper bot's `flushSunset` job), then sends everything held to the burner (`flushed`).
