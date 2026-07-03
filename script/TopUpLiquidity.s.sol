// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DclexStockList} from "./DclexStockList.sol";

/// @notice Add liquidity to the live DclexPools so 1000+ dUSD test swaps don't
/// hit DclexPool__NotEnoughPoolLiquidity (pools were seeded with only ~10
/// stock). addLiquidity() is proportional to current reserves and reads NO
/// price, so a plain broadcast is fine (no staleness/cast-send dance).
///
/// MULTIPLIER=49 → each pool ends with ~50x its current liquidity. NFLX is
/// SKIPPED on purpose so the insufficient-liquidity UX can still be tested;
/// re-run with SKIP_SYMBOL="" (or "NONE") afterwards to top it up too.
///
/// Reads pool addresses (getAllStocks order) from out/topup-pools.json.
/// Env: ADMIN_PRIVATE_KEY, DCLEX_FACTORY, DCLEX_ADMIN. Optional DCLEX_DUSD_SYMBOL.
contract TopUpLiquidity is DclexStockList {
    uint256 constant MULTIPLIER = 49;

    function run() external {
        uint256 adminKey = vm.envUint("ADMIN_PRIVATE_KEY");
        address admin    = vm.envAddress("DCLEX_ADMIN");
        Factory factory  = Factory(vm.envAddress("DCLEX_FACTORY"));
        string memory dusdSymbol = vm.envOr("DCLEX_DUSD_SYMBOL", string("dUSD"));
        string memory skip = vm.envOr("SKIP_SYMBOL", string("NFLX"));
        IERC20 dusd = IERC20(factory.stablecoins(dusdSymbol));

        address[] memory pools = vm.parseJsonAddressArray(
            vm.readFile("out/topup-pools.json"), ".pools"
        );
        StockInfo[] memory stocks = getAllStocks();
        require(pools.length == stocks.length, "pool count mismatch");

        vm.startBroadcast(adminKey);
        for (uint256 i = 0; i < stocks.length; i++) {
            if (keccak256(bytes(stocks[i].symbol)) == keccak256(bytes(skip))) {
                console.log("skip", stocks[i].symbol);
                continue;
            }
            DclexPool pool = DclexPool(pools[i]);
            uint256 supply = pool.totalSupply();
            if (supply == 0) {
                console.log("skip (uninitialized)", stocks[i].symbol);
                continue;
            }
            address stockAddr = factory.stocks(stocks[i].symbol);
            // addLiquidity pulls MULTIPLIER * reserve (Ceil) of each side; mint
            // exactly that + a small buffer for the rounding.
            (uint256 stockReserve, uint256 dusdReserve18) = pool.getReserves();
            factory.forceMintStocks(stocks[i].symbol, admin, MULTIPLIER * stockReserve + 1e18);
            factory.forceMintStablecoin(dusdSymbol, admin, MULTIPLIER * (dusdReserve18 / 1e12) + 1e6);
            IERC20(stockAddr).approve(pools[i], type(uint256).max);
            dusd.approve(pools[i], type(uint256).max);
            pool.addLiquidity(supply * MULTIPLIER);
        }
        vm.stopBroadcast();
        console.log("Liquidity topped up (NFLX skipped).");
    }
}
