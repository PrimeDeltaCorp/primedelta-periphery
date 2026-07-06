// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {UniswapV3Pool} from "@uniswap/v3-core/contracts/UniswapV3Pool.sol";

/// @dev Prints keccak256(type(UniswapV3Pool).creationCode) under the CURRENT
/// compile profile — the value to pin in PoolAddress.POOL_INIT_CODE_HASH when
/// deploying a fresh V3 factory. Run with the SAME profile as the deploy.
contract LogPoolInitCodeHash is Script {
    function run() external pure {
        console.logBytes32(keccak256(type(UniswapV3Pool).creationCode));
    }
}
