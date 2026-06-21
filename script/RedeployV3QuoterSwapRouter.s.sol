// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SwapRouter} from "@uniswap/v3-periphery/contracts/SwapRouter.sol";
import {Quoter} from "@uniswap/v3-periphery/contracts/lens/Quoter.sol";
import {PoolAddress} from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";

interface IUniswapV3Factory {
    function getPool(address, address, uint24) external view returns (address);
}

/// @notice Redeploy ONLY the V3 Quoter + SwapRouter on an existing chain
/// when periphery's PoolAddress.POOL_INIT_CODE_HASH literal was mis-pinned
/// and the previously-deployed Quoter/SwapRouter derive wrong pool
/// addresses (every quote/swap silently reverts). NPM is NOT redeployed
/// (existing LP positions would be stranded — and if NPM works in the
/// field, by definition its literal already matches the live factory).
///
/// Pre-flight: ALWAYS run script/VerifyPoolInitCodeHashLive.s.sol against
/// the same RPC first. This script also runs that check inline.
///
/// Env required: DEPLOYER_PRIVATE_KEY, V3_FACTORY, V3_WDEL.
/// Env optional: PROBE_TOKEN_A, PROBE_TOKEN_B, PROBE_FEE (any (a,b,fee)
/// tuple with a live pool — defaults to dev WDEL/dUSD/3000 via the
/// pre-flight; override for other chains).
contract RedeployV3QuoterSwapRouter is Script {
    function run() external {
        address factory = vm.envAddress("V3_FACTORY");
        address wdel = vm.envAddress("V3_WDEL");

        // Pre-flight: assert literal matches live factory before deploying
        // anything that bakes the literal in.
        address probeA = vm.envOr(
            "PROBE_TOKEN_A",
            address(0x71C95911E9a5D330f4D621842EC243EE1343292e)
        );
        address probeB = vm.envOr(
            "PROBE_TOKEN_B",
            address(0x7c615cEd4cb868dE113fbED981276CD4A1cF2B10)
        );
        uint24 probeFee = uint24(vm.envOr("PROBE_FEE", uint256(3000)));
        address livePool = IUniswapV3Factory(factory).getPool(
            probeA,
            probeB,
            probeFee
        );
        require(
            livePool != address(0),
            "Pre-flight: probe pair has no live pool. Pick a real pair via PROBE_TOKEN_A/B/PROBE_FEE."
        );
        address derived = PoolAddress.computeAddress(
            factory,
            PoolAddress.getPoolKey(probeA, probeB, probeFee)
        );
        require(
            derived == livePool,
            "Pre-flight: POOL_INIT_CODE_HASH does not match this factory. Refusing to deploy a periphery contract that would compute wrong pool addresses. Re-pin the literal (PoolAddress.sol + PoolInitCodeHash.t.sol::CANONICAL) before retrying."
        );
        console.log("Pre-flight OK: literal matches factory");
        console.log("  factory:", factory);
        console.log("  live pool:", livePool);

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        vm.startBroadcast(deployerKey);
        SwapRouter swapRouter = new SwapRouter(factory, wdel);
        Quoter quoter = new Quoter(factory, wdel);
        vm.stopBroadcast();

        console.log("New SwapRouter:", address(swapRouter));
        console.log("New Quoter:    ", address(quoter));
    }
}
