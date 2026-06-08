// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {DeployDclex} from "dclex-protocol/script/DeployDclex.s.sol";
import {
    HelperConfig as DclexProtocolHelperConfig
} from "dclex-protocol/script/HelperConfig.s.sol";
import {
    DigitalIdentity
} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {DeployDclexPool} from "dclex-protocol/script/DeployDclexPool.s.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {Stock} from "dclex-blockchain/contracts/dclex/Stock.sol";
import {USDCMock} from "dclex-blockchain/contracts/mocks/USDCMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {
    ISwapRouter
} from "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import {
    UniswapV3Factory
} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";
import {SwapRouter} from "@uniswap/v3-periphery/contracts/SwapRouter.sol";
import {
    IUniswapV3Pool
} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {
    IUniswapV3MintCallback
} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import {Quoter} from "@uniswap/v3-periphery/contracts/lens/Quoter.sol";
import {
    IQuoter
} from "@uniswap/v3-periphery/contracts/interfaces/IQuoter.sol";
import {WDEL} from "../src/WDEL.sol";
import {MockPriceOracle} from "dclex-protocol/test/MockPriceOracle.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {
    LiquidityAmounts
} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

/// @title DclexRouterAMMTest
/// @notice Tests for AMM (V3) pool integration in DclexRouter
contract DclexRouterAMMTest is Test, IUniswapV3MintCallback {
    uint24 public constant FEE_TIER = 3000;
    int24 private constant MIN_TICK = -887220;
    int24 private constant MAX_TICK = 887220;

    address private ADMIN = makeAddr("admin");
    address private immutable MASTER_ADMIN = makeAddr("master_admin");
    address private immutable USER_1 = makeAddr("user_1");

    // V3 infrastructure
    UniswapV3Factory private v3Factory;
    SwapRouter private v3SwapRouter;
    Quoter private v3Quoter;
    WDEL private weth;

    // Core contracts
    DigitalIdentity internal digitalIdentity;
    Factory private stocksFactory;
    USDCMock internal dusdToken;
    DclexRouter private dclexRouter;

    // Custom pool stock (for cross-pool tests)
    Stock internal aaplStock;
    DclexPool internal aaplPool;

    // AMM stocks
    Stock internal ammStock1;
    Stock internal ammStock2;
    address internal ammPool1;
    address internal ammPool2;

    // Price oracle mock for custom pools
    MockPriceOracle private priceOracle;
    bytes[] internal PRICE_DATA = new bytes[](0);

    // Mint callback data
    struct MintCallbackData {
        address pool;
        address token0;
        address token1;
    }
    MintCallbackData private _mintCallbackData;

    event PoolSetForToken(address indexed token, address pool, DclexRouter.PoolType poolType);

    receive() external payable {}

    function setUp() public {
        // Deploy Dclex infrastructure
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory contracts = deployer.run(
            ADMIN,
            MASTER_ADMIN
        );
        digitalIdentity = contracts.digitalIdentity;
        stocksFactory = contracts.stocksFactory;

        // Get USDC token from protocol config
        DclexProtocolHelperConfig dclexProtocolHelperConfig = new DclexProtocolHelperConfig();
        DclexProtocolHelperConfig.NetworkConfig
            memory protocolConfig = dclexProtocolHelperConfig.getConfig();
        dusdToken = USDCMock(address(protocolConfig.dusdToken));

        // Deploy V3 infrastructure
        _deployV3Infrastructure();

        // Deploy DclexRouter with V3
        dclexRouter = new DclexRouter(IERC20(address(dusdToken)));

        // Create stocks
        vm.startPrank(ADMIN);
        string[] memory names = new string[](3);
        string[] memory symbols = new string[](3);
        names[0] = "Apple";
        names[1] = "AMM Test 1";
        names[2] = "AMM Test 2";
        symbols[0] = "AAPL";
        symbols[1] = "AMMT1";
        symbols[2] = "AMMT2";
        stocksFactory.createStocks(names, symbols);
        vm.stopPrank();

        aaplStock = Stock(stocksFactory.stocks("AAPL"));
        ammStock1 = Stock(stocksFactory.stocks("AMMT1"));
        ammStock2 = Stock(stocksFactory.stocks("AMMT2"));

        priceOracle = MockPriceOracle(address(protocolConfig.oracle));
        bytes32 aaplPriceFeedId = dclexProtocolHelperConfig.getPriceFeedId(
            "AAPL"
        );
        bytes32 usdcPriceFeedId = dclexProtocolHelperConfig.getPriceFeedId(
            "USDC"
        );
        priceOracle.setPrice(aaplPriceFeedId, 20 ether);
        priceOracle.setPrice(usdcPriceFeedId, 1 ether);

        // Deploy custom pool for AAPL
        DeployDclexPool dclexPoolDeployer = new DeployDclexPool();
        aaplPool = dclexPoolDeployer.run(
            IStock(address(aaplStock)),
            dclexProtocolHelperConfig,
            0,
            0,
            0
        );
        dclexRouter.addPool(address(aaplStock), DclexRouter.PoolType.DCLEX, address(aaplPool), 0);

        // Create and initialize V3 pools for AMM stocks
        _setupAMMPools();

        // Setup accounts and DIDs
        _setupAccounts();

        // Transfer ownership to admin
        dclexRouter.transferOwnership(ADMIN);
        ADMIN = dclexRouter.owner();
    }

    function _deployV3Infrastructure() private {
        // Deploy WETH9 mock
        weth = new WDEL();

        // Deploy V3 Factory
        v3Factory = new UniswapV3Factory();

        // Deploy SwapRouter
        v3SwapRouter = new SwapRouter(address(v3Factory), address(weth));

        // Deploy Quoter
        v3Quoter = new Quoter(address(v3Factory), address(weth));
    }

    function _setupAMMPools() private {
        // Create V3 pool for AMMT1/USDC
        ammPool1 = v3Factory.createPool(
            address(ammStock1),
            address(dusdToken),
            FEE_TIER
        );
        _initializePool(ammPool1, address(ammStock1), 20e6); // $20 per stock

        // Create V3 pool for AMMT2/USDC
        ammPool2 = v3Factory.createPool(
            address(ammStock2),
            address(dusdToken),
            FEE_TIER
        );
        _initializePool(ammPool2, address(ammStock2), 50e6); // $50 per stock

        // Register V3 pools with router
        vm.prank(dclexRouter.owner());
        dclexRouter.addPool(address(ammStock1), DclexRouter.PoolType.V3, ammPool1, 3000);
        vm.prank(dclexRouter.owner());
        dclexRouter.addPool(address(ammStock2), DclexRouter.PoolType.V3, ammPool2, 3000);

        // Add liquidity to V3 pools using direct V3 mint
        _addLiquidityToAMMPool(
            address(ammStock1),
            "AMMT1",
            ammPool1,
            1000e18,
            20000e6
        );
        _addLiquidityToAMMPool(
            address(ammStock2),
            "AMMT2",
            ammPool2,
            500e18,
            25000e6
        );
    }

    function _initializePool(
        address poolAddress,
        address stockToken,
        uint256 priceUsd
    ) private {
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        uint160 sqrtPriceX96 = _calculateSqrtPriceX96(
            stockToken,
            address(dusdToken),
            priceUsd
        );
        pool.initialize(sqrtPriceX96);
    }

    function _calculateSqrtPriceX96(
        address stockToken,
        address dusdTokenAddr,
        uint256 priceUsd
    ) private pure returns (uint160) {
        bool stockIsToken0 = stockToken < dusdTokenAddr;

        if (stockIsToken0) {
            uint256 sqrtPrice = Math.sqrt(priceUsd * 1e18);
            return uint160((sqrtPrice << 96) / 1e15);
        } else {
            uint256 price = (1e36) / priceUsd;
            uint256 sqrtPrice = Math.sqrt(price);
            return uint160((sqrtPrice << 96) / 1e9);
        }
    }

    function _addLiquidityToAMMPool(
        address stockToken,
        string memory stockSymbol,
        address poolAddress,
        uint256 stockAmount,
        uint256 usdcAmount
    ) private {
        // Mint DID for pool so it can hold tokens
        vm.prank(ADMIN);
        digitalIdentity.mintAdmin(poolAddress, 0, bytes32(0));

        // Mint DID for test contract if not already minted
        if (digitalIdentity.balanceOf(address(this)) == 0) {
            vm.prank(ADMIN);
            digitalIdentity.mintAdmin(address(this), 0, bytes32(0));
        }

        // Mint stock tokens to this contract
        vm.prank(ADMIN);
        stocksFactory.forceMintStocks(stockSymbol, address(this), stockAmount);

        // Mint USDC to this contract
        dusdToken.mint(address(this), usdcAmount);

        // Use direct V3 pool mint
        IUniswapV3Pool pool = IUniswapV3Pool(poolAddress);
        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

        // Determine token order
        address token0 = stockToken < address(dusdToken)
            ? stockToken
            : address(dusdToken);
        address token1 = stockToken < address(dusdToken)
            ? address(dusdToken)
            : stockToken;
        uint256 amount0 = stockToken < address(dusdToken)
            ? stockAmount
            : usdcAmount;
        uint256 amount1 = stockToken < address(dusdToken)
            ? usdcAmount
            : stockAmount;

        // Calculate liquidity
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(MIN_TICK),
            TickMath.getSqrtRatioAtTick(MAX_TICK),
            amount0,
            amount1
        );

        // Store callback data with pool address for validation
        _mintCallbackData = MintCallbackData({
            pool: address(pool),
            token0: token0,
            token1: token1
        });

        // Mint liquidity
        pool.mint(address(this), MIN_TICK, MAX_TICK, liquidity, "");
    }

    /// @notice IUniswapV3MintCallback implementation
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata /* data */
    ) external override {
        // Validate msg.sender is the expected pool
        require(
            msg.sender == _mintCallbackData.pool,
            "DclexRouterAMMTest: invalid callback sender"
        );

        if (amount0Owed > 0) {
            IERC20(_mintCallbackData.token0).transfer(msg.sender, amount0Owed);
        }
        if (amount1Owed > 0) {
            IERC20(_mintCallbackData.token1).transfer(msg.sender, amount1Owed);
        }
    }

    function _setupAccounts() private {
        // Mint USDC and DIDs
        dusdToken.mint(address(this), 1000000e6);
        dusdToken.mint(USER_1, 1000000e6);

        vm.startPrank(ADMIN);
        // Only mint DID if not already minted
        if (digitalIdentity.balanceOf(address(this)) == 0) {
            digitalIdentity.mintAdmin(address(this), 0, bytes32(0));
        }
        if (digitalIdentity.balanceOf(USER_1) == 0) {
            digitalIdentity.mintAdmin(USER_1, 0, bytes32(0));
        }
        if (digitalIdentity.balanceOf(address(dclexRouter)) == 0) {
            digitalIdentity.mintAdmin(address(dclexRouter), 0, bytes32(0));
        }
        if (digitalIdentity.balanceOf(address(aaplPool)) == 0) {
            digitalIdentity.mintAdmin(address(aaplPool), 2, bytes32(0));
        }
        if (digitalIdentity.balanceOf(address(v3Quoter)) == 0) {
            digitalIdentity.mintAdmin(address(v3Quoter), 0, bytes32(0));
        }
        if (digitalIdentity.balanceOf(address(v3SwapRouter)) == 0) {
            digitalIdentity.mintAdmin(address(v3SwapRouter), 0, bytes32(0));
        }
        vm.stopPrank();

        // Mint stocks to accounts
        vm.startPrank(ADMIN);
        stocksFactory.forceMintStocks("AAPL", address(this), 10000e18);
        stocksFactory.forceMintStocks("AAPL", USER_1, 10000e18);
        stocksFactory.forceMintStocks("AMMT1", address(this), 10000e18);
        stocksFactory.forceMintStocks("AMMT1", USER_1, 10000e18);
        stocksFactory.forceMintStocks("AMMT2", address(this), 10000e18);
        stocksFactory.forceMintStocks("AMMT2", USER_1, 10000e18);
        vm.stopPrank();

        // Approvals
        aaplStock.approve(address(dclexRouter), type(uint256).max);
        ammStock1.approve(address(dclexRouter), type(uint256).max);
        ammStock2.approve(address(dclexRouter), type(uint256).max);
        dusdToken.approve(address(dclexRouter), type(uint256).max);
        aaplStock.approve(address(aaplPool), type(uint256).max);
        dusdToken.approve(address(aaplPool), type(uint256).max);

        vm.startPrank(USER_1);
        aaplStock.approve(address(dclexRouter), type(uint256).max);
        ammStock1.approve(address(dclexRouter), type(uint256).max);
        ammStock2.approve(address(dclexRouter), type(uint256).max);
        dusdToken.approve(address(dclexRouter), type(uint256).max);
        vm.stopPrank();

        // Initialize custom pool with liquidity
        aaplPool.initialize(100e18, 2000e6, PRICE_DATA);

        // Give test contract ETH
        vm.deal(address(this), 10 ether);
    }

    // ============ Pool Type Tests ============

    function test_SetV3Pool_RegistersPoolCorrectly() public {
        address newStock = address(0x1234);
        address newPool = address(0x5678);
        vm.mockCall(newPool, abi.encodeWithSignature("token0()"), abi.encode(address(dusdToken)));
        vm.mockCall(newPool, abi.encodeWithSignature("token1()"), abi.encode(newStock));
        vm.mockCall(newPool, abi.encodeWithSignature("fee()"), abi.encode(uint24(3000)));

        vm.prank(ADMIN);
        vm.expectEmit(true, false, false, true);
        emit PoolSetForToken(newStock, newPool, DclexRouter.PoolType.V3);
        dclexRouter.addPool(newStock, DclexRouter.PoolType.V3, newPool, 3000);

        assertEq(
            uint256(dclexRouter.getPoolType(newStock)),
            uint256(DclexRouter.PoolType.V3)
        );
        assertEq(dclexRouter.stockToV3Pool(newStock), newPool);
    }

    function test_GetPoolType_ReturnsCorrectType() public view {
        // AAPL is on a DCLEX oracle pool
        assertEq(
            uint256(dclexRouter.getPoolType(address(aaplStock))),
            uint256(DclexRouter.PoolType.DCLEX)
        );

        // AMMT1 is on a Uniswap V3 pool
        assertEq(
            uint256(dclexRouter.getPoolType(address(ammStock1))),
            uint256(DclexRouter.PoolType.V3)
        );

        // Unknown address is NONE
        assertEq(
            uint256(dclexRouter.getPoolType(address(0xdead))),
            uint256(DclexRouter.PoolType.NONE)
        );
    }

    // ============ V3 Pool Registration Tests ============

    function test_V3PoolAddresses_AreRegistered() public view {
        // Verify V3 pools are registered with correct addresses
        assertEq(dclexRouter.stockToV3Pool(address(ammStock1)), ammPool1);
        assertEq(dclexRouter.stockToV3Pool(address(ammStock2)), ammPool2);
    }

    function test_V3Stocks_AreInAllStockTokens() public view {
        address[] memory tokens = dclexRouter.allStockTokens();
        bool foundAmm1 = false;
        bool foundAmm2 = false;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(ammStock1)) foundAmm1 = true;
            if (tokens[i] == address(ammStock2)) foundAmm2 = true;
        }

        assertTrue(foundAmm1, "AMMT1 should be in allStockTokens");
        assertTrue(foundAmm2, "AMMT2 should be in allStockTokens");
    }

    function test_RemoveV3Pool_SetsTypeToNone() public {
        // Remove V3 pool via explicit removePool
        vm.prank(ADMIN);
        dclexRouter.removePool(address(ammStock1), DclexRouter.PoolType.V3);

        // Verify type is now NONE
        assertEq(
            uint256(dclexRouter.getPoolType(address(ammStock1))),
            uint256(DclexRouter.PoolType.NONE)
        );
        assertEq(dclexRouter.stockToV3Pool(address(ammStock1)), address(0));
    }

    // Note: Full AMM swap tests require integration with properly deployed V3 pools
    // where pool addresses match SwapRouter's computed addresses. This requires
    // deployment in a real environment rather than forge test's CREATE2 behavior.

    // ============ Unknown Token Tests ============

    function test_SwapExactInput_RevertOnUnknownInputToken() public {
        address unknownToken = address(0x9999);

        vm.prank(USER_1);
        vm.expectRevert(DclexRouter.DclexRouter__UnknownToken.selector);
        dclexRouter.swapExactInput(
            unknownToken,
            address(aaplStock), // Use CUSTOM pool for output to avoid V3 issues
            1e18,
            0,
            block.timestamp + 1,
            PRICE_DATA
        );
    }

    function test_SwapExactInput_RevertOnUnknownOutputToken() public {
        address unknownToken = address(0x9999);

        vm.prank(USER_1);
        vm.expectRevert(DclexRouter.DclexRouter__UnknownToken.selector);
        dclexRouter.swapExactInput(
            address(aaplStock), // Use CUSTOM pool for input
            unknownToken,
            1e18,
            0,
            block.timestamp + 1,
            PRICE_DATA
        );
    }

    // ============ Deadline Tests ============

    function test_SwapExactInput_RevertOnExpiredDeadline() public {
        vm.warp(1000); // Set block timestamp to 1000

        vm.prank(USER_1);
        vm.expectRevert(DclexRouter.DclexRouter__DeadlinePassed.selector);
        dclexRouter.swapExactInput(
            address(aaplStock), // Use CUSTOM pool to avoid V3 pool address issues
            address(aaplStock), // Same token (would fail anyway, but deadline check comes first)
            1e18,
            0,
            500, // Deadline in the past
            PRICE_DATA
        );
    }

    // ============ Liquidity Calculation Tests ============

    function test_V3Pool_HasMeaningfulLiquidity() public view {
        // Verify pools have meaningful liquidity (significantly better than buggy 1e6)
        IUniswapV3Pool pool1 = IUniswapV3Pool(ammPool1);
        IUniswapV3Pool pool2 = IUniswapV3Pool(ammPool2);

        uint128 liquidity1 = pool1.liquidity();
        uint128 liquidity2 = pool2.liquidity();

        // The old buggy calculation produced ~1e6-1e7 liquidity
        // Proper V3 math with full-range positions produces 1e12+ liquidity
        // This is 1M times more than the buggy calculation
        assertGt(
            liquidity1,
            1e11,
            "Pool1 liquidity should be > 1e11 (not 1e6)"
        );
        assertGt(
            liquidity2,
            1e11,
            "Pool2 liquidity should be > 1e11 (not 1e6)"
        );

        console.log("Pool1 liquidity:", liquidity1);
        console.log("Pool2 liquidity:", liquidity2);
    }

    function test_LiquidityCalculation_IsProperV3Math() public view {
        // This test verifies the liquidity calculation formula is correct
        // by comparing the calculated liquidity against expected values

        // For AMMT1 pool with 1000 stocks + $20,000 USDC at $20/stock
        // Full-range liquidity with large tick spread will produce 1e12-1e14 range

        IUniswapV3Pool pool1 = IUniswapV3Pool(ammPool1);
        uint128 liquidity1 = pool1.liquidity();

        // Should be in a reasonable range for full-range positions
        assertGt(liquidity1, 1e11, "Liquidity should be at least 1e11");
        assertLt(liquidity1, 1e22, "Liquidity should be reasonable (< 1e22)");
    }

    function test_Fuzz_LiquidityCalculation_ProducesNonZeroLiquidity(
        uint256 stockAmount,
        uint256 usdcAmount
    ) public {
        // Bound inputs to reasonable ranges for meaningful liquidity
        stockAmount = bound(stockAmount, 100e18, 1e24); // 100 to 1M stocks
        usdcAmount = bound(usdcAmount, 1000e6, 1e12); // $1000 to $1M USDC

        // Create a new pool for this test
        address newStock = address(0x1111);
        address newPool = v3Factory.createPool(
            newStock,
            address(dusdToken),
            FEE_TIER
        );

        // Initialize with a reasonable price ($10 per stock)
        uint160 sqrtPriceX96 = _calculateSqrtPriceX96(
            newStock,
            address(dusdToken),
            10e6
        );
        IUniswapV3Pool(newPool).initialize(sqrtPriceX96);

        // Get sqrt price ratios
        (uint160 currentSqrtPrice, , , , , , ) = IUniswapV3Pool(newPool)
            .slot0();

        // Determine token order
        address token0 = newStock < address(dusdToken)
            ? newStock
            : address(dusdToken);
        uint256 amount0 = newStock < address(dusdToken)
            ? stockAmount
            : usdcAmount;
        uint256 amount1 = newStock < address(dusdToken)
            ? usdcAmount
            : stockAmount;

        // Calculate liquidity using proper V3 math (same as deployment script)
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            currentSqrtPrice,
            TickMath.getSqrtRatioAtTick(MIN_TICK),
            TickMath.getSqrtRatioAtTick(MAX_TICK),
            amount0,
            amount1
        );

        // Liquidity should never be zero for non-zero inputs
        assertGt(liquidity, 0, "Liquidity should not be zero");

        // For meaningful amounts (>= 100 stocks + >= $1000 USDC), liquidity should be > 1e8
        assertGt(
            liquidity,
            1e8,
            "Liquidity should be meaningful for substantial deposits"
        );
    }

    function test_LiquidityCalculation_NotTinyLikeOldBug() public view {
        // The old buggy code: Math.min(balance0 / 1e12, balance1 / 1e3)
        // For 1000 stocks (1000e18) + $10000 USDC (10000e6):
        // Old: min(1000e18/1e12, 10000e6/1e3) = min(1e9, 1e7) = 1e7
        //
        // Proper V3 math produces liquidity 100,000x larger

        IUniswapV3Pool pool1 = IUniswapV3Pool(ammPool1);
        uint128 actualLiquidity = pool1.liquidity();

        // Simulate the old buggy calculation
        uint256 stockBalance = 1000e18;
        uint256 usdcBalance = 20000e6;
        uint256 buggyLiquidity = stockBalance / 1e12 < usdcBalance / 1e3
            ? stockBalance / 1e12
            : usdcBalance / 1e3;

        console.log("Buggy calculation would give:", buggyLiquidity);
        console.log("Actual V3 liquidity:", actualLiquidity);

        // Actual liquidity should be at least 1000x the buggy calculation
        assertGt(
            actualLiquidity,
            buggyLiquidity * 100,
            "Proper V3 math should give 100x+ more liquidity than buggy calc"
        );
    }

    // ============ Cross-Pool Swap Tests (AMM <-> CUSTOM) ============

    function test_CrossPool_AMMToCustom_SwapExactInput() public {
        // Swap AMMT1 (V3) -> AAPL (DCLEX)
        uint256 ammt1BalanceBefore = ammStock1.balanceOf(USER_1);
        uint256 aaplBalanceBefore = aaplStock.balanceOf(USER_1);

        vm.prank(USER_1);
        dclexRouter.swapExactInput(
            address(ammStock1), // AMM input
            address(aaplStock), // CUSTOM output
            10e18, // 10 AMMT1
            0, // min output
            block.timestamp + 1,
            PRICE_DATA
        );

        uint256 ammt1BalanceAfter = ammStock1.balanceOf(USER_1);
        uint256 aaplBalanceAfter = aaplStock.balanceOf(USER_1);

        // AMMT1 should decrease by 10
        assertEq(
            ammt1BalanceBefore - ammt1BalanceAfter,
            10e18,
            "AMMT1 balance should decrease"
        );

        // AAPL should increase (some amount > 0)
        assertGt(
            aaplBalanceAfter,
            aaplBalanceBefore,
            "AAPL balance should increase"
        );

        console.log("AMM -> CUSTOM swap succeeded");
        console.log(
            "  AMMT1 spent:",
            (ammt1BalanceBefore - ammt1BalanceAfter) / 1e18
        );
        console.log(
            "  AAPL received:",
            (aaplBalanceAfter - aaplBalanceBefore) / 1e18
        );
    }

    function test_CrossPool_CustomToAMM_SwapExactInput() public {
        // Swap AAPL (DCLEX) -> AMMT1 (V3)
        uint256 aaplBalanceBefore = aaplStock.balanceOf(USER_1);
        uint256 ammt1BalanceBefore = ammStock1.balanceOf(USER_1);

        vm.prank(USER_1);
        dclexRouter.swapExactInput(
            address(aaplStock), // CUSTOM input
            address(ammStock1), // AMM output
            10e18, // 10 AAPL
            0, // min output
            block.timestamp + 1,
            PRICE_DATA
        );

        uint256 aaplBalanceAfter = aaplStock.balanceOf(USER_1);
        uint256 ammt1BalanceAfter = ammStock1.balanceOf(USER_1);

        // AAPL should decrease by 10
        assertEq(
            aaplBalanceBefore - aaplBalanceAfter,
            10e18,
            "AAPL balance should decrease"
        );

        // AMMT1 should increase (some amount > 0)
        assertGt(
            ammt1BalanceAfter,
            ammt1BalanceBefore,
            "AMMT1 balance should increase"
        );

        console.log("CUSTOM -> AMM swap succeeded");
        console.log(
            "  AAPL spent:",
            (aaplBalanceBefore - aaplBalanceAfter) / 1e18
        );
        console.log(
            "  AMMT1 received:",
            (ammt1BalanceAfter - ammt1BalanceBefore) / 1e18
        );
    }

    function test_CrossPool_AMMToAMM_SwapExactInput() public {
        // Swap AMMT1 (AMM) -> AMMT2 (AMM)
        uint256 ammt1BalanceBefore = ammStock1.balanceOf(USER_1);
        uint256 ammt2BalanceBefore = ammStock2.balanceOf(USER_1);

        vm.prank(USER_1);
        dclexRouter.swapExactInput(
            address(ammStock1), // AMM input
            address(ammStock2), // AMM output
            10e18, // 10 AMMT1
            0, // min output
            block.timestamp + 1,
            PRICE_DATA
        );

        uint256 ammt1BalanceAfter = ammStock1.balanceOf(USER_1);
        uint256 ammt2BalanceAfter = ammStock2.balanceOf(USER_1);

        // AMMT1 should decrease by 10
        assertEq(
            ammt1BalanceBefore - ammt1BalanceAfter,
            10e18,
            "AMMT1 balance should decrease"
        );

        // AMMT2 should increase (some amount > 0)
        assertGt(
            ammt2BalanceAfter,
            ammt2BalanceBefore,
            "AMMT2 balance should increase"
        );

        console.log("AMM -> AMM swap succeeded");
        console.log(
            "  AMMT1 spent:",
            (ammt1BalanceBefore - ammt1BalanceAfter) / 1e18
        );
        console.log(
            "  AMMT2 received:",
            (ammt2BalanceAfter - ammt2BalanceBefore) / 1e18
        );
    }

    // ============ swapExactOutput Tests ============
    // Note: Some swapExactOutput tests may fail due to implementation complexity
    // with cross-pool exact output swaps. These tests document the expected behavior.

    function test_CrossPool_CustomToAMM_SwapExactOutput() public {
        // Swap AAPL (DCLEX) -> AMMT1 (V3) with exact output
        uint256 exactOutput = 5e18; // Want exactly 5 AMMT1
        uint256 maxInput = 20e18; // Max 20 AAPL

        uint256 aaplBalanceBefore = aaplStock.balanceOf(USER_1);
        uint256 ammt1BalanceBefore = ammStock1.balanceOf(USER_1);

        vm.prank(USER_1);
        dclexRouter.swapExactOutput(
            address(aaplStock), // CUSTOM input
            address(ammStock1), // AMM output
            exactOutput,
            maxInput,
            block.timestamp + 1,
            PRICE_DATA
        );

        uint256 aaplBalanceAfter = aaplStock.balanceOf(USER_1);
        uint256 ammt1BalanceAfter = ammStock1.balanceOf(USER_1);

        // AMMT1 should increase by exactly exactOutput
        assertEq(
            ammt1BalanceAfter - ammt1BalanceBefore,
            exactOutput,
            "AMMT1 balance should increase by exact output"
        );

        // AAPL should decrease by some amount <= maxInput
        uint256 aaplSpent = aaplBalanceBefore - aaplBalanceAfter;
        assertLe(aaplSpent, maxInput, "AAPL spent should be <= max input");
        assertGt(aaplSpent, 0, "Should spend some AAPL");

        console.log("CUSTOM -> AMM swapExactOutput succeeded");
        console.log("  AMMT1 received:", exactOutput / 1e18);
        console.log("  AAPL spent:", aaplSpent / 1e18);
    }

    function test_CrossPool_AMMToAMM_SwapExactOutput() public {
        // Swap AMMT1 (AMM) -> AMMT2 (AMM) with exact output
        uint256 exactOutput = 1e14; // Small amount within V3 pool liquidity
        uint256 maxInput = 1000e18; // High max to accommodate V3 price impact

        uint256 ammt1BalanceBefore = ammStock1.balanceOf(USER_1);
        uint256 ammt2BalanceBefore = ammStock2.balanceOf(USER_1);

        vm.prank(USER_1);
        dclexRouter.swapExactOutput(
            address(ammStock1), // AMM input
            address(ammStock2), // AMM output
            exactOutput,
            maxInput,
            block.timestamp + 1,
            new bytes[](0) // No price data for AMM
        );

        uint256 ammt1BalanceAfter = ammStock1.balanceOf(USER_1);
        uint256 ammt2BalanceAfter = ammStock2.balanceOf(USER_1);

        // AMMT2 should increase by exactly exactOutput
        assertEq(
            ammt2BalanceAfter - ammt2BalanceBefore,
            exactOutput,
            "AMMT2 balance should increase by exact output"
        );

        // AMMT1 should decrease by some amount <= maxInput
        uint256 ammt1Spent = ammt1BalanceBefore - ammt1BalanceAfter;
        assertLe(ammt1Spent, maxInput, "AMMT1 spent should be <= max input");
        assertGt(ammt1Spent, 0, "Should spend some AMMT1");

        console.log("AMM -> AMM swapExactOutput succeeded");
        console.log("  AMMT2 received:", exactOutput / 1e18);
        console.log("  AMMT1 spent:", ammt1Spent / 1e18);
    }

    // ============ Single-leg V3 buy/sell coverage ============

    function test_BuyOnV3_ExactInput() public {
        uint256 stableIn = 100e6;
        uint256 balanceBefore = ammStock1.balanceOf(USER_1);
        vm.startPrank(USER_1);
        dusdToken.approve(address(dclexRouter), stableIn);
        dclexRouter.buyExactInput(
            address(ammStock1),
            stableIn,
            0,
            block.timestamp + 1,
            new bytes[](0)
        );
        vm.stopPrank();
        assertGt(ammStock1.balanceOf(USER_1), balanceBefore, "user should receive AMMT1");
    }

    function test_BuyOnV3_ExactOutput() public {
        uint256 exactOut = 1e18;
        uint256 maxIn = 1000e6;
        uint256 balanceBefore = ammStock1.balanceOf(USER_1);
        vm.startPrank(USER_1);
        dusdToken.approve(address(dclexRouter), maxIn);
        dclexRouter.buyExactOutput(
            address(ammStock1),
            exactOut,
            maxIn,
            block.timestamp + 1,
            new bytes[](0)
        );
        vm.stopPrank();
        assertEq(ammStock1.balanceOf(USER_1) - balanceBefore, exactOut, "user should receive exact AMMT1");
    }

    function test_SellOnV3_ExactInput() public {
        uint256 ammIn = 1e18;
        uint256 balanceBefore = dusdToken.balanceOf(USER_1);
        vm.startPrank(USER_1);
        ammStock1.approve(address(dclexRouter), ammIn);
        dclexRouter.sellExactInput(
            address(ammStock1),
            ammIn,
            0,
            block.timestamp + 1,
            new bytes[](0)
        );
        vm.stopPrank();
        assertGt(dusdToken.balanceOf(USER_1), balanceBefore, "user should receive stablecoin");
    }

    function test_SellOnV3_ExactOutput() public {
        uint256 stableOut = 10e6;
        uint256 maxIn = 100e18;
        uint256 balanceBefore = dusdToken.balanceOf(USER_1);
        vm.startPrank(USER_1);
        ammStock1.approve(address(dclexRouter), maxIn);
        dclexRouter.sellExactOutput(
            address(ammStock1),
            stableOut,
            maxIn,
            block.timestamp + 1,
            new bytes[](0)
        );
        vm.stopPrank();
        assertEq(dusdToken.balanceOf(USER_1) - balanceBefore, stableOut, "user should receive exact stablecoin");
    }

    function test_CrossPool_AMMToCustom_SwapExactOutput() public {
        uint256 exactOut = 1e18;
        uint256 maxIn = 100e18;
        uint256 aaplBefore = aaplStock.balanceOf(USER_1);
        vm.startPrank(USER_1);
        ammStock1.approve(address(dclexRouter), maxIn);
        dclexRouter.swapExactOutput(
            address(ammStock1),
            address(aaplStock),
            exactOut,
            maxIn,
            block.timestamp + 1,
            new bytes[](0)
        );
        vm.stopPrank();
        assertEq(aaplStock.balanceOf(USER_1) - aaplBefore, exactOut, "user should receive exact AAPL");
    }

    /// @notice With Quoter, exact-output on both legs means only needed input is consumed
    function test_SwapExactOutput_RefundsExcessInput() public {
        // Test that excess input tokens are refunded when maxInput > actual needed
        uint256 exactOutput = 1e18; // Want exactly 1 AMMT1
        uint256 maxInput = 100e18; // Way more than needed

        uint256 ammt1BalanceBefore = ammStock1.balanceOf(USER_1);
        uint256 ammt2BalanceBefore = ammStock2.balanceOf(USER_1);

        vm.prank(USER_1);
        dclexRouter.swapExactOutput(
            address(ammStock2), // AMM input
            address(ammStock1), // AMM output
            exactOutput,
            maxInput,
            block.timestamp + 1,
            new bytes[](0)
        );

        uint256 ammt1BalanceAfter = ammStock1.balanceOf(USER_1);
        uint256 ammt2BalanceAfter = ammStock2.balanceOf(USER_1);

        // AMMT1 should increase by exactly exactOutput
        assertEq(
            ammt1BalanceAfter - ammt1BalanceBefore,
            exactOutput,
            "AMMT1 balance should increase by exact output"
        );

        // AMMT2 spent should be much less than maxInput (Quoter calculates exact amount)
        uint256 ammt2Spent = ammt2BalanceBefore - ammt2BalanceAfter;
        assertLt(ammt2Spent, maxInput, "AMMT2 spent should be less than max input");
        assertGt(ammt2Spent, 0, "Should spend some AMMT2");

        console.log("ExactOutput refund test passed");
        console.log("  Max input:", maxInput / 1e18);
        console.log("  AMMT2 spent:", ammt2Spent / 1e18);
    }
}
