// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3MintCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import {IUniswapV3SwapCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3SwapCallback.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import {DclexV3Factory} from "../src/DclexV3Factory.sol";

contract V3FeeProtocolTestToken is ERC20 {
    constructor(string memory symbol) ERC20(symbol, symbol) {
        _mint(msg.sender, 1e30);
    }
}

contract V3FeeProtocolTest is Test, IUniswapV3MintCallback, IUniswapV3SwapCallback {
    uint24 private constant FEE_TIER = 3000;
    int24 private constant MIN_TICK = -887220;
    int24 private constant MAX_TICK = 887220;
    uint8 private constant FEE_PROTOCOL_7_7 = 7 + (7 << 4);

    DclexV3Factory private factory;
    IUniswapV3Pool private pool;
    IERC20 private token0;
    IERC20 private token1;
    address private stranger = makeAddr("stranger");
    address private treasury = makeAddr("treasury");

    function setUp() public {
        factory = new DclexV3Factory();
        IERC20 tokenA = new V3FeeProtocolTestToken("TKA");
        IERC20 tokenB = new V3FeeProtocolTestToken("TKB");
        (token0, token1) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);
        pool = IUniswapV3Pool(factory.createPool(address(token0), address(token1), FEE_TIER));
    }

    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata) external {
        if (amount0Owed > 0) token0.transfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) token1.transfer(msg.sender, amount1Owed);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (amount0Delta > 0) token0.transfer(msg.sender, uint256(amount0Delta));
        if (amount1Delta > 0) token1.transfer(msg.sender, uint256(amount1Delta));
    }

    function _feeProtocol() private view returns (uint8 feeProtocol) {
        (, , , , , feeProtocol, ) = pool.slot0();
    }

    function _initializeWithLiquidity() private {
        pool.initialize(TickMath.getSqrtRatioAtTick(0));
        pool.mint(address(this), MIN_TICK, MAX_TICK, 1e24, "");
    }

    function test_PoolStartsAtSevenSevenOnInitialize() public {
        assertEq(_feeProtocol(), 0);
        vm.prank(stranger);
        pool.initialize(TickMath.getSqrtRatioAtTick(0));
        assertEq(_feeProtocol(), FEE_PROTOCOL_7_7);
    }

    function test_PoolHasNoFeeProtocolSetter() public {
        _initializeWithLiquidity();
        assertEq(factory.owner(), address(this));
        (bool ok, ) = address(pool).call(abi.encodeWithSignature("setFeeProtocol(uint8,uint8)", 4, 4));
        assertFalse(ok);
        (ok, ) = address(pool).call(abi.encodeWithSignature("setFeeProtocol(uint8,uint8)", 0, 0));
        assertFalse(ok);
        assertEq(_feeProtocol(), FEE_PROTOCOL_7_7);
    }

    function test_FactoryHasNoFeeAmountSetter() public {
        (bool ok, ) = address(factory).call(abi.encodeWithSignature("enableFeeAmount(uint24,int24)", 100, 1));
        assertFalse(ok);
        assertEq(factory.feeAmountTickSpacing(100), 0);
        assertEq(factory.feeAmountTickSpacing(500), 10);
        assertEq(factory.feeAmountTickSpacing(3000), 60);
        assertEq(factory.feeAmountTickSpacing(10000), 200);
    }

    function test_SwapSendsOneSeventhOfTheFeeToTheProtocol() public {
        _initializeWithLiquidity();
        uint256 amountIn = 1e18;
        uint256 feeAmount = (amountIn * FEE_TIER) / 1e6;

        pool.swap(address(this), true, int256(amountIn), TickMath.MIN_SQRT_RATIO + 1, "");
        (uint128 protocol0, uint128 protocol1) = pool.protocolFees();
        assertApproxEqAbs(protocol0, feeAmount / 7, 1);
        assertEq(protocol1, 0);

        pool.swap(address(this), false, int256(amountIn), TickMath.MAX_SQRT_RATIO - 1, "");
        (protocol0, protocol1) = pool.protocolFees();
        assertApproxEqAbs(protocol1, feeAmount / 7, 1);
    }

    function test_CollectProtocolIsOwnerOnly() public {
        _initializeWithLiquidity();
        pool.swap(address(this), true, int256(1e18), TickMath.MIN_SQRT_RATIO + 1, "");
        (uint128 protocol0, ) = pool.protocolFees();

        vm.prank(stranger);
        vm.expectRevert();
        pool.collectProtocol(stranger, type(uint128).max, type(uint128).max);

        (uint128 collected0, uint128 collected1) =
            pool.collectProtocol(treasury, type(uint128).max, type(uint128).max);
        assertEq(collected0, protocol0 - 1);
        assertEq(collected1, 0);
        assertEq(token0.balanceOf(treasury), protocol0 - 1);
    }
}
