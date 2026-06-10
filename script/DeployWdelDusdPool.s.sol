// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {DclexRouter} from "src/DclexRouter.sol";

/// @title DeployWdelDusdPool
/// @notice Creates the WDEL/dUSD V3 pool, initializes it at $10/WDEL,
///         mints DID for the pool + WDEL token, and registers the pool
///         on DclexRouter so WDEL appears as a swappable token.
///
/// @dev Initial liquidity is NOT seeded — WDEL.mint() is local-only
///      (chainid 31337) and admin must wrap real DEL to add liquidity.
///      Run this script first, then manually add liquidity from a wallet
///      that holds DEL + can mint dUSD (admin via factory.forceMintStablecoin).
///
///      Broadcaster must hold:
///      - DEFAULT_ADMIN_ROLE on DID (for mintAdmin)
///      - DclexRouter.owner (for addPool)
///      On primedelta-{dev,testnet} both are ADMIN.
contract DeployWdelDusdPool is Script {
    uint24 internal constant FEE_TIER = 3000;

    /// @param v3Factory  DclexV3Factory address
    /// @param wdel       WDEL token address
    /// @param dusd       dUSD stablecoin address
    /// @param did        DigitalIdentity address
    /// @param router     DclexRouter address (must be owned by msg.sender)
    /// @param priceUsd6  Price per 1 WDEL in dUSD, 6 decimals (e.g. 10e6 for $10)
    function run(
        address v3Factory,
        address wdel,
        address dusd,
        address did,
        address router,
        uint256 priceUsd6
    ) external returns (address pool) {
        uint256 adminKey = vm.envUint("ADMIN_PRIVATE_KEY");

        console.log("=== WDEL/dUSD V3 Pool Deploy ===");
        console.log("WDEL:    ", wdel);
        console.log("dUSD:    ", dusd);
        console.log("priceUsd:", priceUsd6 / 1e6);

        vm.startBroadcast(adminKey);

        // Create-or-fetch pool. createPool reverts on duplicate, getPool returns
        // zero before creation — so fetch first, create on zero.
        pool = IUniswapV3Factory(v3Factory).getPool(wdel, dusd, FEE_TIER);
        if (pool == address(0)) {
            pool = IUniswapV3Factory(v3Factory).createPool(wdel, dusd, FEE_TIER);
            console.log("Created pool:", pool);
        } else {
            console.log("Pool already exists:", pool);
        }

        // Initialize price if pool isn't yet primed.
        (uint160 sqrtPriceX96, , , , , uint8 feeProtocol, ) = IUniswapV3Pool(pool).slot0();
        if (sqrtPriceX96 == 0) {
            uint160 initSqrtPriceX96 = _calcSqrtPrice(wdel, dusd, priceUsd6);
            IUniswapV3Pool(pool).initialize(initSqrtPriceX96);
            console.log("Initialized sqrtPriceX96:", uint256(initSqrtPriceX96));
        } else {
            console.log("Pool already initialized");
        }

        // Match DclexPool's 15% protocol-fee cut as closely as Uniswap V3's
        // discrete buckets allow. feeProtocol denominator ∈ {0, 4..10};
        // 7 → 1/7 ≈ 14.29% per side, the closest under 15%. setFeeProtocol
        // is onlyFactoryOwner, so this only works when broadcaster ==
        // v3Factory.owner() (which is ADMIN here — see DeployV3Production).
        if (feeProtocol == 0) {
            IUniswapV3Pool(pool).setFeeProtocol(7, 7);
            console.log("Set feeProtocol to 7|7 (~14.29%)");
        }

        // DID for the pool address (contract type = 2)
        DigitalIdentity didContract = DigitalIdentity(did);
        if (didContract.balanceOf(pool) == 0) {
            didContract.mintAdmin(pool, 2, bytes32(0));
            console.log("Minted DID for pool");
        }

        // DID for WDEL token itself (so transfers via router work)
        if (didContract.balanceOf(wdel) == 0) {
            didContract.mintAdmin(wdel, 2, bytes32(0));
            console.log("Minted DID for WDEL token");
        }

        // Register WDEL on router. allStockTokens() includes V3 tokens, so this
        // makes WDEL appear as a swappable asset.
        DclexRouter(payable(router)).addPool(wdel, DclexRouter.PoolType.V3, pool, FEE_TIER);
        console.log("Registered WDEL on router as V3 pool");

        vm.stopBroadcast();
    }

    /// @dev V3 sqrtPriceX96 for WDEL(18dec)/dUSD(6dec) at `priceUsd6` (USD per WDEL, 6dec).
    /// Same logic as DeployAMMStocks._calcSqrtPrice — extracted so it can be
    /// reused for prod WDEL pool deploy.
    function _calcSqrtPrice(
        address wdel,
        address dusd,
        uint256 priceUsd6
    ) internal pure returns (uint160) {
        bool wdelIsToken0 = wdel < dusd;
        uint256 sqrt = Math.sqrt(priceUsd6);
        if (wdelIsToken0) {
            // sqrtPriceX96 = sqrt(priceUsd6 / 1e18) * 2^96 = sqrt(priceUsd6) * 2^96 / 1e9
            return uint160((sqrt << 96) / 1e9);
        } else {
            // sqrtPriceX96 = sqrt(1e18 / priceUsd6) * 2^96 = 1e9 * 2^96 / sqrt(priceUsd6)
            return uint160((1e9 << 96) / sqrt);
        }
    }
}
