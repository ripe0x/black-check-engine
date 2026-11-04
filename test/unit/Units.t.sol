// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Governed} from "../../src/core/Governed.sol";
import {CollectionToken} from "../../src/token/CollectionToken.sol";
import {CollectionBurner} from "../../src/treasury/CollectionBurner.sol";
import {Admin} from "../../src/core/Admin.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";

/// @dev A minimal governed contract: an owner-only setting with a bound, for the administration tests.
contract GovernedSample is Governed {
    uint256 public value;

    constructor(address admin_) Governed(admin_, false) {}

    function set(uint256 v) external onlyOwner {
        if (v > 10_000) revert OutOfBounds();
        value = v;
    }
}

/// @dev Stands in for the game for the burner: the source of surplus, can be retired, quotes no tip.
contract MockGame {
    bool public retired;

    function setRetired(bool r) external {
        retired = r;
    }

    function quoteTip(uint256) external pure returns (uint256) {
        return 0;
    }

    function send(address to) external payable {
        (bool ok,) = to.call{value: msg.value}("");
        require(ok);
    }
}

/// @dev Stands in for the pool owner and its FWA pool for the burner's milestone reserve: listing 7 is a collection
///      listing.
contract MockOwnerPool {
    IFWAPool.ListingStatus public st = IFWAPool.ListingStatus.Active;
    address public purchaser;

    function pool() external view returns (address) {
        return address(this);
    }

    /// Listings 5-7 are Apes; 8 is a prize listed at 0.6 ETH (a big prize); the rest are small prizes.
    function isCollectionListing(uint256 id) external pure returns (bool) {
        return id >= 5 && id <= 7;
    }

    function set(IFWAPool.ListingStatus s, address p) external {
        st = s;
        purchaser = p;
    }

    function listings(uint256 id)
        external
        view
        returns (address, address, address, uint256, uint256, uint256, uint256, IFWAPool.ListingStatus)
    {
        return (address(0), address(this), purchaser, 1, 1, id == 8 ? 0.6 ether : 0.1 ether, 1, st);
    }

    function lastIssuedSequence() external pure returns (uint64) {
        return 0;
    }
}

/// @notice Unit tests (no fork): governance, token, the burner's milestone reserve.
contract UnitsTest is Test {
    address owner = makeAddr("cg.unit.owner");
    Admin adm = new Admin(owner, makeAddr("council"));
    address admAddr = address(adm);

    // ------------------------------------------------------------------ token

    function test_tokenFixedSupplyBurnOnly() public {
        address[] memory to = new address[](1);
        uint256[] memory a = new uint256[](1);
        (to[0], a[0]) = (address(this), 1e27);
        CollectionToken t = new CollectionToken("Coin", "C", "", "", 1e27, to, a, address(this), address(this), address(this));
        assertEq(t.totalSupply(), 1e27);
        assertEq(t.decimals(), 18);
        t.burn(1e18);
        assertEq(t.totalSupply(), 1e27 - 1e18);
        a[0] = 1;
        vm.expectRevert(CollectionToken.SupplyMismatch.selector);
        new CollectionToken("Coin", "C", "", "", 1e27, to, a, address(this), address(this), address(this));
    }

    function testFuzz_tokenSupplyNeverIncreases(uint96 burnAmt) public {
        address[] memory to = new address[](1);
        uint256[] memory a = new uint256[](1);
        (to[0], a[0]) = (address(this), 1e27);
        CollectionToken t = new CollectionToken("Coin", "C", "", "", 1e27, to, a, address(this), address(this), address(this));
        uint256 b = uint256(burnAmt) % 1e27;
        t.burn(b);
        assertLe(t.totalSupply(), 1e27);
        assertEq(t.totalSupply() + b, 1e27);
    }

    // ------------------------------------------------------------------ administration

    /// One owner, read from the Admin contract by every governed contract: it acts at once; nobody else can.
    function test_ownerAdministersDirectly() public {
        GovernedSample pp = new GovernedSample(admAddr);
        vm.prank(owner);
        pp.set(0);
        assertEq(pp.value(), 0);
        vm.prank(owner);
        pp.set(10_000);
        vm.prank(owner);
        vm.expectRevert(Governed.OutOfBounds.selector);
        pp.set(10_001);
        vm.prank(makeAddr("cg.unit.stranger"));
        vm.expectRevert(Governed.NotOwner.selector);
        pp.set(500);
    }

    /// Two-step transfer moves administration of every contract at once; renouncing ends it for good.
    function test_twoStepTransferAndRenounce() public {
        GovernedSample pp = new GovernedSample(admAddr);
        address next = makeAddr("cg.unit.next");
        vm.prank(next);
        vm.expectRevert(Admin.NotOwner.selector);
        adm.transferOwnership(next);
        vm.prank(owner);
        adm.transferOwnership(next);
        assertEq(adm.owner(), owner, "nothing changes until accepted");
        vm.prank(makeAddr("cg.unit.stranger"));
        vm.expectRevert(Admin.NotPendingOwner.selector);
        adm.acceptOwnership();
        vm.prank(next);
        adm.acceptOwnership();
        assertEq(adm.owner(), next);
        assertEq(pp.owner(), next, "every contract follows the Admin");
        vm.prank(owner);
        vm.expectRevert(Governed.NotOwner.selector);
        pp.set(600);
        vm.prank(next);
        pp.set(600);
        // renounce: nobody administers anything again
        vm.prank(next);
        adm.renounceOwnership();
        assertEq(adm.owner(), address(0));
        vm.prank(next);
        vm.expectRevert(Governed.NotOwner.selector);
        pp.set(700);
        vm.prank(address(0));
        vm.expectRevert(Governed.NotOwner.selector);
        pp.set(700);
    }

    // ------------------------------------------------------------------ the burner's milestone reserve

    function _burner() internal returns (CollectionBurner b, MockGame game, MockOwnerPool op) {
        address[] memory to = new address[](1);
        uint256[] memory a = new uint256[](1);
        (to[0], a[0]) = (address(this), 1e27);
        CollectionToken t = new CollectionToken("Coin", "C", "", "", 1e27, to, a, address(this), address(this), address(this));
        b = new CollectionBurner(
            admAddr,
            IPoolManager(address(1)),
            address(t),
            CollectionBurner.Cadence(0.05 ether, 0.005 ether, 100, 1 ether, 60 minutes, 10 minutes, 20, 300, 200),
            CollectionBurner.Tiers(0.5 ether, 1_500, 6_000, 24 hours),
            7_500
        );
        game = new MockGame();
        op = new MockOwnerPool();
        b.wire(address(1), address(game), address(op));
    }

    /// The game's surplus is split into the locked reserve (75%) and ongoing; anything else is ongoing.
    function test_burnerSplitsTheGamesSurplus() public {
        (CollectionBurner b, MockGame game,) = _burner();
        vm.deal(address(this), 5 ether);
        game.send{value: 4 ether}(address(b));
        assertEq(b.reserve(), 3 ether);
        assertEq(b.ongoingBalance(), 1 ether);
        (bool ok,) = address(b).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(b.reserve(), 3 ether, "a donation never reaches the reserve");
        assertEq(b.ongoingBalance(), 2 ether);
    }

    /// The cadence and tiers are the owner's, inside hard bounds no owner can pass.
    function test_burnerHardBounds() public {
        (CollectionBurner b,,) = _burner();
        CollectionBurner.Cadence memory c = b.cadence();
        vm.startPrank(owner);
        c.maxSliceWei = 1 ether + 1;
        vm.expectRevert(Governed.OutOfBounds.selector);
        b.setCadence(c);
        c.maxSliceWei = 1 ether;
        c.minSpacing = 10 minutes - 1;
        vm.expectRevert(Governed.OutOfBounds.selector);
        b.setCadence(c);
        c.minSpacing = 10 minutes;
        c.maxImpactBps = 501;
        vm.expectRevert(Governed.OutOfBounds.selector);
        b.setCadence(c);
        c.maxImpactBps = 500;
        c.maxDeviationBps = 301;
        vm.expectRevert(Governed.OutOfBounds.selector);
        b.setCadence(c);
        c.maxDeviationBps = 300;
        b.setCadence(c);
        CollectionBurner.Tiers memory t = b.tiers();
        t.exitWindow = 7 days + 1;
        vm.expectRevert(Governed.OutOfBounds.selector);
        b.setTiers(t);
        t.exitWindow = 7 days;
        t.firstExitBps = 10_001;
        vm.expectRevert(Governed.OutOfBounds.selector);
        b.setTiers(t);
        t.firstExitBps = 999; // an Ape exit always releases at least 10%: the reserve can never be locked for good
        vm.expectRevert(Governed.OutOfBounds.selector);
        b.setTiers(t);
        t.firstExitBps = 10_000;
        b.setTiers(t);
        vm.stopPrank();
        vm.expectRevert(Governed.NotOwner.selector);
        b.setTiers(t);
    }

    /// The reserve is released in tiers, only for delivered wins read from FWA, once per listing: a big prize 15%, an
    /// Ape exit 60%, a second Ape exit within 24 hours the rest; after retirement, everything left.
    function test_milestoneTiersOnlyOnDeliveredWinsOnce() public {
        (CollectionBurner b, MockGame game, MockOwnerPool op) = _burner();
        vm.deal(address(this), 12 ether);
        game.send{value: 8 ether}(address(b));
        assertEq(b.reserve(), 6 ether);
        // not delivered yet
        vm.expectRevert(CollectionBurner.NotQualifying.selector);
        b.release(7);
        op.set(IFWAPool.ListingStatus.Settled, makeAddr("cg.unit.winner"));
        // a small prize never releases
        vm.expectRevert(CollectionBurner.NotQualifying.selector);
        b.release(9);
        // a refunded delivery never qualifies
        op.set(IFWAPool.ListingStatus.DeliveryRefunded, makeAddr("cg.unit.winner"));
        vm.expectRevert(CollectionBurner.NotQualifying.selector);
        b.release(7);
        op.set(IFWAPool.ListingStatus.Settled, makeAddr("cg.unit.winner"));
        // a big prize: 15%
        assertEq(b.release(8), 0.9 ether);
        assertEq(b.reserve(), 5.1 ether);
        // an Ape exit: 60% of what is left
        assertEq(b.release(7), 3.06 ether);
        assertEq(b.lastExitAt(), vm.getBlockTimestamp());
        vm.expectRevert(CollectionBurner.AlreadyReleased.selector);
        b.release(7);
        // a second Ape exit within 24 hours: the rest
        vm.warp(vm.getBlockTimestamp() + 23 hours);
        assertEq(b.release(6), 2.04 ether);
        assertEq(b.reserve(), 0);
        assertEq(b.milestoneBalance(), 6 ether, "everything released ends in buybacks");
        // a later exit, past the window, is a first exit again
        game.send{value: 4 ether}(address(b));
        vm.warp(vm.getBlockTimestamp() + 25 hours);
        assertEq(b.release(5), 1.8 ether, "60% of 3 ETH");
        // retirement: the rest
        vm.expectRevert(CollectionBurner.NotRetired.selector);
        b.releaseRetired();
        game.setRetired(true);
        assertEq(b.releaseRetired(), 1.2 ether);
        assertEq(b.reserve(), 0);
        assertEq(b.milestoneIn(), 9 ether);
    }

    receive() external payable {}
}
