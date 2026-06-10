// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.12;

import "forge-std/Test.sol";
import {UniswapV3Pool} from "@uniswap/v3-core/contracts/UniswapV3Pool.sol";
import {PoolAddress} from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";

contract PoolInitCodeHashTest is Test {
    function test_poolInitCodeHashMatchesCreationCode() public {
        bytes32 actual = keccak256(type(UniswapV3Pool).creationCode);
        assertEq(
            PoolAddress.POOL_INIT_CODE_HASH,
            actual,
            "PoolAddress.POOL_INIT_CODE_HASH literal is stale. Update it to match keccak256(type(UniswapV3Pool).creationCode) after any change to foundry.toml (evm_version, optimizer_runs, via_ir, bytecodeHash) or to lib/v3-core. NPM/Quoter/SwapRouter derive pool addresses via CREATE2 with this literal; a mismatch means derived addresses do not match factory.createPool deployed addresses and every mint/quote/swap path that uses derivation reverts."
        );
    }
}
