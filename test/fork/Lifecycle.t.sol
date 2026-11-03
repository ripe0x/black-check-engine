// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC721Lite} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";

/// @notice The funded launch lifecycle end to end on the pinned fork.
contract LifecycleForkTest is ForkBase {
    address player = makeAddr("player");

    function setUp() public {
        deployBayc();
    }

    function test_launchAndPlay() public {
        launchGame(6 ether);
        assertEq(pool.owner(), address(sys.poolOwner), "pool owner");
        assertEq(pool.purchaseOperator(), address(sys.poolOwner), "operator");
        assertTrue(pool.localPurchasesEnabled(), "open");
        assertEq(sys.game.liveCount(), sys.game.boardSize(), "board");
        assertEq(sys.poolOwner.listedCount(), 1, "one ape");
        (, uint128 notional,,,) = sys.poolOwner.cListings(sys.poolOwner.listedAt(0));
        assertEq(notional, 6 ether, "the Ape opens at its price");
        emit log_named_uint("exposure bps", sys.poolOwner.exposureBps());
        (uint256 fee,,) = pool.quoteAcquisitionPrice(1);
        emit log_named_uint("ticket wei", fee);
        playMany(player, 30, 1);
        emit log_named_uint("pulls", sys.game.pullsFulfilled());
        emit log_named_int("profit", sys.game.profit());
    }
}
