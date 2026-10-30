// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {SystemBase} from "./SystemBase.sol";
import {IVrfRouted} from "./ForkBase.sol";
import {IFWAPool} from "../../src/interfaces/IFWA.sol";
import {Engine} from "../../src/core/Engine.sol";
import {FwaV2Controller} from "../../src/fwa/FwaV2Controller.sol";
import {Coin} from "../../src/token/Coin.sol";

interface IOwnerOf {
    function ownerOf(uint256) external view returns (address);
}

/// @dev Random sequences of the protocol's public actions on the real FWA pool. Every action may revert; reverts are
///      part of the search (fail_on_revert = false).
contract Handler is Test {
    Engine internal engine;
    FwaV2Controller internal controller;
    IFWAPool internal pool;
    Coin internal coin;
    address internal checks;
    address internal shapes;
    address internal immutable vrfCoordinatorCaller;
    address internal immutable vrfService;
    address internal player = makeAddr("inv-player");

    uint256[] public checkIds;
    uint256[] public shapeIds;
    uint256 public coinSupplyLow;
    mapping(bytes32 => uint256) public succeeded;

    constructor(
        Engine e,
        FwaV2Controller k,
        Coin c,
        address checks_,
        address shapes_,
        uint256[] memory cs,
        uint256[] memory ss,
        address coord,
        address service
    ) {
        engine = e;
        controller = k;
        pool = k.pool();
        coin = c;
        checks = checks_;
        shapes = shapes_;
        checkIds = cs;
        shapeIds = ss;
        vrfCoordinatorCaller = coord;
        vrfService = service;
        coinSupplyLow = c.totalSupply();
    }

    function checkCount() external view returns (uint256) {
        return checkIds.length;
    }

    /// @dev Three settled draws per call, so composition and Shape restocking become reachable.
    function draw(uint256 word) external {
        for (uint256 i; i < 3; ++i) _draw(uint256(keccak256(abi.encode(word, i))));
    }

    function _draw(uint256 word) internal {
        (uint256 fee,, uint256 total) = pool.quoteAcquisitionPrice(1);
        if (pool.activeListingCount() == 0) return;
        uint256 version = pool.inventoryVersion();
        vm.deal(player, player.balance + total);
        vm.prank(player);
        try pool.acquire{value: total}(player, fee, 0, 10_000, version, vm.getBlockTimestamp() + 1 hours) returns (
            uint256 id
        ) {
            vm.roll(vm.getBlockNumber() + 3);
            uint256[] memory words = new uint256[](1);
            words[0] = word;
            vm.prank(vrfCoordinatorCaller);
            (bool ok,) = vrfService.call(abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", id, words));
            ok;
            pool.processAcquisitions(10);
            ++succeeded["draw"];
        } catch {}
    }

    function reprice() external {
        try engine.reprice(_listed()) {
            ++succeeded["reprice"];
        } catch {}
    }

    /// @dev Picks an eligible same-tier pair starting at a random offset (random pairs are almost never eligible).
    function compose(uint256 a, bool swap) external {
        uint256 n = checkIds.length;
        uint256 x;
        uint256 y;
        for (uint256 i; i < n && y == 0; ++i) {
            uint256 p = checkIds[(a % n + i) % n];
            if (!engine.eligible(p)) continue;
            if (x == 0) x = p;
            else if (_tier(p) == _tier(x)) y = p;
        }
        if (y == 0) return;
        try engine.compose(x, y, swap) {
            ++succeeded["compose"];
        } catch {}
        _noteSupply();
    }

    function buyEth(uint256 a) external {
        uint256 id = checkIds[a % checkIds.length];
        uint256 price;
        try engine.ethPrice(_tier(id)) returns (uint256 p) {
            price = p;
        } catch {
            return;
        }
        vm.deal(address(this), price);
        try engine.buyWithEth{value: price}(id) {
            ++succeeded["buyEth"];
        } catch {}
    }

    function buyCoin(uint256 a) external {
        try engine.buyWithCoin(checkIds[a % checkIds.length]) {
            ++succeeded["buyCoin"];
        } catch {}
        _noteSupply();
    }

    function sellBack(uint256 a) external {
        uint256 id = checkIds[a % checkIds.length];
        try IOwnerOf(checks).ownerOf(id) returns (address o) {
            if (o != address(this)) return;
        } catch {
            return;
        }
        (bool ok,) = checks.call(abi.encodeWithSignature("setApprovalForAll(address,bool)", address(engine), true));
        ok;
        try engine.sellCheck(id) {
            ++succeeded["sell"];
        } catch {}
    }

    function fund(uint96 amount) external {
        uint256 v = bound(amount, 0, 2 ether);
        vm.deal(address(this), v);
        engine.fundAcquisitions{value: v}();
    }

    function relist(uint256 a) external {
        uint256[] memory one = new uint256[](1);
        one[0] = checkIds[a % checkIds.length];
        try engine.listChecks(one) {
            ++succeeded["relist"];
        } catch {}
    }

    function restock(uint256 a) external {
        uint256[] memory one = new uint256[](1);
        one[0] = shapeIds[a % shapeIds.length];
        vm.deal(address(engine), address(engine).balance + 0.05 ether);
        try engine.restockShapes(one) {
            ++succeeded["restock"];
        } catch {}
    }

    function collect() external {
        try engine.collect(address(controller)) {} catch {}
    }

    function _tier(uint256 id) internal view returns (uint8) {
        (bool ok, bytes memory out) = checks.staticcall(abi.encodeWithSignature("getCheck(uint256)", id));
        if (!ok) return 0;
        // StoredCheck.divisorIndex is the 17th word of the encoded Check (6 + 5 + 5 array words, then the field).
        return uint8(uint256(bytes32(_slice(out, 16 * 32))));
    }

    function _slice(bytes memory b, uint256 at) internal pure returns (bytes32 w) {
        assembly {
            w := mload(add(add(b, 32), at))
        }
    }

    function _listed() internal view returns (uint256[] memory ids) {
        uint256 n;
        uint256[] memory tmp = new uint256[](checkIds.length);
        for (uint256 i; i < checkIds.length; ++i) {
            (address c, uint64 lid,) = engine.checkListing(checkIds[i]);
            if (c == address(controller) && controller.isListed(lid)) tmp[n++] = checkIds[i];
        }
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) ids[i] = tmp[i];
    }

    function _noteSupply() internal {
        uint256 s = coin.totalSupply();
        require(s <= coinSupplyLow, "coin supply grew");
        coinSupplyLow = s;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/// @notice Stateful invariants of custody and accounting on the real FWA pool, Checks and Shapes.
contract InvariantTest is SystemBase {
    Handler internal handler;

    function setUp() public override {
        super.setUp();
        uint256[] memory cs = _takeEighties(6);
        uint256[] memory ss = _mintShapes(12);
        engine.listChecks(cs);
        engine.listShapes(ss);
        handler = new Handler(
            engine,
            controller,
            coin,
            address(CHECKS),
            SHAPES,
            cs,
            ss,
            IVrfRouted(FWA_VRF_SERVICE).s_vrfCoordinator(),
            FWA_VRF_SERVICE
        );
        coin.transfer(address(handler), 10_000_000 ether);
        vm.prank(address(handler));
        coin.approve(address(engine), type(uint256).max);
        targetContract(address(handler));
    }

    function afterInvariant() public view {
        bytes32[8] memory k = [bytes32("draw"), "reprice", "compose", "buyEth", "buyCoin", "sell", "relist", "restock"];
        for (uint256 i; i < 8; ++i) console2.log(string(abi.encodePacked(k[i])), handler.succeeded(k[i]));
    }

    /// Game capital never dips into the acquisition budget.
    function invariant_budgetBacked() public view {
        assertGe(address(engine).balance, engine.acquisitionBudget());
    }

    /// Every Check is where the engine's records say it is: in the pool while live-listed, in the engine while in
    /// custody, or gone (won, bought, or burned in composition) once the record no longer points to a live listing.
    function invariant_custodyMatchesRecords() public view {
        for (uint256 i; i < handler.checkCount(); ++i) {
            uint256 id = handler.checkIds(i);
            (address c, uint64 lid,) = engine.checkListing(id);
            address owner;
            try CHECKS.ownerOf(id) returns (address o) {
                owner = o;
            } catch {}
            if (c != address(0) && FwaV2Controller(payable(c)).isListed(lid)) {
                assertEq(owner, address(pool), "live listing held by FWA");
            }
            if (owner == address(engine)) assertEq(c, address(0), "custody Check has no live record");
        }
    }

    /// FWA's active count matches the controller's books, and a Check's survival (earlier episodes plus the live one,
    /// disjoint periods of the same pool) never exceeds the pool's total prize allocations.
    function invariant_survivalBounded() public view {
        uint256 allocated = controller.allocated();
        assertEq(controller.listed() - controller.withdrawn() - allocated, pool.activeListingCount());
        for (uint256 i; i < handler.checkCount(); ++i) {
            assertLe(engine.survivedDraws(handler.checkIds(i)), allocated);
        }
    }

    /// Coin is only ever burned.
    function invariant_coinOnlyBurns() public view {
        assertLe(coin.totalSupply(), handler.coinSupplyLow());
    }
}


