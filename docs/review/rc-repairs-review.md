# Independent review: repairs and views before the release candidate

Reviewer: independent subagent, read-only, given `git diff 23e32f7 -- src script` (the fixes from
venue-burner-deploy-review.md, the compose refactor, the two Engine views and the Burner launch guard) and the owner
requirements. Traced, not run. A review is not an audit.

Result: no bug. The `_composeCost` extraction is behaviour-identical to the inline rule it replaced; the tick checks
are complete; `launched == true` implies the canonical pool is initialised.

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | Risk | A council-approved Burner on a hostile venue contract could receive released surplus | Not coded: `setBurner` is council + 7 days, and the same majority can already upgrade the engine (A11). The council checks `Burner.venue()` against the canonical `VenueLiquidity` before approving (Burner docstring, THREAT_MODEL residual trust) |
| 2 | Risk | `maxPerBurn = 0` makes `burn` always revert, stranding ETH in an ownerless contract | Fixed: constructor reverts `Nothing`; Deploy.t.sol |
| 3 | Risk | An unset `venueStartTick` (0) passes the constructor and postflight, opening at 1 coin per ETH | Fixed: postflight refuses 0; `test_postflightRefusesUnsetOpeningTick` |
| 4 | Risk | `composeCost` returned a number for pairs `compose` refuses, and panicked for a Black | Fixed: same eligibility check as `compose`; tier match and distinctness stay with `checks.composite` (documented); Market.t.sol |
| 5 | Risk | `currentNotional` for a won Check sent back counted survival `listChecks` discards | Fixed: a stale record counts 0, as in `listChecks`. Correction to the finding: a won listing's own survival is already 0 (`FwaV2Controller.survived`); the leak was survival carried from an earlier pool. `test_currentNotionalOfAReturnedCheckMatchesItsRelisting` |
| 6 | Nit | `currentNotional` is the reprice target; the posted price can lag by up to `repriceStepBps` | Documented in the view's NatSpec |
