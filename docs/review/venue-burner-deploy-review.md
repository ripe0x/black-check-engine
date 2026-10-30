# Independent review: venue, burner, FWA fee buyer, deployment path

Reviewer: independent subagent, read-only, given the code, v4-core/periphery sources and the founder requirements.
Reviewed at 23e32f7. Traced, not re-run. A review is not an audit.

Result: no ETH, coin or NFT drain and no fee or surplus redirect. Hook permissions match the callbacks; the fee is
`f` of the gross in all four swap directions (exact-output sells revert); only `VenueLiquidity` can initialise the
pool, once, with the exact key; no removal, collect or sweep exists; the deployer renounces timelock admin and
postflight self-checks address predictions.

| # | Severity | Finding | Resolution |
| --- | --- | --- | --- |
| 1 | Low-Med | The deployer chose the opening tick at `launch` time, after postflight | Fixed: `startTick` is a constructor immutable, validated at construction; `launch()` takes no argument; postflight checks it against `Config.venueStartTick`; `test_badStartTickRefusedAtConstruction` |
| 2 | Info | `Burner` took its pool key as a constructor argument | Fixed: it reads the pool manager and key from the venue contract and exposes `venue` for the council to check before `setBurner` |
| 3 | Info | Sandwich loss per burn can approach the whole chunk, not part of it | Docstring corrected; still bounded by `maxPerBurn` per interval (D010) |
| 4 | Info | `releaseSurplus` assumes no player-owed ETH sits in the engine | Holds: FWA keeps refunds and delivery escrow as pull credits inside the pool; the controller forwards only owner proceeds |
