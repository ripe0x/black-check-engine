# Slither triage

Command: `slither . --filter-paths "lib/|external/|test/|script/" --exclude-informational --exclude-optimization`
(slither on this Mac, solc 0.8.28, via_ir from foundry.toml). Run on the release-candidate source tree.
92 results. High and Medium below; Low after the table. Static analysis, not an audit.

| Impact | Detector | Location | Triage |
| --- | --- | --- | --- |
| High | arbitrary-send-eth | `Engine._payBid` | Intended: pays `msg.sender` the bid for the Check or Edition it just transferred in. Budget and weekly cap are debited before the call; caller functions are `nonReentrant` |
| High | reentrancy-eth | `Engine.restockShapes` | `nonReentrant`; external calls go to the canonical Shapes contract (pinned code hash) and the timelock-set controller. Budget check precedes each mint |
| Medium | reentrancy-no-eth (12) | Engine list, compose, formBlack, `_release`, reprice, setController; FwaV2Controller list, withdraw | Engine entry points are `nonReentrant` (reprice and setController: trusted controller only; setController is timelock-only). Calls go to canonical Checks/Shapes, the FWA pool the controller owns, or the controller. Controller functions are engine-only |
| Medium | incorrect-equality (2) | `Burner.burn`, `VenueHook.forward` | `== 0` guards that only revert on nothing to do; an attacker sending ETH cannot make either fail |
| Medium | uninitialized-local | `VenueHook._afterSwap` `fee` | Intended zero default for directions that charge in `beforeSwap` |
| Medium | unused-return (13) | v4 `initialize`/`unlock`/`settle`/`modifyLiquidity`, FWA `listings` tuple fields, `withdrawOwnerProceeds`, FWA token `approve` | Values not needed: v4 enforces settlement by reverting on non-zero deltas; tuple fields read selectively; owner proceeds are forwarded by balance; a failed FWA `approve` makes `createPool` revert |

Low (62): calls-loop (33, bounded caller-chosen batches against canonical contracts; a reverting item reverts only
that caller's batch), missing-zero-check (11: constructor and initializer arguments are checked by postflight;
zero is a deliberate value for `setBurner` (disables `releaseSurplus`), `setOperator` and `setGuardian` (revoke the
role), all timelock-only), reentrancy-events (9) and reentrancy-benign (5) (same reasoning as above), timestamp (3:
day and week windows, seconds of skew are harmless), events-maths (1: `FwaV2Controller.withdraw` updates a counter
the engine already reports through its own events).

Result: no change required.
