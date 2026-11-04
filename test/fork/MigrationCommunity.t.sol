// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {IChecksOriginals} from "../../src/interfaces/IChecks.sol";
import {MigrationAuthority} from "../../src/migration/MigrationAuthority.sol";
import {CommunitySuccessor} from "../utils/CommunitySuccessor.sol";

interface ICommunitySwitches {
    function owner() external view returns (address);
    function poolCreationEnabled() external view returns (bool);
    function globalPurchasesEnabled() external view returns (bool);
    function vrfRequestsPaused() external view returns (bool);
    function setPoolCreationEnabled(bool) external;
    function setGlobalPurchasesEnabled(bool) external;
    function setVrfRequestsPaused(bool) external;
    function vrfService() external view returns (address);
}

interface IVrfSubscription {
    function s_vrfCoordinator() external view returns (address);
    function subscriptionId() external view returns (uint256);
}

interface IVrfFund {
    function fundSubscriptionWithNative(uint256 subId) external payable;
}

interface IVrfConsumerCommunity {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

/// @notice Invariant 11: the protocol adopts a genuinely new FWA implementation. V1 runs on an FWA V2 pool; the council
///         proposes a successor (D012: the council's 7 days, then the MigrationAuthority's 72 hours); anyone executes;
///         V1 settles and unwinds; the Checks and the vault's capital go to the successor, which creates a real pool on
///         FWA's community pool factory (different code from V2: no creation fee, the owner paid the base price) and
///         runs a real draw there. Each Check's survival is carried: V1 records it when retirement withdraws the
///         listing, and the successor reads it.
///         LOCAL ONLY: at this block FWA has not opened its community factory (creation and purchases off, randomness
///         paused); its owner's switches are opened and its randomness subscription funded inside the local fork, as
///         collection-games 72d5179 did. The successor is a test-only contract (test/utils/CommunitySuccessor.sol).
contract MigrationCommunityForkTest is ForkBase {
    address constant COMMUNITY_FACTORY = 0x8919814D825a5Af238cC04DE06b1C18c9eaA477C;
    address alice = makeAddr("community.alice");

    function setUp() public {
        deployChecks();
        launchGame(cfg.refPrice);
    }

    function _shapeDraws(uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            if (!canPull(alice)) {
                window();
                syncAll();
            }
            uint256 r = pull(alice);
            vm.roll(vm.getBlockNumber() + 3);
            deliverWord(r, wordFor(0));
            pool.processAcquisitions(10);
        }
        window();
        syncAll();
    }

    function _openCommunityFactoryLocally() internal {
        ICommunitySwitches f = ICommunitySwitches(COMMUNITY_FACTORY);
        vm.startPrank(f.owner());
        if (!f.poolCreationEnabled()) f.setPoolCreationEnabled(true);
        if (!f.globalPurchasesEnabled()) f.setGlobalPurchasesEnabled(true);
        if (f.vrfRequestsPaused()) f.setVrfRequestsPaused(false);
        vm.stopPrank();
        IVrfSubscription v = IVrfSubscription(f.vrfService());
        vm.deal(address(this), address(this).balance + 10 ether);
        IVrfFund(v.s_vrfCoordinator()).fundSubscriptionWithNative{value: 10 ether}(v.subscriptionId());
    }

    function test_migrationToTheCommunityPoolCarriesChecksCapitalAndSurvival() public {
        (CommunitySuccessor succ, uint256 tokenId, uint32 carried) = _migrate();
        IFWAPool cp = _listOnCommunityPool(succ, tokenId, carried);
        _winThere(cp, tokenId);
    }

    /// @dev V1 runs; the council proposes the successor; V1 retires and hands the Check and its capital over.
    function _migrate() internal returns (CommunitySuccessor succ, uint256 tokenId, uint32 carried) {
        uint256 listing = sys.poolOwner.listedAt(0);
        (tokenId,,,,,) = sys.poolOwner.cListings(listing);
        _shapeDraws(12);
        uint256 survivedInV1 = sys.poolOwner.survived(listing);
        assertEq(survivedInV1, 12);
        succ = new CommunitySuccessor(COMMUNITY_FACTORY, cfg.collection);
        councilCall(address(sys.migration), abi.encodeCall(MigrationAuthority.propose, (address(succ))));
        vm.warp(vm.getBlockTimestamp() + 72 hours);
        vm.prank(alice);
        sys.migration.execute();
        for (uint256 i; i < 30 && !sys.game.retired(); ++i) {
            vm.prank(keeper);
            sys.game.retireStep();
        }
        assertTrue(sys.game.retired());
        (,,,,, carried) = sys.poolOwner.nfts(tokenId);
        assertEq(carried, survivedInV1, "survival recorded at the withdrawal");
        assertEq(sys.migration.migrateApes(10), 1);
        uint256 vaultBal = address(sys.vault).balance;
        assertEq(sys.migration.migrateCapital(), vaultBal);
        assertEq(IChecksOriginals(cfg.collection).ownerOf(tokenId), address(succ));
        assertEq(address(succ).balance, vaultBal, "the vault's capital at the successor");
    }

    /// @dev The successor opens a real community pool and lists the Check where V1 left it (the D005 rule).
    function _listOnCommunityPool(CommunitySuccessor succ, uint256 tokenId, uint32 carried)
        internal
        returns (IFWAPool cp)
    {
        _openCommunityFactoryLocally();
        cp = IFWAPool(succ.open(keccak256("checks.community.v1")));
        assertEq(cp.owner(), address(succ));
        uint256 sched = cfg.schedule[0];
        uint256[] memory ids = new uint256[](1);
        uint256[] memory prices = new uint256[](1);
        (ids[0], prices[0]) = (tokenId, sched - sched * cfg.listing.decayBps * carried / 10_000);
        uint256[] memory lids = succ.list(ids, prices);
        succ.enablePurchases();
        (,,,,, uint256 listedAt,,) = cp.listings(lids[0]);
        assertEq(listedAt, prices[0], "listed where V1 left it");
    }

    /// @dev A real draw on the new FWA code wins the Check.
    function _winThere(IFWAPool cp, uint256 tokenId) internal {
        (uint256 fee,, uint256 total) = cp.quoteAcquisitionPrice(1);
        uint256 version = cp.inventoryVersion();
        vm.deal(alice, total);
        vm.prank(alice);
        uint256 r = cp.acquire{value: total}(alice, fee, 0, 10_000, version, vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 3);
        uint256[] memory words = new uint256[](1);
        words[0] = 7;
        address service = ICommunitySwitches(COMMUNITY_FACTORY).vrfService();
        vm.prank(IVrfSubscription(service).s_vrfCoordinator());
        IVrfConsumerCommunity(service).rawFulfillRandomWords(r, words);
        cp.processAcquisitions(10);
        assertEq(IChecksOriginals(cfg.collection).ownerOf(tokenId), alice, "won on the community pool");
    }
}
