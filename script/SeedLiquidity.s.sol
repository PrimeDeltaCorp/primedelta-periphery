// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IUniswapV3MintCallback} from "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3MintCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LiquidityAmounts} from "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";
import {TickMath} from "@uniswap/v3-core/contracts/libraries/TickMath.sol";

interface INPM {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }
    function mint(MintParams calldata params) external payable returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
}

interface IFactory {
    function stocks(string calldata symbol) external view returns (address);
    function forceMintStocks(string calldata symbol, address to, uint256 amount) external;
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}

contract SeedLiquidity is Script {
    address internal _dusdAddr;

    struct Position {
        string name;
        int24 tickLower;
        int24 tickUpper;
        uint256 stockAmount;
        uint256 dusdAmount;
    }

    function run(
        address factory,
        address npm,
        address dusd,
        address router
    ) external {
        _dusdAddr = dusd;
        // Get stock addresses
        address ammt1 = IFactory(factory).stocks("AMMT1");
        address ammt2 = IFactory(factory).stocks("AMMT2");

        console.log("AMMT1:", ammt1);
        console.log("AMMT2:", ammt2);

        // Get pool addresses from router
        (bool ok1, bytes memory data1) = router.staticcall(abi.encodeWithSignature("stockToV3Pool(address)", ammt1));
        require(ok1 && data1.length >= 32, "stockToV3Pool(AMMT1) call failed");
        address ammt1Pool = abi.decode(data1, (address));
        (bool ok2, bytes memory data2) = router.staticcall(abi.encodeWithSignature("stockToV3Pool(address)", ammt2));
        require(ok2 && data2.length >= 32, "stockToV3Pool(AMMT2) call failed");
        address ammt2Pool = abi.decode(data2, (address));

        console.log("AMMT1 Pool:", ammt1Pool);
        console.log("AMMT2 Pool:", ammt2Pool);

        vm.startBroadcast();

        // Mint tokens to admin for liquidity
        IFactory(factory).forceMintStocks("AMMT1", msg.sender, 100_000 ether);
        IFactory(factory).forceMintStocks("AMMT2", msg.sender, 100_000 ether);
        IMintable(dusd).mint(msg.sender, 10_000_000e6); // 10M dUSD

        // Approve NPM
        IERC20(ammt1).approve(npm, type(uint256).max);
        IERC20(ammt2).approve(npm, type(uint256).max);
        IERC20(dusd).approve(npm, type(uint256).max);

        // === AMMT1 Positions (current price ~$10) ===
        // AMMT1 is token0, dUSD is token1 in pool
        // Higher tick = higher price for token0

        _mintPosition(npm, ammt1Pool, "AMMT1 Tight ($9-$11)",
            _priceToTick(ammt1, dusd, 9e6), _priceToTick(ammt1, dusd, 11e6),
            50 ether, 1000e6);

        _mintPosition(npm, ammt1Pool, "AMMT1 Medium ($7-$13)",
            _priceToTick(ammt1, dusd, 7e6), _priceToTick(ammt1, dusd, 13e6),
            100 ether, 2000e6);

        _mintPosition(npm, ammt1Pool, "AMMT1 Wide ($3-$30)",
            _priceToTick(ammt1, dusd, 3e6), _priceToTick(ammt1, dusd, 30e6),
            200 ether, 5000e6);

        _mintPosition(npm, ammt1Pool, "AMMT1 Asymmetric Up ($10-$25)",
            _priceToTick(ammt1, dusd, 10e6), _priceToTick(ammt1, dusd, 25e6),
            0, 3000e6);  // single-sided dUSD (price below range start)

        _mintPosition(npm, ammt1Pool, "AMMT1 Asymmetric Down ($5-$10)",
            _priceToTick(ammt1, dusd, 5e6), _priceToTick(ammt1, dusd, 10e6),
            80 ether, 0);  // single-sided stock (price above range)

        _mintPosition(npm, ammt1Pool, "AMMT1 Very Tight ($9.5-$10.5)",
            _priceToTick(ammt1, dusd, 9500000), _priceToTick(ammt1, dusd, 10500000),
            20 ether, 400e6);

        // === AMMT2 Positions (current price ~$20) ===
        // AMMT2 pool: dUSD is token0, AMMT2 is token1

        _mintPosition(npm, ammt2Pool, "AMMT2 Tight ($18-$22)",
            _priceToTick(ammt2, dusd, 18e6), _priceToTick(ammt2, dusd, 22e6),
            30 ether, 1200e6);

        _mintPosition(npm, ammt2Pool, "AMMT2 Medium ($15-$25)",
            _priceToTick(ammt2, dusd, 15e6), _priceToTick(ammt2, dusd, 25e6),
            50 ether, 2000e6);

        _mintPosition(npm, ammt2Pool, "AMMT2 Wide ($5-$50)",
            _priceToTick(ammt2, dusd, 5e6), _priceToTick(ammt2, dusd, 50e6),
            100 ether, 4000e6);

        _mintPosition(npm, ammt2Pool, "AMMT2 Very Tight ($19-$21)",
            _priceToTick(ammt2, dusd, 19e6), _priceToTick(ammt2, dusd, 21e6),
            15 ether, 600e6);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Seeding Complete ===");
    }

    function _mintPosition(
        address npm,
        address pool,
        string memory name,
        int24 tickLower,
        int24 tickUpper,
        uint256 stockAmount,
        uint256 dusdAmount
    ) internal {
        // Ensure tickLower < tickUpper
        if (tickLower > tickUpper) {
            (tickLower, tickUpper) = (tickUpper, tickLower);
        }

        // Align to tick spacing (60 for 0.3% fee)
        tickLower = (tickLower / 60) * 60;
        tickUpper = (tickUpper / 60) * 60;
        if (tickLower == tickUpper) tickUpper += 60;

        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();

        // Determine token ordering using stored dUSD address
        bool dusdIsToken0 = (token0 == _dusdAddr);
        uint256 amount0 = dusdIsToken0 ? dusdAmount : stockAmount;
        uint256 amount1 = dusdIsToken0 ? stockAmount : dusdAmount;

        if (amount0 == 0 && amount1 == 0) return;

        try INPM(npm).mint(INPM.MintParams({
            token0: token0,
            token1: token1,
            fee: 3000,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: 0,
            amount1Min: 0,
            recipient: msg.sender,
            deadline: block.timestamp + 3600
        })) returns (uint256 tokenId, uint128 liquidity, uint256 a0, uint256 a1) {
            console.log(name);
            console.log("  tokenId:", tokenId, "liquidity:", uint256(liquidity));
            console.log("  amount0:", a0, "amount1:", a1);
        } catch {
            console.log(name, "- FAILED (may be out of range)");
        }
    }

    function _priceToTick(address stock, address dusd, uint256 priceUsd6dec) internal pure returns (int24) {
        // priceUsd6dec is price in 6 decimals (e.g. 10e6 = $10)
        // V3 tick = log1.0001(token1/token0_raw)
        // If stock < dusd (stock is token0):
        //   raw_price = dusd_raw / stock_raw = priceUsd / 1e18 = priceUsd * 1e-18
        //   But we need to account for decimals: raw = priceUsd6dec / 1e6 * 1e6 / 1e18 = priceUsd6dec / 1e18
        //   tick = log1.0001(priceUsd6dec / 1e18)
        // If dusd < stock (dusd is token0):
        //   raw_price = stock_raw / dusd_raw = 1e18 / priceUsd6dec
        //   tick = log1.0001(1e18 / priceUsd6dec)

        // We use a simple lookup table for common prices
        // These are approximate ticks for stock(18dec)/dusd(6dec) pairs
        // For stockIsToken0: higher price = higher tick
        // For dusdIsToken0: higher price = lower tick

        // General formula: tick ≈ log(price * 1e12) / log(1.0001) for stockIsToken0
        // We'll compute using integer math approximation
        // log1.0001(x) ≈ ln(x) / ln(1.0001) ≈ ln(x) / 0.00009999 ≈ ln(x) * 10001

        // For simplicity, hardcode common ticks
        // $1 → tick ≈ 276324 (stockIsToken0)
        // $3 → tick ≈ 287325
        // $5 → tick ≈ 292425
        // $7 → tick ≈ 295800
        // $9 → tick ≈ 298320
        // $9.5 → tick ≈ 298860
        // $10 → tick ≈ 299340
        // $10.5 → tick ≈ 299820
        // $11 → tick ≈ 300300
        // $13 → tick ≈ 302340
        // $15 → tick ≈ 303780
        // $18 → tick ≈ 305580
        // $19 → tick ≈ 306120
        // $20 → tick ≈ 306600
        // $21 → tick ≈ 307080
        // $22 → tick ≈ 307500
        // $25 → tick ≈ 308760
        // $30 → tick ≈ 310560
        // $50 → tick ≈ 315660

        // Use TickMath for precise calculation
        // sqrtPriceX96 = sqrt(priceUsd6dec * 1e12) * 2^96 / 1e9
        // = sqrt(priceUsd6dec) * 1e6 * 2^96 / 1e9
        // = sqrt(priceUsd6dec) * 2^96 / 1e3

        uint256 sqrtPrice = _sqrt(priceUsd6dec);
        uint160 sqrtPriceX96;

        if (stock < dusd) {
            // stockIsToken0: sqrtPriceX96 = sqrt(price_raw) * 2^96
            // price_raw = priceUsd6dec / 1e18 (adjusting for decimals)
            // sqrtPriceX96 = sqrt(priceUsd6dec) * 2^96 / 1e9
            sqrtPriceX96 = uint160((sqrtPrice << 96) / 1e9);
        } else {
            // dusdIsToken0: sqrtPriceX96 = sqrt(1/price_raw) * 2^96
            // = 1e9 * 2^96 / sqrt(priceUsd6dec)
            sqrtPriceX96 = uint160((1e9 << 96) / sqrtPrice);
        }

        return TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}
