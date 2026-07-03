// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Canonical 44-stock table + FIOracle price-signing helper shared
/// by RedeployFIOracleAndPools (deploy) and SeedDclexPoolsBatch (seed) so
/// the symbol/feedId order stays in lockstep across the two broadcasts.
abstract contract DclexStockList is Script {
    struct StockInfo {
        string symbol;
    }

    function getAllStocks() internal pure returns (StockInfo[] memory stocks) {
        string[44] memory syms = [
            "AMZN", "V", "JPM", "GE", "AI", "CPNG", "DOW", "CAT", "MRK", "AMGN",
            "KO", "MSTR", "GS", "DIS", "WMT", "NVDA", "IBM", "MCD", "BA", "AXP",
            "TRV", "CVX", "JNJ", "AMC", "CSCO", "HON", "BLK", "NKE", "INTC", "MMM",
            "VZ", "NFLX", "WBA", "UNH", "TSLA", "COIN", "AAPL", "GOOG", "MSFT",
            "META", "CRM", "GME", "PG", "HD"
        ];
        stocks = new StockInfo[](44);
        for (uint256 i = 0; i < 44; i++) {
            stocks[i] = StockInfo(syms[i]);
        }
    }

    function _signedPriceData(
        uint256 signerKey,
        address oracle,
        bytes32 feedId,
        int64 price,
        int32 expo,
        uint64 publishTime
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(
            abi.encodePacked(block.chainid, oracle, feedId, price, expo, publishTime)
        );
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, ethSignedHash);
        return abi.encodePacked(feedId, price, expo, publishTime, v, r, s);
    }
}
