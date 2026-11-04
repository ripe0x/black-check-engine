# Security

**No independent audit has been done.** This document states the threat model, what the code enforces, how it is
tested, and what trust and risk remain.

## The sunset guarantee (for holders)

**If the game is ended into the sunset, everything it hands over buys the coin and burns it. None of it can go to the
owner or to anyone else.**

- **Every Ape is sold in a public Dutch auction.** The Apes go to the `Sunset` contract (src/migration/Sunset.sol).
  Each one's price starts at 150% of its recorded cost (what the vault paid for it; for a donated Ape, the clearing
  price the vault had last recorded when it was donated) and falls in a straight line to 25% over 30 days, then stays at 25%. Anyone can
  buy one (`buy`). **The auction price goes to the CollectionBurner in the same call**; anything paid above it is
  refunded to the buyer. If nobody starts the clock, the first `flush` does (the keeper bot runs it), so the auction
  cannot stall.
- **The vault's capital and the trading fees go to the burner too.** The vault hands everything it holds to the Sunset
  contract (`migrateCapital`), trading fees are pointed at it for good, and anyone can send what it holds to the burner
  (`flush`).
- **The burner only buys the coin and burns it**, in bounded slices, every coin burned in the same call; its keeper is
  reimbursed at most 5% of a slice.
- **The Sunset contract has no owner and no other outflow.** No administrator, no setter, no upgrade: ETH leaves it only
  to the burner (and an overpayment back to its buyer), an Ape only to the buyer who paid its auction price.
- **The sunset is final.** Once the successor is the Sunset contract, `propose` reverts (`SunsetFinal`) and no
  fee-recipient change can be proposed (`Started`): nothing it was handed, nothing still on its way to it and no later
  trading fee can be pointed anywhere else.

**Why the owner can trigger it at once, and nothing else.** `MigrationAuthority.sunset()` (the owner) needs no notice,
because its only destination is buybacks: the successor is the immutable Sunset contract wired at deployment. Every
other way value could change destination waits a public **72 hours**: a migration to any other successor
(`propose`, then anyone `execute`s) and a change of the trading-fee recipient (`proposeFeeRecipient`, then anyone
`executeFeeRecipient`s, only before any migration or the sunset has started: from then on fees follow the successor).
In both the destination must be a contract and its code hash is pinned at proposal and checked
at execution: code changed in between cannot execute (`CodeChanged`). The owner cannot redirect fees at the hook
directly: `CollectionHook.setFeeRecipient` answers only to the MigrationAuthority (`NotMigrator`).

**What the guarantee does not cover**, so that nothing is overstated:

- Players keep what is theirs: draws in flight settle or refund in FWA, refund credit and prizes in FWA's delivery
  quarantine stay claimable. ETH already in the burner was already committed to buybacks.
- While the game unwinds, `retireStep` pays its caller from the game's cash (gas plus margin at the owner's keeper
  parameters; see "Administration") before the rest goes to the vault and on to the Sunset contract. That pay never
  exceeds the keeper allowance left (`keeperAvailable()`), so keeper parameters raised before a sunset can take at most
  that allowance, never the rest of the cash.
- After `renounceOwnership` nobody can trigger the sunset or a migration: the game then runs on its last settings for
  good.

## Assets and who could want them

| Asset | Held by | Threats |
| --- | --- | --- |
| Players' tickets in flight | FWA pool | FWA failure; drift refunds; stuck delivery |
| Prize Shapes and collection NFTs | FWA pool / CollectionPoolOwner | theft via owner actions; relisting at worse odds; leaking NFTs at the end |
| Game working capital | CollectionGame | distributing capital as "profit"; keeper pay for work not done; insolvency after expensive wins |
| Vault capital (fees, contributions, surplus share) | FundingVault | overpaying or fake acquisitions (an owner-set bid paying a colluding seller); misclassification as profit; owner withdrawal; a fee overflow that takes the game's capital, its growth or the bid's ETH |
| Future trading fees | CollectionHook → fee recipient (the vault) | redirection (only through the MigrationAuthority: a 72-hour notice, or the sunset) |
| Keeper allowance | CollectionGame (`keeperAllowance − keeperPaid`) | pay for calls without work; a paid refill loop; parameters chosen to pay one caller |
| Buyback ETH | CollectionBurner (locked reserve, milestone and ongoing buckets) | early or faked milestone release (tier gaming); sandwiching buybacks, above all a release's announced first slice; keeping bought coins |
| Apes and capital at the end | Sunset | sales below the stated price; proceeds diverted |
| Coin supply / liquidity | CollectionToken / ProtocolLiquidity | minting; liquidity removal |

## Invariants (enforced in code; tested)

`test/invariant/Invariants.t.sol` runs a fork handler with random pulls (single and batched), VRF words in and out of
order, timeouts, keeper syncs, maintenance windows, trading, contributions, acquisitions, bid sweeps (with the fee
overflow), buybacks, milestone releases and adversarial calls (by a stranger and by the owner); each invariant is also covered by focused
fork tests.

| # | Invariant | Enforced by | Test |
| --- | --- | --- | --- |
| 1 | Total supply never increases | no mint function (`CollectionToken`) | `invariant_supplyNeverIncreases` |
| 2 | No outside contract has custody authority | the vault's one adapter (fixed at wiring) runs inside vault postconditions; the DrawRouter and the Sunset contract hold no privileges | `invariant_noLeaks`, `test_adapterMustDeliver` |
| 3 | Every ETH/NFT outflow has an authorised purpose and destination | each holder's narrow functions (ARCHITECTURE.md) | `invariant_booksAndDistributions`, `invariant_nftCustody`, `test_custodyIsNotAnAdministrativeFunction` |
| 4 | Gameplay capital is never distributed as profit | `distributable = min(profit − distributed, cash − protected)` | `assertBooks` everywhere, `test_consecutiveExpensiveWins` |
| 5 | Distributions ≤ realised surplus (revenue − prize expense − keeper pay) | same | `invariant_booksAndDistributions` |
| 6 | Losses are not erased by fee income | capital never enters `profit` | `test_consecutiveExpensiveWins` |
| 7 | Every distribution goes only to the vault or the burner: `continuityShareBps` to the vault, at most its shortfall of one Ape at the funding reference, the rest to the burner; once the vault can buy an Ape, all of it buys back the coin | `CollectionGame._pay` | `invariant_surplusOnlyToVaultAndBurner`, `test_distributionSplitsVaultThenBurner`, `test_allSurplusToBuybacksOnceTheVaultHoldsAnApe` |
| 8 | Milestone ETH only for a verified delivered win, or once the game has retired: an Ape exit (`firstExitBps`, 60% of the reserve; a second exit within `exitWindow` of the last, the rest) or a big prize (a Shape or Pack listed at `bigPrizeWei` or more, `bigPrizeBps`, 15%) (D64) | `CollectionBurner.releaseBps` / `release` read FWA `Settled` to a purchaser other than the pool owner, then the pool owner's registry (an Ape exit) or FWA's listed price (a big prize); `releaseRetired` reads `retired`. The owner sets the shares (`setTiers`), never the trigger | `invariant_milestoneOnlyOnWins`, `test_milestoneTiersOnlyOnDeliveredWinsOnce`, `test_smallPrizeNeverReleasesBigPrizeReleasesItsTier`, `test_failedApeDeliveryReturnsToCustodyWithoutRelease`, `test_releaseNeedsADeliveredCollectionWin`, `test_milestoneReserveReleasesOnlyAfterRetirement` |
| 9 | At most one release per win | `released[listingId]` in the burner | `test_milestoneTiersOnlyOnDeliveredWinsOnce`, `test_milestoneBuybackExecutesInSlicesAndTwoWinsAccountedApart`, `test_apeWonEarlyWithNoReplacementKeepsShapeDrawsOpen` |
| 10 | No NFT counted twice as acquired or won | `register` requires state `None`; wins recorded once on `Settled` | `invariant_nftCustody` |
| 11 | Exposure ≤ the target after every listing and reprice (≤ the 50% ceiling at the gate) | pool owner checks every listing and reprice; the gate checks the ceiling live | `invariant_exposureTarget`, `test_targetDefersDecayAndGrowthResumesIt`, `test_manyApesAllListedAsTheBoardGrows` |
| 12 | No change worsens an existing prize commitment | a published notional is never raised, whatever the listing parameters | `invariant_commitmentsNeverWorsen`, `test_listingParamsApplyForwardAndNeverRaise` |
| 13 | Refund and settlement survive pauses | pause only toggles FWA admission | `test_guardianPauseKeepsSettlementAndRefunds` |
| 14 | The end of the game never pays the owner: a migration pays only the contract proposed 72 hours earlier with its code unchanged; the sunset pays only the Sunset contract, whose ETH goes only to the burner | retirement: prizes → game → vault; Apes and vault capital only to `MigrationAuthority.successor` | `test_sunsetWithPendingRequestsAuctionsAndBurns`, `test_fullMigrationConservesAssetsAndClaims`, `test_ownerCannotBypassTheDelay`, `test_changedCodeCannotExecute`, `test_sunsetIsFinal` |
| 15 | No administrative function moves custody NFTs, prizes in play, game cash, vault ETH or committed buyback ETH directly, or redirects trading fees | custody, capital and fee functions answer only to the game, the vault and the MigrationAuthority; `onlyOwner` functions set parameters, the pattern and board size, and propose (their indirect reach: "Administration") | `test_custodyIsNotAnAdministrativeFunction`, `test_ownerCannotBypassTheDelay`, `invariant_noLeaks` (owner among the handler's attackers) |
| 16 | FWA pool owner never changes | FWA locks ownership; no transfer/execute here | `invariant_poolOwnerFixed`, `test_directFwaPurchaseBlockedBeforeActivation` |
| 17 | Bought coins never go anywhere | burned in the same call | `invariant_noLeaks`, `test_ongoingBuybacksFollowPlay` |
| 18 | Donated assets cannot be withdrawn | no function | `test_nftContributionUsesConservativeReference` |
| 19 | With no keeper at all, exposure stays within the 50% ceiling after every in-flight request settles, and in-flight requests never exceed `maxInFlight − 1 + maxBatch` | `canPurchase` reads live FWA state; listing and decay keep `gateHeadroom` | `invariant_liveExposureAfterInFlightSettle`, `test/fork/Outage.t.sol` |
| 20 | The burner conserves ETH: received = locked reserve + buckets + spent on the coin + keeper reimbursement; balance = reserve + buckets; no outflow but the swap and the slice's keeper (≤ 5%) | `CollectionBurner.receive` / `process` | `invariant_burnerConservation`, `test_ongoingBuybacksFollowPlay` |
| 21 | A migration moves V1's NFTs and vault capital only to the successor proposed at least 72 hours earlier (code unchanged) or to the Sunset contract, and only after V1 has settled and retired; committed buyback ETH never moves; player claims stay in FWA | `MigrationAuthority` (owner proposal, 72 h, code pinned, execution by anyone; `sunset`); the pool owner's and vault's migration functions answer only to it; `migrateApes` / `migrateCapital` require the game `retired` | `test/fork/Migration.t.sol`, `test/fork/Sunset.t.sol` |
| 22 | No step of `sync` can block booking, and retirement completes with minting broken | each step in its own `try`; booking and retirement mint nothing | `test_brokenMintingBlocksNothingEssential`, `test_collectionWinWithMintingBroken` |
| 23 | Booked revenue never exceeds what FWA pays | revenue booked at the highest admissible edge (lower bound), trued up to ETH received | `test_bookingIgnoresChangesBetweenRequestAndBooking`, `assertBooks` (exact when caught up) |
| 24 | Without an executed migration or the sunset nothing migrates: V1 stays live, no stranger or owner call reaches a migration function, and trading fees go to the vault until a fee-recipient change executes after its notice | migrator-only hooks; `execute` / `executeFeeRecipient` need a proposal 72 hours old | `invariant_migrationLocked`, `test_feeRecipientMovesOnlyAfterTheNotice` |
| 25 | The live bid never offers the game's protected capital, and an acquisition pays at most the bid (direct sale) or the listing's price plus the finder fee within the bid (marketplace) | `liveBid = min(bidBalance, acquisitionBudget, maxPrice)`; `sellToProtocol`, `fillOrder` checks | `test_gameCapitalComesFirst`, `test_sellerNamesPriceAtMostTheBid`, `test_seaportOrderFilledThroughAdapter` |
| 26 | Keeper pay: nothing for a call without work; at most `quoteTip(gasUsed)`; always within the allowance (retirement included) and, while the game runs, never out of cash owed to replacements; a step that runs out of gas fails the whole call, so a low gas limit cannot skip work and be paid | `CollectionGame._tip`, `_gasCheck` (`OutOfGas`) | `test_noWorkNoPay`, `test_payNeverExceedsTheAllowance`, `test_aboveTheCapReimbursedAtTheCap`, `test_retirementPayWithinTheAllowance`, `test_tooLittleGasNeverSkipsWork` |
| 27 | The Sunset contract holds nothing while the game runs; it auctions only after retirement and sends everything it receives to the burner, except a buyer's overpayment, refunded to the buyer | `Sunset.start` / `buy` / `flush` | `invariant_noLeaks`, `test_auctionOnlyAfterRetirement`, `test_sunsetWithPendingRequestsAuctionsAndBurns` |
| 28 | The vault conserves ETH: balance + acquisition spend + finder fees + sweep rewards + game capital sent + migrated out + fee overflow = trading fees + contributions + surplus in + returned from the game (D64) | every vault inflow and outflow has its counter (`overflowOut` for the overflow) | `invariant_vaultConservation` |
| 29 | The fee overflow goes only to the immutable CollectionBurner (its ongoing bucket), only once the game is active and while the live bid is at its fill target (the activation threshold, or the ceiling or `maxPrice` when lower), and never takes the game's capital need, the board growth its Apes wait for, the bid's ETH or one more Ape at the funding reference (D64, D65) | `FundingVault.pendingOverflow` (capped at the acquisition budget less the bid and `referencePrice`), `sweep` | `test_noOverflowWhileTheBidCanUseTheEth`, `test_noOverflowBeforeActivation`, `test_feesOverflowBeyondTheNextApe`, `test_overflowStopsAtTheNextApe`, `test_overflowShareIsTheOwners`, `invariant_surplusOnlyToVaultAndBurner`, `invariant_vaultConservation` |
| 30 | No owner setting passes the burner's hard bounds (slice ≤ 1 ETH, spacing 10 minutes to 30 days, impact ≤ 5%, deviation ≤ 3%, backlog share ≤ 10%), and the opening fee curve cannot be changed or restarted (D64) | constants in `CollectionBurner._setCadence`; `CollectionHook.LAUNCH_FEE_BPS` / `LAUNCH_DECAY_BPS_PER_MINUTE` and the one initialisation | `test_burnerHardBounds`, `test_curveIsFixedAndOnlyAfterLaunch`, `test_openingCurveOnBuysThenOrdinary` |

## Administration (D57, D63, D64, D65): the trust that remains

**One owner** administers every contract. It acts at once, except where value would change destination: a migration
and a change of the trading-fee recipient each wait a public 72 hours, with the destination's code pinned; the sunset,
whose only destination is buybacks, is instant. The `Admin` contract records the owner; every `onlyOwner` function goes
through `Governed._checkOwner` (`msg.sender == admin.owner()`, never address(0)). `Admin.transferOwnership` names the
next owner and `acceptOwnership` by that address completes it (address(0) cancels a pending transfer); one transfer
moves every contract. `renounceOwnership` ends administration for good: every parameter is frozen, the game keeps
running on its last settings, and neither a migration nor the sunset can ever start
(`test_ownershipTransfersInTwoStepsAndRenounces`). There is no separate renounce of the end-of-life powers and no
holder veto (D63). The deployer's one-shot `wire` rights end at deployment. Draw Packs' presentation admin is a
separate address set at deploy (the owner's); an `Admin` transfer does not move it.

**No administrative function** withdraws prizes in play, game cash, vault ETH or committed buyback ETH (the burner's
reserve and buckets) to an address, moves a custody NFT, redirects trading fees, mints coins, removes liquidity or
changes the FWA pool owner. The custody, capital and fee functions answer only to the game, the vault and the
MigrationAuthority; the owner cannot retire the game directly (`retire` answers only to the MigrationAuthority)
(`test_custodyIsNotAnAdministrativeFunction`, `test_ownerCannotBypassTheDelay`,
`test_onlyTheOwnerSunsetsAndOnlyTheAuthorityRetires`; the invariant handler calls them as the owner). What the owner
can do, and the worst case of each (a compromised owner key can do all of them at once):

| Power | Function (bounds) | Worst case |
| --- | --- | --- |
| Future trading fees | `MigrationAuthority.proposeFeeRecipient` (a contract; code pinned; only before any migration or the sunset has started), executed by anyone 72 hours later | after a public 72-hour notice every future fee goes to a contract of the owner's choosing, which may forward it to the owner; one that refuses ETH makes swaps revert until changed (again after 72 hours). Fees already in the vault stay there. The game keeps running |
| Migration | `MigrationAuthority.propose` (a contract; code pinned), executed by anyone 72 hours later | after a public 72-hour notice V1 stops for good, trading fees follow the successor, and once V1 has settled the Apes and all the vault's ETH go to the proposed contract, which may forward them to the owner |
| Sunset | `MigrationAuthority.sunset()` (at once; cancels pending proposals; final) | V1 stops for good and everything handed over is auctioned or sent to the burner: the game ends earlier than holders want, but no value can reach the owner (above, "The sunset guarantee") |
| Keeper pay | `CollectionGame.setKeeperParams` (flat fee ≤ 0.1 ETH, `payDelay` ≤ 1 hour; gas-price cap and overhead without bounds) | while the game runs, whoever calls `sync` first, the owner included, takes the unpaid allowance (`keeperAvailable`), up to the cash not owed to replacements. During retirement (after a migration or the sunset) `retireStep` may pay from any game cash, but still never above the allowance left: high parameters let its caller take at most that, never the rest of the cash on its way to the vault and the successor (`test_retirementPayWithinTheAllowance`). The burner reimburses its keeper at the game's quote, at most 5% of a slice (`MAX_TIP_BPS`, constant) |
| Surplus split | `CollectionGame.setSettings` (`continuityShareBps` 0-100%), `CollectionBurner.setMilestoneBps` (0-100%) | more of each distribution to the vault (never beyond its shortfall of one Ape) or to the locked milestone reserve; every distribution still goes only to the vault or the burner |
| Fee overflow (D64, D65) | `FundingVault.setOverflowBps` (0-100%; `OutOfBounds` above 10,000) | at 100% every trading fee beyond the game's capital, the board growth, the bid and one more Ape at the funding reference goes to buybacks while the bid is at its fill target; at 0% none does. It can never take the game's capital or the next Ape. Either way fees stay in the vault or reach the immutable burner, nowhere else |
| Stray NFTs | `sweepNFT` on every governed contract (never the collection, Shapes or Draw Packs: `Admin.isProtected`, recorded once at deployment and closed) | the owner takes an unrelated ERC-721 sent to a contract by mistake; nothing the game holds or lists |
| The live bid | `FundingVault.setBidParams` (threshold ≤ 100%; sweep ≤ 100 ETH; cooldown 1-7,200 blocks; `maxPrice` 0 = no cap; ceiling 0 or 100-1,000% of the funding reference; slow sweep ≤ sweep; `maxDropBps` 100-10,000, D83), `setActivationThreshold` (≤ 1,000 ETH) | a high threshold fills the bid with everything the vault may spend at once: a colluding seller is then paid up to the acquisition budget (the vault's ETH not needed as game capital or board growth) for one Ape. The Ape does reach custody. The marketplace adapter is fixed at wiring (Seaport): it spends at most the bid less the finder fee and must deliver the NFT to custody in the same call |
| Economics and the board | `CollectionGame.setPricing` (markup and keeper allowance rate 0-100%; the markup also sets which prizes are listed at or above the big-prize price), `setSettings` (reserve ≥ the largest backing and ≤ 1,000 ETH, and the rest bounded), `setPattern` (1-1,000 backings, each mintable; applies to each row when next listed), `setBoardSize` (grow only, ≤ 50 rows a call, the vault must cover them and the game's need), `setBoardParams` (`listBatch` 1-20, `maxPerCall` 1-10, `bookPerCall` 1-20, each ceiling measured under the gas cap, D81), `CollectionPoolOwner.setListingParams` (target ≤ 50%), `setMaxInFlight` (1-50), `CollectionHook.setFees` (each ≤ 10%; the opening curve is a constant and the hook clamps every fee at 69%), `FundingVault.setExcluded` | worse prices or odds, a different or larger board (vault capital turned into prizes, still game capital), higher fees; with no markup, or a very low Ape minimum, settings under which a draw's expected return exceeds its price, so anyone, the owner included, plays at the protocol's expense. Kept: the reserve covers the largest prize (D79), a published notional is never raised, exposure at the gate ≤ 50% |
| Buyback cadence and milestone tiers (D64) | `CollectionBurner.setCadence` (hard bounds, constants: slice ≤ 1 ETH, spacing 10 minutes to 30 days, impact ≤ 5%, deviation ≤ 3%, backlog share ≤ 10%), `setTiers` (each share 0-100%, exit window ≤ 7 days, big-prize price > 0) | timing only: no setting sends a wei anywhere but the coin swap and the slice's keeper (≤ 5%), and every release still ends in buybacks. Fastest: 1 ETH slices every 10 minutes at the 5% impact and 3% deviation limits, where low trading fees let a sandwicher take part of each slice (bounded by those limits; the coins are still burned). Slowest: slices as small as 1 wei every 30 days (no keeper is paid enough to run them), and tiers at 0 (or a big-prize price no prize reaches) keep the reserve locked until the game retires; locked for good if the owner then renounces, since nothing can retire the game afterwards |
| $LAYER share (D90) | `CollectionHook.setLayer` (0-5% of each trading fee after the launch curve, 1% at launch; the tap any contract) | a twentieth of each later fee leaves the game, and a compromised owner key can point it at a contract it controls (accepted owner power, D90); a tap that refuses ETH makes swaps revert until it is changed, so taps are LayerTaps, which always accept |
| Coin metadata (D86) | `CollectionToken.updateImage`, `updateMetadata`, `setMetadataRenderer` | wrong or invalid metadata (bytes that are not UTF-8 make the default JSON invalid, accepted: owner input, no contract reads it) |
| Pause | `CollectionGame.setPaused` (refused once retiring) | new draws stop; settlement and refunds continue |
| Market launch | `ProtocolLiquidity.launch` (once; no ETH) | opens the market at a chosen price |
| Coin allowlist (D84) | `CollectionToken.setAllowed` (at most 50; never the PoolManager or zero; frozen after a renounce) | while restricted, the owner lets chosen addresses send and receive the coin; an allowed venue could host fee-free trading, at the owner's choice |

Readers should treat the system as "administered by one owner who can change the economics, keeper pay and the timing
of buybacks at once, end the game into buybacks at once and for good, and, after a public 72-hour notice, redirect future trading fees
(until a migration or the sunset starts) or move the Apes and treasury to a contract it chose", not trustless. Every change emits an event; the site lists them as they happen.

## External dependencies

- **FWA V2** (factory owner can change edge, cooldown, global switches, VRF limits; `edgeBps ≤ 10%`, cooldown ≤ 7 days).
  The game reads them live and closes admission outside its supported range (edge ≤ 5%, cooldown ≤ 30 days, D82; tested with
  FWA's real setters). FWA can disable purchases globally; settlement and refunds continue. A delivery can be stuck
  until the player refunds it; the game keeps working (tested).
- **Chainlink VRF via FWA's service**: missing words expire and refund (tested).
- **Uniswap v4 PoolManager**, **Shapes** (mint fee read live), **BAYC** (plain ERC-721), **Seaport 1.6** (the vault's
  adapter). Shapes' admin, who sets its mint fee, is `0xCB43078C32423F5348Cab5885911C3B5faE217F9` (ripe0x.eth), the
  same address as this system's owner: a fee raise after prizes are listed leaves those listings priced on the old
  cost until they turn over, so it is an owner-key economic power, not a third party's (round 4 E1).
- **FWA token** transfer lock: verified from source; the relay route depends on the FWA hook's current allowance rules
  and `externalBuysEnabled` (true today). If FWA changes them before deploy, use the ETH buy route.

## Draw Packs: the second custody contract (security review)

Draw Packs (`lib/shape-packs`, ripe0x/shape-packs `draw-packs` @ `3a463f7`, used unmodified, built through
`src/vendor/PacksBuild.sol`) is first-party code: a separate ERC-721 whose token holds Shapes. Every Pack prize, while
listed, while won and after, is custody in that contract, so it is in the independent audit scope together with `src/`
(docs/AUDIT_SCOPE.md). Reviewed boundaries:

| Boundary | Behaviour (source) | How this system relies on it | Evidence |
| --- | --- | --- | --- |
| Entry of Shapes | only pulled from the caller (`transferFrom(msg.sender, …)`) or minted into it inside a one-call receiver window; a safe transfer of a Shape from anyone is refused | the pool owner creates each Pack with ETH only (`createPackTo([], makeup(backing), poolOwner)`: the fewest Shapes adding up to the backing, exact payment = backing + one Shapes mint fee per Shape) | `test_boardListedAtMarkupOverFullCost` (each Pack's contents add up to its backing exactly), `test_packMakeupUsesFewestShapes` |
| Exit of Shapes / ETH | owner-only (`open`, `openTo`, `redeem`, `redeemTo`, `unseal`; approvals do not suffice); state is final before the first external call; `redeem` pays through Shapes `redeemBatchTo` to the recipient | a winner owns the Pack outright (FWA delivers with `transferFrom`); the pool owner redeems Packs it holds on withdrawal, refunded delivery and retirement, and forwards the measured ETH to the game | `test_winnerOwnsPackAndRedeemsIt`, `test_winnerOpensPackIntoShapes`, `test_failedPackDeliveryRecoveredAndRedeemed`, `test_retirementRedeemsEveryPack` |
| Administration | the admin (here the owner's address, set at deploy; not moved by an `Admin` transfer) reaches presentation only: renderer, preview limit, copy, one-way lock. No path into custody, no pause, no upgrade | none; a broken renderer can only break `tokenURI`, which neither FWA nor the game calls | source review |
| Self-custody / ETH | a Pack cannot be held by the Packs contract; direct ETH is refused (forced ETH is stranded, not reachable) | the pool owner never sends ETH except inside `createPackTo` | `test_packCustodyBoundary` |
| Minimum | `MIN_PACK_VALUE = 2 × unit` (0.02 ETH) in this dedicated instance | `CollectionPoolOwner.prizeCost` refuses any non-denomination prize below it or not a whole number of units | `test_packCustodyBoundary`; postflight checks the minimum |
| Receipt into the pool owner | Packs arrive by `_safeMint` with operator = pool owner, or back from FWA with operator = the pool | `onERC721Received` accepts Packs and Shapes only from those operators; an outsider's Pack is refused | `test_packCustodyBoundary` |
| Listing in FWA | FWA takes any ERC-721 by `transferFrom` from the owner; the pool owner approves the pool for the Packs collection | Packs are ordinary listings: weight, settlement, delivery, refunds, quarantine and `recoverRefundedNFT` behave as for Shapes | `test/fork/Packs.t.sol`, `Outage.t.sol`, throughput study |

Residual: a stranded Shape pushed into the Packs contract by plain `transferFrom` cannot be recovered (by design, no
admin path); a Pack's value is the live sum of its Shapes' backing, so it depends on the Shapes contract's redemption
rules; the presentation admin can change metadata until it locks presentation (recommend locking once the renderer is
final). The game's own exposure to Packs is limited to: minting with exact ETH, holding Packs while listed (FWA holds
them) or returned, and redeeming them; a failed redemption keeps the request open and is retried without blocking
other steps (D39).

## Migration and the sunset (D55, D57, D63)

docs/MIGRATION.md. Two ways to end V1, both through the MigrationAuthority (the game's `retire` answers only to it):

- **Migration**: the owner proposes a successor contract (`propose`; its code hash is pinned; `propose(0)` cancels; a
  new proposal replaces the pending one and restarts the clock); 72 hours later anyone executes it, if its code is
  unchanged (`CodeChanged`).
- **Sunset**: the owner calls `sunset()`: the successor is the immutable Sunset contract, at once, and pending
  proposals (migration and fee recipient) are cancelled. It can follow a migration that has started, for whatever has
  not moved yet (`test_sunsetOverridesAMigration`, `test_sunsetTakesWhatAMigrationHasNotMoved`). It is final: `propose`
  then reverts `SunsetFinal` and `proposeFeeRecipient` reverts `Started` (`test_sunsetIsFinal`).

The first execution (or the sunset) retires V1's FWA pool: no new draws; requests in flight settle; `retireStep`
(anyone, paid as keeper work) books them, redeems every Shape and Pack, withdraws the listed Apes into custody and
returns the game's ETH to the vault. Every execution points the hook's trading-fee recipient at the successor (no
separate owner step) and cancels a pending fee-recipient proposal. Nothing moves until the game has retired. Then `migrateApes` (plain ERC-721 `transferFrom`, no
callback; each record stays readable in the pool owner, which is how the Sunset prices its auction) and
`migrateCapital` (the vault's whole balance, a forced ETH transfer) send the assets straight to the successor; both are
permissionless and repeatable, so anything that reaches V1 later follows (`test_quarantinedApeFollowsLater`). A later
proposal (again 72 hours; refused after the sunset) replaces the successor for what has not moved. Committed buyback ETH never moves: the burner's
locked reserve is released into its milestone bucket once V1 has retired (`releaseRetired`, anyone). The pool owner's
and vault's migration functions answer only to the MigrationAuthority, which holds nothing and whose entry points are
`nonReentrant`. The Sunset contract's `start` (anyone, once the game has retired) starts the auction clock; `buy` and
`flush` start it too, so it cannot stall.

Separately, `proposeFeeRecipient` / `executeFeeRecipient` (72 hours, a contract, code pinned) change only where trading
fees go (for example a splitter that also funds another buy-and-burn) while the game runs on
(`test_feeRecipientMovesOnlyAfterTheNotice`); only before any migration or the sunset has started (`Started`): from
then on fees follow the successor, and only a later successor proposal (outside a sunset) moves them. A recipient must accept ETH from the PoolManager cheaply in the middle of a
swap, or swaps revert until it is changed again.

Remaining trust: the owner's choice of successor or fee recipient (any contract, including one that forwards to the
owner or is upgradeable: the code hash pins the proxy, not its implementation), public 72 hours before anything moves;
FWA's own rules for assets it holds (settlement, refunds, delivery quarantine).

## Board pattern and size after deployment (D46, D59, D63)

The board is a pattern of prize backings stored in the game, repeated without end: row `r` asks for
`pattern[r % length]` (`rowAt`). `setPattern` (the owner, at once) checks that every backing is a prize the pool owner
can mint (`prizeCost`) and that the operating reserve still covers the largest. It applies lazily: nothing listed
moves and FWA's inventory is untouched; each row takes its new backing the next time it is listed (after its prize is
won, or when it is new), and rows already owed are recosted at once (`replacementsOwed`). There is no stale-listing
withdrawal and no rebinding sweep. Tested in `test/fork/Pattern.t.sol`: a new pattern changes nothing listed; won rows
relist at the new backing; owed rows are recosted; the books reconcile.

`setBoardSize` (the owner) only grows the board, by at most 50 rows a call, and only when the vault's balance covers the
new rows on top of the game's capital need; the rows are then listed like replacements
(`test_ownerGrowsTheBoard`). The board also grows on its own when the collection NFTs need rows for the exposure target
(the pool owner's `rowsShort`), under the same funding condition.

## Many Apes (D59)

Every NFT held is listed and the board grows with them, so the number of NFTs and rows is unbounded by design. Every
step stays bounded: ten NFTs listed and ten repriced per call, eight prizes minted and listed (the game's `maxPerCall`,
D61), fifty rows added; an outcome is recorded per listing (`settleListing`) and retirement withdraws ten prizes and
twenty NFTs per call; the purchase gate is O(1) (7.6k gas warm with 100 NFTs and 2,581 rows). Fork-tested with 1, 20,
50 and 100 NFTs (`test/scenario/ManyApes.t.sol`): the largest maintenance call used 7.3M gas
(docs/receipts/many-apes-100.json). **Per-transaction gas cap (D61):** mainnet rejects a transaction above 16,777,216
gas (EIP-7825); with 20 prizes per call the heaviest board needed 24.3M, so the board's restock would have failed for
good. The game's `maxPerCall` (8 at launch, at most 20) and its ten withdrawals per call keep every measured worst case
under 90% of the cap (`test/fork/TxCap.t.sol`). An owner who sets a pattern with heavier Packs, or raises
`maxPerCall`, must measure it first; a board whose batch exceeds the cap stops restocking (draws stay safe: the purchase
gate closes as rows run out) until `setBoardParams` lowers it. One loop grows with size and is an owner action:
`setPattern` recosts every owed row once (linear; docs/receipts/gas-prizes.json `set_pattern_50_rows`). The sunset
auction prices and sells one Ape per call. A row shortage that cannot be funded yet is recorded (it counts as work
once, never again unchanged) so the vault keeps its cost before bidding and growth resumes when funds arrive.

## Fresh-discovery audit (2026-10-30) and fixes (D66)

An independent fresh-discovery run (docs/AUDIT_PROMPT.md; report and path ledger in `audit/`) examined commit
`004c0a4` on a Tenderly fork of block 26,301,533. It is a bounded review, not a safety conclusion. Its results and what
changed:

| Audit item | What it showed | Disposition |
| --- | --- | --- |
| F-1 tiny reference price | A holder sells an Ape for 1 wei (`sellToProtocol` takes any price up to the bid), a donation inherits the 1-wei `lastPrice`; after a draw the minimum notional rounds to 0 and `_decayBatch` divides by it: collection maintenance fails (`StepFailed("collection")`), turnover is not credited, until the owner raised the listing floor | **Fixed:** `register` values any NFT at least `MIN_REF_COST` (0.01 ETH) for listing and exposure; the cash cost stays what was paid (`test_tinyReferenceIsFlooredAndMaintenanceKeepsWorking`). A 1-wei sale still sets `lastPrice`, so the threshold and the ceiling follow it down until the next acquisition or the owner's `setActivationThreshold` / `setBidParams` (the seller gives up an Ape to cause it). **Revised (D83):** the threshold and ceiling now track `referencePrice`, not `lastPrice`; a 1-wei sale lowers the reference by at most `maxDropBps` (25%) and never below the Ape floor, so a single cheap sale can no longer drive the threshold to 0 or the ceiling to 1 wei (`test/fork/FundingReference.t.sol`) |
| F-2 adapter prefund | ETH sent to the adapter's `receive()` came back to the vault mixed with its change: at or above the order price `fillOrder` underflowed (every adapter fill up to the bid blocked); below it the vault booked price minus prefund as the cost and `lastPrice` | **Fixed:** the adapter returns exactly `msg.value − spent`; the vault checks that the adapter's balance did not grow (instead of requiring it empty). A prefund stays in the adapter, inert (`test_adapterPrefundCannotBlockOrRepriceAFill`) |
| F-3 Pack delivery quarantine | A caller names the Packs contract as purchaser; the Pack prize cannot be delivered to its own contract, stays `DeliveryPending` in FWA, and only the purchaser (the Packs contract, which cannot) could claim the refund: 0.02 ETH of backing stranded through retirement for a 0.02541 ETH draw | **Fixed:** `canPurchase` refuses the Shapes and Packs contracts as purchasers (both refuse their own tokens); FWA delivers with `transferFrom`, so no other launch token rejects delivery this way (`test_systemAddressesCannotBePurchasers`) |
| R-1 proxy nominee | The 72-hour code-hash pin does not bind a proxy's implementation: an owner who nominates an upgradeable successor or fee recipient lets its controller change what runs | **Accepted, owner procedure** (already stated in this file and docs/MIGRATION.md): the runbook now makes "not upgradeable, no settable delegatecall" an explicit check before proposing and during the notice |
| Deployment gate | `script/env/mainnet.env` has `OWNER=0`, so the checked-in deploy reverts (`ZeroAddress`) | By design: the owner and the reference price are inputs set before deployment (docs/LAUNCH_CHECKLIST.md) |

**Round 2** (docs/AUDIT_PROMPT_2.md; commit `f44ab9f`, same block) confirmed the three fixes (round 1's reproductions now
stop at their former harm assertions; 15 adapter variants, reference boundaries and the Shapes/Packs refusal tested)
and found:

| Audit item | What it showed | Disposition |
| --- | --- | --- |
| N-1 system purchaser wins a BAYC | The gate refused only Shapes and Packs. Naming the FWA pool as purchaser settles a collection win without moving the BAYC (FWA's self-transfer), books it as won and releases 60% of the milestone reserve; naming the pool owner, game, vault or BAYC contract delivers the BAYC where no route recovers it. Paid with one draw, and only if the draw selects the Ape | **Fixed (D67):** `canPurchase` refuses every system address (the pool, the pool owner, the game, the vault, the migration authority, the collection, Shapes, Packs); the burner also releases nothing for a listing settled to the pool itself (`test_systemAddressesCannotBePurchasers`, `test_poolSelfWinReleasesNothing`) |
| N-2 system purchaser wins a Pack or Shape | The same addresses receive or self-settle Pack and Shape prizes with no forwarding or claim path | **Fixed** by the same refusal |
| R-1 extended | Besides a proxy, a plain contract whose payout or refusal is set in storage can change behaviour at a stable code hash after the 72-hour notice (fork test through the real PoolManager) | **Accepted, owner procedure:** the runbook requires a successor or fee recipient whose behaviour is fixed in code (no proxy, no admin-settable payout, forwarding or refusal) |

**Round 3** (docs/AUDIT_PROMPT_3.md; commit `6d9f949`, same block; a partial report) confirmed the earlier fixes against
both rounds' reproductions and found:

| Audit item | What it showed | Disposition |
| --- | --- | --- |
| R4 G3 the burner as purchaser | A payer names the burner as purchaser; if the draw selects the Ape, FWA delivers it to the burner, the game books a win and releases buyback reserve, and no route (not even the sunset) moves it again | **Fixed (D81):** the pool owner records every other system contract at wiring (`isSystem`: the burner, the hook, ProtocolLiquidity, the coin, Admin, the Sunset, the adapter, Lens, the DrawRouter, the Draw Packs renderer) and `canPurchase` refuses them; postflight checks each (`test_systemContractsCannotPurchase`). Arbitrary outside contracts stay admitted (R3-1) |
| R4 T1 owner board settings above the gas cap | `maxPerCall` 20 (D80's ceiling) or `bookPerCall` 100 on a board of four-Shape Packs made one maintenance call cost 19-25M gas, above EIP-7825's 16,777,216 cap: upkeep stalls until the owner lowers them | **Fixed (D81):** ceilings `maxPerCall` 10 and `bookPerCall` 50, measured on that board within 90% of the cap (`test_ceiling*FitsTheCap`); a pattern of heavier Packs must still be measured first |
| R4 site rounding and deployment readbacks | The site rounded a 0.014 ETH draw price to "0.01" and a 0.016 ETH minimum to "At least 0.02"; `deploy.sh` guarded mainnet by env name, not chain; postflight missed the opening board size, FWA approvals, the Packs renderer and names | **Fixed (D81):** what a user pays rounds up and a minimum received rounds down (`site/test/format.test.mjs`); `Deploy` requires `DEPLOY_ENV=mainnet` exactly on chain 1 and `deploy.sh` guards on the connected chain ID; postflight checks those fields (`test/fork/Postflight.t.sol`) |
| R3-1, R3-2 other system and dependency addresses as purchaser | Fourteen more addresses (the burner, Admin, the hook, the coin, ProtocolLiquidity, the Sunset, the Seaport adapter, the DrawRouter, the FWA factory, token and hook, the VRF service, the PoolManager, Seaport) can be named as purchaser; FWA delivers the won BAYC, Pack or Shape there and the game books an ordinary win (for a BAYC the burner releases its exit tier) | **Accepted (D68):** unlike the pool-self case (round 2), the prize really leaves the game, exactly as in any win; the payer gave it to an address that cannot use it, at the payer's own cost. Any contract a payer names can be such an address, so no list can be complete; the game's books and the release match an ordinary win. **Revised (D81):** this system's own contracts are now refused (R4 G3); dependency and outside addresses stay accepted |
| R3-11 refund credit to a named purchaser | A request naming a system purchaser that expires or is refunded leaves the refund credit with that purchaser in FWA, unusable | **Accepted:** FWA credits refunds to the purchaser the payer named; the payer's own loss, no protocol loss |
| R3-3 Shapes mint fee change | The game recorded owed rows at the fee when they were owed and subtracted today's cost at restock: after Shapes' admin changes its fee, `protectedCash` and `capitalNeed` were wrong (a payout before a costlier restock; or a phantom debt), until the owner re-set the pattern | **Fixed (D68):** a won row is owed at its current cost, and `sync` recounts every owed row at today's fee before booking or paying out when the fee differs from the one the count was made at (`test_mintFeeChangeRecountsWhatTheGameOwes`) |
| R3-12 a Seaport callback lowers the booked price | During a fill, a seller-chosen consideration recipient called `Game.sync`, whose payout to the vault was counted against the order's price (booked 0.9934 for a 1 ETH order) | **Fixed (D68):** the vault books what it sent the adapter less what the adapter returned; other ETH arriving during the fill is booked as what it is (`test_otherInflowDuringAFillDoesNotLowerThePrice`) |
| R3-10 order consideration to the pool owner | A seller-chosen consideration paid to the pool owner stayed there, with no route out | **Fixed (D68):** `flushStray()` sends any ETH the pool owner holds to the vault as a contribution, anyone may call it (`test_strayEthInThePoolOwnerGoesToTheVault`). The seller chose to give that ETH up; the vault paid the order's price for the NFT |
| Open in the report | 15 Game/PoolOwner reentrancy detector paths not yet dispositioned; dynamic FWA, Seaport and owner-nominee callback variants | Open for the independent audit (docs/AUDIT_SCOPE.md) |

Other bounded checks in the report (Sunset auction and reentrancy, Pack custody, v4 fee paths, burner buckets, FWA
pending retirement, Seaport callback rebates) found no violation within their stated models; they are not exclusions
beyond those models. A seller who rebates part of the price to the vault itself inside the Seaport order is booked at
the net price while the rebate also counts as a contribution: an accounting quirk at the seller's own expense.

## Residual vulnerabilities and limits

1. **Purchase gate is per request, not per queue.** `canPurchase` sees the current state; a purchase admitted while the
   last collection NFT is in the draw can settle after it is won (the player receives a Shape). Documented to players.
   FWA asks once per transaction without the batch size, so the gate assumes a full batch (5).
2. **Exposure between actions** is bounded without a keeper: the gate refuses a purchase unless the 50% ceiling still
   holds after every unsettled request plus a full batch has removed a listing, and listing and decay leave that
   headroom under the lower target. The gate's record of open collection listings is updated as outcomes are recorded;
   while stale it overstates exposure (refuses more, never less).
3. **Buyback price check and cadence (D64).** The deviation check (2% at launch, at most 3%) defeats same-block
   manipulation, not a manipulation held across a block; the slice and the impact cap (3% at launch, at most 5%) bound
   the loss. An ongoing slice is `0.05 ETH + 0.005 ETH × draws since the last slice + 1% of the bucket`, at most 1 ETH,
   every `60 min × 20 / (20 + draws)`, never under 10 minutes (sim/results/burner.md); a slice larger than the impact
   limit allows fills only to the limit and the rest waits. Inflating the draw count costs each draw's house edge and
   only brings a slice forward. A sandwich pays the trading fee twice (5% each way at launch), more than a slice may
   move the price; a lower fee set by the owner narrows that margin. What a sunset hands over is ongoing ETH: with no
   draws after retirement it is spent at most 1 ETH an hour (0.05 ETH plus 1% of what waits), so a large hand-over
   takes days to weeks; the released reserve goes at the milestone cadence.
3a. **Milestone releases (D64).** A release is verified from FWA alone (listing `Settled` to a purchaser other than the
   pool owner, not released before): an Ape exit releases 60% of the reserve, a second exit within 24 hours of the last
   the rest, a big prize (a Shape or Pack listed at 0.5 ETH or more) 15%. Anyone may call `release`; the game calls it
   when it books the win (in a `try`: a failure never blocks booking). Gaming it needs a real delivered win: winning
   the 0.5 ETH Shape or an Ape to bring a release forward is a prize the protocol really paid out, and inflating the
   tier only moves buyback ETH into the bucket sooner. The big-prize test reads FWA's listed price, cost × (1 +
   markup), so the owner's markup and pattern decide which prizes count (timing only). An exit that relists a returned
   Ape (sold back to the vault at the bid, won again) is a new delivered win and releases again. Released ETH is spent
   first, 1 ETH every 10 minutes; a release resets `lastRunAt`, so its first slice may run at once, in practice at the
   keeper's next tick, not inside the booking (FWA settles wins without calling the protocol, and a swap inside the
   game's booking would expose the sync to MEV). The release is public, so searchers know a slice is coming: the
   deviation and impact limits bound what they can take, keepers should send buybacks privately, and a 9 ETH release
   takes nine slices over 80 minutes (sim/results/burner.md). The reset applies even when the reserve is empty, so one
   ongoing slice per qualifying win may run early (timing only).
4. **Owner proceeds.** FWA fixes each request's base price at request time and does not expose it afterwards. Revenue is
   booked at `bookingEdgeBps` (the highest `maxEdgeBps` ever set; the gate refuses requests above the current one), a
   lower bound, and trued up to the ETH FWA paid once every issued request is booked. A request stuck in FWA's 7-day
   delivery quarantine delays the true-up, never overstates revenue.
4a. **Keeper allowance and the refill loop (D63).** The allowance starts at `openingAllowance` (0.2 ETH at launch, D82, a limit rather than a deposit, for
   listing the opening board) and grows by each capture's `opsBps` (1% at launch, D82, frozen at listing) of its replacement
   cost (a collection capture: the last listed `opsBps` of its base price). Keeper pay is an expense in `profit`.
   It is paid from the game's cash outside what replacements are owed, so it draws the operating reserve down and the
   next `sync` refills it from the vault. That refill counts as work only when it covers the whole need **and** the
   need was at least one row's cost (`rowCost`): otherwise two calls could each be paid for refilling what the other's
   pay took. `activate()` draws the refill of the opening reserve itself, and `ready()` requires
   `capitalNeed() <= vault.generalBalance()`.
4b. **The live bid** has no immutable ceiling (D59). It is ETH actually metered in: fast up to the activation threshold
   (75% of the funding reference; before the first acquisition 100% of the deploy-time reference,
   `firstThresholdBps`, so the opening fees can buy the first Ape at once), then the metered step per cooldown
   (`maxSweepWei`; D65 removed D64's play meter); nothing rises with time alone. Without sweeps it
   stays where it is. Two exposures no oracle-free bid avoids: a floor that falls far overnight is hit at the old bid
   (then the funding reference, and with it the threshold, descends at most `maxDropBps` (25%) per purchase toward the
   real price, never below the Ape floor, D83), and if nobody sells for a long time the bid keeps growing at the
   metered rate while funded and the first seller takes all of it (docs/ECONOMICS.md section 2a). D60/D61 slow the
   second: above 120% of the funding reference only `slowSweepWei` enters (0.01 ETH per cooldown at launch, D82; `ceilingBps`),
   so the windfall grows with time (+48% after 30 days without sellers, +198% after six months in the D60/D61 model at its 0.0025 slow rate) instead of
   at the full rate (+576%, +3,576%), without ever stopping the bid (a hard ceiling would stop acquisitions for good
   after a floor jump; the cost is a slow catch-up, ≈ 80 days after an overnight doubling). `maxPrice` remains the
   absolute brake. A wrong deploy-time reference (`REF_PRICE_WEI`) sets a wrong first threshold until the first
   purchase (`setActivationThreshold` corrects it). The seller names its price; a marketplace fill pays the listing's price.
4c. **The fee overflow (D64; trigger D65).** Trading fees are counted as they arrive (`unsplitFees`) and split at the
   next `sweep`: while the live bid is at its fill target (the activation threshold, or the ceiling or `maxPrice` when
   lower), `overflowBps` (0 at launch, D72; owner-adjustable) of them go to the CollectionBurner's ongoing bucket, capped at what the
   acquisition budget holds beyond the bid and one more Ape at the funding reference (`referencePrice`), so never the game's
   capital need, the board growth its Apes wait for, the bid's ETH or the next Ape (`pendingOverflow`); otherwise they
   stay as capital. The bid is rate-limited, so fees that outrun Ape purchases would otherwise sit idle; the next Ape is
   always funded first, so acquisitions are not slowed. Custody and listing counts play no part (the vault no longer
   reads the pool owner for it). The burner is immutable in the vault, so this outflow has one destination. The
   accounting is lazy: the condition at the sweep decides for every fee since the last one, and every sweep clears the
   count. Whoever times the sweeps moves fees between the two uses and nowhere else: a sweep run while the bid is below
   its fill target (just after an acquisition, while the bid refills) keeps those fees as capital; a holder who sells
   an Ape far below the bid lowers the funding reference by at most `maxDropBps` (25%, D83), and with it the Ape the
   overflow keeps back, at the cost of that Ape.
   Nothing overflows before the game is active (`pendingOverflow` checks `game.activated()`; before activation the
   acquisition budget is the whole balance, which belongs to the first Ape and the game's capital) or while it retires
   (the budget is 0). A sweep that only overflows still succeeds but earns no reward (the
   reward is paid on ETH forwarded into the bid). The burner's 1% backlog term works an overflow backlog down: with
   5 ETH a day of overflow, 91-98% of the inflow is spent at 50-500 draws a day (sim/results/burner.md).
4d. **No play meter (D65).** D64's play meter (a metered step that grew with FWA draws) is gone: above the activation
   threshold a sweep forwards at most `maxSweepWei` per `minBlocksBetweenSweeps`, `slowSweepWei` above the ceiling, so
   the D61 drought bound holds as before.
5. **Zero trading volume** after the first win leaves no collection NFT in the draw until fees or contributions fund a
   new one; draws continue for Shapes and Packs only (D53; economics, not safety).
6. **Contract sizes** (D68 build; CollectionGame since D77): CollectionGame 24,182 B (394 B under EIP-170; D63 unfroze it, and
   `test_gameLedgerSizePinned` pins its size so any growth is deliberate), CollectionPoolOwner 21,151 B, ShapePacks
   17,715 B, FundingVault 11,572 B, CollectionBurner 11,758 B, CollectionHook 7,396 B
   (`test_everyContractWithinEip170`).
7. **Keeper economics.** Each useful `sync` or `retireStep` pays its caller
   `(gasUsed + gasOverhead) × min(tx.gasprice, maxGasPrice) + flatFee`: launch 70,000 gas, 3 gwei, 0.0002 ETH
   (the flat fee gives a third-party keeper a reason to run; D79). Above 3 gwei keepers are reimbursed at 3 gwei; once the
   allowance is spent, calls are paid nothing more until captures earn more. Whether each capture's `opsBps` (1% since D82; the break-even figures here were measured at the former 5%) of its cost
   covers upkeep depends on gas: on the 50-row board the allowance breaks even at about 0.58 gwei average basefee when
   every draw runs its own upkeep and about 0.9-1.1 gwei in batches of three to ten (sim/results/keepers.md, re-run for
   D64; current gas receipts in docs/receipts/gas.json). When keepers are not paid, rational keepers stop and players running upkeep through the
   DrawRouter carry it; if nobody does it, won prizes are not replaced and the purchase gate closes the game when about
   half the board is missing (its Shape floor). Settlement, refunds and custody are unaffected (no keeper is needed for
   safety); the game reopens when someone runs the upkeep. The owner can raise `opsBps` (future listings) or the keeper
   parameters.
7a. **A failing step** stops only itself (`StepFailed`): if prize minting or FWA listing fails, the maintenance step
   fails as a whole (restocking, and with it that window's collection listing, decay and board growth), the board runs
   down and the gate and admission close the game; booking, distributions and admission continue. Assets are never
   trapped: retirement mints nothing (`test_brokenMintingBlocksNothingEssential`).
7b. **Liquidity launch and the opening fee curve (D64).** All supply is single-sided below the start price; the price
   can never return above it, so the launch accepts no ETH (it could never be reached nor removed). From the pool's
   single initialisation (`launch` initialises and adds the liquidity in one call), buys and sells pay
   `max(ordinary fee, 69% − 1 point a minute)`, linear per second, back to the 5% fee at minute 64. The curve is a set
   of constants, starts from `launchedAt` (set once; a second initialisation reverts) and can never return; 69% is
   also the hook's absolute clamp. Exact-output buys pay `net × f / (1 − f)`, the same share of the gross ETH as an
   exact-input buy, so exact output cannot pay less during the curve; exact-output sells revert. A minute-0 buyer of
   1 ETH needs about 28 ETH of later buying to break even at the 30.7 ETH opening valuation (89 ETH at 100 ETH;
   sim/launch.py), so sniping
   moves late into the curve. **Accepted by the owner:** a 69% sell fee for the first ~20 minutes will likely get the
   coin labelled a honeypot by wallet and token scanners, and cached labels can outlive the curve
   (docs/review/FLYWHEEL_REVIEW.md section 4). Early-buyer concentration also depends on the opening valuation
   (ECONOMICS §8).
7c. **Keeper pay reads `tx.gasprice`.** A keeper that also builds blocks can pay itself priority up to `maxGasPrice`
   (3 gwei) plus the flat fee, at the game's cost within the allowance; the cap bounds it. A call without work reverts
   (`NoWork`) and is paid nothing; funding the game counts only as stated in 4a, so dust cannot earn a fee. The payment
   is made at the end of the call (no `try`): a call sent with too little gas reverts as a whole. Each isolated step
   (`try`) that fails with less than 1/8 of the gas it started with left reverts the whole call (`OutOfGas`), so a
   low gas limit cannot make steps fail quietly and still be paid, and a gas estimate covers every step; a step that
   fails on its own still fails alone given enough gas (`test_tooLittleGasNeverSkipsWork`).
7d. **DrawRouter (D53, D59, D60)** holds nothing between calls and has no privileges. After the purchase it runs
   `game.sync` with at most the caller's `upkeepGas`, then `sweep` on the vault that `game` reports (250,000 gas since D64; a metered sweep and one that splits the fee
   overflow both stay well inside it: 126,362 and 211,044 gas on the fork, D65 code), for
   whatever `game` the caller passes (each in a `try`; a hostile one affects only the caller's own `nonReentrant`
   call; `TAIL_GAS` is kept back so an upkeep that runs out of gas cannot make the draw revert; a gas limit below the
   budget reverts up front, `UpkeepGas`), then sends its whole balance (FWA's change, the game's keeper pay, the sweep
   reward, anything sent by mistake) to the caller. A player who draws through it may pay gas to settle other players'
   waiting draws (not reimbursed; the site shows it).
7e. **The sunset auction** prices each Ape from its recorded cost (`refCost`), not from the market: if the floor has
   fallen far below it, Apes sell only near the 25% end; if it has risen far above it, the first buyer gets a bargain.
   The clock starts once (the first `start`, `buy` or `flush` after retirement): an Ape that reaches the Sunset contract later
   (for example one recovered from FWA's delivery quarantine) is priced on the same clock.
8. **Gas test coverage** is on a fork, not mainnet; the hook address must be mined again for the final constructor
   arguments (the deploy script does it).
9. **Reentrancy**: every state-changing holder function that makes external value transfers is `nonReentrant`
   (Solady); FWA and Uniswap callbacks are checked by sender. Not formally verified.
10. **Seaport adapter**: validated against a real on-chain-validated order. It accepts signed (not CONTRACT) orders
    selling one collection ERC-721 for native ETH, with exactly the seller's signed consideration and none of it
    paying the vault or custody (D70); not tested against every zone or conduit configuration.
11. **Fee-free side pools and the transfer restriction (D71).** While the coin is restricted it settles only through
    the canonical pool, so a v2/v3 pair or a v4 pool without the hook cannot take or deliver it, and trading cannot
    move off the 5% fee. The cost: no wallet-to-wallet transfers, no aggregators that route through their own
    contracts, no exchange deposits, and wallet scanners may flag the coin. After the owner's one-way `unrestrict()`,
    side pools become possible again: the hook pool's 10% round trip leaves room for trading to move there, and that
    volume funds neither the vault nor buybacks. Two limits, both shared with the artcoins model the restriction follows: the gate is on
    ERC-20 transfers, so coin already credited inside the PoolManager by a fee-paid canonical swap can circulate there
    (a hookless v4 pool, ERC-6909 claims) without another transfer, though turning it back into a wallet balance needs
    a canonical swap's allowance again. The owner may renounce while the coin is restricted (D82): renouncing before
    `unrestrict()` leaves the restriction in place forever, so the coin then moves only through swaps in its canonical pool
    and to or from the allowlist as it stands then. The allowlist (D84) is an owner power: an allowed contract may take
    and pass on the coin while holders cannot, so an allowed exchange or pool contract could host trading off the fee
    (the PoolManager itself is excluded, and every transfer through it keeps the swap rule).
12. **The DrawRouter's NFT approval (D75).** Paying with winnings needs the player's `setApprovalForAll` on Shapes and
    Packs for the router. The router takes tokens only from `msg.sender`, only on the contracts `game.poolOwner()`
    names, and redeems them in the same call; a caller-supplied fake game can only point the caller's own call at fake
    contracts. A mistake in that code would expose every approving player's Shapes and Packs, so it is kept small and
    fork-tested, and players can revoke the approval at any time.

## Before material funds

Independent audit of `src/` and Draw Packs (first-party); review of the FWA relay against the then-current FWA token;
the owner key's security (one address administers everything; it may be a multisig); a second look at the decisions
marked "Needs owner review" in docs/IMPLEMENTOR_DECISIONS.md (D57 among them) and at the two limits of the sunset
guarantee stated at the top (player claims; keeper pay while unwinding, within the allowance left).
