# Phase 2 independent security review

Reviewer: independent subagent with no implementation history, read-only, given the code, the verified external
sources and the founder's five custody requirements (not the implementer's conclusions). Reviewed commit b49a191.
A review is not an audit.

Result: all five requirements traced from source and held (no owner, operator, guardian or keeper drain; upgrades and
new pools timelock-only; survival only from FWA state; pending draws cannot be cancelled; no caller-set price).
No Critical, High or Medium findings.

| # | Severity | Finding | Resolution (commit after b49a191) |
| --- | --- | --- | --- |
| 1 | Low | `halt` stops new draws but not composition | Intended: a halt protects players from new commitments; maintenance on settled state continues. Documented on `Engine.halt` and in THREAT_MODEL |
| 2 | Low | A won Check transferred back to the engine was stuck (stale listing record) | Fixed: `_clearIfWon` clears records whose listing is no longer live and resets that Check's history; `test_wonCheckReturnedIsRelistableWithFreshHistory` |
| 3 | Low/Info | `eligible` could be true for a won Check with carried draws (view only) | Fixed: `eligible` requires `controller.isListed` |
| 4 | Info | `reprice` unreachable | Kept: decay repricing uses it in Phase 4 |
| 5 | Info | Listing and Shape migration not chunked to FWA's 20-item batch | Fixed: the controller chunks every list and withdraw; `test_listsMoreThanTwentyInOneCall` |
| 6 | Info | Collected ETH has no exit until an upgrade | Intended for this phase; Phase 4 adds bounded outflows |
| 7 | Residual trust | An approved controller receives listed NFTs, so the council's review of controller code is the migration security boundary | Added to THREAT_MODEL and `IController` |

The same commit replaced the draw-by-draw `SurvivalCursor` with the O(1) rule of C010 (allocations = listed −
withdrawn − FWA `activeListingCount`). Survival semantics are unchanged; that change has not been independently
reviewed yet and is queued for the Phase 4 review.
