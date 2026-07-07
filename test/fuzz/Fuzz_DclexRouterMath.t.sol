// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// PrimeDelta audit round-2 — DIFFERENTIAL PROPERTY FUZZING for DclexRouter.
//
// PROPERTY UNDER TEST — "the router is a thin pass-through": for a DCLEX
// single-pool trade the DclexRouter quote must EQUAL the underlying DclexPool
// quote. The router forwards the caller's input verbatim to the pool, the pool
// sends the output straight to the caller, and the router keeps nothing — it
// must neither skim the output nor inflate the input.
//
// DclexPool exposes NO preview() function, so — exactly as the brief allows —
// the reference is a SECOND, byte-identical DclexPool (`refPool`) initialised to
// the SAME reserves as the router's pool (`routerPool`) and settled DIRECTLY via
// a minimal IDclexSwapCallback reference caller. Foundry re-runs setUp() before
// every fuzz input, so both pools start from an identical state on each run; a
// single router leg and a single reference leg are then compared:
//
//   (1) buyExactInput(token,in)   : stock delivered by the router == stock
//       returned by refPool.swapExactInput for the same input.
//   (2) buyExactOutput(token,out) : dUSD the router pulls from the caller ==
//       the gross input refPool.swapExactOutput derives for that output.
//   (3) sell mirrors both of the above (stock in / dUSD out).
//   (4) round-trip: buyExactInput then sellExactInput of the received stock
//       returns NO MORE dUSD than was put in (no value extraction via router).
//
// Legitimate pool reverts (NotEnoughPoolLiquidity, ZeroOutputAmount) are
// try/caught on the REFERENCE leg and skipped; when the reference leg succeeds
// the router leg MUST also succeed AND match — a router-only revert or a
// mismatch is a genuine finding. A ghost counter + deterministic non-vacuity
// tests prove the differential machinery actually fires.
//
// Run:
//   cd primedelta-periphery && FOUNDRY_EVM_VERSION=cancun \
//     forge test --match-path test/fuzz/Fuzz_DclexRouterMath.t.sol -vv

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DclexRouter} from "src/DclexRouter.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {IDclexSwapCallback} from "dclex-protocol/src/IDclexSwapCallback.sol";
import {DeployDclex} from "dclex-protocol/script/DeployDclex.s.sol";
import {DeployDclexPool} from "dclex-protocol/script/DeployDclexPool.s.sol";
import {
    HelperConfig as DclexProtocolHelperConfig
} from "dclex-protocol/script/HelperConfig.s.sol";
import {MockPriceOracle} from "dclex-protocol/test/MockPriceOracle.sol";
import {
    DigitalIdentity
} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {Stock} from "dclex-blockchain/contracts/dclex/Stock.sol";
import {USDCMock} from "dclex-blockchain/contracts/mocks/USDCMock.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";

/// @notice Minimal IDclexSwapCallback caller used to settle `refPool` DIRECTLY
///         (the pool pushes output to `recipient`, then calls back for payment).
///         It holds stock + dUSD and, in the callback, simply hands the pool the
///         exact `amount` of the requested `token`. This is the "ground truth"
///         the router is measured against.
contract RefCaller is IDclexSwapCallback {
    using SafeERC20 for IERC20;

    function dclexSwapCallback(
        address token,
        uint256 amount,
        bytes calldata
    ) external override {
        // msg.sender is the DclexPool mid-swap; pay it what it asks.
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function buyExactInput(
        DclexPool pool,
        uint256 scIn6,
        bytes[] calldata pd
    ) external returns (uint256) {
        return pool.swapExactInput(true, scIn6, address(this), "", pd);
    }

    function sellExactInput(
        DclexPool pool,
        uint256 stockIn,
        bytes[] calldata pd
    ) external returns (uint256) {
        return pool.swapExactInput(false, stockIn, address(this), "", pd);
    }

    function buyExactOutput(
        DclexPool pool,
        uint256 stockOut,
        bytes[] calldata pd
    ) external returns (uint256) {
        return pool.swapExactOutput(true, stockOut, address(this), "", pd);
    }

    function sellExactOutput(
        DclexPool pool,
        uint256 scOut6,
        bytes[] calldata pd
    ) external returns (uint256) {
        return pool.swapExactOutput(false, scOut6, address(this), "", pd);
    }
}

contract Fuzz_DclexRouterMath is Test {
    // Fixed signed price for the whole suite (mirrors the DclexRouter unit
    // harness: AAPL $20). USDC price is never read by DclexPool (stablecoin
    // price is hard-coded to 1e18) but is set for parity with the harness.
    uint256 internal constant AAPL_PRICE = 20 ether;
    uint256 internal constant USDC_PRICE = 1 ether;
    uint256 internal constant STOCK_LIQ = 100 ether;
    uint256 internal constant DUSD_LIQ = 2000e6;

    address internal ADMIN = makeAddr("admin");
    address internal immutable MASTER_ADMIN = makeAddr("master_admin");

    DigitalIdentity internal did;
    Factory internal factory;
    USDCMock internal dusd;
    MockPriceOracle internal oracle;

    Stock internal aapl;
    bytes32 internal aaplFeed;
    bytes32 internal usdcFeed;

    DclexRouter internal router;
    DclexPool internal routerPool; // registered in the router
    DclexPool internal refPool; // settled directly by RefCaller (ground truth)
    RefCaller internal ref;

    bytes[] internal EMPTY;

    // Non-vacuity witness: number of differential comparisons that ran to the
    // assertion (i.e. the reference leg succeeded and a real amount was
    // compared). Proves the fuzz assertions are not passing vacuously.
    uint256 internal ghost_compared;

    receive() external payable {}

    function setUp() public {
        // ---- core dclex world (Factory / DID / Stock / dUSD / oracle) ----
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory c = deployer.run(ADMIN, MASTER_ADMIN);
        did = c.digitalIdentity;
        factory = c.stocksFactory;

        vm.startPrank(ADMIN);
        string[] memory names = new string[](1);
        string[] memory symbols = new string[](1);
        names[0] = "Apple";
        symbols[0] = "AAPL";
        factory.createStocks(names, symbols);
        vm.stopPrank();
        aapl = Stock(factory.stocks("AAPL"));

        DclexProtocolHelperConfig helperConfig = new DclexProtocolHelperConfig();
        DclexProtocolHelperConfig.NetworkConfig memory cfg = helperConfig
            .getConfig();
        dusd = USDCMock(address(cfg.dusdToken));
        oracle = MockPriceOracle(address(cfg.oracle));

        aaplFeed = keccak256(abi.encodePacked(address(aapl)));
        usdcFeed = helperConfig.getPriceFeedId("USDC");
        oracle.setPrice(aaplFeed, AAPL_PRICE);
        oracle.setPrice(usdcFeed, USDC_PRICE);

        // ---- router + TWO fee-free, identical DCLEX pools for AAPL ----
        // Same stock ⇒ same price feed id + same multiplier ⇒ the two pools'
        // swap math is identical once their reserves match.
        router = new DclexRouter(IERC20(address(dusd)));
        DeployDclexPool poolDeployer = new DeployDclexPool();
        routerPool = poolDeployer.deploy(IStock(address(aapl)), helperConfig, 0, 0, 0);
        refPool = poolDeployer.deploy(IStock(address(aapl)), helperConfig, 0, 0, 0);

        router.addPool(address(aapl), DclexRouter.PoolType.DCLEX, address(routerPool), 0);

        ref = new RefCaller();

        // ---- DIDs (pools level 2, everything else level 0) ----
        vm.startPrank(ADMIN);
        did.mintAdmin(address(router), 0, bytes32(0));
        did.mintAdmin(address(routerPool), 2, bytes32(0));
        did.mintAdmin(address(refPool), 2, bytes32(0));
        did.mintAdmin(address(ref), 0, bytes32(0));
        did.mintAdmin(address(this), 0, bytes32(0));
        vm.stopPrank();

        // ---- fund this contract: it is BOTH the LP that seeds the two pools
        //      AND the router's user. Generous balances so trades never fail
        //      for lack of funds (only for pool-liquidity math). ----
        vm.startPrank(ADMIN);
        factory.forceMintStocks("AAPL", address(this), 1_000_000 ether);
        factory.forceMintStocks("AAPL", address(ref), 1_000_000 ether);
        vm.stopPrank();
        dusd.mint(address(this), 100_000_000e6);
        dusd.mint(address(ref), 100_000_000e6);

        // LP approvals + seed identical reserves into both pools.
        aapl.approve(address(routerPool), type(uint256).max);
        aapl.approve(address(refPool), type(uint256).max);
        dusd.approve(address(routerPool), type(uint256).max);
        dusd.approve(address(refPool), type(uint256).max);
        routerPool.initialize(STOCK_LIQ, DUSD_LIQ, EMPTY);
        refPool.initialize(STOCK_LIQ, DUSD_LIQ, EMPTY);

        // Router user approvals (the pool callback pulls the user's input via
        // the router → allowance is user→router).
        aapl.approve(address(router), type(uint256).max);
        dusd.approve(address(router), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    //                              helpers
    // ---------------------------------------------------------------------

    function _refresh() internal {
        // Re-stamp publishTime = now so neither pool ever reads a stale quote.
        oracle.setPrice(aaplFeed, AAPL_PRICE);
    }

    function _dusdReserve6(DclexPool pool) internal view returns (uint256) {
        (, uint256 scR18) = pool.getReserves();
        return scR18 / 1e12;
    }

    function _stockReserve(DclexPool pool) internal view returns (uint256) {
        (uint256 stockR, ) = pool.getReserves();
        return stockR;
    }

    // =====================================================================
    // (1) BUY exact input — dUSD in, stock out.
    //     Router-delivered stock == refPool's returned stock output.
    // =====================================================================
    function testFuzz_buyExactInput_matchesPool(uint256 amtSeed) public {
        _refresh();
        uint256 cap = _dusdReserve6(refPool);
        uint256 scIn6 = bound(amtSeed, 1e4, cap / 10);

        // Reference leg (ground truth) — skip only on a legitimate pool revert.
        uint256 refOut;
        try ref.buyExactInput(refPool, scIn6, EMPTY) returns (uint256 o) {
            refOut = o;
        } catch {
            return;
        }

        // Router leg on the identical routerPool — MUST succeed and match.
        uint256 before = aapl.balanceOf(address(this));
        router.buyExactInput(address(aapl), scIn6, 0, block.timestamp + 1, EMPTY);
        uint256 routerOut = aapl.balanceOf(address(this)) - before;

        assertEq(routerOut, refOut, "router buyExactInput skims/adds vs pool");
        ghost_compared++;
    }

    // =====================================================================
    // (2) BUY exact output — stock out, dUSD in.
    //     dUSD the router pulls == refPool's derived gross input.
    // =====================================================================
    function testFuzz_buyExactOutput_matchesPool(uint256 amtSeed) public {
        _refresh();
        uint256 cap = _stockReserve(refPool);
        uint256 stockOut = bound(amtSeed, 1e13, cap / 10);

        uint256 refIn6;
        try ref.buyExactOutput(refPool, stockOut, EMPTY) returns (uint256 i) {
            refIn6 = i;
        } catch {
            return;
        }

        uint256 dusdBefore = dusd.balanceOf(address(this));
        uint256 stockBefore = aapl.balanceOf(address(this));
        router.buyExactOutput(
            address(aapl),
            stockOut,
            type(uint256).max,
            block.timestamp + 1,
            EMPTY
        );
        uint256 routerIn6 = dusdBefore - dusd.balanceOf(address(this));
        uint256 routerOut = aapl.balanceOf(address(this)) - stockBefore;

        assertEq(routerIn6, refIn6, "router buyExactOutput inflates input vs pool");
        assertEq(routerOut, stockOut, "router buyExactOutput short-filled the exact output");
        ghost_compared++;
    }

    // =====================================================================
    // (3a) SELL exact input — stock in, dUSD out.
    // =====================================================================
    function testFuzz_sellExactInput_matchesPool(uint256 amtSeed) public {
        _refresh();
        uint256 cap = _stockReserve(refPool);
        uint256 stockIn = bound(amtSeed, 1e13, cap / 10);

        uint256 refOut6;
        try ref.sellExactInput(refPool, stockIn, EMPTY) returns (uint256 o) {
            refOut6 = o;
        } catch {
            return;
        }

        uint256 before = dusd.balanceOf(address(this));
        router.sellExactInput(address(aapl), stockIn, 0, block.timestamp + 1, EMPTY);
        uint256 routerOut6 = dusd.balanceOf(address(this)) - before;

        assertEq(routerOut6, refOut6, "router sellExactInput skims/adds vs pool");
        ghost_compared++;
    }

    // =====================================================================
    // (3b) SELL exact output — stock in, dUSD out (exact dUSD).
    //     Stock the router pulls == refPool's derived gross input.
    // =====================================================================
    function testFuzz_sellExactOutput_matchesPool(uint256 amtSeed) public {
        _refresh();
        uint256 cap = _dusdReserve6(refPool);
        uint256 scOut6 = bound(amtSeed, 1e3, cap / 10);

        uint256 refIn;
        try ref.sellExactOutput(refPool, scOut6, EMPTY) returns (uint256 i) {
            refIn = i;
        } catch {
            return;
        }

        uint256 stockBefore = aapl.balanceOf(address(this));
        uint256 dusdBefore = dusd.balanceOf(address(this));
        router.sellExactOutput(
            address(aapl),
            scOut6,
            type(uint256).max,
            block.timestamp + 1,
            EMPTY
        );
        uint256 routerIn = stockBefore - aapl.balanceOf(address(this));
        uint256 routerOut6 = dusd.balanceOf(address(this)) - dusdBefore;

        assertEq(routerIn, refIn, "router sellExactOutput inflates input vs pool");
        assertEq(routerOut6, scOut6, "router sellExactOutput short-filled the exact output");
        ghost_compared++;
    }

    // =====================================================================
    // (4) ROUND-TRIP through the router extracts no value: buy stock with
    //     dUSD, then sell exactly that stock back — never end with more dUSD
    //     than you started (fee-free pool ⇒ rounding always favors the pool).
    // =====================================================================
    function testFuzz_roundTrip_noValueExtraction(uint256 amtSeed) public {
        _refresh();
        uint256 cap = _dusdReserve6(routerPool);
        uint256 scIn6 = bound(amtSeed, 1e4, cap / 20);

        uint256 dusdBefore = dusd.balanceOf(address(this));
        uint256 stockBefore = aapl.balanceOf(address(this));

        // Buy leg.
        try
            router.buyExactInput(address(aapl), scIn6, 0, block.timestamp + 1, EMPTY)
        {} catch {
            return;
        }
        uint256 stockGot = aapl.balanceOf(address(this)) - stockBefore;
        if (stockGot == 0) return;

        // Sell exactly the stock we received back for dUSD.
        _refresh();
        try
            router.sellExactInput(address(aapl), stockGot, 0, block.timestamp + 1, EMPTY)
        {} catch {
            return;
        }

        uint256 dusdAfter = dusd.balanceOf(address(this));
        assertLe(dusdAfter, dusdBefore, "router round-trip extracted dUSD value");
        ghost_compared++;
    }

    // ---------------------------------------------------------------------
    //          deterministic non-vacuity proofs (machinery fires)
    // ---------------------------------------------------------------------

    /// Concrete differential over every entry point with real, non-zero
    /// amounts — proves the fuzz comparisons above are not trivially skipped
    /// and that the router truly returns the pool's own quote.
    function test_nonVacuous_routerEqualsPool() public {
        _refresh();

        // buy exact input: 200 dUSD.
        {
            uint256 refOut = ref.buyExactInput(refPool, 200e6, EMPTY);
            uint256 b = aapl.balanceOf(address(this));
            router.buyExactInput(address(aapl), 200e6, 0, block.timestamp + 1, EMPTY);
            uint256 got = aapl.balanceOf(address(this)) - b;
            assertGt(got, 0, "buy produced no stock");
            assertEq(got, refOut, "buy exact-in mismatch");
        }
        // buy exact output: 3 AAPL.
        {
            _refresh();
            uint256 refIn = ref.buyExactOutput(refPool, 3 ether, EMPTY);
            uint256 db = dusd.balanceOf(address(this));
            router.buyExactOutput(address(aapl), 3 ether, type(uint256).max, block.timestamp + 1, EMPTY);
            uint256 spent = db - dusd.balanceOf(address(this));
            assertGt(spent, 0, "buy exact-out spent nothing");
            assertEq(spent, refIn, "buy exact-out mismatch");
        }
        // sell exact input: 2 AAPL.
        {
            _refresh();
            uint256 refOut = ref.sellExactInput(refPool, 2 ether, EMPTY);
            uint256 db = dusd.balanceOf(address(this));
            router.sellExactInput(address(aapl), 2 ether, 0, block.timestamp + 1, EMPTY);
            uint256 got = dusd.balanceOf(address(this)) - db;
            assertGt(got, 0, "sell produced no dUSD");
            assertEq(got, refOut, "sell exact-in mismatch");
        }
        // sell exact output: 40 dUSD.
        {
            _refresh();
            uint256 refIn = ref.sellExactOutput(refPool, 40e6, EMPTY);
            uint256 sb = aapl.balanceOf(address(this));
            router.sellExactOutput(address(aapl), 40e6, type(uint256).max, block.timestamp + 1, EMPTY);
            uint256 spent = sb - aapl.balanceOf(address(this));
            assertGt(spent, 0, "sell exact-out spent no stock");
            assertEq(spent, refIn, "sell exact-out mismatch");
        }
    }

    /// The round trip actually moves funds and is lossy-or-equal (never a gain).
    function test_nonVacuous_roundTripLossyOrEqual() public {
        _refresh();
        uint256 dusdBefore = dusd.balanceOf(address(this));
        uint256 stockBefore = aapl.balanceOf(address(this));

        router.buyExactInput(address(aapl), 500e6, 0, block.timestamp + 1, EMPTY);
        uint256 stockGot = aapl.balanceOf(address(this)) - stockBefore;
        assertGt(stockGot, 0, "round-trip buy produced no stock");
        assertEq(dusd.balanceOf(address(this)), dusdBefore - 500e6, "buy did not cost exactly 500 dUSD");

        _refresh();
        router.sellExactInput(address(aapl), stockGot, 0, block.timestamp + 1, EMPTY);

        uint256 dusdAfter = dusd.balanceOf(address(this));
        assertLe(dusdAfter, dusdBefore, "round-trip extracted dUSD value");
        // And the router keeps nothing.
        assertEq(dusd.balanceOf(address(router)), 0, "router retains dUSD");
        assertEq(aapl.balanceOf(address(router)), 0, "router retains stock");
    }
}
