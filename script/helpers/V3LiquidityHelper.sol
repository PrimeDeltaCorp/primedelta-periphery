// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

/// @title V3LiquidityHelper
/// @notice Helper contract for adding liquidity to V3 pools
/// @dev Handles the uniswapV3MintCallback that V3 pools require
contract V3LiquidityHelper {
    address public immutable owner;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    /// @notice Add single-sided liquidity to a V3 pool
    /// @param pool The V3 pool address
    /// @param token The token to provide as liquidity
    /// @param tickLower Lower tick of the position
    /// @param tickUpper Upper tick of the position
    /// @param liquidity Amount of liquidity to add
    function addLiquidity(
        address pool,
        address token,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external onlyOwner returns (uint256 amount0, uint256 amount1) {
        // Encode callback data (single token for single-sided)
        bytes memory data = abi.encode(token, token);

        // Call pool.mint - pool will call back to this contract
        (amount0, amount1) = IUniswapV3Pool(pool).mint(
            msg.sender, // recipient of the position
            tickLower,
            tickUpper,
            liquidity,
            data
        );
    }

    /// @notice Add two-sided liquidity to a V3 pool
    /// @param pool The V3 pool address
    /// @param token0 The first token (lower address)
    /// @param token1 The second token (higher address)
    /// @param tickLower Lower tick of the position
    /// @param tickUpper Upper tick of the position
    /// @param liquidity Amount of liquidity to add
    function addLiquidityTwoSided(
        address pool,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external onlyOwner returns (uint256 amount0, uint256 amount1) {
        // Encode callback data with both tokens
        bytes memory data = abi.encode(token0, token1);

        // Call pool.mint - pool will call back to this contract
        (amount0, amount1) = IUniswapV3Pool(pool).mint(
            msg.sender, // recipient of the position
            tickLower,
            tickUpper,
            liquidity,
            data
        );
    }

    /// @notice V3 mint callback - pool calls this to receive tokens
    function uniswapV3MintCallback(
        uint256 amount0Owed,
        uint256 amount1Owed,
        bytes calldata data
    ) external {
        (address token0, address token1) = abi.decode(data, (address, address));

        // Pay whatever is owed
        if (amount0Owed > 0) {
            IERC20(token0).transfer(msg.sender, amount0Owed);
        }
        if (amount1Owed > 0) {
            IERC20(token1).transfer(msg.sender, amount1Owed);
        }
    }

    /// @notice Add single-sided liquidity using pre-calculated liquidity amount
    /// @param pool The V3 pool address
    /// @param token The token to provide as liquidity
    /// @param tickLower Lower tick of the position
    /// @param tickUpper Upper tick of the position
    /// @param liquidity Liquidity amount to add
    function addLiquiditySingleSide(
        address pool,
        address token,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) external onlyOwner returns (uint256 usedAmount) {
        if (liquidity == 0) return 0;

        bytes memory data = abi.encode(token, token);

        (uint256 amount0, uint256 amount1) = IUniswapV3Pool(pool).mint(
            msg.sender,
            tickLower,
            tickUpper,
            liquidity,
            data
        );

        // Return whichever amount was used
        usedAmount = amount0 > 0 ? amount0 : amount1;
    }

    /// @notice Withdraw any tokens left in this contract
    function withdraw(address token, address to) external onlyOwner {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            IERC20(token).transfer(to, balance);
        }
    }

    /// @notice Withdraw ETH if any
    function withdrawETH(address payable to) external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance > 0) {
            to.transfer(balance);
        }
    }

    receive() external payable {}
}
