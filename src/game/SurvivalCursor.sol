// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFWAPool} from "../interfaces/IFWA.sol";

/// @notice Counts, from FWA's own ordered records, how many draws allocated a prize while a listing stayed in the
///         pool. Nobody reports counts: `advance` reads `requestIdAtSequence` and `acquisitions` for each processed
///         sequence, in order, exactly once.
/// @dev A draw "allocated" when FWA selected some listing for it: its processed status is Fulfilled, DeliveryPending
///      or DeliveryRefunded (selection already happened; only delivery to the winner is unresolved). Expired and
///      Refunded (no listing, or price slippage) select nothing and count nothing.
///      Episode rule: an entry is recorded only when every issued sequence is processed and counted, which is also
///      when FWA activates a new listing immediately instead of staging it. Every later sequence then selects from a
///      pool containing that listing, so while the listing is still Active, `allocated - entry` is the number of
///      draws it survived. A withdrawn or won listing is no longer Active and earns nothing further; relisting creates
///      a new listing ID and a new episode.
contract SurvivalCursor {
    IFWAPool public immutable pool;
    /// @notice The only address that records new episodes (the pool's controller, which lists inside the same call).
    address public immutable recorder;

    /// @notice Last sequence counted.
    uint64 public cursor;
    /// @notice Draws that allocated a prize, through `cursor`.
    uint64 public allocated;
    /// @notice `allocated` when the listing entered the pool, plus one (zero = no episode recorded).
    mapping(uint256 listingId => uint64) internal entryPlusOne;

    event Advanced(uint64 cursor, uint64 allocated);
    event EpisodeStarted(uint256 indexed listingId, uint64 entry);

    error NotRecorder();
    error NotCaughtUp();
    error NotActive();
    error AlreadyRecorded();
    error NoEpisode();

    constructor(IFWAPool pool_, address recorder_) {
        pool = pool_;
        recorder = recorder_;
    }

    /// @notice Counts up to `maxCount` processed sequences. Permissionless and idempotent.
    function advance(uint256 maxCount) public returns (uint256 counted) {
        uint64 processedThrough = pool.nextSequenceToProcess() - 1;
        uint64 c = cursor;
        uint64 a = allocated;
        while (counted < maxCount && c < processedThrough) {
            ++c;
            (,,,, IFWAPool.AcquisitionStatus status) = pool.acquisitions(pool.requestIdAtSequence(c));
            if (
                status == IFWAPool.AcquisitionStatus.Fulfilled || status == IFWAPool.AcquisitionStatus.DeliveryPending
                    || status == IFWAPool.AcquisitionStatus.DeliveryRefunded
            ) ++a;
            ++counted;
        }
        if (counted != 0) {
            cursor = c;
            allocated = a;
            emit Advanced(c, a);
        }
    }

    /// @notice Starts the survival episode of a listing the recorder has just activated.
    function startEpisode(uint256 listingId) external {
        if (msg.sender != recorder) revert NotRecorder();
        if (pool.unsettledAcquisitionCount() != 0 || cursor != pool.lastIssuedSequence()) revert NotCaughtUp();
        (,,,,,,, IFWAPool.ListingStatus status) = pool.listings(listingId);
        if (status != IFWAPool.ListingStatus.Active) revert NotActive();
        if (entryPlusOne[listingId] != 0) revert AlreadyRecorded();
        entryPlusOne[listingId] = allocated + 1;
        emit EpisodeStarted(listingId, allocated);
    }

    /// @notice Allocating draws this listing has survived, through `cursor`. Zero once it is no longer Active.
    function survived(uint256 listingId) external view returns (uint256) {
        uint64 e = entryPlusOne[listingId];
        if (e == 0) revert NoEpisode();
        (,,,,,,, IFWAPool.ListingStatus status) = pool.listings(listingId);
        if (status != IFWAPool.ListingStatus.Active) return 0;
        return allocated - (e - 1);
    }
}
