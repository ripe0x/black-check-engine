// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Engine, IShapesBacking, ICoinBurn} from "../../src/core/Engine.sol";
import {IController} from "../../src/interfaces/IController.sol";
import {IChecksOriginals, IChecksEdition} from "../../src/interfaces/IChecks.sol";

contract EngineHarness is Engine {
    constructor() Engine(IChecksOriginals(address(1)), IChecksEdition(address(2)), IShapesBacking(address(3)), ICoinBurn(address(4))) {}

    function notional(uint8 tier, uint256 survived) external view returns (uint256) {
        return _notional(tier, survived);
    }
}

/// @notice Decay rule properties (no fork): starts at the schedule, never rises with survival, never goes below the
///         floor, and parameter bounds hold.
contract DecayTest is Test {
    EngineHarness internal e;

    function _params(uint16 decay, uint16 floor) internal pure returns (Engine.Params memory) {
        return Engine.Params(1000, decay, floor, 500, 50, 2500, 9000, 1 ether);
    }

    function setUp() public {
        uint256[8] memory tiers = [uint256(0.25 ether), 0.5 ether, 1 ether, 2 ether, 4 ether, 8 ether, 16 ether, 1024 ether];
        uint32[7] memory d;
        uint256[7] memory b;
        uint256[8] memory c;
        e = EngineHarness(
            payable(
                address(
                    new ERC1967Proxy(
                        address(new EngineHarness()),
                        abi.encodeCall(
                            Engine.initialize,
                            (address(this), address(5), address(6), IController(address(7)), tiers, d, b, c, _params(20, 8500))
                        )
                    )
                )
            )
        );
    }

    function testFuzz_decayIsMonotonicAndFloored(uint8 tier, uint256 a, uint256 b, uint16 decay, uint16 floor) public {
        tier = uint8(bound(tier, 0, 7));
        decay = uint16(bound(decay, 0, 100));
        floor = uint16(bound(floor, 5000, 10_000));
        e.setParams(_params(decay, floor));
        a = bound(a, 0, 1e9);
        b = bound(b, a, 1e9);
        uint256 schedule = e.tierNotional(tier);
        assertEq(e.notional(tier, 0), schedule);
        assertLe(e.notional(tier, b), e.notional(tier, a));
        assertGe(e.notional(tier, b), schedule * floor / 10_000);
    }

    function testFuzz_paramBounds(uint16 decay, uint16 floor, uint16 markup, uint16 buyout) public {
        bool ok = decay <= 100 && floor >= 5000 && floor <= 10_000 && markup <= 5000 && buyout >= 1000;
        Engine.Params memory p = Engine.Params(markup, decay, floor, 500, 50, buyout, 9000, 1 ether);
        if (!ok) vm.expectRevert(Engine.BadInput.selector);
        e.setParams(p);
    }
}
