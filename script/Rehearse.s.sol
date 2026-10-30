// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {DeploySystem} from "./DeploySystem.sol";
import {LaunchConfig} from "./LaunchConfig.sol";
import {Engine} from "../src/core/Engine.sol";
import {IChecksOriginals} from "../src/interfaces/IChecks.sol";

/// @notice Local-only rehearsal helper for the keeper (keeper/). Deploys the system to an anvil mainnet fork, opens the
///         FWA pool (the 50,000 FWA creation fee is written to the controller and mirrored onto anvil), funds the
///         acquisition budget and resumes draws, then prints a revealed 80-Check holder for the shell to sell into the
///         engine by impersonation. It is not a mainnet deploy path: Deploy.s.sol is. Never run against mainnet.
contract Rehearse is Script, DeploySystem {
    using stdStorage for StdStorage;

    address internal constant FWA_TOKEN = 0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845;

    function run() external {
        Config memory c = LaunchConfig.mainnet();
        // anvil default development accounts (local node only); guardian resumes in its own broadcast below.
        c.guardian = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // anvil #3
        c.council = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // anvil #1
        c.operator = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC; // anvil #2
        c.coinSymbol = "TEST";
        c.poolSalt = keccak256("rehearsal.pool");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        System memory s = deploySystem(c, deployer, CREATE2_FACTORY);

        // Give the controller the FWA creation fee: in-memory for this run's simulation, and on anvil for the replay.
        uint256 fee = c.fwaFactory.poolCreationFee();
        uint256 slot = stdstore.target(FWA_TOKEN).sig("balanceOf(address)").with_key(address(s.controller)).find();
        vm.store(FWA_TOKEN, bytes32(slot), bytes32(fee));
        vm.rpc(
            "anvil_setStorageAt",
            string.concat(
                '["', vm.toString(FWA_TOKEN), '","', vm.toString(bytes32(slot)), '","', vm.toString(bytes32(fee)), '"]'
            )
        );
        s.engine.openPool();
        s.engine.fundAcquisitions{value: 1 ether}();
        vm.stopBroadcast();
        postflight(s, c, deployer); // the production checks, before the game opens

        vm.startBroadcast(c.guardian);
        s.engine.resume();
        vm.stopBroadcast();

        (address holder, uint256 tokenId) = _findRevealedEighty(c.checks, address(s.engine));

        console2.log("ENGINE", address(s.engine));
        console2.log("HOOK", address(s.hook));
        console2.log("CONTROLLER", address(s.controller));
        console2.log("POOL", address(s.controller.pool()));
        console2.log("SELLER", holder);
        console2.log("TOKENID", tokenId);
    }

    /// @dev First revealed 80-Check (divisorIndex 0) not already held by the engine, with its current owner.
    function _findRevealedEighty(IChecksOriginals checks, address engine)
        internal
        view
        returns (address holder, uint256 tokenId)
    {
        for (uint256 id = 1; id < 20_000; ++id) {
            try checks.ownerOf(id) returns (address o) {
                if (o == engine || o == address(0)) continue;
                IChecksOriginals.Check memory info = checks.getCheck(id);
                if (info.isRevealed && info.stored.divisorIndex == 0) return (o, id);
            } catch {}
        }
        revert("no revealed 80-check found");
    }
}
