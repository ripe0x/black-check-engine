// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FwaFeeRelay, FwaFeeBuyer} from "../src/periphery/FwaFeeRoutes.sol";

interface IFactoryFee {
    function poolCreationFee() external view returns (uint256);
    function fwaToken() external view returns (address);
}

interface IPoolOwnerCreate {
    function createPool(bytes32 salt) external returns (address);
    function factory() external view returns (address);
    function pool() external view returns (address);
}

interface IERC20Min {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/// @notice The owner's FWA pool creation step, run from the wallet that holds the FWA (broadcast by the owner).
///         ROUTE=relay (default): converts FWA_IN of the caller's FWA into ≥ 50,000 FWA held by the pool owner through
///         FwaFeeRelay (sell then buy inside one PoolManager unlock; ~2% cost, measured on the fork). ROUTE=buy: spends
///         ETH_IN buying the fee with ETH through FwaFeeBuyer. Then creates the pool (anyone may).
/// @dev Env: POOL_OWNER, POOL_MANAGER (default mainnet), ROUTE, FWA_IN_WEI or ETH_IN_WEI, POOL_SALT (string).
contract FwaFee is Script {
    function run() external {
        IPoolOwnerCreate owner_ = IPoolOwnerCreate(vm.envAddress("POOL_OWNER"));
        address pm = vm.envOr("POOL_MANAGER", address(0x000000000004444c5dc75cB358380D2e3dE08A90));
        IFactoryFee factory = IFactoryFee(owner_.factory());
        address fwa = factory.fwaToken();
        uint256 fee = factory.poolCreationFee();
        string memory route = vm.envOr("ROUTE", string("relay"));
        vm.startBroadcast();
        if (fee != 0 && IERC20Min(fwa).balanceOf(address(owner_)) < fee) {
            if (keccak256(bytes(route)) == keccak256("relay")) {
                uint256 fwaIn = vm.envUint("FWA_IN_WEI");
                FwaFeeRelay relay = new FwaFeeRelay(IPoolManager(pm), fwa);
                IERC20Min(fwa).approve(address(relay), fwaIn);
                relay.relay(fwaIn, address(owner_), fee);
            } else {
                FwaFeeBuyer buyer = new FwaFeeBuyer(IPoolManager(pm), fwa);
                buyer.buyTo{value: vm.envUint("ETH_IN_WEI")}(address(owner_), fee);
            }
        }
        address created = owner_.createPool(keccak256(bytes(vm.envOr("POOL_SALT", string("collection-games.v1")))));
        vm.stopBroadcast();
        console2.log("FWA pool", created);
    }
}
