// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IFWAPool, IFWAFactory} from "../../src/interfaces/IFWA.sol";
import {IChecksOriginals, IChecksEdition} from "../../src/interfaces/IChecks.sol";

interface IVrfConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external;
}

interface IVrfRouted {
    function s_vrfCoordinator() external view returns (address);
}

/// @dev Ethereum mainnet at a pinned block. Every address and code hash here was read at FORK_BLOCK
///      (docs/STATUS.md "Pinned environment").
abstract contract ForkBase is Test {
    uint256 internal constant FORK_BLOCK = 26_302_000;
    string internal constant DEFAULT_RPC = "https://mainnet.gateway.tenderly.co";

    IChecksOriginals internal constant CHECKS = IChecksOriginals(0x036721e5A769Cc48B3189EFbb9ccE4471E8A48B1);
    IChecksEdition internal constant EDITIONS = IChecksEdition(0x34eEBEE6942d8Def3c125458D1a86e0A897fd6f9);
    address internal constant EDITIONS_IMPL = 0x7C74dfe39976dc395529c14e54a597809980e01C;
    address internal constant SHAPES = 0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0;
    IFWAFactory internal constant FWA_FACTORY = IFWAFactory(0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c);
    address internal constant FWA_IMPL = 0xEaa4d032908A9734a2c7939c0D211c35ad51eb31;
    address internal constant FWA_VRF_SERVICE = 0xA4adFC35dB18326eFB3b5D9bf66A8103Ec2D5EE2;
    address internal constant FWA_TOKEN = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;
    address internal constant BLKCHK = 0x718477C471B335ee0ca29B9f4b95Edd26d2eDE54;

    function setUp() public virtual {
        vm.createSelectFork(vm.envOr("MAINNET_RPC_URL", DEFAULT_RPC), FORK_BLOCK);
    }

    /// @dev Delivers a VRF word the way FWA's service does: the Chainlink coordinator calls the service, which routes
    ///      to the pool.
    function deliverWord(uint256 requestId, uint256 word) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vm.prank(IVrfRouted(FWA_VRF_SERVICE).s_vrfCoordinator());
        IVrfConsumer(FWA_VRF_SERVICE).rawFulfillRandomWords(requestId, words);
    }
}
