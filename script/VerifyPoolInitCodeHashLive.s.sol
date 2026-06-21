// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.12;

import {Script, console} from "forge-std/Script.sol";
import {PoolAddress} from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";

interface IUniswapV3Factory {
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address);
}

/// @notice Pre-broadcast guard for any V3 periphery deploy (Quoter,
/// SwapRouter, NPM, DclexPositionManager). Asserts that
/// PoolAddress.POOL_INIT_CODE_HASH CREATE2-derives the same address that
/// the LIVE factory reports for a known pool.
///
/// If this fails, you are about to deploy a periphery contract that will
/// compute wrong pool addresses → every quote/swap/mint will silently
/// revert. The fix is to re-extract the canonical hash from the live NPM
/// bytecode (see PoolAddress.sol natspec) and pin it in:
///   1. lib/v3-periphery/contracts/libraries/PoolAddress.sol
///   2. test/PoolInitCodeHash.t.sol::CANONICAL
/// then re-run this guard.
///
/// Required env: V3_FACTORY, PROBE_TOKEN_A, PROBE_TOKEN_B (any pair that
/// has a deployed pool at PROBE_FEE), PROBE_FEE.
/// Defaults to dev WDEL/dUSD/3000 if env unset.
contract VerifyPoolInitCodeHashLive is Script {
    function run() external view {
        address factory = vm.envOr(
            "V3_FACTORY",
            address(0x948B3c65b89DF0B4894ABE91E6D02FE579834F8F)
        );
        address tokenA = vm.envOr(
            "PROBE_TOKEN_A",
            address(0x71C95911E9a5D330f4D621842EC243EE1343292e) // WDEL (dev)
        );
        address tokenB = vm.envOr(
            "PROBE_TOKEN_B",
            address(0x7c615cEd4cb868dE113fbED981276CD4A1cF2B10) // dUSD (dev)
        );
        uint24 fee = uint24(vm.envOr("PROBE_FEE", uint256(3000)));

        address live = IUniswapV3Factory(factory).getPool(tokenA, tokenB, fee);
        require(
            live != address(0),
            "VerifyPoolInitCodeHashLive: probe pair has no live pool on this factory. Pick a different PROBE_TOKEN_A/B or check V3_FACTORY env."
        );

        address derived = PoolAddress.computeAddress(
            factory,
            PoolAddress.getPoolKey(tokenA, tokenB, fee)
        );

        console.log("factory:", factory);
        console.log("probe tokens:", tokenA, tokenB);
        console.log("probe fee:", fee);
        console.log("live pool:", live);
        console.log("derived:  ", derived);

        require(
            derived == live,
            "VerifyPoolInitCodeHashLive: PoolAddress.POOL_INIT_CODE_HASH does NOT match this factory deployed pools. Periphery deploy MUST NOT proceed - see script natspec for re-pinning recipe."
        );

        console.log("OK: POOL_INIT_CODE_HASH matches live factory.");
    }
}
