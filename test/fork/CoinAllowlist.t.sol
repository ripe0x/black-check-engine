// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {CollectionToken} from "../../src/token/CollectionToken.sol";
import {IVenuePolicy} from "../../src/interfaces/IVenuePolicy.sol";

/// @dev A contract wallet that holds the coin (a Safe, a staking or bridge contract stands in).
contract CoinVault {
    function send(CollectionToken coin, address to, uint256 amount) external {
        coin.transfer(to, amount);
    }
}

/// @notice D84: while the coin is restricted, the Admin owner keeps an allowlist (like FWA's distributors). A transfer
///         from or to an allowed address passes; one through the PoolManager always takes the swap rule; the
///         PoolManager and the zero address can never be allowed; the list is capped and published under URC-5.
contract CoinAllowlistForkTest is ForkBase {
    address alice = makeAddr("allow.alice");
    address bob = makeAddr("allow.bob");
    CoinVault box;

    function setUp() public {
        deployChecks();
        openMarket();
        pastOpeningCurve();
        buyCoin(alice, 1 ether);
        box = new CoinVault();
    }

    function _allow(address a, bool on) internal {
        vm.prank(council);
        sys.token.setAllowed(a, on);
    }

    function test_onlyTheOwnerSetsIt() public {
        vm.prank(alice);
        vm.expectRevert(CollectionToken.NotCouncil.selector);
        sys.token.setAllowed(address(box), true);
        _allow(address(box), true);
        assertTrue(sys.token.isAllowed(address(box)));
    }

    function test_allowedAddressSendsAndReceives() public {
        uint256 bal = sys.token.balanceOf(alice);
        assertGt(bal, 0);
        // not allowed: holder to contract reverts
        vm.prank(alice);
        vm.expectRevert();
        sys.token.transfer(address(box), bal / 2);
        // allowed: in, then out to anyone
        _allow(address(box), true);
        vm.prank(alice);
        sys.token.transfer(address(box), bal / 2);
        assertEq(sys.token.balanceOf(address(box)), bal / 2);
        box.send(sys.token, bob, bal / 4);
        assertEq(sys.token.balanceOf(bob), bal / 4);
        // two holders who are not allowed still cannot transfer
        vm.prank(bob);
        vm.expectRevert();
        sys.token.transfer(alice, 1);
        // removed: closed again
        _allow(address(box), false);
        vm.prank(alice);
        vm.expectRevert();
        sys.token.transfer(address(box), 1);
        assertFalse(sys.token.isAllowed(address(box)));
    }

    function test_poolManagerAndZeroCannotBeAllowed() public {
        vm.startPrank(council);
        vm.expectRevert(CollectionToken.CannotAllow.selector);
        sys.token.setAllowed(cfg.poolManager, true);
        vm.expectRevert(CollectionToken.CannotAllow.selector);
        sys.token.setAllowed(address(0), true);
        vm.stopPrank();
    }

    /// An allowed address sending straight to the PoolManager (no swap) still takes the swap rule and reverts, so the
    /// allowlist never opens another pool or an unswapped route through Uniswap.
    function test_allowedAddressStillTakesTheSwapRuleAtThePoolManager() public {
        _allow(address(box), true);
        uint256 bal = sys.token.balanceOf(alice);
        vm.prank(alice);
        sys.token.transfer(address(box), bal);
        vm.expectRevert();
        box.send(sys.token, cfg.poolManager, bal);
        vm.prank(alice);
        vm.expectRevert();
        sys.token.transfer(cfg.poolManager, 1);
    }

    function test_publishedUnderUrc5() public {
        _allow(address(box), true);
        _allow(bob, true);
        assertTrue(sys.token.venueAllowed(address(box), bytes32(0), true));
        assertFalse(sys.token.venueAllowed(alice, bytes32(0), true));
        (bool inR, bool outR, IVenuePolicy.ExternalVenue[] memory v) = sys.token.externalVenues();
        assertTrue(inR && outR);
        assertEq(v.length, 2);
        assertEq(sys.token.allowedList().length, 2);
        _allow(bob, false);
        (,, v) = sys.token.externalVenues();
        assertEq(v.length, 1);
        assertEq(v[0].venue, address(box));
        assertTrue(v[0].inbound && v[0].outbound);
    }

    function test_listIsCapped() public {
        uint256 cap = sys.token.MAX_ALLOWED();
        vm.startPrank(council);
        for (uint256 i; i < cap; ++i) {
            sys.token.setAllowed(address(uint160(0x1000 + i)), true);
        }
        vm.expectRevert(CollectionToken.CannotAllow.selector);
        sys.token.setAllowed(address(0xdead), true);
        sys.token.setAllowed(address(uint160(0x1000)), false); // room again
        sys.token.setAllowed(address(0xdead), true);
        vm.stopPrank();
        assertEq(sys.token.allowedList().length, cap);
    }

    /// After a renounce the list is frozen as it is (nobody holds the owner's key).
    /// D012: the allowlist is the council's, so the owner renouncing changes nothing about it.
    function test_ownerRenounceLeavesTheCouncilsAllowlist() public {
        _allow(address(box), true);
        vm.prank(owner);
        sys.admin.renounceOwnership();
        vm.prank(council);
        sys.token.setAllowed(address(box), false);
        assertFalse(sys.token.isAllowed(address(box)), "the council still decides");
    }
}
