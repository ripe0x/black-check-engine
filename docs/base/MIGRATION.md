# Migration and sunset: moving Ape Draw off FWA V2, or ending it, without changing the coin

Status: implemented (D55, simplified by D57, revised by D63), tested on a mainnet fork (`test/fork/Migration.t.sol`,
`test/fork/Sunset.t.sol`) and rehearsed end to end on a local anvil fork (`script/rehearse-anvil.sh`: step 11 changes
the fee recipient alone, step 12 migrates). Nothing deployed.

## What it is for

Ape Draw's V1 game runs on an FWA V2 pool. A future FWA version, or an independently built pool system, may be better or
necessary. Migration moves the game's Apes and treasury to such a **successor** while keeping the Ape Draw coin, its
Uniswap v4 market, its liquidity, its hook and its burner exactly as they are. It is one-way: V1 stops for good.

The `MigrationAuthority` is the only way the game ends or moves, and the only way trading fees change destination:

- **Migration** (`propose`, then `execute` by anyone): to a successor the owner proposed, after a public 72-hour notice,
  running only the code that was proposed (its code hash is pinned at proposal).
- **Sunset** (`sunset`, the owner, at once): the end of the game into the built-in `Sunset` contract, which turns
  everything into buy-and-burn of the coin.
- **Fee recipient** (`proposeFeeRecipient`, then `executeFeeRecipient` by anyone): trading fees alone go somewhere
  else after a public 72-hour notice, code pinned; the game keeps running. Only before a migration or the sunset has
  started: from then on fees follow the successor.

## Sunset

**In a sunset, everything goes to buying and burning the coin: the Apes' auction proceeds, the vault's capital and the
trading fees. None of it can go to the owner or to anyone else.** The `Sunset` contract (`src/migration/Sunset.sol`)
has no owner, no administrator and one destination for ETH: the CollectionBurner, which only buys the coin on its own
market and burns every token it buys. The burner's committed buyback ETH stays where it is and is spent the same way.

That is why the sunset is instant: it can only send value to buybacks. It is also final: once the successor is the
Sunset, no migration (`SunsetFinal`) and no fee-recipient change (`Started`) can be proposed again.

1. `sunset()` (owner). At once: pending migration and fee-recipient proposals are cancelled; the successor becomes the
   Sunset; the game retires (its FWA pool is retired, so **no new draws**, direct FWA purchases included; settlement,
   delivery and refunds continue); every later trading fee goes to the Sunset, less the $LAYER share, which keeps going
   to the owner's tap (D90).
2. `CollectionGame.retireStep` (anyone, batched) until `retired()`: every request in flight settles, every Shape and
   Pack is redeemed, every listed Ape returns to custody and all game ETH goes to the vault.
3. `migrateApes(max)` and `migrateCapital()` (anyone): the Apes and the vault's whole balance go to the Sunset.
4. `Sunset.flush()` (anyone, repeatable): everything the Sunset holds (the vault's capital, trading fees) goes to the
   burner. The first flush after retirement also starts the auction clock if nobody has, so it cannot stall.
5. The auction: every Ape is for sale through `Sunset.buy(tokenId)` at `auctionPrice(tokenId)`, a public Dutch auction
   from 150% of its recorded cost (`refCost`: the price the vault paid, or for a donated Ape the bid's reference price
   when it arrived) falling linearly to 25% over 30 days, then 25%. The clock starts with `start()` (anyone, once the
   game has retired), the first `buy` or the first `flush`. **The auction price goes to the burner in the same call**;
   anything paid above it is refunded to the buyer.
6. `CollectionBurner.releaseRetired()` (anyone): all of the milestone reserve that V1's wins had not released (each
   big prize and Ape exit released only its tier of it) joins the milestone bucket. `process` keeps buying and burning,
   milestone bucket first.

The keeper bot runs steps 2-4 and 6 on its own once the game has retired. Players keep every refund and pending
delivery right. Irreversible. The sunset can also follow a migration that has started: it takes whatever has not moved
yet (`test_sunsetTakesWhatAMigrationHasNotMoved`).

The guarantee covers everything that reaches the Sunset, and getting it there needs nobody's permission once the game
has retired; because the sunset is final, nothing on its way there (later trading fees, an Ape recovered later) can be
pointed elsewhere either (`test_sunsetIsFinal`). Outside it: player claims, which stay in FWA, and keeper pay while the
game unwinds, which never exceeds the game's remaining keeper allowance, whatever the keeper parameters
(`test_retirementPayWithinTheAllowance`).

## Migration

1. `propose(successor)` (owner). The successor must be a contract; its code hash is pinned. Executable 72 hours later
   (`executableAt()`); the site shows it at once. `propose(address(0))` cancels; a new proposal replaces the pending one
   and restarts the 72 hours.
2. `execute()` (anyone, after the 72 hours; refused with `CodeChanged` if the successor's code changed). It:
   - the first time, calls `CollectionGame.retire` (only the MigrationAuthority can): the FWA pool is retired, so **no
     new draws**, direct FWA purchases included. Settlement, delivery and refunds continue;
   - points the hook's trading-fee recipient at the successor, at once, and cancels a pending fee-recipient proposal. No
     owner step follows. The hook keeps its
     address (part of the pool's identity), so the market does not change.
3. `CollectionGame.retireStep` (anyone, paid its gas plus the flat fee from the game's cash, within the keeper allowance,
   batched): settles and books
   every request in flight, withdraws and redeems every Shape and Pack, withdraws every listed Ape into custody, then
   returns all game ETH to the vault. The game is then `retired`.
4. `migrateApes(max)` (anyone, batched, repeatable): each custody Ape goes **directly** from the V1 pool owner to the
   successor. Its V1 record (reference cost, cash cost, source) stays readable in the pool owner (`nfts(tokenId)`).
5. `migrateCapital()` (anyone, repeatable): the vault's whole balance goes **directly** to the successor (a forced ETH
   transfer: it cannot be refused).

`migrateApes` and `migrateCapital` revert until V1 has retired (`NotSettled`). Anything that reaches V1 later still
follows: an Ape a winner refunds after a failed delivery (`migrateApes`), late game returns (`retireStep`, then
`migrateCapital`), and late contributions. A later proposal (again 72 hours) replaces the successor for whatever has not
moved yet; the sunset can take it over at any time (and then nothing can be proposed again). Once a migration has
started, fees follow the successor: a pending fee-recipient proposal is cancelled at execution, no new one can be made
(`Started`), and only a later successor proposal moves them.

## Changing only the fee recipient

`proposeFeeRecipient(recipient)` (owner): a contract, code hash pinned; `executeFeeRecipient()` (anyone) after 72 hours
(`feeExecutableAt()`), refused with `CodeChanged` if its code changed. Only while no migration or sunset has started
(`Started`); a migration's execution or the sunset cancels a pending one. Every later trading fee, less the $LAYER share (D90), goes to the recipient
(for example a splitter that also funds another buy-and-burn) while the game keeps running; the vault then lives on its
share of the game's surplus and on contributions. `proposeFeeRecipient(address(0))` cancels. The recipient must accept
ETH from the PoolManager in the middle of a swap, cheaply, or every swap reverts until it is changed again (another
72-hour proposal, a migration, or the sunset). The owner cannot set the fee recipient directly: `CollectionHook.setFeeRecipient`
answers only to the MigrationAuthority.

## What never moves

- **Committed buyback ETH.** The burner, with its milestone reserve, is not touched by a migration or a sunset. What
  is left of the reserve (V1's big prizes and Ape exits release it in tiers) is released, all of it, into the milestone
  bucket once V1 is retired (`CollectionBurner.releaseRetired`, anyone). The burner keeps buying and burning the same
  coin. The vault's fee overflow stops with retirement (it never gives up the game's capital, and a retiring game's
  vault has nothing to spend): fees it had not split are capital and move with `migrateCapital`.
- **Player claims.** Refund credits, and prizes waiting in FWA's delivery quarantine, stay in FWA for their owners.
- **The coin and its market**: token, liquidity position, pool, hook and burner.

## The successor

Any contract the owner proposes. It receives ERC-721 `transferFrom` (no callback), plain ETH, and from execution on the
trading fees (ETH from the PoolManager mid-swap: it must accept it cheaply, or swaps revert until the next change). No
interface is required: a successor is a separately built pool system that reads V1's records if it wants them. Each
pool system needs its own pool-owning contract, so a custody contract shared across pool systems would not remove a
deployment; it was not built (D57).

## Trust

- **The owner chooses the successor.** After a public 72-hour notice, the Apes and the treasury go to the contract the
  owner proposed, running the code that was proposed (code hash pinned; an upgradeable successor's code hash does not
  pin what it delegates to, so review that). The 72 hours let players and holders see it coming; nothing on chain judges
  the successor, and there is no holder veto (D63).
- **The sunset is instant** because its only destination is buy-and-burn, and final (section "Sunset").
- **Assets held by FWA.** Owner proceeds, listed prizes and the VRF flow are FWA V2's. A V1 that cannot settle (FWA halted
  or its VRF stopped for good) cannot finish `retireStep`, so the hand-over cannot proceed. Requests time out and become
  refunds under FWA's own rules. Prizes in FWA's quarantine follow FWA's 7-day delivery rules.
- **The vault's ETH between execution and the hand-over** stays in V1 until the game has retired: no capital moves while
  V1 still owes players settlements.

## Tests

`test/fork/Migration.t.sol`, on a running V1 game with three Apes, ≈ 5 ETH of Shape and Pack backing (a 160-prize board),
treasury capital, committed buyback ETH (the burner and its milestone reserve) and two player draws in flight:

| Test | Proves |
| --- | --- |
| `test_fullMigrationConservesAssetsAndClaims` | execution by a third party after 72 hours; no new draws; trading fees follow the successor at once; nothing moves before settlement; the draw in flight settles and its prize is delivered; the timed-out draw's refund stays claimable and is withdrawn afterwards; every Shape and Pack redeemed; three Apes moved in two batches, records readable; successor capital = vault balance + everything the game returned (exact); burner and milestone reserve untouched until V1 retires; nothing to the owner; the same market trades; buy-and-burn continues |
| `test_executionNeedsTheOwnersProposalAndTheDelay` | nothing without a proposal; only the owner proposes, only a contract; code hash pinned; not one second before 72 hours; cancel |
| `test_ownerCannotBypassTheDelay` | custody, capital, the fee recipient and retirement answer only to the MigrationAuthority |
| `test_changedCodeCannotExecute` | code changed after the proposal cannot execute (`CodeChanged`) |
| `test_feeRecipientMovesOnlyAfterTheNotice` | fees move only to a contract proposed 72 hours earlier, executed by anyone; the game runs on |
| `test_incompleteSettlementBlocksTheHandOver` | nothing moves while a request is unsettled |
| `test_laterProposalReplacesTheSuccessorForWhatRemains` | a second proposal (72 hours) redirects the rest |
| `test_successorRefusingEthStillReceivesCapital` | the capital transfer cannot be blocked |
| `test_sunsetOverridesAMigration` | the sunset cancels a pending proposal; Apes and fees go to the Sunset |
| `test_sunsetTakesWhatAMigrationHasNotMoved` | after a migration started, the sunset takes the remaining Apes and capital |
| `test_quarantinedApeFollowsLater` | an Ape in delivery quarantine does not block the hand-over; after its winner's refund it migrates |
| `test_milestoneReserveReleasesOnlyAfterRetirement` | the milestone reserve is released without a win only once V1 is retired |

`test/fork/Sunset.t.sol`: `test_sunsetWithPendingRequestsAuctionsAndBurns` (requests in flight settle, refunds stay
claimable, prizes cashed out, the Ape and the vault's ETH to the Sunset, `flush` to the burner, the auction from 150% to
25%, the price to the burner and any excess back to the buyer, nothing to the owner),
`test_onlyTheOwnerSunsetsAndOnlyTheAuthorityRetires`, `test_sunsetIsFinal` (no proposal of either kind afterwards; a
pending fee-recipient proposal cancelled), `test_retirementPayWithinTheAllowance` (raised keeper parameters reach only
the allowance left), `test_retiredGameRefusesNewCapitalAndAcquisitions`, `test_auctionOnlyAfterRetirement`.

Rehearsal steps 11 and 12 run the fee-recipient change and the migration with real transactions.
