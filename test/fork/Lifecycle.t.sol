// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ForkBase} from "./ForkBase.sol";
import {Lab} from "./Lab.sol";
import {IFWAPool, IFWAFactory, FWA_ACQUISITIONS_ENABLED} from "../../src/interfaces/IFWA.sol";
import {IChecksOriginals} from "../../src/interfaces/IChecks.sol";

interface IERC20Approve {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IShapesMint {
    function mintBatchTo(uint256 amountWei, uint256 quantity, address to)
        external
        payable
        returns (uint256 firstTokenId);
    function mintFee() external view returns (uint256);
    function setApprovalForAll(address operator, bool approved) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice E1-E4, E8, E9 against the real FWA factory, clone, VRF service, Checks and Shapes at the pinned block.
///         Setup steps that are not protocol paths: the FWA creation fee is written to the test vault's balance
///         (`deal`), real Check holders are impersonated to move tokens into the vault, and VRF words are delivered by
///         impersonating the Chainlink coordinator into FWA's real VRF service.
contract LifecycleTest is ForkBase {
    Lab internal lab;
    IFWAPool internal pool;
    // The controller survival rule (C010), mirrored here for the Lab-owned pool: allocations = listed - withdrawn -
    // activeListingCount, valid because the Lab is the only depositor and lists only into an empty queue.
    uint256 internal listedCount;
    uint256 internal withdrawnCount;
    mapping(uint256 => uint256) internal entry;
    address internal player = makeAddr("player");
    uint256 internal constant CHECK_PRICE = 1 ether;
    uint256 internal constant SHAPE_BACKING = 0.01 ether;
    uint256 internal nextScan = 1;

    function setUp() public override {
        super.setUp();
        lab = new Lab();
        vm.txGasPrice(1 gwei);
        pool = _createPool(keccak256("checks-survival.lab"));
        lab.exec(address(CHECKS), abi.encodeCall(IChecksOriginals.setApprovalForAll, (address(pool), true)));
        lab.exec(SHAPES, abi.encodeCall(IShapesMint.setApprovalForAll, (address(pool), true)));
    }

    // ---------------------------------------------------------------- helpers

    function _createPool(bytes32 salt) internal returns (IFWAPool p) {
        uint256 fee = FWA_FACTORY.poolCreationFee();
        deal(FWA_TOKEN, address(lab), fee);
        lab.exec(FWA_TOKEN, abi.encodeCall(IERC20Approve.approve, (address(FWA_FACTORY), fee)));
        bytes memory out = lab.exec(
            address(FWA_FACTORY),
            abi.encodeWithSignature("createPool(bytes32,uint256,address)", salt, fee, FWA_IMPL)
        );
        p = IFWAPool(abi.decode(out, (address)));
    }

    function _takeEighties(uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        uint256 got;
        for (uint256 id = nextScan; got < n; ++id) {
            try CHECKS.ownerOf(id) returns (address holder) {
                if (CHECKS.getCheck(id).stored.divisorIndex != 0) continue;
                vm.prank(holder);
                CHECKS.transferFrom(holder, address(lab), id);
                ids[got++] = id;
            } catch {}
            nextScan = id + 1;
        }
    }

    function _mintShapes(uint256 n) internal returns (uint256[] memory ids) {
        uint256 cost = n * (SHAPE_BACKING + IShapesMint(SHAPES).mintFee());
        vm.deal(address(this), address(this).balance + cost);
        bytes memory out = lab.exec{value: cost}(
            SHAPES, abi.encodeCall(IShapesMint.mintBatchTo, (SHAPE_BACKING, n, address(lab)))
        );
        uint256 first = abi.decode(out, (uint256));
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = first + i;
    }

    function _list(address collection, uint256[] memory ids, uint256 price) internal returns (uint256[] memory lids) {
        IFWAPool.ListingInput[] memory items = new IFWAPool.ListingInput[](ids.length);
        for (uint256 i; i < ids.length; ++i) items[i] = IFWAPool.ListingInput(collection, ids[i], price);
        assertEq(pool.unsettledAcquisitionCount(), 0, "list only into an empty queue");
        lids = abi.decode(lab.exec(address(pool), abi.encodeCall(IFWAPool.listNFTs, (items))), (uint256[]));
        listedCount += lids.length;
        for (uint256 i; i < lids.length; ++i) {
            assertEq(uint8(_listingStatus(lids[i])), uint8(IFWAPool.ListingStatus.Active), "never staged");
            entry[lids[i]] = _allocated();
        }
    }

    function _allocated() internal view returns (uint256) {
        return listedCount - withdrawnCount - pool.activeListingCount();
    }

    function _survived(uint256 listingId) internal view returns (uint256) {
        if (_listingStatus(listingId) != IFWAPool.ListingStatus.Active) return 0;
        return _allocated() - entry[listingId];
    }

    function _withdraw(uint256[] memory listingIds) internal {
        lab.exec(address(pool), abi.encodeCall(IFWAPool.withdrawListingsTo, (listingIds, address(lab))));
        withdrawnCount += listingIds.length;
    }

    function _enable(bool on) internal {
        lab.exec(address(pool), abi.encodeCall(IFWAPool.setBool, (FWA_ACQUISITIONS_ENABLED, on)));
    }

    function _pull() internal returns (uint256 requestId) {
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(player, player.balance + total);
        vm.prank(player);
        requestId = pool.acquire{value: total}(player, fee, 0, 10_000, version, block.timestamp + 1 hours);
    }

    /// @dev A word whose `word % totalWeight` lands on `listingId` (FWA descends its tree in slot order).
    function _wordFor(uint256 listingId) internal view returns (uint256 prefix) {
        for (uint256 slot = 1; slot < 200; ++slot) {
            uint256 id = pool.slotToListing(slot);
            if (id == 0) continue;
            (,,,, uint256 weight,,, IFWAPool.ListingStatus st) = pool.listings(id);
            if (st != IFWAPool.ListingStatus.Active) continue;
            if (id == listingId) return prefix;
            prefix += weight;
        }
        revert("wordFor: not active");
    }

    function _status(uint256 requestId) internal view returns (IFWAPool.AcquisitionStatus st) {
        (,,,, st) = pool.acquisitions(requestId);
    }

    function _listingStatus(uint256 listingId) internal view returns (IFWAPool.ListingStatus st) {
        (,,,,,,, st) = pool.listings(listingId);
    }

    // ---------------------------------------------------------------- E1

    function test_E1_contractCreatesAndPermanentlyOwnsPool() public {
        assertEq(pool.owner(), address(lab));
        assertEq(FWA_FACTORY.poolImplementation(address(pool)), FWA_IMPL);
        assertEq(pool.purchaseOperator(), address(0));
        assertFalse(pool.localPurchasesEnabled());
        assertEq(pool.selectionTimeoutBlocks(), 30);

        // One pool per wallet: the same controller can never open a second pool.
        uint256 fee = FWA_FACTORY.poolCreationFee();
        deal(FWA_TOKEN, address(lab), fee);
        lab.exec(FWA_TOKEN, abi.encodeCall(IERC20Approve.approve, (address(FWA_FACTORY), fee)));
        vm.expectRevert();
        lab.exec(
            address(FWA_FACTORY),
            abi.encodeWithSignature("createPool(bytes32,uint256,address)", bytes32("second"), fee, FWA_IMPL)
        );
        // Ownership is locked forever.
        vm.expectRevert(bytes4(keccak256("OwnershipLocked()")));
        lab.exec(address(pool), abi.encodeWithSignature("transferOwnership(address)", address(this)));
    }

    // ---------------------------------------------------------------- E2

    function test_E2_drawDeliversSelectedCheckAndPaysOwner() public {
        uint256[] memory checks = _takeEighties(3);
        uint256[] memory checkListings = _list(address(CHECKS), checks, CHECK_PRICE);
        _list(SHAPES, _mintShapes(2), SHAPE_BACKING);
        _enable(true);

        (uint256 fee, uint256 vrf, uint256 total) = pool.quoteAcquisitionPrice(1);
        console2.log("draw fee wei", fee);
        console2.log("vrf fee wei at 1 gwei", vrf);
        uint256 requestId = _pull();
        assertEq(uint8(_status(requestId)), uint8(IFWAPool.AcquisitionStatus.Pending));

        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(requestId, _wordFor(checkListings[1]));
        pool.processAcquisitions(10);

        assertEq(uint8(_status(requestId)), uint8(IFWAPool.AcquisitionStatus.Fulfilled));
        assertEq(CHECKS.ownerOf(checks[1]), player, "winner holds the selected Check");
        assertEq(uint8(_listingStatus(checkListings[1])), uint8(IFWAPool.ListingStatus.Settled));
        assertEq(pool.activeListingCount(), 4);

        // Owner share = paid - (paid - base) / 2, base = EV at the request.
        uint256 owed = pool.ownerProceeds();
        uint256 base = fee * 10_000 / 10_500;
        assertApproxEqAbs(owed, fee - (fee - base) / 2, 2);
        uint256 before = address(lab).balance;
        lab.exec(address(pool), abi.encodeCall(IFWAPool.withdrawOwnerProceeds, ()));
        assertEq(address(lab).balance - before, owed);
        assertEq(total, fee + vrf);
    }

    // ---------------------------------------------------------------- E3 + E9

    function test_E3_E9_survivalCountsOnlyAllocatingDraws() public {
        uint256[] memory checks = _takeEighties(4);
        uint256[] memory checkListings = _list(address(CHECKS), checks, CHECK_PRICE);
        uint256[] memory shapeListings = _list(SHAPES, _mintShapes(4), SHAPE_BACKING);
        _enable(true);

        // 1: fills (a Shape). Counts.
        uint256 r1 = _pull();
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(r1, _wordFor(shapeListings[0]));
        pool.processAcquisitions(10);
        assertEq(uint8(_status(r1)), uint8(IFWAPool.AcquisitionStatus.Fulfilled));

        // 2: no word within 30 blocks, expires. Does not count.
        uint256 r2 = _pull();
        vm.roll(vm.getBlockNumber() + 31);
        pool.processAcquisitions(10);
        assertEq(uint8(_status(r2)), uint8(IFWAPool.AcquisitionStatus.Expired));

        // 3: the word arrives after the deadline. Does not count.
        uint256 r3 = _pull();
        vm.roll(vm.getBlockNumber() + 31);
        deliverWord(r3, 7);
        pool.processAcquisitions(10);
        assertEq(uint8(_status(r3)), uint8(IFWAPool.AcquisitionStatus.Expired));

        // 4 and 5 on the same quote: 4 takes a cheap Shape, the fee rises >10%, so 5 refunds on slippage.
        uint256 r4 = _pull();
        uint256 r5 = _pull();
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(r5, 1);
        deliverWord(r4, _wordFor(shapeListings[1]));
        pool.processAcquisitions(10);
        assertEq(uint8(_status(r4)), uint8(IFWAPool.AcquisitionStatus.Fulfilled));
        assertEq(uint8(_status(r5)), uint8(IFWAPool.AcquisitionStatus.Refunded));

        // Two of five requests allocated a prize; expired, timed-out and slippage-refunded requests left the active
        // count untouched. Every still-listed prize survived exactly those two.
        assertEq(pool.activeListingCount(), 6);
        assertEq(_allocated(), 2);
        for (uint256 i; i < 4; ++i) assertEq(_survived(checkListings[i]), 2);
        assertEq(_survived(shapeListings[2]), 2);
        assertEq(_survived(shapeListings[0]), 0, "a won listing has no survival");

        // Refunds are purchaser credits (pull).
        uint256 credit = pool.acquisitionRefundCredit(player);
        assertGt(credit, 0);
        uint256 before = player.balance;
        vm.prank(player);
        pool.withdrawAcquisitionRefund();
        assertEq(player.balance - before, credit);
    }

    // ---------------------------------------------------------------- E4

    function test_E4_pauseDrainWithdrawComposeRelist() public {
        uint256[] memory checks = _takeEighties(2);
        uint256[] memory checkListings = _list(address(CHECKS), checks, CHECK_PRICE);
        uint256[] memory shapeListings = _list(SHAPES, _mintShapes(3), SHAPE_BACKING);
        _enable(true);

        uint256 r1 = _pull();
        _enable(false);
        // Paused: no new draws, and the in-flight one still blocks withdrawal.
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        vm.deal(player, total);
        vm.prank(player);
        vm.expectRevert(bytes4(keccak256("AcquisitionsNotEnabled()")));
        pool.acquire{value: total}(player, fee, 0, 10_000, version, block.timestamp + 1 hours);
        vm.expectRevert(bytes4(keccak256("WithdrawLocked()")));
        lab.exec(address(pool), abi.encodeCall(IFWAPool.withdrawListingsTo, (checkListings, address(lab))));

        // The pending draw settles normally (its player keeps the entitlement).
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(r1, _wordFor(shapeListings[0]));
        pool.processAcquisitions(10);
        assertEq(uint8(_status(r1)), uint8(IFWAPool.AcquisitionStatus.Fulfilled));
        assertEq(_survived(checkListings[0]), 1);

        // Withdraw both, compose, relist the survivor as a new episode.
        _withdraw(checkListings);
        assertEq(CHECKS.ownerOf(checks[0]), address(lab));
        uint256 g = gasleft();
        lab.exec(address(CHECKS), abi.encodeCall(IChecksOriginals.composite, (checks[0], checks[1], false)));
        console2.log("composite 80->40 gas", g - gasleft());
        assertEq(CHECKS.getCheck(checks[0]).stored.divisorIndex, 1);

        uint256[] memory survivor = new uint256[](1);
        survivor[0] = checks[0];
        uint256[] memory relisted = _list(address(CHECKS), survivor, 2 * CHECK_PRICE);
        assertEq(_survived(relisted[0]), 0, "new episode starts at zero");
        assertEq(_survived(checkListings[0]), 0, "old episode ended");

        _enable(true);
        uint256 r2 = _pull();
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(r2, _wordFor(shapeListings[1]));
        pool.processAcquisitions(10);
        assertEq(_survived(relisted[0]), 1);
    }

    // ---------------------------------------------------------------- E8

    function test_E8_repriceLockedWhileUnsettledAndInvalidatesQuotes() public {
        uint256[] memory checkListings = _list(address(CHECKS), _takeEighties(2), CHECK_PRICE);
        uint256[] memory shapeListings = _list(SHAPES, _mintShapes(2), SHAPE_BACKING);
        _enable(true);

        uint256 r1 = _pull();
        vm.expectRevert(bytes4(keccak256("WithdrawLocked()")));
        lab.exec(address(pool), abi.encodeCall(IFWAPool.updatePrice, (checkListings[0], CHECK_PRICE / 2)));

        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(r1, _wordFor(shapeListings[0]));
        pool.processAcquisitions(10);

        (uint256 feeBefore,,) = pool.quoteAcquisitionPrice(1);
        uint256 staleVersion = pool.inventoryVersion();
        lab.exec(address(pool), abi.encodeCall(IFWAPool.updatePrice, (checkListings[0], CHECK_PRICE / 2)));
        (uint256 feeAfter,, uint256 total) = pool.quoteAcquisitionPrice(1);
        assertLt(feeAfter, feeBefore, "a cheaper Check lowers the harmonic-mean fee");
        assertEq(pool.inventoryVersion(), staleVersion + 1);

        vm.deal(player, total);
        vm.prank(player);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("InventoryVersionMismatch(uint256,uint256)")), staleVersion, staleVersion + 1
            )
        );
        pool.acquire{value: total}(player, feeAfter, 0, 10_000, staleVersion, block.timestamp + 1 hours);

        // A repriced listing keeps its survival episode (the listing ID is unchanged).
        assertEq(_survived(checkListings[0]), 1);
    }
}
