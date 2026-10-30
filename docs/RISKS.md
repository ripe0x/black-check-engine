# Risk register and executable experiments

Evidence block: Ethereum mainnet 26,302,000 (2026-10-29). "Fact" = read on that fork or from verified source.
Each risk names the experiment that settles it. Status is updated as experiments run.

## Facts established in Phase 0

1. FWA factory `0xF5A3…300c`, standard implementation `0xEaa4…eb31`, VRF service `0xA4ad…5EE2`; runtime code hashes
   pinned in `test/fork/Pins.t.sol`. Pool creation enabled, `betaAccess` off, `maxPoolsPerWallet` 1, creation fee
   50,000 FWA, `edgeBps` 500, `inventoryChangeCooldown` 0, `maxAcquisitionsPerTx` 5, `selectionTimeoutBlocks` 30,
   `maxOutstandingRequestsPerPool` 10. Factory owner `0x0198…E8Cb` can change edge, cooldown, global switches and the
   implementation for new pools at any time.
2. Checks Originals: 12,474 minted, 7,149 burned, **5,325 live tokens** (storage slot 8), epoch 3,203. Unmigrated
   Editions: 3,556. Upper bound on 80-Check-equivalent units that can ever exist: 12,474 + 3,556 = **16,030**; pure
   burns and sacrifices reduce it further.
3. **No Black Check has ever been created** (no `Infinity` event since block 16,000,000). **85 Checks have reached the
   single-Check tier** (`Composite` events with `checks == 1`), IDs in `docs/receipts/single-check-ids.txt`.
4. A Black Check needs 4,096 Original-equivalents: at least 25.6% of every Check unit that can ever exist. With a
   ~20 Original launch, the protocol is ~200× short of one Black Check from 80s alone; buying existing singles or
   high-tier composites is the only realistic route (risk R4).
5. `Checks.composite` checks neither reveal state nor epoch; it requires caller ownership or approval of both tokens,
   equal tier, tier <= 5. `mint` uses `_safeMint` (contract recipients need `onERC721Received`) and the Checks contract
   burns the Edition, so the Edition owner must approve the Checks contract.
6. FWA `withdrawListingTo(listingId, recipient)` lets the depositor choose any recipient, so the controller must fix
   the recipient itself. Active withdrawals and repricing need `unsettledAcquisitionCount == 0`; staged, unreserved
   listings can be withdrawn at any time.

## Risks

| ID | Risk | Severity | Settled by | Status |
| --- | --- | --- | --- | --- |
| R1 | A contract cannot create and own an FWA pool (fee token, beta gate, one pool per wallet) | High | E1 | Closed: a contract creates and permanently owns its pool; one pool per controller. The 50,000 FWA fee is bought with ETH straight into the controller (`src/periphery/FwaFeeBuyer.sol`): 0.1303 ETH at block 26,302,000, then `openPool` succeeds (`test/fork/Deploy.t.sol`) |
| R2 | Draws survived cannot be counted from FWA state without trusting a keeper | High | E3 | Closed: survival derived in O(1) from FWA `activeListingCount` (C010); the earlier per-sequence cursor (~29k gas per draw) was removed; see D002 |
| R3 | Public purchases keep the queue unsettled, blocking withdrawal, composition and repricing indefinitely | High | E4 | Closed: `setBool(ACQUISITIONS_ENABLED,false)` stops new draws without touching quotes; the queue drains within 30 blocks plus a permissionless `processAcquisitions` |
| R4 | A Black Check is unreachable: 64 singles in one call may not fit in a block, and 4,096 units may be unaffordable | High | E5, Phase 3 | Gas closed: `infinity` on 64 real singles uses 742,242 gas. Economics open (D001) |
| R5 | Pair composition is too expensive per tier for routine keeper execution | Medium | E6 | Closed: 165k-200k gas per pair, 78k for 4 -> 1 |
| R6 | Edition migration and epoch reveal leave newly minted Originals with undefined art when listed | Medium | E7 | Closed: mint 169k gas; art fixed after the epoch's reveal block (51 blocks) once anyone calls `resolveEpochIfNecessary`. Rule: list only revealed Originals |
| R7 | Repricing for decay collides with in-flight draws and FWA cooldown, or gets stale | Medium | E8 | Mechanics closed: reprice needs an empty queue, bumps `inventoryVersion` (stale quotes revert), keeps the listing ID and its episode; cooldown is 0 today but factory-set. Stale-market policy open (R9) |
| R8 | Refund, expiry, slippage and failed-delivery paths credit false survival or strand NFTs | High | E9 | Closed for expiry, late word and slippage (no credit, purchaser pull refund). Failed delivery happens when the Shapes contract is named purchaser of a Shape (it rejects its own tokens), which strands the Shape: the controller's purchase gate now refuses it, the Checks contract, the pool, itself and the engine (rc1 audit H2, D011). Otherwise plain `transferFrom` delivers within FWA's 150k stipend; FWA's 7-day refund and `recoverRefundedNFT` remain the path |
| R9 | No trustless onchain price for Checks: initial notional, buyouts and acquisition limits rely on signers | High | Phase 3 design | Open |
| R10 | Owner extraction through upgrade, migration, pricing, marketplace routes or approvals | Critical | Phase 2 | Open |
| R11 | FWA factory owner changes edge, cooldown, global switches or the pool implementation | Medium | E2, Phase 2 | Open |
| R12 | Trading-fee capture for the coin on a real venue (Uniswap v4 hook) is unproven in this repo | Medium | Phase 4 | Closed: locked single-sided v4 liquidity and a flat ETH hook fee to `fundAcquisitions`, fork-tested end to end (`Venue.t.sol`, `Deploy.t.sol`); fee rate and opening tick open (D009) |
| R13 | Name or legal exposure: paid chance draws for NFTs; confusion with the existing Black Check / BLKCHK | High | Legal review | Open (not technical) |

## Phase 1 receipts (block 26,302,000, real contracts)

`forge test --match-path 'test/fork/*.t.sol'`: 12 passed, 0 failed (Pins 3, Lifecycle 5, BlackCheck 3, Editions 1).
Setup cheats, stated once: FWA creation fee written with `deal`; real holders impersonated to move tokens into the test
vault; VRF words delivered by impersonating the Chainlink coordinator into FWA's real VRF service.

| Measurement | Value |
| --- | --- |
| `infinity` on 64 real singles (execution) | 742,242 gas |
| `composite` per tier 80->40, 40->20, 20->10, 10->5, 5->4, 4->1 (avg) | 195,292 / 166,531 / 165,043 / 165,534 / 166,707 / 77,773 |
| Edition `mint` to a contract vault | 169,088 gas; reveal 51 blocks later |
| Survival cursor | 144,172 gas for 5 sequences |
| Draw fee, 3 Checks at 1 ETH + 2 Shapes at 0.01 ETH | 0.02586 ETH plus VRF 0.00195 ETH at 1 gwei (VRF scales with gas price) |

## Experiments (Phase 1, mainnet fork, real contracts)

Each one is a fork test against the pinned block. Impersonating a real holder to move a real Check into the test
controller is a test setup step. It is not a protocol path and is stated as such in every receipt.

- **E1 Pool creation.** A minimal controller contract creates an FWA pool with the expected-implementation overload,
  pays the 50,000 FWA fee (balance written on the fork; the purchase route for FWA is a separate measurement), and is
  the permanent owner. Pass: `owner() == controller`, `poolImplementation(pool) == FWA_IMPL`, a second pool reverts.
- **E2 Draw lifecycle.** List real Checks and Shapes, enable purchases, `acquire` from a player, deliver a VRF word
  through the real service, `processAcquisitions`, assert the winner received the selected NFT and owner proceeds
  accrued. Pass: delivered NFT matches `word % totalWeight` selection; proceeds equal `paid - (paid - base)/2`.
- **E3 Survival counting.** A permissionless cursor walks `requestIdAtSequence` and `acquisitions`, counts a
  sequence only when it is processed and an NFT was allocated, and credits each listing episode with the draws issued
  after its entry. Pass: the count equals the number of allocating draws a listing survived; expired, timed-out,
  slippage-refunded and no-listing requests add nothing; a relisted Check starts at zero; repeated cursor calls change
  nothing.
- **E4 Withdraw, compose, relist.** Pause purchases (`setBool(ACQUISITIONS_ENABLED, false)`), let the queue drain
  through processing and expiry, withdraw two same-tier Checks to the vault, `composite`, relist the survivor. Pass:
  pending requests settle normally; withdrawal while unsettled reverts; the result is listed with a new episode.
- **E5 Black Check.** Collect 64 real singles from their current owners (impersonated), call `infinity` from the
  vault. Pass: Black Check exists; gas recorded against the 30M block gas limit and the 16.78M (2^24) per-transaction
  cap of EIP-7825.
- **E6 Composite gas.** Measure `composite` at each tier with real tokens. Pass: numbers recorded.
- **E7 Edition migration.** Migrate a real Edition to the vault, roll past the reveal block, resolve the epoch. Pass:
  the Original exists in the vault and `getCheck(id).isRevealed` becomes true only after the reveal.
- **E8 Repricing.** `updatePrice` under an empty queue changes the fee; under an unsettled request it reverts; an
  in-flight request priced before a cut refunds or fills according to FWA's slippage rule.
- **E9 Refund paths.** Expire a request (no word within 30 blocks), time out a late word, and trigger a slippage
  refund; assert purchaser credit and zero survival credit for each.
