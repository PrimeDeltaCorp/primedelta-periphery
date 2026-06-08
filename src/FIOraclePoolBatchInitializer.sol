// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FIOraclePoolBatchInitializer
/// @notice Seeds N DclexPools with two-sided liquidity in a single tx
///         using FIOracle-signed price data. All inits run under one
///         block.timestamp so the pool's `maxPriceStaleness` check
///         passes regardless of how long the broadcast queue is.
///
///         Caller must beforehand:
///         - mint a DID for this contract (Stock/Stablecoin transfers
///           require it),
///         - grant DEFAULT_ADMIN_ROLE on Factory (for forceMintStocks),
///         - transfer enough dUSD here to cover all pools (this contract
///           does not mint dUSD itself; mint to it via
///           `Factory.forceMintStablecoin` or a transferFrom).
contract FIOraclePoolBatchInitializer {
    struct InitParams {
        Factory factory;
        IERC20 dusdToken;
        address[] pools;
        string[] stockSymbols;
        bytes[] priceUpdateData;
        uint256 stockAmount;
        uint256 dusdAmount;
        uint256 feePerPool;
    }

    function initializeAll(InitParams calldata p) external payable {
        require(p.pools.length == p.stockSymbols.length, "len mismatch");
        require(p.pools.length == p.priceUpdateData.length, "len mismatch");

        for (uint256 i = 0; i < p.pools.length; i++) {
            DclexPool pool = DclexPool(p.pools[i]);
            address stockAddr = address(pool.stockToken());

            p.factory.forceMintStocks(p.stockSymbols[i], address(this), p.stockAmount);
            IERC20(stockAddr).approve(p.pools[i], p.stockAmount);
            p.dusdToken.approve(p.pools[i], p.dusdAmount);

            bytes[] memory data = new bytes[](1);
            data[0] = p.priceUpdateData[i];
            pool.initialize{value: p.feePerPool}(p.stockAmount, p.dusdAmount, data);
        }

        if (address(this).balance > 0) {
            (bool ok, ) = msg.sender.call{value: address(this).balance}("");
            require(ok, "refund failed");
        }
    }

    receive() external payable {}
}
