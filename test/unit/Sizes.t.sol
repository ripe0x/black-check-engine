// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice EIP-170 limits for every contract, and a size guard on CollectionGame: D63 unfroze it (the simplification
///         removed the policy modules, KeeperFund, the router and board rebinding, 24,409 → 22,874 B); its current size
///         is pinned so that any growth is deliberate and reviewed (docs/AUDIT_SCOPE.md).
contract SizesTest is Test {
    uint256 internal constant EIP170 = 24_576;
    /// @dev Via-IR (C015) on 40599e6: 22,392 B, with the markup floor and keeper caps of D012 (collection-games pinned
    ///      24,536 B without IR). Measured under the default profile only; the fast profile does not build with IR.
    uint256 internal constant GAME_PINNED = 22_392;

    function test_gameLedgerSizePinned() public view {
        assertLe(vm.getDeployedCode("CollectionGame.sol:CollectionGame").length, GAME_PINNED, "CollectionGame grew");
    }

    function test_everyContractWithinEip170() public view {
        string[16] memory names = [
            "CollectionGame.sol:CollectionGame",
            "CollectionPoolOwner.sol:CollectionPoolOwner",
            "FundingVault.sol:FundingVault",
            "CollectionHook.sol:CollectionHook",
            "CollectionToken.sol:CollectionToken",
            "ProtocolLiquidity.sol:ProtocolLiquidity",
            "CollectionBurner.sol:CollectionBurner",
            "Lens.sol:Lens",
            "Admin.sol:Admin",
            "MigrationAuthority.sol:MigrationAuthority",
            "Sunset.sol:Sunset",
            "DrawRouter.sol:DrawRouter",
            "SeaportAdapter.sol:SeaportAdapter",
            "ShapePacks.sol:ShapePacks",
            "ShapePackRenderer.sol:ShapePackRenderer",
            "ChecksDesk.sol:ChecksDesk"
        ];
        for (uint256 i; i < names.length; ++i) {
            assertLe(vm.getDeployedCode(names[i]).length, EIP170, names[i]);
        }
    }
}
