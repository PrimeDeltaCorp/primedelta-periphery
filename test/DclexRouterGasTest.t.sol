// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {MockPriceOracle} from "dclex-protocol/test/MockPriceOracle.sol";
import {DclexRouter} from "../src/DclexRouter.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {DeployDclex} from "dclex-protocol/script/DeployDclex.s.sol";
import {
    DigitalIdentity
} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {HelperConfig} from "../script/HelperConfig.s.sol";
import {
    HelperConfig as DclexProtocolHelperConfig
} from "dclex-protocol/script/HelperConfig.s.sol";
import {DeployDclexPool} from "dclex-protocol/script/DeployDclexPool.s.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {Stock} from "dclex-blockchain/contracts/dclex/Stock.sol";
import {USDCMock} from "dclex-blockchain/contracts/mocks/USDCMock.sol";
import {
    UniswapV3Factory
} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {SwapRouter} from "@uniswap/v3-periphery/contracts/SwapRouter.sol";
import {Quoter} from "@uniswap/v3-periphery/contracts/lens/Quoter.sol";
import {IQuoter} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import {
    ISwapRouter
} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {
    IUniswapV3Pool
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WDEL} from "../src/WDEL.sol";

contract DclexRouterGasTest is Test {
    bytes32 internal AAPL_PRICE_FEED_ID;
    bytes32 internal NVDA_PRICE_FEED_ID;
    bytes32 internal USDC_PRICE_FEED_ID;
    address private immutable ADMIN = makeAddr("admin");
    address private immutable MASTER_ADMIN = makeAddr("master_admin");
    DigitalIdentity internal digitalIdentity;
    Stock internal aaplStock;
    Stock internal nvdaStock;
    USDCMock internal dusdToken;
    Factory private stocksFactory;
    MockPriceOracle private priceOracle;
    DclexRouter private dclexRouter;
    DclexPool private aaplPool;
    DclexPool internal nvdaPool;

    // V3 Infrastructure
    WDEL private weth;
    UniswapV3Factory private v3Factory;
    SwapRouter private v3SwapRouter;
    Quoter private v3Quoter;
    address private ethUsdcPool;

    receive() external payable {}

    function setUp() public {
        // Deploy DCLEX core infrastructure
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory contracts = deployer.run(
            ADMIN,
            MASTER_ADMIN
        );
        digitalIdentity = contracts.digitalIdentity;
        stocksFactory = contracts.stocksFactory;
        vm.startPrank(ADMIN);
        string[] memory names = new string[](2);
        string[] memory symbols = new string[](2);
        names[0] = "Apple";
        names[1] = "NVIDIA";
        symbols[0] = "AAPL";
        symbols[1] = "NVDA";
        stocksFactory.createStocks(names, symbols);
        vm.stopPrank();
        aaplStock = Stock(contracts.stocksFactory.stocks("AAPL"));
        nvdaStock = Stock(contracts.stocksFactory.stocks("NVDA"));

        // Get config for USDC and oracle
        DclexProtocolHelperConfig dclexProtocolHelperConfig = new DclexProtocolHelperConfig();
        DclexProtocolHelperConfig.NetworkConfig
            memory protocolConfig = dclexProtocolHelperConfig.getConfig();
        dusdToken = USDCMock(address(protocolConfig.dusdToken));

        // Deploy V3 infrastructure
        weth = new WDEL();
        v3Factory = new UniswapV3Factory();
        v3SwapRouter = new SwapRouter(address(v3Factory), address(weth));
        v3Quoter = new Quoter(address(v3Factory), address(weth));

        // Create and initialize ETH/USDC V3 pool
        address token0 = address(weth) < address(dusdToken)
            ? address(weth)
            : address(dusdToken);
        address token1 = address(weth) < address(dusdToken)
            ? address(dusdToken)
            : address(weth);
        ethUsdcPool = v3Factory.createPool(token0, token1, 3000);

        // Initialize pool with price (1 ETH = 3000 USDC)
        uint160 sqrtPriceX96;
        if (address(weth) < address(dusdToken)) {
            sqrtPriceX96 = 4339505179874779903; // 1 ETH = 3000 USDC
        } else {
            sqrtPriceX96 = 1363618308704293893;
        }
        IUniswapV3Pool(ethUsdcPool).initialize(sqrtPriceX96);

        // Deploy DclexRouter with V3 infrastructure
        dclexRouter = new DclexRouter(IERC20(address(dusdToken)));


        priceOracle = MockPriceOracle(address(protocolConfig.oracle));
        AAPL_PRICE_FEED_ID = dclexProtocolHelperConfig.getPriceFeedId("AAPL");
        NVDA_PRICE_FEED_ID = dclexProtocolHelperConfig.getPriceFeedId("NVDA");
        USDC_PRICE_FEED_ID = dclexProtocolHelperConfig.getPriceFeedId("USDC");
        priceOracle.setPrice(AAPL_PRICE_FEED_ID, 20 ether);
        priceOracle.setPrice(NVDA_PRICE_FEED_ID, 30 ether);
        priceOracle.setPrice(USDC_PRICE_FEED_ID, 1 ether);

        // Deploy pools for stocks using deployer
        DeployDclexPool dclexPoolDeployer = new DeployDclexPool();
        aaplPool = dclexPoolDeployer.run(
            IStock(address(aaplStock)),
            dclexProtocolHelperConfig,
            0,
            0,
            0
        );
        nvdaPool = dclexPoolDeployer.run(
            IStock(address(nvdaStock)),
            dclexProtocolHelperConfig,
            0,
            0,
            0
        );

        // Register pools in router
        dclexRouter.addPool(address(aaplStock), DclexRouter.PoolType.DCLEX, address(aaplPool), 0);
        dclexRouter.addPool(address(nvdaStock), DclexRouter.PoolType.DCLEX, address(nvdaPool), 0);

        // Mint DIDs for router and pools (needed for token transfers)
        vm.startPrank(ADMIN);
        digitalIdentity.mintAdmin(address(dclexRouter), 2, bytes32(0));
        digitalIdentity.mintAdmin(address(aaplPool), 2, bytes32(0));
        digitalIdentity.mintAdmin(address(nvdaPool), 2, bytes32(0));
        vm.stopPrank();

        setupAccount(address(this));

        vm.startPrank(address(this));
        aaplStock.approve(address(dclexRouter), 100000 ether);
        nvdaStock.approve(address(dclexRouter), 100000 ether);
        dusdToken.approve(address(dclexRouter), 100000 ether);
        vm.stopPrank();

        vm.startPrank(address(this));
        aaplStock.approve(address(aaplPool), 100000 ether);
        nvdaStock.approve(address(nvdaPool), 100000 ether);
        dusdToken.approve(address(aaplPool), 100000e6);
        dusdToken.approve(address(nvdaPool), 100000 ether);
        vm.stopPrank();

        // Initialize pools with liquidity
        aaplPool.initialize(100 ether, 2000e6, new bytes[](0));
        nvdaPool.initialize(100 ether, 2000e6, new bytes[](0));
    }

    function setupAccount(address account) private {
        dusdToken.mint(account, 1000000e6);
        vm.prank(ADMIN);
        digitalIdentity.mintAdmin(account, 0, bytes32(0));
        vm.prank(ADMIN);
        stocksFactory.forceMintStocks("AAPL", account, 100000 ether);
        vm.prank(ADMIN);
        stocksFactory.forceMintStocks("NVDA", account, 10000 ether);
    }

    function testBuyStockExactOutput() external {
        dclexRouter.buyExactOutput(
            address(aaplStock),
            1 ether,
            1000e6,
            block.timestamp + 1,
            new bytes[](0)
        );
    }

    function testSellStockExactOutput() external {
        dclexRouter.sellExactOutput(
            address(aaplStock),
            1e6,
            100 ether,
            block.timestamp + 1,
            new bytes[](0)
        );
    }

    function testBuyStockExactInput() external {
        dclexRouter.buyExactInput(
            address(aaplStock),
            1e6,
            0,
            block.timestamp + 1,
            new bytes[](0)
        );
    }

    function testSellStockExactInput() external {
        dclexRouter.sellExactInput(
            address(aaplStock),
            1 ether,
            0,
            block.timestamp + 1,
            new bytes[](0)
        );
    }

    function testStockToStockExactInput() external {
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            0,
            block.timestamp + 1,
            new bytes[](0)
        );
    }

    function testStockToStockExactOutput() external {
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(nvdaStock),
            1 ether,
            type(uint256).max,
            block.timestamp + 1,
            new bytes[](0)
        );
    }
}
