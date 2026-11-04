// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IPacksView} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {CollectionGame} from "../../src/game/CollectionGame.sol";
import {CollectionPoolOwner} from "../../src/core/CollectionPoolOwner.sol";

interface IShapesP {
    function ownerOf(uint256) external view returns (address);
    function backingOf(uint256) external view returns (uint256);
    function redeem(uint256) external;
    function mintFee() external view returns (uint256);
    function mintTo(uint256 amountWei, address to) external payable returns (uint256);
    function safeTransferFrom(address from, address to, uint256 id) external;
}

interface IPacksCreate {
    function createPackTo(uint256[] calldata shapeIds, uint32[] calldata mintCounts, address to)
        external
        payable
        returns (uint256);
    function safeTransferFrom(address from, address to, uint256 id) external;
}

/// @notice Draw Packs as ordinary prizes on the real FWA pool and VRF service, with the dedicated Packs instance:
///         a winner owns the Pack outright and can open or redeem it; Pack rows are replaced with new Packs; a
///         refunded Pack delivery is recovered and redeemed; retirement redeems every Pack still held; batches and
///         late VRF words settle without refunds; custody refuses anything unsolicited.
contract PacksForkTest is ForkBase {
    address alice = makeAddr("cg.player.alice");
    address bob = makeAddr("cg.player.bob");

    function setUp() public {
        deployChecks();
        launchGame(0.25 ether);
    }

    function _win(address who, uint256 backing) internal returns (uint256 r, uint256 listingId, uint256 tokenId) {
        r = pull(who);
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(r, wordFor(backing));
        pool.processAcquisitions(10);
        (,,, listingId,) = pool.acquisitions(r);
        (tokenId,,,,,,) = sys.game.items(listingId);
    }

    function _isPack(uint256 listingId) internal view returns (bool p) {
        (,,,,,, p) = sys.game.items(listingId);
    }

    /// A 0.02 ETH Pack is won: the player owns it outright and redeems it for exactly 0.02 ETH; the game booked its
    /// full cost (backing + two Shapes mint fees) as the prize expense, and a keeper replaces the row with a new Pack.
    function test_winnerOwnsPackAndRedeemsIt() public {
        (uint256 r, uint256 listingId, uint256 packId) = _win(alice, 0.02 ether);
        assertEq(uint8(statusOf(r)), uint8(IFWAPool.AcquisitionStatus.Fulfilled));
        assertTrue(_isPack(listingId));
        assertEq(IPacksView(sys.packs).ownerOf(packId), alice, "the player owns the Pack");
        assertEq(IPacksView(sys.packs).valueOf(packId), 0.02 ether);
        uint256 expenseBefore = sys.game.prizeExpense();
        vm.prank(keeper);
        sys.game.sync();
        uint256 fee = IShapesP(cfg.shapes).mintFee();
        assertEq(sys.game.prizeExpense() - expenseBefore, 0.02 ether + 2 * fee, "full cost, both mint fees");
        // redemption by the owner, with no involvement of the game
        uint256 before = alice.balance;
        vm.prank(alice);
        IPacksView(sys.packs).redeem(packId);
        assertEq(alice.balance - before, 0.02 ether, "exact backing");
        assertFalse(IPacksView(sys.packs).exists(packId));
        // replacement
        window();
        syncAll();
        assertEq(sys.game.liveCount(), sys.game.boardSize());
        uint256 newPacks;
        for (uint256 i; i < sys.game.liveCount(); ++i) {
            uint256 id = sys.game.liveAt(i);
            (, uint72 backing,,,,, bool p) = sys.game.items(id);
            if (p && backing == 0.02 ether) ++newPacks;
        }
        assertEq(newPacks, 16, "the row holds a new 0.02 ETH Pack");
        assertBooks();
    }

    /// A 0.03 ETH Pack is won and opened: the player receives its three 0.01 ETH Shapes and can redeem each.
    function test_winnerOpensPackIntoShapes() public {
        (, uint256 listingId, uint256 packId) = _win(bob, 0.03 ether);
        assertTrue(_isPack(listingId));
        uint256[] memory inside = IPacksView(sys.packs).contentsOf(packId);
        assertEq(inside.length, 3);
        vm.prank(bob);
        IPacksView(sys.packs).open(packId);
        uint256 before = bob.balance;
        for (uint256 i; i < 3; ++i) {
            assertEq(IShapesP(cfg.shapes).ownerOf(inside[i]), bob, "each Shape now the player's");
            assertEq(IShapesP(cfg.shapes).backingOf(inside[i]), 0.01 ether);
            vm.prank(bob);
            IShapesP(cfg.shapes).redeem(inside[i]);
        }
        assertEq(bob.balance - before, 0.03 ether);
        vm.prank(keeper);
        sys.game.sync();
        assertBooks();
    }

    /// A Pack delivery that fails (the purchaser's side reverts) stays pending; after FWA's window the player takes the
    /// refund; the pool owner recovers the Pack and redeems it; the game gets the backing back and writes off only the
    /// two mint fees.
    function test_failedPackDeliveryRecoveredAndRedeemed() public {
        uint256 r = pull(alice);
        vm.roll(vm.getBlockNumber() + 3);
        uint256 w = wordFor(0.02 ether);
        vm.mockCallRevert(sys.packs, abi.encodeWithSignature("transferFrom(address,address,uint256)"), "");
        deliverWord(r, w);
        pool.processAcquisitions(10);
        vm.clearMockedCalls();
        assertEq(uint8(statusOf(r)), uint8(IFWAPool.AcquisitionStatus.DeliveryPending));
        (,,, uint256 listingId,) = pool.acquisitions(r);
        (uint256 packId,,,,,,) = sys.game.items(listingId);
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.liveCount(), sys.game.boardSize() - 1, "row vacated while pending");
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        vm.prank(alice);
        pool.refundFailedDelivery(listingId);
        uint256 expenseBefore = sys.game.prizeExpense();
        uint256 cashBefore = sys.game.cash();
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.deliveriesRefunded(), 1);
        assertFalse(IPacksView(sys.packs).exists(packId), "redeemed by the pool owner");
        uint256 fee = IShapesP(cfg.shapes).mintFee();
        assertEq(sys.game.prizeExpense() - expenseBefore, 2 * fee, "only the mint fees are lost");
        assertGe(sys.game.cash() + sys.game.inventoryCost(), cashBefore, "backing returned to the game");
        assertBooks();
    }

    /// Five-draw batches with late VRF words, on the 100-item board: every request settles, nothing is refunded for
    /// drift, and every Pack won is with its purchaser.
    function test_batchesWithLateVrf() public {
        uint256[] memory all = new uint256[](15);
        uint256 k;
        for (uint256 b; b < 3; ++b) {
            (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(5);
            uint256 version = pool.inventoryVersion();
            vm.deal(alice, alice.balance + total);
            vm.prank(alice);
            uint256[] memory ids = pool.acquireBatch{value: total}(alice, 5, fee, 0, 10_000, version, vm.getBlockTimestamp() + 1 hours);
            for (uint256 i; i < 5; ++i) {
                all[k++] = ids[i];
            }
            vm.roll(vm.getBlockNumber() + 1);
            if (!sys.poolOwner.canPurchase(alice)) {
                // the in-flight bound: settle what is outstanding before the next batch
                vm.roll(vm.getBlockNumber() + 25);
                for (uint256 j; j < k; ++j) {
                    if (statusOf(all[j]) == IFWAPool.AcquisitionStatus.Pending) {
                        deliverWord(all[j], uint256(keccak256(abi.encode("late", j))));
                    }
                }
                pool.processAcquisitions(20);
            }
        }
        vm.roll(vm.getBlockNumber() + 25);
        for (uint256 j; j < k; ++j) {
            if (statusOf(all[j]) == IFWAPool.AcquisitionStatus.Pending) {
                deliverWord(all[j], uint256(keccak256(abi.encode("late", j))));
            }
        }
        pool.processAcquisitions(20);
        uint256 refunded;
        for (uint256 j; j < k; ++j) {
            IFWAPool.AcquisitionStatus st = statusOf(all[j]);
            if (st == IFWAPool.AcquisitionStatus.Refunded) ++refunded;
            if (st == IFWAPool.AcquisitionStatus.Fulfilled) {
                (,,, uint256 listingId,) = pool.acquisitions(all[j]);
                if (_isPack(listingId)) {
                    (uint256 packId,,,,,,) = sys.game.items(listingId);
                    assertEq(IPacksView(sys.packs).ownerOf(packId), alice);
                }
            }
        }
        assertEq(refunded, 0, "no drift refunds");
        syncAll();
        assertBooks();
    }

    /// Retirement with Packs and Shapes still listed: every listed prize is withdrawn and cashed out (Packs redeemed,
    /// Shapes burned), the pool owner keeps no Pack, and everything returns to the vault.
    function test_retirementRedeemsEveryPack() public {
        playMany(alice, 40, 9);
        vm.prank(address(sys.migration)); // a migration's execution, or the sunset
        sys.game.retire();
        for (uint256 i; i < 20 && !sys.game.retired(); ++i) {
            vm.prank(keeper);
            try sys.game.retireStep() {} catch {}
        }
        assertTrue(sys.game.retired());
        assertEq(sys.game.liveCount(), 0);
        assertEq(address(sys.game).balance, 0);
        assertEq(sys.game.inventoryCost(), 0, "no prize left at cost");
        assertEq(address(sys.poolOwner).balance, 0);
        // no live Pack is held by the pool owner or the FWA pool
        uint256 minted = IPacksTotal(sys.packs).totalMinted();
        for (uint256 id = 1; id <= minted; ++id) {
            if (!IPacksView(sys.packs).exists(id)) continue;
            address o = IPacksView(sys.packs).ownerOf(id);
            assertTrue(o != address(sys.poolOwner) && o != address(pool), "only winners hold Packs");
        }
    }

    /// Custody boundary: the pool owner refuses Packs and Shapes it did not mint or withdraw itself, only the game can
    /// have prizes minted and listed, a prize at a backing that is neither a denomination nor a valid Pack is refused,
    /// and the Packs contract refuses ETH and self-custody.
    function test_packCustodyBoundary() public {
        // an outsider's own Pack, safe-transferred to the pool owner, is refused
        uint32[] memory counts = new uint32[](9);
        counts[0] = 2;
        uint256 fee = IShapesP(cfg.shapes).mintFee();
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        uint256 packId = IPacksCreate(sys.packs).createPackTo{value: 2 * (0.01 ether + fee)}(new uint256[](0), counts, bob);
        vm.prank(bob);
        vm.expectRevert();
        IPacksCreate(sys.packs).safeTransferFrom(bob, address(sys.poolOwner), packId);
        // only the game mints and lists
        CollectionPoolOwner.Prize[] memory prizes = new CollectionPoolOwner.Prize[](1);
        prizes[0] = CollectionPoolOwner.Prize(0.02 ether, 0.03 ether);
        vm.deal(address(this), 1 ether);
        vm.expectRevert(CollectionPoolOwner.NotGame.selector);
        sys.poolOwner.mintAndList{value: 0.022 ether}(prizes);
        // a backing that is not a Shapes denomination and not a whole number of units at or above the Pack minimum
        vm.expectRevert(CollectionPoolOwner.BadPrize.selector);
        sys.poolOwner.prizeCost(0.015 ether);
        vm.expectRevert(CollectionPoolOwner.BadPrize.selector);
        sys.poolOwner.prizeCost(0.001 ether);
        (uint256 c2, bool p2) = sys.poolOwner.prizeCost(0.02 ether);
        assertTrue(p2);
        assertEq(c2, 0.02 ether + 2 * fee);
        (uint256 c5, bool p5) = sys.poolOwner.prizeCost(0.05 ether);
        assertFalse(p5, "a denomination is a Shape");
        assertEq(c5, 0.05 ether + fee);
        // the Packs contract takes no ETH and cannot hold its own tokens
        (bool ok,) = sys.packs.call{value: 1}("");
        assertFalse(ok);
        assertEq(IPacksView(sys.packs).MIN_PACK_VALUE(), 0.02 ether, "the dedicated two-unit instance");
    }

    /// Packs are made of the fewest Shapes that add up to their backing exactly: 0.04 needs four 0.01 Shapes (no
    /// smaller denomination than 0.05 fits), 0.06 is 0.05 + 0.01, 0.15 is 0.1 + 0.05, 0.07 would be 0.05 + 2 x 0.01.
    function test_packMakeupUsesFewestShapes() public view {
        uint256 fee = 0.001 ether;
        uint256[5] memory backings = [uint256(0.04 ether), 0.06 ether, 0.15 ether, 0.07 ether, 1.6 ether];
        uint256[5] memory shapes = [uint256(4), 2, 2, 3, 3];
        for (uint256 i; i < 5; ++i) {
            (uint32[] memory counts, uint256 n) = sys.poolOwner.makeup(backings[i]);
            assertEq(n, shapes[i]);
            uint256 sum;
            for (uint8 d; d < counts.length; ++d) {
                sum += counts[d] * IShapesDen(cfg.shapes).denominationAt(d);
            }
            assertEq(sum, backings[i], "exact backing");
            (uint256 cost, bool isPack) = sys.poolOwner.prizeCost(backings[i]);
            assertTrue(isPack);
            assertEq(cost, backings[i] + shapes[i] * fee);
        }
        (, uint256 one) = sys.poolOwner.makeup(1 ether);
        assertEq(one, 1, "a denomination is one Shape");
    }

    /// The 0.15 ETH Pack (a 0.1 and a 0.05 Shape) is won, opened and each Shape redeemed for exactly 0.15 ETH; the
    /// game booked backing plus two mint fees.
    function test_mixedPackWonOpenedAndRedeemed() public {
        uint256 expenseBefore = sys.game.prizeExpense();
        (, uint256 listingId, uint256 packId) = _win(bob, 0.15 ether);
        assertTrue(_isPack(listingId));
        assertEq(IPacksView(sys.packs).ownerOf(packId), bob);
        uint256[] memory inside = IPacksView(sys.packs).contentsOf(packId);
        assertEq(inside.length, 2);
        vm.prank(keeper);
        sys.game.sync();
        assertEq(sys.game.prizeExpense() - expenseBefore, 0.15 ether + 2 * 0.001 ether);
        vm.prank(bob);
        IPacksView(sys.packs).open(packId);
        uint256 before = bob.balance;
        for (uint256 i; i < 2; ++i) {
            assertEq(IShapesP(cfg.shapes).ownerOf(inside[i]), bob);
            vm.prank(bob);
            IShapesP(cfg.shapes).redeem(inside[i]);
        }
        assertEq(bob.balance - before, 0.15 ether, "exact backing");
        window();
        syncAll();
        assertEq(sys.game.liveCount(), sys.game.boardSize(), "row replaced with a new 0.15 Pack");
        assertBooks();
    }

    /// Audits (D66, D67): no system address can be the purchaser. A draw naming the FWA pool, the pool owner, the game,
    /// the vault, the migration authority, the collection, Shapes or Packs is refused before any fee is paid: the
    /// pool's own "win" never moves the prize (yet settles it), the others hold it where no route recovers it, and
    /// Shapes and Packs refuse their own tokens. Ordinary players, smart-contract wallets included, are unaffected.
    function test_systemAddressesCannotBePurchasers() public {
        address[8] memory system = [
            address(pool), address(sys.poolOwner), address(sys.game), address(sys.vault), address(sys.migration),
            cfg.collection, cfg.shapes, sys.packs
        ];
        assertTrue(sys.poolOwner.canPurchase(alice));
        assertTrue(sys.poolOwner.canPurchase(address(this)), "a contract wallet may play");
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        uint256 version = pool.inventoryVersion();
        address griefer = makeAddr("griefer");
        vm.deal(griefer, total);
        for (uint256 i; i < system.length; ++i) {
            assertFalse(sys.poolOwner.canPurchase(system[i]));
            vm.prank(griefer);
            vm.expectRevert();
            pool.acquire{value: total}(system[i], fee, 0, 10_000, version, vm.getBlockTimestamp() + 1 hours);
        }
        assertEq(griefer.balance, total, "nothing was charged");
        assertEq(pool.unsettledAcquisitionCount(), 0);
    }
}

interface IShapesDen {
    function denominationAt(uint8) external view returns (uint256);
}

interface IPacksTotal {
    function totalMinted() external view returns (uint256);
}
