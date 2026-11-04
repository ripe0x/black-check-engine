# Audit scope: Checks Survival Protocol on the collection-games base

Candidate: branch `claude/wizardly-shannon-440owk` (PR ripe0x/black-check-engine#1). Not deployed. This replaces the
rc2 scope (UUPS `Engine`, archived at tag `rc2`).

## What changed and what did not

The base is ripe0x/collection-games at 409ca75 (D92), which went through a fresh-discovery audit and final rounds 1-8
(its `audit/` directory at that commit). Those rounds cover its code with its Ape settings. **Every line below is
unaudited**, and the audit must cover the diff against 409ca75, not only new files.

| File | Lines changed (diff -c) | What |
| --- | --- | --- |
| `src/checks/ChecksDesk.sol` | new, 240 | Composition, Black Check formation, ETH and coin buyouts (from rc2 `Engine`) |
| `src/interfaces/IChecks.sol` | new, 75 | Checks Originals and Editions subset (from rc2) |
| `src/core/CollectionPoolOwner.sol` | 538 | Tier, council schedule, survival counters (listed - withdrawn - active), decay per survived draw, schedule repricing both ways, custody index, desk operations with chunked withdrawals, carried survival at retirement |
| `src/core/FundingVault.sol` | 77 | 80-Check-only purchases, `sellEdition`, the 120%-of-schedule price cap |
| `src/core/Admin.sol`, `Governed.sol` | 30, 12 | The council authority (`council`, `setCouncil`, `onlyCouncil`) |
| `src/game/CollectionGame.sol` | 13 | Markup floor 5%, keeper pay caps |
| `src/token/CollectionToken.sol` | 19 | `burnFrom`; allowlist and unrestriction council-only |
| `src/token/CollectionHook.sol`, `ProtocolLiquidity.sol` | 5, 6 | `setLayer` council-only; owner or council opens the market |
| `src/migration/MigrationAuthority.sol` | 7 | Proposals council-only |
| `src/migration/Sunset.sol`, `src/periphery/Lens.sol` | 7, 7 | The record's new layout |
| `script/DeploySystem.sol`, `LaunchConfig.sol`, `Deploy.s.sol` | | The council TimelockController, the desk, the Checks config, postflight (council roles, schedule, desk, name gate) |

Unchanged from 409ca75 (audited there): `CollectionBurner`, `DrawRouter`, `SeaportAdapter`, `FwaFeeRoutes`,
`LayerTap`, `IFWA`, and the Draw Packs build.

## Build and run

```
git submodule update --init --recursive
forge build                                   # via-IR, solc 0.8.28, cancun; about 33 minutes from clean
anvil --fork-url <archive rpc> --fork-block-number 26337000 --port 8546 &
MAINNET_RPC_URL=http://127.0.0.1:8546 forge test --threads 3 --no-match-path 'test/scenario/Throughput.t.sol'
```

Fork block 26,337,000: after FWA reopened V2 pool creation (D014). Only `test/fork/MigrationCommunity.t.sol` opens FWA
switches locally (the community factory, off on mainnet at this block).

## Properties to break

1. **No single key moves value (invariants 10, 11; D012).** The owner cannot withdraw custody or ETH, redirect fees,
   change a Check's worth (schedule, listing rule, buyout prices), change the coin's venue, or approve new code. The
   council can, only through its 7-day timelock (guardian cancels) and, for a migration or fee recipient, the
   MigrationAuthority's further 72 hours with the code pinned. Look for indirect extraction through owner settings
   (keeper pay, board pattern, bid parameters, composition parameters, pause and sunset ordering).
2. **Survival is FWA's truth.** `allocated() = listedTotal - withdrawnTotal - activeListingCount` must equal the
   number of draws that allocated a prize. Every listing and withdrawal must go through the counters; a staged
   listing, a withdrawal path that skips the counter, a refund or recovery path, or a migration would break it.
   Composition eligibility and decay both read it.
3. **The desk moves only what it should.** `deskCompose`, `deskFormBlack` and `deskRelease` take only open, active
   Check listings with nothing unsettled; composition burns exactly what `composeCost` says, or nothing on failure; a
   buyout pays at least schedule + 10% to the vault or burns the council's coin price.
4. **Pricing and exposure.** Schedule changes reprice both ways; the exposure sum must match the open listings'
   terms after any sequence of listing, reprice, win, refund, composition, buyout and retirement.
5. **Acquisition.** The vault books nothing above 120% of the 80-Check schedule, buys only 80-Check Originals, and an
   Edition sale lands the Original in custody with nothing stranded in the vault.
6. **Everything from collection-games' scope** (docs/base/AUDIT_SCOPE.md) still holds.

## Known issues and accepted limits

- The council majority is trusted with migrations after 7 + 3 days in public (disclosed in docs/ADMIN.md).
- The schedule is set by the council and lags the market by at least 7 days (rc2 risk carried).
- A production successor for FWA's community factory is not built; the migration path is proven with a test-only
  successor.
- `CollectionPoolOwner` has 980 B of EIP-170 headroom under via-IR.
- The $LAYER share code is kept but off at launch and council-only.
- Coin name, ticker, council keys and guardian are unset; the deployment refuses the placeholders.
