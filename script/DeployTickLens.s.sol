// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {TickLens} from "@uniswap/v3-periphery/contracts/lens/TickLens.sol";

/// @title DeployTickLens
/// @notice Deploys the stateless TickLens helper used by the DEX add-liquidity
///         range-selector chart. TickLens has no constructor args, no owner,
///         no DID — pool address is passed per call. One deploy works for
///         every present and future UniswapV3Pool created via DclexV3Factory.
contract DeployTickLens is Script {
    function run() external returns (address tickLens) {
        uint256 adminKey = vm.envUint("ADMIN_PRIVATE_KEY");

        vm.startBroadcast(adminKey);
        TickLens lens = new TickLens();
        tickLens = address(lens);
        vm.stopBroadcast();

        console.log("TickLens deployed at:", tickLens);
    }
}
