// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC721Lite} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {IChecksOriginals} from "../../src/interfaces/IChecks.sol";
import {CollectionPoolOwner} from "../../src/core/CollectionPoolOwner.sol";
import {ChecksDesk} from "../../src/checks/ChecksDesk.sol";
import {Governed} from "../../src/core/Governed.sol";

/// @notice The Checks desk on real Checks and the real FWA pool: composition with a coin burn for a free choice and a
///         free deterministic outcome after the grace (D008), eligibility from survival (D002), Black Check formation
///         from 64 real singles inside the per-transaction gas cap, and buyouts with ETH and coin (D006). Ported from
///         rc2 `test/fork/{Lifecycle,BlackCheck,Custody,Market}.t.sol` onto the collection-games base.
contract DeskForkTest is ForkBase {
    address alice = makeAddr("checks.player.alice");
    address bob = makeAddr("checks.player.bob");
    IChecksOriginals checks;
    uint256 constant LIMIT = 15_099_494; // 90% of EIP-7825's 16,777,216

    /// @dev Token ids that were singles before rc2's fork block (rc2 docs/receipts/single-check-ids.txt); filtered
    ///      for the ones still alive and single here.
    uint16[85] internal SINGLES = [
        1, 9, 13, 14, 21, 22, 32, 35, 36, 38, 42, 48, 54, 57, 62, 65, 70, 73, 77, 84, 88, 105, 109, 111, 123, 136, 139,
        149, 190, 200, 235, 240, 256, 262, 303, 325, 366, 449, 500, 555, 622, 658, 661, 669, 686, 749, 765, 917, 1077,
        1189, 1222, 1237, 1337, 1538, 1776, 1992, 2023, 2212, 2446, 2580, 3675, 4079, 4242, 4455, 4466, 5005, 5050,
        5660, 5678, 6400, 6404, 6661, 7007, 7321, 7379, 7878, 8215, 8888, 9999, 10600, 11662, 12001, 16000, 16007, 16031
    ];

    function setUp() public {
        deployChecks();
        checks = IChecksOriginals(cfg.collection);
        launchGame(cfg.refPrice);
        // a quick pace for the tests: eligible after 2 survived draws, the free deterministic outcome 3 later
        ChecksDesk.ComposeParams memory p = sys.desk.composeParams();
        for (uint256 t; t < 7; ++t) p.drawsToCompose[t] = 2;
        p.graceDraws = 3;
        govern(address(sys.desk), abi.encodeCall(ChecksDesk.setComposeParams, (p)));
    }

    // ------------------------------------------------------------------ helpers

    function _donateId(uint256 id) internal {
        address holder = checks.ownerOf(id);
        vm.startPrank(holder);
        IERC721Lite(cfg.collection).setApprovalForAll(address(sys.vault), true);
        sys.vault.contributeNFT(id);
        vm.stopPrank();
    }

    /// @dev Lists every Check in custody, growing the board with fee capital as the target needs.
    function _listAll() internal {
        for (uint256 i; i < 80 && sys.poolOwner.custodyCount() != 0; ++i) {
            if (i % 4 == 0) accrueFees(5 ether);
            window();
            syncAll();
        }
        assertEq(sys.poolOwner.custodyCount(), 0, "all listed");
    }

    function _listingOf(uint256 tokenId) internal view returns (uint256) {
        for (uint256 i; i < sys.poolOwner.listedCount(); ++i) {
            uint256 id = sys.poolOwner.listedAt(i);
            (uint256 t,,,, bool open,) = sys.poolOwner.cListings(id);
            if (t == tokenId && open) return id;
        }
        revert("not listed");
    }

    /// @dev `n` real draws that each capture a Shape or Pack, restocked as keepers would.
    function _shapeDraws(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            if (!canPull(bob)) {
                window();
                syncAll();
            }
            uint256 r = pull(bob);
            vm.roll(vm.getBlockNumber() + 3);
            deliverWord(r, wordFor(0));
            pool.processAcquisitions(10);
        }
        window();
        syncAll();
    }

    function _coin(address who, uint256 amount) internal {
        pastOpeningCurve();
        buyCoin(who, 1 ether);
        assertGe(sys.token.balanceOf(who), amount, "enough coin");
        vm.prank(who);
        sys.token.approve(address(sys.desk), type(uint256).max);
    }

    /// @dev Two 80-Check listings, both eligible: the launch Check and a donated one.
    function _twoEligible() internal returns (uint256 a, uint256 b) {
        _donateId(nextCheckId());
        _listAll();
        _shapeDraws(2);
        a = sys.poolOwner.listedAt(0);
        b = sys.poolOwner.listedAt(1);
        assertTrue(sys.desk.eligible(a) && sys.desk.eligible(b), "both eligible");
    }

    // ------------------------------------------------------------------ composition

    function test_freeChoiceBurnsCoinAndComposesCanonically() public {
        (uint256 a, uint256 b) = _twoEligible();
        (uint256 ta,,) = sys.desk.listingInfo(a);
        (uint256 tb,,) = sys.desk.listingInfo(b);
        _coin(alice, 1_000 ether);
        uint256 supply = sys.token.totalSupply();
        uint256 bal = sys.token.balanceOf(alice);
        uint256 cost = sys.desk.composeCost(a, b, true);
        assertEq(cost, cfg.compose.composeBurn[0], "a swap is a free choice: it costs the tier's burn");
        vm.prank(alice);
        sys.desk.compose(a, b, true);
        assertEq(sys.token.totalSupply(), supply - cost, "burned");
        assertEq(sys.token.balanceOf(alice), bal - cost);
        assertEq(checks.getCheck(ta).stored.divisorIndex, 1, "the kept Check is a 40 now");
        vm.expectRevert();
        checks.ownerOf(tb); // burned by Checks
        assertEq(sys.poolOwner.tierOf(ta), 1);
        assertEq(uint8(_state(tb)), uint8(CollectionPoolOwner.NftState.Burned));
        assertEq(sys.poolOwner.custodyCount(), 1, "back in custody for a new episode");
        assertEq(sys.poolOwner.listedCount(), 0);
        assertEq(sys.poolOwner.exposureSum(), 0, "both listings closed");
        // the next maintenance lists it at the 40 tier's price, survival from zero
        _listAll();
        uint256 relisted = _listingOf(ta);
        (, uint128 n,,,,) = sys.poolOwner.cListings(relisted);
        assertEq(n, cfg.schedule[1]);
        assertEq(sys.poolOwner.survived(relisted), 0);
        assertBooks();
    }

    function test_deterministicOutcomeIsFreeAfterTheGrace() public {
        (uint256 a, uint256 b) = _twoEligible();
        // keep = more survived draws, the lower id on a tie: here they tie unless the listings started apart
        (uint256 ta,, uint256 da) = sys.desk.listingInfo(a);
        (uint256 tb,, uint256 db) = sys.desk.listingInfo(b);
        (uint256 keep, uint256 burn) = (da > db || (da == db && ta < tb)) ? (a, b) : (b, a);
        assertEq(sys.desk.composeCost(keep, burn, false), cfg.compose.composeBurn[0], "within the grace: still a burn");
        assertEq(sys.desk.composeCost(burn, keep, false), cfg.compose.composeBurn[0], "the other outcome is a choice");
        _shapeDraws(3);
        assertEq(sys.desk.composeCost(keep, burn, false), 0, "past the grace: free");
        assertEq(sys.desk.composeCost(keep, burn, true), cfg.compose.composeBurn[0], "a swap is never free");
        uint256 supply = sys.token.totalSupply();
        vm.prank(makeAddr("anyone")); // no coin, no approval: the free outcome needs neither
        sys.desk.compose(keep, burn, false);
        assertEq(sys.token.totalSupply(), supply, "nothing burned");
    }

    function test_ineligibleCompositionsRevert() public {
        _donateId(nextCheckId());
        _listAll();
        uint256 a = sys.poolOwner.listedAt(0);
        uint256 b = sys.poolOwner.listedAt(1);
        assertFalse(sys.desk.eligible(a), "no draws survived yet");
        vm.expectRevert(ChecksDesk.NotEligible.selector);
        sys.desk.compose(a, b, false);
        _shapeDraws(2);
        vm.expectRevert(ChecksDesk.NotEligible.selector);
        sys.desk.compose(a, a, false);
        vm.expectRevert(ChecksDesk.NotEligible.selector);
        sys.desk.compose(a, 999_999, false);
    }

    /// A composition waits for every draw in flight to settle: the Check stays at risk until withdrawn (spec 6.7).
    function test_compositionWaitsForDrawsInFlightAndBurnsNothingOnFailure() public {
        (uint256 a, uint256 b) = _twoEligible();
        _coin(alice, 1_000 ether);
        uint256 supply = sys.token.totalSupply();
        uint256 r = pull(bob);
        vm.prank(alice);
        vm.expectRevert(CollectionPoolOwner.Busy.selector);
        sys.desk.compose(a, b, true);
        assertEq(sys.token.totalSupply(), supply, "nothing burned");
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(r, wordFor(0));
        pool.processAcquisitions(10);
        // a canonical failure (here forced) reverts everything, the coin burn included
        vm.mockCallRevert(cfg.collection, abi.encodeWithSelector(IChecksOriginals.composite.selector), "no");
        vm.prank(alice);
        vm.expectRevert();
        sys.desk.compose(a, b, true);
        vm.clearMockedCalls();
        assertEq(sys.token.totalSupply(), supply, "nothing burned");
        assertTrue(sys.desk.eligible(a) && sys.desk.eligible(b), "still listed");
    }

    // ------------------------------------------------------------------ buyouts

    function test_buyWithEthAtScheduleAndMarkup() public {
        uint256 id = sys.poolOwner.listedAt(0);
        (uint256 tokenId,,) = sys.desk.listingInfo(id);
        uint256 price = sys.desk.ethPrice(id);
        assertEq(price, cfg.schedule[0] * 12_500 / 10_000, "schedule + 25%");
        vm.deal(alice, 2 ether);
        vm.prank(alice);
        vm.expectRevert(ChecksDesk.Underpaid.selector);
        sys.desk.buyWithEth{value: price - 1}(id);
        uint256 vaultBefore = address(sys.vault).balance;
        vm.prank(alice);
        sys.desk.buyWithEth{value: 1 ether}(id);
        assertEq(checks.ownerOf(tokenId), alice);
        assertEq(alice.balance, 2 ether - price, "the excess came back");
        assertEq(address(sys.vault).balance - vaultBefore, price, "the price funds acquisitions");
        assertEq(uint8(_state(tokenId)), uint8(CollectionPoolOwner.NftState.Sold));
        assertEq(sys.poolOwner.listedCount(), 0);
        assertEq(sys.poolOwner.exposureSum(), 0);
        assertTrue(pool.localPurchasesEnabled() || !sys.game.admissible(), "the game carries on with Shapes");
    }

    function test_coinBuyoutsLaunchDisabledAndAreTheCouncils() public {
        uint256 id = sys.poolOwner.listedAt(0);
        (uint256 tokenId,,) = sys.desk.listingInfo(id);
        _coin(alice, 5_000 ether);
        vm.prank(alice);
        vm.expectRevert(ChecksDesk.Disabled.selector);
        sys.desk.buyWithCoin(id);
        ChecksDesk.BuyoutParams memory b = sys.desk.buyoutParams();
        b.coinPrice[0] = 5_000 ether;
        vm.prank(owner);
        vm.expectRevert(Governed.NotCouncil.selector);
        sys.desk.setBuyoutParams(b);
        councilCall(address(sys.desk), abi.encodeCall(ChecksDesk.setBuyoutParams, (b)));
        uint256 supply = sys.token.totalSupply();
        vm.prank(alice);
        sys.desk.buyWithCoin(id);
        assertEq(checks.ownerOf(tokenId), alice);
        assertEq(sys.token.totalSupply(), supply - 5_000 ether, "every coin paid is burned");
        // the ETH markup can never go below 10% (D012)
        b.ethMarkupBps = 999;
        vm.prank(council);
        vm.expectRevert(Governed.OutOfBounds.selector);
        sys.desk.setBuyoutParams(b);
    }

    function test_buyoutWaitsForDrawsInFlight() public {
        uint256 id = sys.poolOwner.listedAt(0);
        uint256 price = sys.desk.ethPrice(id);
        pull(bob);
        vm.deal(alice, price);
        vm.prank(alice);
        vm.expectRevert(CollectionPoolOwner.Busy.selector);
        sys.desk.buyWithEth{value: price}(id);
        assertEq(alice.balance, price, "nothing taken");
    }

    // ------------------------------------------------------------------ Black Check

    /// 64 real singles, listed and eligible, form a Black Check in one transaction within the gas cap's margin.
    function test_formBlackFromSixtyFourRealSingles() public {
        uint256[] memory ids = new uint256[](64);
        uint256 n;
        for (uint256 i; i < SINGLES.length && n < 64; ++i) {
            uint256 id = SINGLES[i];
            try checks.ownerOf(id) returns (address o) {
                if (o == address(0) || checks.getCheck(id).stored.divisorIndex != 6) continue;
                ids[n++] = id;
            } catch {}
        }
        assertEq(n, 64, "64 living singles at the fork block");
        for (uint256 i; i < 64; ++i) {
            _donateId(ids[i]);
        }
        _listAll();
        _shapeDraws(2);
        uint256[] memory listings = new uint256[](64);
        for (uint256 i; i < 64; ++i) {
            listings[i] = _listingOf(ids[i]); // ascending token ids
        }
        ChecksDesk.ComposeParams memory p = sys.desk.composeParams();
        p.graceDraws = 0;
        govern(address(sys.desk), abi.encodeCall(ChecksDesk.setComposeParams, (p)));
        assertEq(sys.desk.formBlackCost(listings), 0, "ascending and past the grace: free");
        uint256 supply = checks.totalSupply();
        uint256 g = gasleft();
        vm.prank(alice);
        sys.desk.formBlack(listings);
        uint256 used = g - gasleft();
        emit log_named_uint("formBlack: 64 withdrawals + infinity (gas)", used);
        assertLt(used, LIMIT, "within EIP-7825's cap with a 10% margin");
        assertEq(checks.getCheck(ids[0]).stored.divisorIndex, 7, "a Black Check");
        assertEq(checks.ownerOf(ids[0]), address(sys.poolOwner));
        assertEq(checks.totalSupply(), supply - 63);
        assertEq(sys.poolOwner.tierOf(ids[0]), 7);
        assertEq(sys.poolOwner.burnedCount(), 63);
        // it is listed again at the Black tier's schedule price, a prize like any other (invariant 2)
        _listAll();
        (, uint128 notional,,,,) = sys.poolOwner.cListings(_listingOf(ids[0]));
        assertEq(notional, cfg.schedule[7]);
        assertBooks();
    }

    function test_formBlackRejectsWrongInputs() public {
        vm.expectRevert(ChecksDesk.BadInput.selector);
        sys.desk.formBlack(new uint256[](63));
        uint256[] memory l = new uint256[](64);
        l[0] = sys.poolOwner.listedAt(0); // an 80, not a single
        vm.expectRevert(ChecksDesk.NotEligible.selector);
        sys.desk.formBlack(l);
    }

    function _state(uint256 tokenId) internal view returns (CollectionPoolOwner.NftState s) {
        (,,,, s,) = sys.poolOwner.nfts(tokenId);
    }
}
