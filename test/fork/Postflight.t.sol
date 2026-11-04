// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase, IERC721Lite} from "./ForkBase.sol";
import {DeploySystem} from "../../script/DeploySystem.sol";
import {CollectionBurner} from "../../src/treasury/CollectionBurner.sol";

/// @notice The postflight catches every launch value the requirements depend on (final audit round 2, B6): each case
///         changes one value, on chain or in the config it is checked against, and the postflight names it.
contract PostflightForkTest is ForkBase {
    function setUp() public {
        deployChecks();
    }

    function _expect(string memory what, Config memory c) internal {
        vm.expectRevert(abi.encodeWithSelector(DeploySystem.DeployMismatch.selector, what));
        this.postflight(c, sys, address(this));
    }

    function test_passesAsDeployed() public view {
        this.postflight(cfg, sys, address(this));
    }

    function test_catchesBuybackTiers() public {
        CollectionBurner.Tiers memory t = cfg.tiers;
        t.exitWindow = 12 hours;
        vm.prank(owner);
        sys.burner.setTiers(t);
        _expect("buyback tiers", cfg);
    }

    function test_catchesOpeningAllowance() public {
        Config memory c = cfg;
        c.openingAllowance = 0.3 ether;
        _expect("opening allowance", c);
    }

    function test_catchesAnyBoardRow() public {
        Config memory c = cfg;
        uint256[] memory p = new uint256[](c.boardPattern.length);
        for (uint256 i; i < p.length; ++i) {
            p[i] = c.boardPattern[i];
        }
        p[p.length - 1] = 1 ether;
        c.boardPattern = p;
        _expect("pattern row", c);
    }

    /// A config changed to open the pool at a giveaway price (the audit's tick 886,800: 1 wei bought 56% of supply).
    function test_catchesAnExtremeOpeningTick() public {
        Config memory c = cfg;
        c.startTick = 886_800;
        _expect("opening tick range", c);
    }

    // final audit round 4 (B6): readbacks the postflight lacked, and G3's purchaser exclusions

    function test_catchesOpeningBoardSize() public {
        Config memory c = cfg;
        c.initialBoardSize = c.initialBoardSize - 1;
        _expect("board", c);
    }

    function test_catchesNames() public {
        Config memory c = cfg;
        c.symbol = "OTHER";
        _expect("coin identity", c);
        c = cfg;
        c.packsName = "Other Packs";
        _expect("packs identity", c);
    }

    function test_catchesPacksRenderer() public {
        sys.packRenderer = makeAddr("other renderer");
        _expect("packs renderer", cfg);
    }

    function test_catchesARevokedFwaApproval() public {
        createPool();
        this.postflight(cfg, sys, address(this));
        vm.prank(address(sys.poolOwner));
        IERC721Lite(cfg.collection).setApprovalForAll(address(pool), false);
        _expect("fwa approvals", cfg);
    }

    /// No system contract may be named as a draw's purchaser (G3: a prize sent to one is stranded), and the
    /// postflight confirms each is recorded; a player still can, within FWA's 100,000-gas stipend for the check.
    function test_systemContractsCannotPurchase() public {
        launchGame(0.25 ether);
        address[10] memory system = [
            address(sys.burner), address(sys.hook), address(sys.liquidity), address(sys.token), address(sys.admin),
            address(sys.sunset), address(sys.adapter), address(sys.lens), address(sys.drawRouter), sys.packRenderer
        ];
        for (uint256 i; i < system.length; ++i) {
            assertTrue(sys.poolOwner.isSystem(system[i]), "recorded");
            assertFalse(sys.poolOwner.canPurchase(system[i]), "refused as purchaser");
        }
        address player = makeAddr("player");
        uint256 g = gasleft();
        bool ok = sys.poolOwner.canPurchase(player);
        uint256 used = g - gasleft();
        assertTrue(ok, "a player is admitted");
        assertLt(used, 100_000, "within FWA's stipend");
    }
}
