# Administrative powers

**One owner** administers every contract (D57). The `Admin` contract records it; every governed contract reads
`admin.owner()` for its `onlyOwner` functions. They take effect at once, except the MigrationAuthority's two proposals
(a migration, a new trading-fee recipient), which anyone can execute only after a public 72-hour notice, with the
proposed contract's code pinned (D63).

- `Admin.transferOwnership(next)` names the next owner (step one; `address(0)` cancels a pending transfer);
  `Admin.acceptOwnership()` by `next` completes it (step two). One transfer moves administration of every contract.
- `Admin.renounceOwnership()` ends administration for good: every owner-only function of every contract becomes
  uncallable (including migration, the fee-recipient proposal and the sunset), and the game keeps running on its last
  settings. A proposal already pending stays executable by anyone: cancel it first if it should not run.
- The deployer's one-shot `wire` rights are gone after deployment (postflight checks `deployer() == 0` everywhere).

How to act: a transaction from the owner to the target contract. Every change emits an event; the site's Governance page
lists them as they happen.

| Contract | Function | Limits | Consequence |
| --- | --- | --- | --- |
| Admin | `transferOwnership`, `acceptOwnership`, `renounceOwnership` | two steps | who administers everything |
| CollectionHook | `setFees(buy, sell)` | each ≤ 10% | the ordinary trading fees (5% / 5% at launch): trading cost; vault income. The opening curve (69%, one point less a minute, from the pool's initialisation) is fixed code: no call changes it, and it applies only while above the ordinary fee |
| CollectionToken | `updateImage(url)`, `updateMetadata(description)`, `setMetadataRenderer(renderer)` | a renderer must have code; zero returns to the built-in default | the coin's ERC-7572 metadata (image, description, or the whole JSON from a renderer); each change emits `ContractURIUpdated`; frozen after a renounce (D86) |
| CollectionToken | `setAllowed(account, allowed)` | at most 50 addresses; never the zero address or the PoolManager; empty at launch | while restricted, the allowed address may send and receive the coin (a Safe, a bridge, a staking contract); through the PoolManager it still needs a canonical swap. Published under URC-5 (`externalVenues`). Frozen as it is after a renounce (D84) |
| CollectionToken | `unrestrict()` (once, one way) | none | the coin becomes freely transferable: wallet transfers, aggregators and exchanges work, and fee-free side pools become possible (SECURITY.md item 11); its URC-5 policy turns `Preferred` (D71) |
| ProtocolLiquidity | `launch()` (once) | no ETH; the price is fixed at deployment (D70) | opens the market at tick 173,000 (≈ 32.6M coins per ETH, ≈ 30.7 ETH FDV, about $69k at $2,242 ETH; D70) |
| FundingVault | `setBidParams((thresholdBps, maxSweepWei, minBlocksBetweenSweeps, maxPrice, ceilingBps, slowSweepWei, maxDropBps))` | threshold ≤ 100%; sweep > 0, ≤ 100 ETH; 1-7,200 blocks; maxPrice 0 = no cap; ceiling 0 (none) or 100-1,000% of the funding reference; slow sweep ≤ sweep (0 = hard ceiling); maxDropBps 100-10,000 (D83; 2,500 = 25% at launch, 10,000 = floor-only) | the live bid (docs/SPEC.md "The bid"): how fast ETH is metered in above the threshold, and above the relative ceiling (D60); `maxDropBps` bounds how far one acquisition may lower the funding reference (D83); the ETH already in the bid stays |
| CollectionHook | `setLayer(tap, bps)` | share 0-5% of each trading fee after the launch curve (1% at launch); `bps` 0 with tap 0 turns it off; a tap must be a contract | the share that buys and burns $LAYER through a LayerTap and artcoins' router (D90) |
| FundingVault | `setOverflowBps(bps)` | 0-100% | the fee overflow (D65): the share of trading fees a sweep sends to the burner's ongoing buybacks while the live bid is at its fill target, capped at what the acquisition budget holds beyond the bid and one more Ape at the funding reference (0% at launch, D72: every fee stays as capital until the owner turns it on). At 100% every trading fee beyond the game's capital, the board growth, the bid and one more Ape at the funding reference goes to buybacks; it never takes the game's capital or the next Ape |
| FundingVault | `setActivationThreshold(wei)` | ≤ 1,000 ETH | corrects the threshold until the next acquisition re-syncs it (75% of the funding reference; the deploy-time first threshold is 100% of the reference price) |
| FundingVault | `setExcluded(id, bool)` | — | refuses specific token IDs (e.g. stolen) |
| CollectionPoolOwner | `setListingParams((start, minNotional, decay, step, target, dailyDecay))` | minNotional 0.01-100 ETH (`MIN_FLOOR`/`MAX_FLOOR`), start ≤ 1,000%, step ≤ 100%, target 1 bp-50%, daily decay ≤ 100% | how every Ape opens and decays (`minNotional`: the absolute ETH floor any Ape opens at and decays down to, 1 ETH at launch, D82, so a cheaper Ape still opens at 1 ETH; `dailyDecay`: share of its price lost per day in the draw, 0 at launch; D78: switched on, it counts from then) and the exposure target the board grows to keep (20% at launch); applies to every Ape from its next update; never raises a notional (a floor raised above a published notional leaves it there); a lower target defers listing and decay (it never closes the purchase gate, whose ceiling is 50%) |
| CollectionPoolOwner | `setMaxInFlight(n)` | 1-50 | throughput vs headroom (10 at launch, FWA's own per-pool limit: the gate and the target keep `n − 1 + 5` listings of headroom, 14; lower it if refunds matter more than throughput, D82) |
| CollectionGame | `setPattern(backings[])` | 1-1,000 backings, each a prize the pool owner can mint (a Shape or a Draw Pack); reserve ≥ the largest backing | the board's prizes: each row takes its new backing the next time it is listed (after its prize is won, or when the row is new); prizes already listed stay; rows already owed are recosted |
| CollectionGame | `setBoardSize(to)` | grow only, ≤ 50 rows per call; the vault must hold the new rows' cost on top of the game's capital need; not once retiring | more rows now (the board also grows on its own as the Apes need rows, `rowsShort`) |
| CollectionGame | `setPricing(markup, ops)` | each 0-100% | ticket price, and the keeper allowance each capture earns (10% and 1% at launch, D82); frozen into each prize when it is listed |
| CollectionGame | `setBoardParams(listBatch, maxPerCall, bookPerCall)` | listBatch 1-20; maxPerCall 1-10; bookPerCall 1-20 | replacement trigger, prizes one maintenance call lists, and requests one `sync` or `retireStep` books (8 and 20 at launch). Every call at the ceilings stays within 90% of EIP-7825's 16,777,216-gas cap on a board of four-Shape Packs (test/fork/TxCap.t.sol); a pattern with a Pack of more than four Shapes is refused (D61, D80, D81, D85) |
| CollectionGame | `setKeeperParams((maxGasPrice, gasOverhead, flatFee, payDelay))` | flat fee ≤ 0.1 ETH, delay ≤ 1 hour; gas cap and overhead unbounded | keeper pay: `(gasUsed + gasOverhead) × min(tx gas price, maxGasPrice) + flatFee`, always within the allowance captures earn (3 gwei, 70,000, 0.0002 ETH at launch; docs/ECONOMICS.md section 8); `payDelay` (5 minutes at launch, 0 turns it off): within it of an upkeep that did work, a paid `sync` of light work (under 2.5M gas) does the work and is paid nothing (D82; a no-work call still reverts `NoWork`) |
| CollectionGame | `setSettings(...)` | reserve ≥ the largest backing, ≤ 1,000 ETH; interval and cooldown ≤ 30 d; fill 0-100%; outstanding 1-10,000; edge ≤ 100%; minDistribution ≤ 100 ETH; continuity share ≤ 100% | operating buffer (0.5 ETH at launch, D79), admission (fill 70%, outstanding 10, edge 5%, cooldown 30 days, D82: an FWA cooldown alone never closes purchases), and the share of each distribution sent to the vault while it is short of one Ape (35% at launch; the rest goes to the burner) |
| CollectionGame | `setPaused(bool)` | not once retiring | new draws stop/resume; settlement continues |
| CollectionBurner | `setCadence((baseSliceWei, perDrawWei, backlogBps, maxSliceWei, idleSpacing, minSpacing, drawsToHalve, maxImpactBps, maxDeviationBps))` | hard bounds (constants no owner can pass): `maxSliceWei` 1 wei-1 ETH; `minSpacing` ≥ 10 minutes; `idleSpacing` ≥ `minSpacing`, ≤ 30 days; impact 0.01-5%; deviation 0.01-3%; `backlogBps` ≤ 10%; also `baseSliceWei` > 0 and ≤ `maxSliceWei`, `perDrawWei` ≤ `maxSliceWei`, `drawsToHalve` 1-1,000,000 | buyback pace and protection: an ongoing slice of `min(maxSlice, bucket, base + perDraw × n + backlog × bucket)` every `max(minSpacing, idleSpacing × drawsToHalve / (drawsToHalve + n))` for the `n` FWA draws since the last slice; released milestone ETH at `maxSliceWei` every `minSpacing` (launch: 0.05 ETH, 0.005 ETH, 1%, 1 ETH, 60 minutes, 10 minutes, 20, 3%, 2%) |
| CollectionBurner | `setTiers((bigPrizeWei, bigPrizeBps, firstExitBps, exitWindow))` | `bigPrizeWei` > 0; each share 0-100%; window ≤ 7 days | how much of the milestone reserve each delivered win releases: a Shape or Pack listed at `bigPrizeWei` or more, an Ape exit, and a second Ape exit within the window (the rest) (0.5 ETH, 0%, 100%, 24 hours at launch: only an Ape exit releases, and all of it, D74). The release itself stays burner code verified from FWA; every release ends in buybacks, so the tiers change only the timing |
| CollectionBurner | `setMilestoneBps(bps)` | 0-100% | share of each future game surplus reaching the burner that is locked in the milestone reserve until wins release it (100% at launch, D74) |
| Every governed contract | `sweepNFT(token, id, to)` | never the collection, Shapes or Draw Packs (`Admin.isProtected`, fixed at deployment) | sends out an unrelated ERC-721 a contract holds by mistake (D62) |
| Draw Packs (ShapePacks) | `setRenderer(r)`, `setPreviewCardLimit(n)`, `setMetadataCopy(prefix, description)`, `lockPresentation()` | admin only, until the one-way lock; a renderer must answer ERC-165 for `IShapePackRenderer` | presentation only: metadata and images, never custody of Shapes, ETH or anyone's Pack. The admin is the owner's address itself, set at deployment, not `Admin`: moving `Admin` ownership does not move it; use `transferAdmin(next)` (one step, at once) or `renounceAdmin()` |
| MigrationAuthority | `propose(successor)` | a contract; its code hash is pinned; executable by anyone (`execute`) 72 hours later, only if the code is unchanged; `propose(0)` cancels; refused after the sunset (`SunsetFinal`) | the game retires for good, trading fees (less the $LAYER share, D90) go to the successor, then its Apes and the vault's ETH (docs/MIGRATION.md) |
| MigrationAuthority | `proposeFeeRecipient(recipient)` | a contract; its code hash is pinned; executable by anyone (`executeFeeRecipient`) 72 hours later, only if the code is unchanged; `proposeFeeRecipient(0)` cancels; refused once a migration or the sunset has started (`Started`: fees then follow the successor); it must accept ETH from the PoolManager mid-swap, cheaply, or swaps revert | where every future trading fee, less the $LAYER share (D90), goes (the vault at launch); the game keeps running |
| MigrationAuthority | `sunset()` | at once; cancels pending proposals; final (no proposal of either kind afterwards) | the game retires for good into the built-in Sunset: its Apes are auctioned, and the auction proceeds, the vault's capital and the trading fees that reach the Sunset (all but the $LAYER share, D90) all buy and burn the coin (docs/MIGRATION.md "Sunset") |

The owner cannot set the fee recipient directly: `CollectionHook.setFeeRecipient` answers only to the MigrationAuthority
(`NotMigrator`). Nor can the owner retire the game except through a migration's execution or the sunset.

**What no administrative call does**: mint coins; remove liquidity; withdraw prizes, game cash or the vault's funds to
an address; transfer the collection's NFTs, Shapes or Packs out of the protocol (they leave only to FWA, winners, a
migration's successor after its 72-hour notice, or the Sunset, which sells Apes only for ETH that goes to the burner);
change the FWA pool owner or the game; raise a listed notional; take bought coins; move the burner's committed buyback
ETH (not even in a migration); release milestone ETH except on a delivered win FWA shows (a big prize or a collection
win, by the tiers) or after the game retired (both into the burner's own milestone bucket); redirect trading fees
without the 72-hour notice (the sunset and the $LAYER share excepted: `setLayer` moves up to 5% of each later fee
at once, D90); change the opening fee curve; set a buyback slice, spacing, impact or
deviation past the burner's hard bounds; limit the number of Apes held or listed (there is no such limit).

**What the owner can steer** (stated plainly, D57, D63): after a public 72-hour notice with the code pinned, where
future trading fees go (until a migration or the sunset starts) and the destination of a migration; at once and for
good, the end of the game into the sunset (buy-and-burn only); at once, the $LAYER share (0-5% of each fee after the opening curve) and its tap, also after a migration or the
sunset (D90); the bid and how much of the trading fees overflows to the
burner; the ordinary trading fees (up to 10%; not the opening curve); the board's pattern and size; markup, keeper
allowance rate and keeper pay; how much of each distribution goes to the vault rather than the burner, how much of the
burner's share waits for a milestone and how much each win releases; and the buyback pace, within hard bounds. Announce
material changes before making them; the ones without a notice take effect at once.
