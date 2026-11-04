// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC20Lite} from "./ForkBase.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IFWAPool, IFWAFactory} from "../../src/interfaces/IFWA.sol";
import {FwaFeeBuyer, FwaFeeRelay} from "../../src/periphery/FwaFeeRoutes.sol";
import {CollectionPoolOwner} from "../../src/core/CollectionPoolOwner.sol";

/// @notice Creating the FWA pool from a permanent protocol contract with the 50,000 FWA fee, through both supported
///         routes, against the real (transfer-locked) FWA token, its hook and the FWA factory.
contract FwaPoolForkTest is ForkBase {
    address fwaHolder = makeAddr("ownerWithFwa");
    IERC20Lite fwa = IERC20Lite(MAINNET_FWA_TOKEN);

    function setUp() public {
        deployChecks();
    }

    /// @dev Gives `fwaHolder` FWA the only way an ordinary wallet can receive it: a buy delivered by the PoolManager.
    function _fundOwner(uint256 amount) internal {
        FwaFeeBuyer b = new FwaFeeBuyer(IPoolManager(cfg.poolManager), MAINNET_FWA_TOKEN);
        uint256 eth = fwaQuoteEth(amount);
        vm.deal(address(this), address(this).balance + eth);
        b.buyTo{value: eth}(fwaHolder, amount);
    }

    function test_walletTransferIsLocked() public {
        _fundOwner(1_000 ether);
        vm.prank(fwaHolder);
        (bool ok,) = MAINNET_FWA_TOKEN.call(abi.encodeWithSignature("transfer(address,uint256)", address(sys.poolOwner), 1 ether));
        assertFalse(ok, "FWA wallet-to-contract transfer reverts");
    }

    function test_relayOwnersFwaAndCreatePool() public {
        uint256 fee = IFWAFactory(cfg.fwaFactory).poolCreationFee();
        assertEq(fee, 50_000 ether);
        _fundOwner(52_000 ether);
        FwaFeeRelay relay = new FwaFeeRelay(IPoolManager(cfg.poolManager), MAINNET_FWA_TOKEN);
        // find the smallest input that delivers the fee (binary search on snapshots)
        uint256 lo = fee;
        uint256 hi = 52_000 ether;
        for (uint256 i; i < 30; ++i) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.startPrank(fwaHolder);
            fwa.approve(address(relay), mid);
            uint256 out = relay.relay(mid, address(sys.poolOwner), 0);
            vm.stopPrank();
            vm.revertToState(snap);
            if (out >= fee) hi = mid;
            else lo = mid;
        }
        emit log_named_decimal_uint("FWA input needed for 50,000 FWA delivered", hi, 18);
        emit log_named_decimal_uint("round-trip cost, % (x100)", (hi - fee) * 10_000 / fee, 2);
        uint256 ownerBefore = fwa.balanceOf(fwaHolder);
        uint256 ethBefore = fwaHolder.balance;
        vm.startPrank(fwaHolder);
        fwa.approve(address(relay), hi);
        uint256 got = relay.relay(hi, address(sys.poolOwner), fee);
        vm.stopPrank();
        assertGe(got, fee);
        assertEq(ownerBefore - fwa.balanceOf(fwaHolder), hi, "exactly fwaIn spent");
        assertGe(fwaHolder.balance, ethBefore, "no ETH taken");
        assertEq(fwa.balanceOf(address(relay)), 0, "relay holds nothing");
        assertEq(address(relay).balance, 0);

        // anyone can now create the pool; the pool fwaHolder contract is its permanent fwaHolder
        address created = sys.poolOwner.createPool(keccak256("bayc"));
        IFWAPool p = IFWAPool(created);
        assertEq(p.owner(), address(sys.poolOwner));
        assertEq(p.purchaseOperator(), address(sys.poolOwner));
        assertFalse(p.localPurchasesEnabled(), "purchases off until activation");
        assertEq(fwa.balanceOf(address(sys.poolOwner)), 0, "leftover FWA burned");
        vm.expectRevert(CollectionPoolOwner.PoolExists.selector);
        sys.poolOwner.createPool(keccak256("again"));
    }

    function test_buyRouteCreatesPool() public {
        createPool();
        assertEq(pool.owner(), address(sys.poolOwner));
        assertEq(pool.activeListingCount(), 0);
    }

    function test_createPoolWithoutFeeReverts() public {
        vm.expectRevert();
        sys.poolOwner.createPool(keccak256("nofee"));
    }

    function test_directFwaPurchaseBlockedBeforeActivation() public {
        createPool();
        openMarket();
        accrueFees(0.25 ether);
        riseBidTo(0.25 ether);
        sellCheck(nextCheckId());
        accrueFees(sys.game.capitalNeed() + 0.1 ether); // + the KeeperFund top-up
        syncAll();
        assertTrue(sys.game.ready(), "ready");
        // the board is full and an Ape is listed, but nobody has activated: direct FWA purchases revert
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        address buyer = makeAddr("eager");
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert();
        pool.acquire{value: total}(buyer, fee, 0, 10_000, version, block.timestamp + 1);
        // ownership cannot change: FWA locks it and the pool fwaHolder has no transfer or execute function
        vm.prank(address(sys.poolOwner));
        (bool ok,) = address(pool).call(abi.encodeWithSignature("transferOwnership(address)", fwaHolder));
        assertFalse(ok, "FWA ownership is locked");
    }
}
