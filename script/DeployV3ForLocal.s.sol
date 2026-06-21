// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SwapRouter} from "@uniswap/v3-periphery/contracts/SwapRouter.sol";
import {Quoter} from "@uniswap/v3-periphery/contracts/lens/Quoter.sol";
import {PoolAddress} from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import {UniswapV3Pool} from "@uniswap/v3-core/contracts/UniswapV3Pool.sol";
import {WDEL} from "../src/WDEL.sol";
import {DclexV3Factory} from "../src/DclexV3Factory.sol";
import {DclexPositionManager} from "../src/DclexPositionManager.sol";
import {DclexNFTDescriptor} from "../src/DclexNFTDescriptor.sol";
import {IDID} from "dclex-blockchain/contracts/interfaces/IDID.sol";

/// @title DeployV3ForLocal
/// @notice Deploys full V3 infrastructure with admin-only pool creation and DID-gated positions
contract DeployV3ForLocal is Script {
    function run(address didAddress)
        external
        returns (
            address weth,
            address v3Factory,
            address v3SwapRouter,
            address v3Quoter,
            address v3PositionManager
        )
    {
        require(
            PoolAddress.POOL_INIT_CODE_HASH == keccak256(type(UniswapV3Pool).creationCode),
            "POOL_INIT_CODE_HASH stale vs UniswapV3Pool.creationCode for current compile settings"
        );

        vm.startBroadcast();

        WDEL wethMock = new WDEL();
        weth = address(wethMock);
        console.log("WDEL deployed at:", weth);

        DclexV3Factory factory = new DclexV3Factory();
        v3Factory = address(factory);
        console.log("DclexV3Factory deployed at:", v3Factory);

        SwapRouter swapRouter = new SwapRouter(v3Factory, weth);
        v3SwapRouter = address(swapRouter);
        console.log("V3 SwapRouter deployed at:", v3SwapRouter);

        Quoter quoter = new Quoter(v3Factory, weth);
        v3Quoter = address(quoter);
        console.log("V3 Quoter deployed at:", v3Quoter);

        DclexNFTDescriptor descriptor = new DclexNFTDescriptor(msg.sender, "http://local/nft/positions/");
        console.log("DclexNFTDescriptor deployed at:", address(descriptor));

        DclexPositionManager positionManager = new DclexPositionManager(
            v3Factory, weth, address(descriptor), IDID(didAddress)
        );
        v3PositionManager = address(positionManager);
        console.log("DclexPositionManager deployed at:", v3PositionManager);

        vm.stopBroadcast();
    }
}
