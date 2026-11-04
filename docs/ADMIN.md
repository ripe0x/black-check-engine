# Administration: who can do what (D012)

Two authorities, recorded in `Admin`. Every governed contract reads them from there.

- **Owner** (the operator): routine settings within hard bounds, pause, the instant sunset, opening the market. Two-step
  transfer; renounceable. A renounce freezes the owner's settings and ends the sunset power; it does not touch the
  council.
- **Council**: an OpenZeppelin `TimelockController`. The council Safe is its only proposer, every action waits 7
  days, the guardian (and the Safe) can cancel, anyone executes, and it administers only itself. It holds every power
  that changes where value goes or what custody is worth. Only the council replaces the council.

No function of either authority withdraws Checks, Shapes, Packs, game cash, vault ETH or committed buyback ETH to an
address. Assets leave only by the game's rules: a player's win, a buyout someone paid for, canonical composition, the
Sunset's auction (proceeds to buy-and-burn), or a migration to a successor whose code was pinned at proposal.

## Council powers (7 days, cancellable)

| Power | Function | Worst case |
| --- | --- | --- |
| Migration | `MigrationAuthority.propose` (then 72 hours, code pinned, anyone executes) | After 7 + 3 days in public, V1 stops and its Checks and the vault's ETH move to the proposed contract. The disclosed residual trust: a council majority, unchecked by the guardian, can choose that code |
| Trading-fee recipient | `MigrationAuthority.proposeFeeRecipient` (then 72 hours) | Future trading fees go to a contract the council chose; fees already in the vault stay |
| Price schedule | `CollectionPoolOwner.setSchedule` (per tier 0.001-100,000 ETH, or 0: not listed) | Odds and the vault's 120% purchase cap move with it; a low schedule makes Checks easier to win and cheaper to buy out |
| Listing rule | `CollectionPoolOwner.setListingParams` (decay, floor 1-100%, step, target at most 50%, daily decay) | Faster decay or a lower floor raises the odds of winning Checks |
| Buyout prices | `ChecksDesk.setBuyoutParams` (ETH markup at least 10%; coin price per tier, 0 disables) | Checks leave for schedule + 10% in ETH, or for the coin price set |
| Coin venue | `CollectionToken.setAllowed` (at most 50), `unrestrict` (once, for good) | An allowed address could host fee-free trading; unrestriction lets the coin trade anywhere |
| $LAYER share | `CollectionHook.setLayer` (0-5% of each fee after the curve; off at launch, D016) | Up to 5% of later fees to a contract the council chose |
| Council | `Admin.setCouncil` | Replaces the timelock (only through the current one) |
| Market opening | `ProtocolLiquidity.launch` (also the owner's; once, at the fixed tick) | Opens the market at the fixed price |

## Owner powers (immediate, bounded)

| Power | Function (bounds) | Worst case |
| --- | --- | --- |
| Pause | `CollectionGame.setPaused` | New draws stop; settlement and refunds continue |
| Sunset | `MigrationAuthority.sunset` (instant, final) | The game ends early; every Check is auctioned 150% → 25% over 30 days and every wei goes to buy-and-burn. No value can reach the owner |
| Board and pricing | `setPattern`, `setBoardSize` (grow only), `setPricing` (markup 5-100%, constant floor), `setBoardParams`, `setSettings` | A different board, higher prices; never a prize below cost + 5% |
| Keeper pay | `setKeeperParams` (gas price at most 30 gwei, overhead at most 200,000, flat fee at most 0.001 ETH a call, delay at most 1 hour) | Whoever calls first takes the keeper allowance faster, still only the allowance captures earned |
| Composition pace | `ChecksDesk.setComposeParams` (draws per tier 1-1,000,000, grace, coin burned for a choice) | Composition sooner or later, cheaper or dearer choices; never which Check is worth what |
| The live bid | `FundingVault.setBidParams`, `setActivationThreshold`, `setOverflowBps`, `setExcluded` | A seller is paid up to the bid, never above 120% of the council's 80-Check price (constant) |
| Buyback cadence | `CollectionBurner.setCadence`, `setTiers`, `setMilestoneBps` (hard bounds) | Timing of buybacks only; every release still ends in buybacks |
| Purchase gate | `CollectionPoolOwner.setMaxInFlight` (1-50) | Fewer or more draws in flight |
| Hook fees | `CollectionHook.setFees` (each at most 10%; the opening curve is constant) | Higher or lower trading fees |
| Coin metadata | `CollectionToken.updateImage`, `updateMetadata`, `setMetadataRenderer` | Wrong presentation |
| Stray NFTs | `sweepNFT` (never Checks, Shapes or Packs) | An unrelated NFT sent by mistake |

Tests: `test/fork/Council.t.sol` (the real timelock path and every refusal), `test/fork/Governance.t.sol`,
`test/fork/Migration.t.sol`, `test/fork/Sunset.t.sol`.
