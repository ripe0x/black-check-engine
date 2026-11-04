# Independent security review of the rebase (da2fde1 against collection-games 409ca75)

Read-only review by an independent reviewer agent (no access to the implementer's reasoning beyond the code and docs),
2026-11-04. Findings verified against the code by the lead before acting; fixes in the commit after this record.

| # | Severity | Finding | Verified | Outcome |
| --- | --- | --- | --- | --- |
| C-1 | Critical | Composition changed a Check's tier but not its recorded cost; the Sunset prices from that cost, and the owner can sunset at once: a composite or Black Check would be auctioned from 150% of one 80-Check's cost (a Black Check from about 0.375 ETH), value leaking to the buyer (proceeds burned). D015 said "from its schedule price". | Yes | Fixed: the survivor of a composition takes on the burned Checks' recorded and cash cost (`_absorb`, all 64 for a Black Check); the Sunset prices from the higher of recorded cost and the tier's schedule. Test `test_sunsetSellsACompositeAtItsValue` |
| M-1 | Medium | The vault may pay up to 120% of the schedule; the council could set the ETH buyout markup as low as 10%: sell to the vault at 1.2·S, buy back at 1.1·S, repeat while the acquisition budget lasts (the owner can arrange the bid at once). | Yes | Fixed: the buyout markup floor is 25% (above the 20% purchase cap with a margin) and the ETH price is the higher of schedule and recorded cost. Test `test_buyoutNeverBelowWhatTheVaultPaid` |
| L-1 | Low | The free deterministic composition fixes keep/burn within a pair, but the caller picks the pair (and the 64 of N for a Black Check); the owner can set the coin burn for a choice to zero. | Yes | Accepted and recorded (D017): artistic choice of which eligible Checks to pair is part of the game; the keeper's fallback picks the longest survivors; the burn amounts are a pace setting with no value transfer |
| L-2 | Low | A Check that left (won, bought out) could never be registered again (inherited from the base). | Yes | Fixed: a Won or Sold record may register again as a new arrival. Test `test_aCheckThatLeftCanComeBack` |
| L-3 | Low | DECISIONS said "only revealed Originals"; the code accepts unrevealed ones (an Edition migrated by `sellEdition` is unrevealed for an epoch). | Yes | Spec corrected (D017): tier is fixed at mint, reveal is automatic; Checks' own composition rules apply at composition time |

Areas reported clean: survival counters on every listing and withdrawal path (Staged listings cannot occur because every
listing path requires nothing unsettled; hardening noted), desk custody bookkeeping and chunked withdrawals, exposure
consistency, reentrancy ordering, `sellEdition`, `burnFrom`, every council-only power, the timelock deployment and
postflight. Nit noted: postflight cannot see whether the owner controls the council Safe or the guardian (an offchain
fact; recorded in ADMIN.md's residual trust).
