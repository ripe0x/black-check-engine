// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DeploySystem} from "./DeploySystem.sol";
import {Engine, IShapesBacking} from "../src/core/Engine.sol";
import {IFWAFactory} from "../src/interfaces/IFWA.sol";
import {IChecksOriginals, IChecksEdition} from "../src/interfaces/IChecks.sol";

/// @notice Launch values only (docs/ECONOMICS.md proposals; every economic value awaits founder review). Roles, the
///         coin's public name and the liquidity recipient are deliberately unset: the deploy script and postflight
///         refuse to run without them.
library LaunchConfig {
    function mainnet() internal pure returns (DeploySystem.Config memory c) {
        c.delay = 7 days;
        c.checks = IChecksOriginals(0x036721e5A769Cc48B3189EFbb9ccE4471E8A48B1);
        c.editions = IChecksEdition(0x34eEBEE6942d8Def3c125458D1a86e0A897fd6f9);
        c.shapes = IShapesBacking(0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0);
        c.fwaFactory = IFWAFactory(0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c);
        c.fwaImplementation = 0xEaa4d032908A9734a2c7939c0D211c35ad51eb31;
        c.poolSalt = keccak256("checks-survival.pool.v1");
        c.coinName = "Placeholder Coin";
        c.coinSymbol = "BLACK"; // placeholder: the mainnet script refuses it (CLAUDE.md invariant 9)
        c.coinSupply = 1_000_000_000 ether;
        // 80-Check floor 0.25 ETH (late October 2026) x units, no rarity premium; Black = 4,096 units.
        c.tierNotional = [uint256(0.25 ether), 0.5 ether, 1 ether, 2 ether, 4 ether, 8 ether, 16 ether, 1024 ether];
        c.drawsToCompose = [uint32(100), 100, 100, 100, 100, 100, 200];
        // Placeholder coin amounts until the coin trades (founder decision).
        c.composeBurn = [uint256(1_000 ether), 2_000 ether, 4_000 ether, 8_000 ether, 16_000 ether, 32_000 ether, 1_000_000 ether];
        // Coin buyouts launch disabled (D006).
        c.params = Engine.Params({
            shapeMarkupBps: 1000, // D004
            decayBpsPerDraw: 20, // D005
            floorBps: 8500, // D005
            repriceStepBps: 500,
            graceDraws: 50, // D008
            buyoutMarkupBps: 2500,
            bidBps: 9000, // D007
            bidWeeklyCap: 0.75 ether // about three 80s a week until listing depth is measured
        });
    }
}
