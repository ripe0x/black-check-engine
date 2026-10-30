// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IFWAFactory} from "../src/interfaces/IFWA.sol";
import {IController} from "../src/interfaces/IController.sol";
import {IChecksOriginals, IChecksEdition} from "../src/interfaces/IChecks.sol";
import {Engine, IShapesBacking, ICoinBurn} from "../src/core/Engine.sol";
import {FwaV2Controller} from "../src/fwa/FwaV2Controller.sol";
import {Coin} from "../src/token/Coin.sol";

/// @notice The one deployment routine. Tests, the anvil rehearsal and any future mainnet script call `deploySystem`
///         and `postflight`; environments differ only in the `Config` values.
/// @dev Creation order is fixed so the controller can be built with the engine proxy's address before the proxy
///      exists (the engine is initialized with the controller, the controller is immutable on the engine).
///      `deployer` must be the account whose nonce the `new` calls use (the test contract, or the broadcaster).
abstract contract DeploySystem is CommonBase {
    struct Config {
        address council; // sole timelock proposer (Safe multisig in production)
        address guardian; // extra canceller; halts and resumes draws
        address operator; // project owner: halt only
        uint256 delay; // timelock delay, at least 7 days
        IChecksOriginals checks;
        IChecksEdition editions;
        IShapesBacking shapes;
        IFWAFactory fwaFactory;
        address fwaImplementation; // pinned; the controller refuses a pool of any other code
        bytes32 poolSalt;
        string coinName;
        string coinSymbol;
        uint256 coinSupply;
        address coinRecipient; // the venue's liquidity contract in production
        uint256[8] tierNotional;
        uint32[7] drawsToCompose;
        uint256[7] composeBurn;
        uint256[8] coinPrice;
        Engine.Params params;
    }

    struct System {
        TimelockController timelock;
        Coin coin;
        Engine implementation;
        Engine engine;
        FwaV2Controller controller;
    }

    error Postflight(string what);

    function deploySystem(Config memory c, address deployer) internal returns (System memory s) {
        address[] memory proposers = new address[](1);
        proposers[0] = c.council;
        address[] memory executors = new address[](1); // address(0): anyone executes once the delay has passed
        s.timelock = new TimelockController(c.delay, proposers, executors, deployer);
        s.timelock.grantRole(s.timelock.CANCELLER_ROLE(), c.guardian);
        s.timelock.renounceRole(s.timelock.DEFAULT_ADMIN_ROLE(), deployer);

        s.coin = new Coin(c.coinName, c.coinSymbol, c.coinSupply, c.coinRecipient);
        s.implementation = new Engine(c.checks, c.editions, c.shapes, ICoinBurn(address(s.coin)));
        address enginePredicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        s.controller =
            new FwaV2Controller(enginePredicted, c.fwaFactory, c.fwaImplementation, c.poolSalt, address(c.checks), address(c.shapes));
        s.engine = Engine(
            payable(
                address(
                    new ERC1967Proxy(
                        address(s.implementation),
                        abi.encodeCall(
                            Engine.initialize,
                            (
                                address(s.timelock),
                                c.operator,
                                c.guardian,
                                IController(address(s.controller)),
                                c.tierNotional,
                                c.drawsToCompose,
                                c.composeBurn,
                                c.coinPrice,
                                c.params
                            )
                        )
                    )
                )
            )
        );
        if (address(s.engine) != enginePredicted) revert Postflight("engine address");
    }

    /// @notice Reverts unless the deployed system matches `c` and holds no deployer power.
    function postflight(System memory s, Config memory c, address deployer) internal view {
        TimelockController t = s.timelock;
        if (c.council == address(0) || c.guardian == address(0) || c.operator == address(0)) revert Postflight("roles unset");
        if (c.council == c.operator || c.guardian == c.operator) revert Postflight("operator holds council or guardian");
        if (c.delay < 7 days || t.getMinDelay() != c.delay) revert Postflight("delay");
        if (t.hasRole(t.DEFAULT_ADMIN_ROLE(), deployer)) revert Postflight("deployer is timelock admin");
        if (!t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(t))) revert Postflight("timelock not self-administered");
        if (!t.hasRole(t.PROPOSER_ROLE(), c.council) || t.hasRole(t.PROPOSER_ROLE(), c.operator)) revert Postflight("proposer");
        if (t.hasRole(t.PROPOSER_ROLE(), deployer) || t.hasRole(t.CANCELLER_ROLE(), deployer)) revert Postflight("deployer role");
        if (!t.hasRole(t.CANCELLER_ROLE(), c.guardian)) revert Postflight("guardian cancel");
        if (!t.hasRole(t.EXECUTOR_ROLE(), address(0))) revert Postflight("open execution");

        Engine e = s.engine;
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        if (address(uint160(uint256(vm.load(address(e), implSlot)))) != address(s.implementation)) revert Postflight("impl");
        if (e.timelock() != address(t) || e.operator() != c.operator || e.guardian() != c.guardian) revert Postflight("engine roles");
        if (address(e.controller()) != address(s.controller) || !e.halted()) revert Postflight("engine state");
        if (address(e.coin()) != address(s.coin) || address(e.checks()) != address(c.checks)) revert Postflight("engine deps");
        for (uint256 i; i < 8; ++i) {
            if (e.tierNotional(i) != c.tierNotional[i] || e.coinPrice(i) != c.coinPrice[i]) revert Postflight("schedule");
        }

        FwaV2Controller k = s.controller;
        if (k.engine() != address(e) || k.implementation() != c.fwaImplementation) revert Postflight("controller");
        if (address(k.pool()) != c.fwaFactory.predictPoolAddress(address(k), c.poolSalt)) revert Postflight("pool address");
        if (c.fwaFactory.implementation() != c.fwaImplementation) revert Postflight("FWA implementation moved");

        if (s.coin.totalSupply() != c.coinSupply || s.coin.balanceOf(c.coinRecipient) != c.coinSupply) revert Postflight("coin");
    }
}
