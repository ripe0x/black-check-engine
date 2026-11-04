// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {CollectionToken} from "../../src/token/CollectionToken.sol";
import {IMetadataRenderer} from "../../src/interfaces/IMetadataRenderer.sol";
import {DeploySystem} from "../../script/DeploySystem.sol";
import {Base64} from "solady/utils/Base64.sol";

contract FixedRenderer is IMetadataRenderer {
    function contractURI(address) external pure returns (string memory) {
        return "https://example.com/apeball.json";
    }
}

/// @notice D86: the coin's metadata, as artcoins' coins: `contractURI` and `tokenURI` (ERC-7572 JSON with name, symbol,
///         description and image) from a built-in default or an owner-set renderer; the Admin owner updates the image
///         and description; every change emits `ContractURIUpdated`; a renounce freezes it.
contract CoinMetadataForkTest is ForkBase {
    event ContractURIUpdated();

    function setUp() public {
        deployChecks();
    }

    function _json(string memory description, string memory image) internal view returns (string memory) {
        return string.concat(
            "data:application/json;base64,",
            Base64.encode(bytes(string.concat('{"name":"', cfg.name, '","symbol":"', cfg.symbol, '","description":"',
                description, '","image":"', image, '"}')))
        );
    }

    function test_launchMetadataIsTheDefault() public view {
        assertEq(sys.token.contractURI(), _json("", ""), "empty image and description at launch");
        assertEq(sys.token.tokenURI(), sys.token.contractURI());
        assertEq(sys.token.metadataRenderer(), address(0));
    }

    function test_ownerUpdatesImageAndDescription() public {
        vm.expectEmit(address(sys.token));
        emit ContractURIUpdated();
        vm.prank(owner);
        sys.token.updateImage("ipfs://apeball");
        vm.prank(owner);
        sys.token.updateMetadata("The coin of ApeBall");
        assertEq(sys.token.imageUrl(), "ipfs://apeball");
        assertEq(sys.token.metadata(), "The coin of ApeBall");
        assertEq(sys.token.contractURI(), _json("The coin of ApeBall", "ipfs://apeball"));
    }

    function test_jsonIsEscaped() public {
        vm.prank(owner);
        sys.token.updateMetadata('say "hi"');
        assertEq(sys.token.contractURI(), _json('say \\"hi\\"', ""), "quotes cannot break the JSON");
    }

    function test_onlyTheOwner() public {
        address stranger = makeAddr("meta.stranger");
        vm.startPrank(stranger);
        vm.expectRevert(CollectionToken.NotOwner.selector);
        sys.token.updateImage("x");
        vm.expectRevert(CollectionToken.NotOwner.selector);
        sys.token.updateMetadata("x");
        vm.expectRevert(CollectionToken.NotOwner.selector);
        sys.token.setMetadataRenderer(address(0));
        vm.stopPrank();
    }

    function test_rendererSwapAndFallback() public {
        vm.prank(owner);
        vm.expectRevert(CollectionToken.InvalidRenderer.selector);
        sys.token.setMetadataRenderer(makeAddr("meta.eoa"));
        FixedRenderer r = new FixedRenderer();
        vm.prank(owner);
        sys.token.setMetadataRenderer(address(r));
        assertEq(sys.token.contractURI(), "https://example.com/apeball.json");
        assertEq(sys.token.tokenURI(), "https://example.com/apeball.json");
        vm.prank(owner);
        sys.token.setMetadataRenderer(address(0));
        assertEq(sys.token.contractURI(), _json("", ""), "zero: back to the built-in default");
    }

    function test_frozenAfterRenounce() public {
        vm.prank(owner);
        sys.token.updateImage("ipfs://final");
        vm.prank(owner);
        sys.admin.renounceOwnership();
        address r = address(new FixedRenderer());
        vm.startPrank(owner);
        vm.expectRevert(CollectionToken.NotOwner.selector);
        sys.token.updateImage("ipfs://changed");
        vm.expectRevert(CollectionToken.NotOwner.selector);
        sys.token.setMetadataRenderer(r);
        vm.stopPrank();
        assertEq(sys.token.imageUrl(), "ipfs://final");
    }

    function test_postflightChecksTheLaunchMetadata() public {
        Config memory c = cfg;
        c.coinImage = "ipfs://other";
        vm.expectRevert(abi.encodeWithSelector(DeploySystem.DeployMismatch.selector, "coin metadata"));
        this.postflight(c, sys, address(this));
    }
}
