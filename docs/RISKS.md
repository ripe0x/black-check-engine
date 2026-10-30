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
| R1 | A contract cannot create and own an FWA pool (fee token, beta gate, one pool per wallet) | High | E1 | Open |
| R2 | Draws survived cannot be counted from FWA state without trusting a keeper | High | E3 | Open |
| R3 | Public purchases keep the queue unsettled, blocking withdrawal, composition and repricing indefinitely | High | E4 | Open |
| R4 | A Black Check is unreachable: 64 singles in one call may not fit in a block, and 4,096 units may be unaffordable | High | E5, Phase 3 | Open |
| R5 | Pair composition is too expensive per tier for routine keeper execution | Medium | E6 | Open |
| R6 | Edition migration and epoch reveal leave newly minted Originals with undefined art when listed | Medium | E7 | Open |
| R7 | Repricing for decay collides with in-flight draws and FWA cooldown, or gets stale | Medium | E8 | Open |
| R8 | Refund, expiry, slippage and failed-delivery paths credit false survival or strand NFTs | High | E9 | Open |
| R9 | No trustless onchain price for Checks: initial notional, buyouts and acquisition limits rely on signers | High | Phase 3 design | Open |
| R10 | Owner extraction through upgrade, migration, pricing, marketplace routes or approvals | Critical | Phase 2 | Open |
| R11 | FWA factory owner changes edge, cooldown, global switches or the pool implementation | Medium | E2, Phase 2 | Open |
| R12 | Trading-fee capture for the coin on a real venue (Uniswap v4 hook) is unproven in this repo | Medium | Phase 4 | Open |
| R13 | Name or legal exposure: paid chance draws for NFTs; confusion with the existing Black Check / BLKCHK | High | Legal review | Open (not technical) |

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
