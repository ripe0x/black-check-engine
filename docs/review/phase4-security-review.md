# Phase 4 independent security review

Reviewer: independent subagent, read-only, given the code, verified external sources and seven founder requirements
(custody, timelock authority, survival from FWA state, pending draws, pricing, exact burns, bounded ETH outflows).
Reviewed: Engine, FwaV2Controller and Coin at bf6034f..9a33dae (Phase 4a engine, C010 survival). Traced, not
fuzzed; the reviewer did not run fork tests. A review is not an audit.

Result: no Critical or High findings. The C010 identity was traced against FWAClone: `activeListingCount` changes
only on activation (reached only through an empty-queue `listNFTs`), active withdrawal by the depositor, and
allocation. Burns happen after the canonical call in the same transaction; `balance >= acquisitionBudget` holds on
every path; `_payBid` follows checks-effects-interactions under the lock.

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | Info | Survival depends on the controller never staging a listing and counting only Active withdrawals; a future controller that broke either would mis-count | Documented on `IController` as a requirement for every controller the council approves |
| 2 | Info | Free fallback composition is a permissionless state change on protocol assets | Intended (D008); the survivor stays in custody |
| 3 | Low | The weekly bid cap is epoch-aligned, so up to 2x the cap can be spent across a week boundary | Accepted: still bounded by `acquisitionBudget`; documented on `bidWeeklyCap` |
| 4 | Info | Narrowing casts (`uint64` listing IDs, `uint32` survived) | Unreachable in practice; no change |
