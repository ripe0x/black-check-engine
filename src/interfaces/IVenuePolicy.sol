// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title IVenuePolicy
/// @notice URC-5, Token Venue Policy (Uniswap URCs, status Discussion at 2026-10-31; author 0xBeans): a token declares
///         where it may be traded so routers send trades to its canonical v4 pools and drop routes that would revert.
///         Declaration only: enforcement is the token's own (CollectionToken's transfer restriction).
interface IVenuePolicy {
    enum VenueEnforcement {
        Preferred,
        Enforced
    }

    struct ExternalVenue {
        address venue;
        bool inbound;
        bool outbound;
    }

    event VenueEnforcementChanged(VenueEnforcement enforcement);
    event CanonicalPoolsChanged();
    event VenueStatusChanged(address indexed venue, bytes32 indexed poolId, bool inbound, bool allowed);
    event ExternalVenuesChanged();

    error VenueNotAllowed(address venue, bytes32 poolId, bool inbound);

    function venueEnforcement() external view returns (VenueEnforcement);
    function canonicalPools() external view returns (PoolKey[] memory);
    function venueAllowed(address venue, bytes32 poolId, bool inbound) external view returns (bool);
    function externalVenues()
        external
        view
        returns (bool inboundRestricted, bool outboundRestricted, ExternalVenue[] memory allowed);
}
