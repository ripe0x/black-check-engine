# Notice and provenance

Released under the MIT license (SPDX headers in each file).

## Collection Games (the base)

`src/`, `test/`, `script/`, `keeper/`, `site/`, `sim/` and `foundry.toml` were imported on 2026-11-03 from
**ripe0x/collection-games** at commit `409ca75` ("Merge 3d865c0: D92 round 8 observations accepted"), MIT, by the
owner's direction (docs/REBASE_PLAN.md, phase R1). Collection-games' own documents are kept unchanged for reference in
`docs/base/` (they describe the BAYC game; this repository's docs describe the Checks game). Its audit outputs are not
copied; they are at that commit under `audit/`. Each file changed after the import says so in its NatSpec or in the
commit that changed it.

Collection-games itself adapts parts of **ripe0x/draw-shapes** PR #9 at `0020bea6bdf330cdd2b79b0a669b01573e2f5285`
(MIT); its NOTICE lists the files (`Governed`, `CollectionGame` from `FwaGame`, `CollectionHook` from `EngineHook`,
`ProtocolLiquidity`, `CollectionToken` from `EngineToken`, `CollectionBurner` from `Buyback` + `EngineBuyer`,
`FwaFeeBuyer`, `IFWA`, `test/utils/Swapper.sol`, `docs/external/fwa-v2.md`).

## The previous implementation of this repository

The Checks Survival Protocol's first implementation (UUPS `Engine`, `FwaV2Controller`, `VenueHook`,
`VenueLiquidity`, `Burner`, `Coin`, `FwaFeeBuyer`, keeper, site, `sim/model.py`) is archived at tag `rc2`
(6b00eed). Checks-specific parts are ported from it in phases R3-R5 and name `rc2` as their origin.

## Third-party sources

`external/` holds third-party verified sources, read only, never compiled: FWA V2 factory, clone and VRF service;
the FWA token and hook; Checks Originals and Editions; Shapes; BLKCHK (reference only, invariant 8). See each
`SOURCE.md`.

Dependencies (git submodules, pinned): forge-std 7fdf81f, Solady v0.1.26 (acd959a), Uniswap v4-core 59d3ecf and v4-periphery 60cd938, Shapes 1b84c10, and **Draw Packs**: ripe0x/shape-packs
branch `draw-packs` at 3a463f7, unmodified, compiled with its own settings (via-IR, 20 runs) through
`src/vendor/PacksBuild.sol`. OpenZeppelin Contracts comes only from the copy Shapes vendors (v5.5.0, including
`TimelockController`); the separate v5.1.0 submodule used up to `rc2` is removed.
