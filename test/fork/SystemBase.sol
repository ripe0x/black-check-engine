// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {IController} from "../../src/interfaces/IController.sol";
import {IChecksOriginals} from "../../src/interfaces/IChecks.sol";
import {Engine, IShapesBacking, ICoinBurn} from "../../src/core/Engine.sol";
import {Coin} from "../../src/token/Coin.sol";
import {FwaV2Controller} from "../../src/fwa/FwaV2Controller.sol";
import {DeploySystem} from "../../script/DeploySystem.sol";
import {LaunchConfig} from "../../script/LaunchConfig.sol";

interface IShapesMintTo {
    function mintBatchTo(uint256 amountWei, uint256 quantity, address to)
        external
        payable
        returns (uint256 firstTokenId);
    function mintFee() external view returns (uint256);
}

/// @dev The deployed system on the pinned fork, built by the production routine (script/DeploySystem.sol) with test
///      schedule values, and checked by its postflight. Setup cheats: the FWA creation fee is written to the controller with `deal`; real Check holders are
///      impersonated to move tokens into the engine; coin for tests is taken from the unlaunched venue contract; VRF words
///      come through FWA's real service.
abstract contract SystemBase is ForkBase, DeploySystem {
    uint256 internal constant DELAY = 7 days;
    uint256 internal constant SHAPE_BACKING = 0.01 ether;
    uint16 internal constant MARKUP = 1000;
    uint256 internal constant SHAPE_PRICE = SHAPE_BACKING * 11 / 10;

    address internal council = makeAddr("council");
    address internal guardian = makeAddr("guardian");
    address internal operator = makeAddr("operator");
    address internal player = makeAddr("player");
    address internal keeper = makeAddr("keeper");

    TimelockController internal timelock;
    Engine internal engine;
    Coin internal coin;
    FwaV2Controller internal controller;
    IFWAPool internal pool;
    uint256 internal nextScan = 1;
    uint256 internal opSalt;

    function setUp() public virtual override {
        super.setUp();
        vm.txGasPrice(1 gwei);

        Config memory c = LaunchConfig.mainnet();
        c.council = council;
        c.guardian = guardian;
        c.operator = operator;
        c.coinName = "Test Coin";
        c.coinSymbol = "TEST";
        c.poolSalt = "pool-1";
        c.tierNotional = _tiers();
        c.drawsToCompose = _thresholds();
        c.composeBurn = _composeBurn();
        c.coinPrice = _coinPrice();
        c.params = _params();
        System memory s = deploySystem(c, address(this), address(this));
        postflight(s, c, address(this));
        timelock = s.timelock;
        coin = s.coin;
        engine = s.engine;
        controller = s.controller;
        // Setup only: take coin for tests from the unlaunched venue contract that holds the whole supply.
        vm.prank(address(s.liquidity));
        coin.transfer(address(this), 100_000_000 ether);
        deal(FWA_TOKEN, address(controller), FWA_FACTORY.poolCreationFee());
        engine.openPool();
        pool = controller.pool();
        vm.prank(guardian);
        engine.resume();
        coin.approve(address(engine), type(uint256).max); // this test contract holds the supply and may pay burns
    }

    function _newController(address engine_, bytes32 salt) internal returns (FwaV2Controller) {
        return new FwaV2Controller(engine_, FWA_FACTORY, FWA_IMPL, salt, address(CHECKS), SHAPES);
    }

    function _tiers() internal pure returns (uint256[8] memory t) {
        t = [uint256(1 ether), 2 ether, 4 ether, 8 ether, 16 ether, 32 ether, 64 ether, 4096 ether];
    }

    function _thresholds() internal pure returns (uint32[7] memory d) {
        d = [uint32(2), 2, 2, 2, 2, 2, 2];
    }

    function _composeBurn() internal pure returns (uint256[7] memory b) {
        b = [uint256(100 ether), 200 ether, 400 ether, 800 ether, 1600 ether, 3200 ether, 6400 ether];
    }

    function _coinPrice() internal pure returns (uint256[8] memory c) {
        c = [uint256(10_000 ether), 20_000 ether, 40_000 ether, 80_000 ether, 160_000 ether, 320_000 ether, 640_000 ether, 0];
    }

    function _params() internal pure returns (Engine.Params memory) {
        return Engine.Params({
            shapeMarkupBps: MARKUP,
            decayBpsPerDraw: 20,
            floorBps: 8500,
            repriceStepBps: 500,
            graceDraws: 3,
            buyoutMarkupBps: 2000,
            bidBps: 9000,
            bidWeeklyCap: 10 ether
        });
    }

    // ------------------------------------------------------------------ governance

    function _govern(address target, bytes memory data) internal {
        bytes32 s = bytes32(++opSalt);
        vm.prank(council);
        timelock.schedule(target, 0, data, bytes32(0), s, DELAY);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        timelock.execute(target, 0, data, bytes32(0), s);
    }

    // ------------------------------------------------------------------ inventory

    function _takeEighties(uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        uint256 got;
        for (uint256 id = nextScan; got < n; ++id) {
            try CHECKS.ownerOf(id) returns (address holder) {
                nextScan = id + 1;
                if (holder == address(engine)) continue;
                IChecksOriginals.Check memory c = CHECKS.getCheck(id);
                if (c.stored.divisorIndex != 0 || !c.isRevealed) continue;
                vm.prank(holder);
                CHECKS.transferFrom(holder, address(engine), id);
                ids[got++] = id;
            } catch {
                nextScan = id + 1;
            }
        }
    }

    function _mintShapes(uint256 n) internal returns (uint256[] memory ids) {
        uint256 cost = n * (SHAPE_BACKING + IShapesMintTo(SHAPES).mintFee());
        vm.deal(address(this), address(this).balance + cost);
        uint256 first = IShapesMintTo(SHAPES).mintBatchTo{value: cost}(SHAPE_BACKING, n, address(engine));
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = first + i;
    }

    // ------------------------------------------------------------------ draws

    function _pullAt(IFWAPool p) internal returns (uint256 requestId) {
        (uint256 fee,, uint256 total) = p.quoteAcquisitionPrice(1);
        uint256 version = p.inventoryVersion();
        vm.deal(player, player.balance + total);
        vm.prank(player);
        requestId = p.acquire{value: total}(player, fee, 0, 10_000, version, block.timestamp + 1 hours);
    }

    function _wordFor(IFWAPool p, uint256 listingId) internal view returns (uint256 prefix) {
        for (uint256 slot = 1; slot < 300; ++slot) {
            uint256 id = p.slotToListing(slot);
            if (id == 0) continue;
            (,,,, uint256 weight,,, IFWAPool.ListingStatus st) = p.listings(id);
            if (st != IFWAPool.ListingStatus.Active) continue;
            if (id == listingId) return prefix;
            prefix += weight;
        }
        revert("wordFor: not active");
    }

    /// @dev One draw at `p` that selects `listingId`, settled.
    function _drawSelecting(IFWAPool p, uint256 listingId) internal returns (uint256 requestId) {
        requestId = _pullAt(p);
        vm.roll(vm.getBlockNumber() + 3);
        deliverWord(requestId, _wordFor(p, listingId));
        p.processAcquisitions(10);
    }

    function _shapeListing(uint256 shapeId) internal view returns (uint256 listingId) {
        (, listingId,) = engine.shapeListing(shapeId);
    }

    function _checkListing(uint256 tokenId) internal view returns (uint256 listingId) {
        (, listingId,) = engine.checkListing(tokenId);
    }
}
