// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC721Lite} from "./ForkBase.sol";
import {CollectionGame} from "../../src/game/CollectionGame.sol";
import {CollectionPoolOwner} from "../../src/core/CollectionPoolOwner.sol";

/// @notice Every maintenance transaction fits EIP-7825's per-transaction gas cap (2^24 = 16,777,216 gas, mainnet since
///         Fusaka), in the worst case the board allows (D61): a board made only of the heaviest prize (the 0.04 ETH
///         Pack, four Shapes minted and packed per listing); a keeper call that books a batch of wins, relists a full
///         batch of those Packs (`maxPerCall`, 8 at launch) and lists a full batch of Apes; a call that reprices a
///         batch of Apes; and the owner growing the board by 50 rows. Each is measured as one `sync` and must stay under the cap with a 10% margin,
///         at the launch settings and at the setters' ceilings (D81).
contract TxCapForkTest is ForkBase {
    uint256 constant CAP = 16_777_216;
    uint256 constant LIMIT = 15_099_494; // 90% of the cap
    address alice = makeAddr("cg.cap.alice");

    function setUp() public {
        setUpFork();
        cfg = _baycConfig(owner);
        uint256[] memory heavy = new uint256[](1);
        heavy[0] = 0.04 ether; // the heaviest prize per listing: a Pack of four 0.01 Shapes
        cfg.boardPattern = heavy;
        _deploy();
    }

    function _sync() internal returns (uint256 used) {
        uint256 g = gasleft();
        vm.prank(keeper);
        try sys.game.sync() {} catch {}
        used = g - gasleft();
    }

    function _notional(uint256 i) internal view returns (uint256) {
        (, uint128 n,,,) = sys.poolOwner.cListings(sys.poolOwner.listedAt(i));
        return n;
    }

    /// The opening board of 100 heaviest Packs is listed in calls that each fit the cap.
    function test_heaviestOpeningBoardFitsTheCap() public {
        createPool();
        openMarket();
        accrueFees(6.05 ether);
        riseBidTo(6 ether);
        sellApeAt(nextApeId(), 6 ether);
        accrueFees(sys.game.capitalNeed() + 0.1 ether);
        uint256 maxGas;
        uint256 calls;
        for (uint256 i; i < 40 && sys.game.liveCount() < sys.game.boardSize(); ++i) {
            uint256 used = _sync();
            if (used > maxGas) maxGas = used;
            ++calls;
        }
        assertEq(sys.game.liveCount(), sys.game.boardSize(), "board listed");
        emit log_named_uint("calls to list 100 heaviest Packs", calls);
        emit log_named_uint("largest call (gas)", maxGas);
        assertLt(maxGas, LIMIT, "within the cap with a 10% margin");
    }

    /// The owner grows a board of the heaviest prize by 50 rows: the new rows list in calls that each fit the cap.
    function test_heaviestBoardGrowthFitsTheCap() public {
        launchGame(6 ether);
        accrueFees(30 ether);
        uint256 size = sys.game.boardSize();
        govern(address(sys.game), abi.encodeCall(CollectionGame.setBoardSize, (size + 50)));
        uint256 maxGas;
        uint256 calls;
        for (uint256 i; i < 60 && sys.game.liveCount() < sys.game.boardSize(); ++i) {
            window();
            uint256 used = _sync();
            if (used > maxGas) maxGas = used;
            ++calls;
        }
        assertEq(sys.game.liveCount(), size + 50, "the grown board listed");
        emit log_named_uint("growth calls", calls);
        emit log_named_uint("largest growth call (gas)", maxGas);
        assertLt(maxGas, LIMIT, "within the cap with a 10% margin");
    }

    /// Retirement withdraws and unwinds every listed Pack (and the Apes) in calls that each fit the cap.
    function test_heaviestRetirementFitsTheCap() public {
        launchGame(6 ether);
        vm.prank(address(sys.migration)); // a migration's execution (or the sunset) retires the game
        sys.game.retire();
        uint256 maxGas;
        uint256 calls;
        for (uint256 i; i < 40 && !sys.game.retired(); ++i) {
            uint256 g = gasleft();
            vm.prank(keeper);
            sys.game.retireStep();
            uint256 used = g - gasleft();
            if (used > maxGas) maxGas = used;
            ++calls;
        }
        assertTrue(sys.game.retired());
        emit log_named_uint("retirement calls", calls);
        emit log_named_uint("largest retirement call (gas)", maxGas);
        assertLt(maxGas, LIMIT, "within the cap with a 10% margin");
    }

    /// One keeper call books a batch of wins, relists a full batch of the heaviest Packs and lists Apes from custody,
    /// at most `LIST_BATCH_AFTER_PACKS` once it has minted Packs (the next call lists the rest); another reprices a
    /// full batch of Apes. Every call fits the cap with a 10% margin.
    function test_heaviestCombinedCallsFitTheCap() public {
        launchGame(6 ether);
        // Apes waiting in custody (the vault's donations need no bid)
        for (uint256 i; i < 12; ++i) {
            uint256 id = nextApeId();
            address holder = IERC721Lite(cfg.collection).ownerOf(id);
            vm.startPrank(holder);
            IERC721Lite(cfg.collection).setApprovalForAll(address(sys.vault), true);
            sys.vault.contributeNFT(id);
            vm.stopPrank();
        }
        accrueFees(30 ether); // board growth and replacements are funded
        // the gate's ceiling as the target, so a full batch of ten Apes fits the 50-row board in one call
        CollectionPoolOwner.ListingParams memory lp = sys.poolOwner.listingParams();
        lp.targetBps = 5_000;
        govern(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (lp)));
        // a full batch of wins, settled at FWA and waiting to be booked and replaced
        for (uint256 i; i < 20; ++i) { // a 50-row board: below the Shape floor (25 in play) the gate would close
            pullAndSettle(alice, uint256(keccak256(abi.encode("cap", i))));
        }
        window();
        uint256 listedBefore = sys.poolOwner.listedCount();
        uint256 combined = _sync();
        emit log_named_uint("book wins + relist a batch + list Apes (gas)", combined);
        assertEq(
            sys.poolOwner.listedCount() - listedBefore,
            sys.poolOwner.LIST_BATCH_AFTER_PACKS(),
            "after a Pack restock, a smaller batch of Apes in the same call"
        );
        assertLt(combined, LIMIT, "combined call within the cap");
        window();
        _sync();
        assertEq(sys.poolOwner.listedCount() - listedBefore, 10, "the rest of the Apes in the next call");
        uint256 maxGas = combined;
        for (uint256 i; i < 40; ++i) {
            window();
            uint256 used = _sync();
            if (used < 100_000) break;
            if (used > maxGas) maxGas = used;
        }
        // gameplay credited to every Ape: the collection step reprices a full batch (measured here as the game's call
        // into the pool owner, the part of a maintenance call that grows with the Apes)
        uint256 credited = sys.poolOwner.creditedTurnover();
        window();
        uint256 before = _notional(0);
        vm.prank(address(sys.game));
        uint256 g = gasleft();
        sys.poolOwner.processCollection(credited + 13 * 3 ether);
        uint256 reprice = g - gasleft() + _sync();
        emit log_named_uint("reprice a batch of Apes (gas)", reprice);
        assertLt(_notional(0), before, "the call repriced the Apes");
        if (reprice > maxGas) maxGas = reprice;
        emit log_named_uint("largest call (gas)", maxGas);
        assertLt(maxGas, LIMIT, "every call within the cap with a 10% margin");
    }

    // ------------------------------------------------------------------ the setter ceilings (D81)

    /// The most the owner may set: `listBatch` 20, `maxPerCall` 10, `bookPerCall` 20 (D85).
    function _ceiling() internal {
        govern(address(sys.game), abi.encodeCall(CollectionGame.setBoardParams, (20, 10, 20)));
    }

    /// At the ceilings, the opening board of the heaviest Packs lists in calls that each fit the cap.
    function test_ceilingOpeningBoardFitsTheCap() public {
        createPool();
        openMarket();
        _ceiling();
        accrueFees(6.05 ether);
        riseBidTo(6 ether);
        sellApeAt(nextApeId(), 6 ether);
        accrueFees(sys.game.capitalNeed() + 0.1 ether);
        uint256 maxGas;
        for (uint256 i; i < 40 && sys.game.liveCount() < sys.game.boardSize(); ++i) {
            uint256 used = _sync();
            if (used > maxGas) maxGas = used;
        }
        assertEq(sys.game.liveCount(), sys.game.boardSize(), "board listed");
        emit log_named_uint("ceiling: largest opening call (gas)", maxGas);
        assertLt(maxGas, LIMIT, "within the cap with a 10% margin");
    }

    /// At the ceilings, one call books a batch of wins, relists the most Packs a call may and lists Apes from custody.
    function test_ceilingCombinedCallFitsTheCap() public {
        launchGame(6 ether);
        _ceiling();
        for (uint256 i; i < 12; ++i) {
            uint256 id = nextApeId();
            address holder = IERC721Lite(cfg.collection).ownerOf(id);
            vm.startPrank(holder);
            IERC721Lite(cfg.collection).setApprovalForAll(address(sys.vault), true);
            sys.vault.contributeNFT(id);
            vm.stopPrank();
        }
        accrueFees(30 ether);
        CollectionPoolOwner.ListingParams memory lp = sys.poolOwner.listingParams();
        lp.targetBps = 5_000;
        govern(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (lp)));
        for (uint256 i; i < 20; ++i) {
            pullAndSettle(alice, uint256(keccak256(abi.encode("cap", i))));
        }
        window();
        uint64 seenBefore = sys.game.seenSeq();
        uint256 used = _sync();
        emit log_named_uint("ceiling: book + relist + list Apes (gas)", used);
        assertGt(sys.game.seenSeq(), seenBefore, "the call booked the wins");
        assertLt(used, LIMIT, "within the cap with a 10% margin");
    }

    /// At the ceilings, a call facing more waiting wins than it may book (a grown board) fits the cap.
    function test_ceilingBookingBacklogFitsTheCap() public {
        launchGame(6 ether);
        accrueFees(60 ether);
        _ceiling();
        for (uint256 k; k < 2; ++k) {
            govern(address(sys.game), abi.encodeCall(CollectionGame.setBoardSize, (sys.game.boardSize() + 50)));
            for (uint256 i; i < 80 && sys.game.liveCount() < sys.game.boardSize(); ++i) {
                window();
                _sync();
            }
        }
        uint256 wins;
        for (uint256 i; i < 90; ++i) {
            try this.pullOne(i) {
                ++wins;
            } catch {}
        }
        assertGt(wins, 50, "more wins waiting than one call books");
        window();
        uint64 seenBefore = sys.game.seenSeq();
        uint256 used = _sync();
        emit log_named_uint("ceiling: waiting wins", wins);
        emit log_named_uint("ceiling: booking call (gas)", used);
        assertGt(sys.game.seenSeq(), seenBefore, "the call booked wins");
        assertLt(used, LIMIT, "within the cap with a 10% margin");
    }

    function pullOne(uint256 i) external {
        pullAndSettle(alice, uint256(keccak256(abi.encode("backlog", i))));
    }

    /// @dev Final audit round 5 (F1): a board grown to 150 rows of the heaviest Packs, twelve Apes in custody and the
    ///      exposure target at its ceiling, ready for the heaviest calls.
    function _grownBoardWithApes() internal {
        launchGame(6 ether);
        accrueFees(80 ether);
        _ceiling();
        for (uint256 k; k < 2; ++k) {
            govern(address(sys.game), abi.encodeCall(CollectionGame.setBoardSize, (sys.game.boardSize() + 50)));
            for (uint256 i; i < 80 && sys.game.liveCount() < sys.game.boardSize(); ++i) {
                window();
                _sync();
            }
        }
        for (uint256 i; i < 12; ++i) {
            uint256 id = nextApeId();
            address holder = IERC721Lite(cfg.collection).ownerOf(id);
            vm.startPrank(holder);
            IERC721Lite(cfg.collection).setApprovalForAll(address(sys.vault), true);
            sys.vault.contributeNFT(id);
            vm.stopPrank();
        }
        CollectionPoolOwner.ListingParams memory lp = sys.poolOwner.listingParams();
        lp.targetBps = 5_000;
        govern(address(sys.poolOwner), abi.encodeCall(CollectionPoolOwner.setListingParams, (lp)));
    }

    /// Round 5's F1 case: ten requests already open and more new wins than a call books, with relists and Ape
    /// listings. Resolving and seeing share one `bookPerCall` budget (D85), so the call fits.
    function test_ceilingOpenPlusNewBookingsFitsTheCap() public {
        _grownBoardWithApes();
        uint256[10] memory pending;
        for (uint256 i; i < pending.length; ++i) {
            pending[i] = pull(alice);
        }
        sys.game.upkeep(10); // ten pending requests into the game's open set
        vm.roll(block.number + 3);
        for (uint256 i; i < pending.length; ++i) {
            deliverWord(pending[i], uint256(keccak256(abi.encode("old", i))));
        }
        pool.processAcquisitions(10);
        uint256 wins;
        for (uint256 i; i < 70; ++i) {
            try this.pullOne(i) {
                ++wins;
            } catch {}
        }
        assertGe(wins, 50);
        window();
        uint256 openBefore = sys.game.openCount();
        uint64 seenBefore = sys.game.seenSeq();
        uint256 used = _sync();
        uint256 booked = openBefore - sys.game.openCount() + (sys.game.seenSeq() - seenBefore);
        emit log_named_uint("ceiling: open + new bookings (gas)", used);
        assertLe(booked, 20, "one budget for resolving and seeing");
        assertLt(used, LIMIT, "within the cap with a 10% margin");
    }

    /// Round 5's F1 case: a player's `upkeep` asking for far more than a keeper's call books no more than one.
    function test_ceilingLargeUpkeepFitsTheCap() public {
        _grownBoardWithApes();
        for (uint256 i; i < 90; ++i) {
            try this.pullOne(i) {} catch {}
        }
        window();
        uint64 seenBefore = sys.game.seenSeq();
        uint256 g = gasleft();
        sys.game.upkeep(1_000);
        uint256 used = g - gasleft();
        emit log_named_uint("ceiling: upkeep(1000) (gas)", used);
        assertEq(sys.game.seenSeq() - seenBefore, 20, "capped at bookPerCall");
        assertLt(used, LIMIT, "within the cap with a 10% margin");
    }
}
