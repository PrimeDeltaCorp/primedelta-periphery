// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UniswapV3Factory} from "@uniswap/v3-core/contracts/UniswapV3Factory.sol";

/// @title DclexV3Factory
/// @notice Restricts pool creation to factory owner only.
/// Uses V3Factory's native owner pattern (not OZ Ownable).
/// All other V3Factory functions remain publicly accessible.
contract DclexV3Factory is UniswapV3Factory {
    /// @notice Override createPool to restrict to owner only
    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) public override returns (address pool) {
        require(msg.sender == owner, "DclexV3Factory: caller is not owner");
        return super.createPool(tokenA, tokenB, fee);
    }
}
