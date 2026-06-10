// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SwapRouter} from "@uniswap/v3-periphery/contracts/SwapRouter.sol";
import {Quoter} from "@uniswap/v3-periphery/contracts/lens/Quoter.sol";
import {TickLens} from "@uniswap/v3-periphery/contracts/lens/TickLens.sol";
import {PoolAddress} from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import {UniswapV3Pool} from "@uniswap/v3-core/contracts/UniswapV3Pool.sol";
import {WDEL} from "../src/WDEL.sol";
import {DclexV3Factory} from "../src/DclexV3Factory.sol";
import {DclexPositionManager} from "../src/DclexPositionManager.sol";
import {IDID} from "dclex-blockchain/contracts/interfaces/IDID.sol";

/// @title DeployV3Production
/// @notice Deploys V3 infrastructure + DclexRouter for production
/// @dev Requires: Factory and DID already deployed (from dclex-blockchain)
///      Uses admin key for all operations (must have DEFAULT_ADMIN_ROLE on Factory)
contract DeployV3Production is Script {
    struct V3Contracts {
        address wdel;
        address v3Factory;
        address swapRouter;
        address quoter;
        address positionManager;
        address tickLens;
    }

    /// @notice Deploy V3 infrastructure only (no DclexRouter — that's in DeployDclexRouterWithPools)
    /// @param did DigitalIdentity contract address (for DclexPositionManager DID gating)
    function run(address did) external returns (V3Contracts memory result) {
        require(
            PoolAddress.POOL_INIT_CODE_HASH == keccak256(type(UniswapV3Pool).creationCode),
            "POOL_INIT_CODE_HASH stale"
        );

        uint256 adminKey = vm.envUint("ADMIN_PRIVATE_KEY");

        console.log("\n=== Deploying V3 Infrastructure ===");
        console.log("DID:", did);

        vm.startBroadcast(adminKey);

        WDEL wdel = new WDEL();
        result.wdel = address(wdel);
        console.log("WDEL:", result.wdel);

        DclexV3Factory v3Factory = new DclexV3Factory();
        result.v3Factory = address(v3Factory);
        console.log("DclexV3Factory:", result.v3Factory);

        SwapRouter swapRouter = new SwapRouter(result.v3Factory, result.wdel);
        result.swapRouter = address(swapRouter);
        console.log("SwapRouter:", result.swapRouter);

        Quoter quoter = new Quoter(result.v3Factory, result.wdel);
        result.quoter = address(quoter);
        console.log("Quoter:", result.quoter);

        DclexPositionManager npm = new DclexPositionManager(
            result.v3Factory,
            result.wdel,
            address(0),
            IDID(did)
        );
        result.positionManager = address(npm);
        console.log("DclexPositionManager:", result.positionManager);

        // Stateless lens used by the DEX add-liquidity histogram. No
        // constructor args, no DID gating, factory-agnostic — one deploy
        // per chain serves every present and future V3 pool.
        TickLens tickLens = new TickLens();
        result.tickLens = address(tickLens);
        console.log("TickLens:", result.tickLens);

        vm.stopBroadcast();

        console.log("\n=== V3 Infrastructure Deployed ===");
        console.log("Next: run DeployDclexRouterWithPools with SwapRouter and Quoter addresses");
    }
}
