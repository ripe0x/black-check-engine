# Slither triage: the rebased system (5d8db23 + da2fde1)

`slither . --foundry-out-directory out-fast --filter-paths "lib/|test/|script/|external/" --exclude-dependencies`
(Slither 0.11.6 on the fast, non-IR build: the same source; detectors read source, not IR output). 141 contracts, 102
detectors, 281 results: High 6, Medium 96, Low 135, Informational 42, Optimization 2. Collection-games triaged the same
detector classes on its code (docs/base/AUDIT_SCOPE.md section 7; 92-95 results counted without Low/Informational).
This record triages what our diff (docs/AUDIT_SCOPE.md) adds or touches; the rest is unchanged code with its base
triage.

## High (6)

| Detector | Location | Verdict |
| --- | --- | --- |
| arbitrary-send-eth | `ChecksDesk.buyWithEth` (new) | By design. It sends the price to the immutable vault (`contribute`) and the excess back to `msg.sender`, the payer. No caller-chosen recipient. |
| arbitrary-send-eth | `CollectionPoolOwner._mintPrize` | Base code (mints Shapes/Packs with exactly the game's payment); unchanged. Base triage applies. |
| arbitrary-send-eth | `FundingVault.fundGame` | Base code (to the immutable game); unchanged. |
| arbitrary-send-erc20 | `FwaFeeRelay.unlockCallback` | Base code (the payer is the relay's caller, passed through the PoolManager callback); unchanged. |
| reentrancy-eth | `CollectionGame.maintainStep`, `FundingVault.fillOrder` | Base code; both `nonReentrant` paths with fixed counterparties, triaged in the base (fillOrder's adapter return accounting, D68/D70). |

## Medium, in our diff

| Detector | Location | Verdict |
| --- | --- | --- |
| reentrancy-no-eth | `FundingVault.sellEdition` (new) | `nonReentrant`; external calls go to the immutable Editions and Checks contracts, then a transfer to custody and `_book`. A Checks `_safeMint` callback reaches the vault's `onERC721Received`, which is `view` and accepts only Checks minting to itself. |
| reentrancy-no-eth | `CollectionPoolOwner._reprice`, `_listBatch`, `processCollection`, `withdrawCollection`, `settleListing` | The base pattern: `nonReentrant`, the only external party the pool owner's own FWA pool (and Checks for `getCheck`). State written after `updatePrice`/`listNFTs` is this contract's bookkeeping of that same call. |
| incorrect-equality | `CollectionPoolOwner._reprice` (`target == current`) | Intended: no reprice when nothing moved. |
| uninitialized-local | `ChecksDesk.formBlackCost` (`prev`) | Intended zero before the first id. |
| unused-return | `ChecksDesk.listingInfo` (`cListings` partial tuple) | Intended: only the token id and `open` are needed. |

No finding in `ChecksDesk.compose`, `formBlack`, `buyWithCoin`, `CollectionToken.burnFrom`, `Admin`/`Governed` council
code, or the desk operations (`_take`, `deskCompose`, `deskFormBlack`, `deskRelease`) beyond the classes above.

## Low and Informational

Base classes (calls-loop, timestamp, reentrancy-benign/events, missing-zero-check, naming, assembly, costly-loop);
the new loops (`_take` chunks of at most 20, `minNotionalWei` over 8 tiers, `_listBatch` custody scan bounded by the
batch) are bounded. No change made.
