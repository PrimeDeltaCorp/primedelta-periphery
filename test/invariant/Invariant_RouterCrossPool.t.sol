// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// PrimeDelta audit round-2 — STATEFUL INVARIANT FUZZING for the DclexRouter
// CROSS-POOL (stock -> dUSD -> stock) multi-hop path.
//
// swapExactInput(inputStock, outputStock, ...) / swapExactOutput(...) route
//   inputStock --(DclexPool A: sell)--> dUSD --(DclexPool B: buy)--> outputStock
// with the ROUTER as the transient intermediary. The inner dUSD leg re-enters
// dclexSwapCallback while the outer leg's callback is still on the stack
// (nested DCLEX callback + sentinel save/restore). This suite hammers that
// path from several DID-holding actors and asserts three safety properties:
//
//   (CP-1) MID-HOP CUSTODY IS TRANSIENT — after every settled cross swap the
//          router holds ZERO stock / dUSD / native. Funds are never left
//          stuck between the two hops. Asserted EXACTLY zero (no dust epsilon
//          is even permitted: the router forwards the precise dUSD it received
//          from pool A into pool B). → invariant_routerHoldsNoResidualFunds
//
//   (CP-2) TRADE DIRECTION IS MONOTONE — a trader that runs a cross swap
//          RECEIVES outputStock and SPENDS inputStock, never the reverse: the
//          input-token balance never rises and the output-token balance never
//          falls across a settled swap. → invariant_traderDirectionRespected
//
//   (CP-3) NEITHER POOL LOSES VALUE — each DclexPool's reserve value, priced
//          at its own oracle price, is non-decreasing across the whole
//          campaign (the trader never extracts value from a pool; rounding
//          only ever favors the pool). → invariant_poolsRemainSolvent
//
// Non-vacuity: a ghost counter proves real cross swaps settled, and a
// deterministic meta-test drives concrete cross swaps end-to-end.
//
// World is the SAME production fixtures the unit/invariant harness uses
// (DeployDclex + HelperConfig + DeployDclexPool). Two fee-free DclexPools
// (feeCurve = 0, protocolFeeRate = 0) so getReserves() == raw balances and
// value-conservation reasoning is clean. V3 is deliberately omitted (brief
// scope: the DCLEX two-hop path).
//
// Run:
//   FOUNDRY_EVM_VERSION=cancun forge test \
//     --match-path test/invariant/Invariant_RouterCrossPool.t.sol -vvv

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {DclexRouter} from "src/DclexRouter.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
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

/// @notice Bounded-action fuzz actor for the router's cross-pool path. It owns
///         a set of DID-holding traders (each with stock/dUSD balances and a
///         standing router approval) and, per action, pranks as one of them to
///         run a stock->stock cross swap. Every action wraps the router entry
///         point in try/catch, bounds the amount to a reachable range, keeps
///         both oracle feeds fresh, and — on success — records real balance
///         deltas so the direction + non-vacuity invariants can be asserted.
contract RouterCrossPoolHandler is Test {
    // 1e18-scaled oracle prices — constants (not ctor args) to keep the
    // constructor's ABI decode below the stack-too-deep threshold.
    uint256 public constant aaplPrice = 20 ether;
    uint256 public constant nvdaPrice = 30 ether;

    DclexRouter public immutable router;
    IERC20 public immutable dusd;
    MockPriceOracle public immutable oracle;

    address public immutable aaplStock;
    address public immutable nvdaStock;
    DclexPool public immutable aaplPool;
    DclexPool public immutable nvdaPool;
    bytes32 public immutable aaplFeed;
    bytes32 public immutable nvdaFeed;

    address[] public actors;
    bytes[] internal EMPTY;

    // ---- ghost accounting ----
    // A settled cross swap moved a trader's balances the WRONG way: the input
    // token rose, the output token fell, or an exact-output swap short-filled.
    bool public ghost_traderDirectionViolated;
    // Non-vacuity witness: number of cross swaps that actually settled.
    uint256 public ghost_crossSwapsSettled;
    uint256 public callCount;

    struct Leg {
        address token;
        DclexPool pool;
        bytes32 feed;
        uint256 price;
    }

    constructor(
        DclexRouter _router,
        IERC20 _dusd,
        MockPriceOracle _oracle,
        address _aaplStock,
        address _nvdaStock,
        DclexPool _aaplPool,
        DclexPool _nvdaPool,
        address[] memory _actors
    ) {
        router = _router;
        dusd = _dusd;
        oracle = _oracle;
        aaplStock = _aaplStock;
        nvdaStock = _nvdaStock;
        aaplPool = _aaplPool;
        nvdaPool = _nvdaPool;
        // Feed IDs are derived the same way DclexPool derives them:
        // keccak256(abi.encodePacked(stockToken)).
        aaplFeed = keccak256(abi.encodePacked(_aaplStock));
        nvdaFeed = keccak256(abi.encodePacked(_nvdaStock));
        actors = _actors;
    }

    function _leg(uint256 seed) internal view returns (Leg memory) {
        if (seed % 2 == 0) {
            return Leg(aaplStock, aaplPool, aaplFeed, aaplPrice);
        }
        return Leg(nvdaStock, nvdaPool, nvdaFeed, nvdaPrice);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // Re-stamp BOTH feeds' publishTime to `now` so neither pool ever reads a
    // stale quote — the pool's MAX_PRICE_STALENESS is 60s and the campaign
    // holds block.timestamp fixed, so a fresh stamp keeps age == 0.
    function _refreshBoth() internal {
        oracle.setPrice(aaplFeed, aaplPrice);
        oracle.setPrice(nvdaFeed, nvdaPrice);
    }

    function _stockReserve(DclexPool pool) internal view returns (uint256) {
        (uint256 stockR, ) = pool.getReserves();
        return stockR;
    }

    // ---------------- ACTIONS ----------------

    /// Cross-pool stock->stock, EXACT INPUT. Exercises the nested DCLEX
    /// callback + sentinel save/restore. On success asserts the trader spent
    /// input stock and received output stock (never the reverse).
    function crossSwapExactInput(
        uint256 actorSeed,
        uint256 dirSeed,
        uint256 amtSeed,
        uint256 minSeed
    ) external {
        callCount++;
        _refreshBoth();
        address trader = _actor(actorSeed);
        Leg memory inLeg = _leg(dirSeed);
        Leg memory outLeg = _leg(dirSeed + 1); // the OTHER token

        uint256 hi = _stockReserve(inLeg.pool) / 10;
        if (hi < 1e15) return;
        uint256 stockIn = bound(amtSeed, 1e15, hi);
        // value-conserving estimate; middle 6-dec truncation makes the real
        // output <= this, so cap minOut at 90% to avoid rounding false reverts.
        uint256 expectedOut = Math.mulDiv(stockIn, inLeg.price, outLeg.price);
        uint256 minOut = bound(minSeed, 0, (expectedOut * 9) / 10);

        uint256 inBefore = IERC20(inLeg.token).balanceOf(trader);
        uint256 outBefore = IERC20(outLeg.token).balanceOf(trader);

        vm.prank(trader);
        try
            router.swapExactInput(
                inLeg.token,
                outLeg.token,
                stockIn,
                minOut,
                block.timestamp + 1000,
                EMPTY
            )
        {
            uint256 inAfter = IERC20(inLeg.token).balanceOf(trader);
            uint256 outAfter = IERC20(outLeg.token).balanceOf(trader);
            // Direction: input MUST fall, output MUST rise. Anything else is a
            // trader-favoring (or fund-stealing) break.
            if (inAfter > inBefore) ghost_traderDirectionViolated = true;
            if (outAfter < outBefore) ghost_traderDirectionViolated = true;
            // A settled exact-input cross swap consumes exactly `stockIn` and delivers a positive
            // amount of the output token. Guard the subtraction with the direction check so a wrong-way
            // result records the violation instead of underflow-reverting (masked by fail_on_revert=false).
            if (inAfter <= inBefore && inBefore - inAfter != stockIn) ghost_traderDirectionViolated = true;
            if (outAfter <= outBefore) ghost_traderDirectionViolated = true;
            ghost_crossSwapsSettled++;
        } catch {}
    }

    /// Cross-pool stock->stock, EXACT OUTPUT. On success asserts the trader
    /// spent input stock (<= maxInput) and received EXACTLY the output
    /// requested (DCLEX pools never partial-fill).
    function crossSwapExactOutput(
        uint256 actorSeed,
        uint256 dirSeed,
        uint256 amtSeed
    ) external {
        callCount++;
        _refreshBoth();
        address trader = _actor(actorSeed);
        Leg memory inLeg = _leg(dirSeed);
        Leg memory outLeg = _leg(dirSeed + 1);

        uint256 hi = _stockReserve(outLeg.pool) / 10;
        if (hi < 1e15) return;
        uint256 stockOut = bound(amtSeed, 1e15, hi);
        uint256 expectedIn = Math.mulDiv(stockOut, outLeg.price, inLeg.price);
        uint256 maxIn = expectedIn * 2 + 1e18; // generous but a real bound

        uint256 inBefore = IERC20(inLeg.token).balanceOf(trader);
        uint256 outBefore = IERC20(outLeg.token).balanceOf(trader);

        vm.prank(trader);
        try
            router.swapExactOutput(
                inLeg.token,
                outLeg.token,
                stockOut,
                maxIn,
                block.timestamp + 1000,
                EMPTY
            )
        {
            uint256 inAfter = IERC20(inLeg.token).balanceOf(trader);
            uint256 outAfter = IERC20(outLeg.token).balanceOf(trader);
            if (inAfter > inBefore) ghost_traderDirectionViolated = true;
            if (outAfter < outBefore) ghost_traderDirectionViolated = true;
            // exact-output: received EXACTLY stockOut, spent > 0 and <= maxIn. Guard the subtractions
            // with the direction checks so a wrong-way result records the violation instead of
            // underflow-reverting (which fail_on_revert=false would mask).
            if (outAfter >= outBefore && outAfter - outBefore != stockOut) ghost_traderDirectionViolated = true;
            if (inAfter <= inBefore) {
                uint256 spent = inBefore - inAfter;
                if (spent == 0 || spent > maxIn) ghost_traderDirectionViolated = true;
            }
            ghost_crossSwapsSettled++;
        } catch {}
    }

    /// Cheap no-op: keep both feeds fresh so the fuzzer can interleave without
    /// wasting depth on stale-price reverts.
    function poke() external {
        callCount++;
        _refreshBoth();
    }
}

contract Invariant_RouterCrossPool is StdInvariant, Test {
    uint256 internal constant AAPL_PRICE = 20 ether;
    uint256 internal constant NVDA_PRICE = 30 ether;
    uint256 internal constant USDC_PRICE = 1 ether;

    // Balanced pools (stock value == dUSD value at the oracle price) so the
    // imbalance-fee curve leaves plenty of room for bounded cross trades.
    uint256 internal constant STOCK_LIQ = 100 ether;
    uint256 internal constant AAPL_DUSD_LIQ = 2000e6; // 100 * $20
    uint256 internal constant NVDA_DUSD_LIQ = 3000e6; // 100 * $30

    uint256 internal constant WAD = 1e18;

    address internal ADMIN = makeAddr("admin");
    address internal immutable MASTER_ADMIN = makeAddr("master_admin");

    DigitalIdentity internal did;
    Factory internal factory;
    USDCMock internal dusd;
    MockPriceOracle internal oracle;

    Stock internal aaplStock;
    Stock internal nvdaStock;
    DclexPool internal aaplPool;
    DclexPool internal nvdaPool;
    DclexRouter internal router;

    bytes32 internal aaplFeed;
    bytes32 internal nvdaFeed;
    bytes32 internal usdcFeed;

    // (CP-3) value baselines at each pool's own oracle price, captured right
    // after initialization. Pool value must never fall below these.
    uint256 internal aaplBaseValue;
    uint256 internal nvdaBaseValue;

    RouterCrossPoolHandler internal handler;
    address[] internal actors;

    bytes[] internal EMPTY;

    receive() external payable {}

    function setUp() public {
        // Fixed, non-zero timestamp so freshly-stamped prices have publishTime
        // > 0 (MockPriceOracle treats publishTime == 0 as "feed not found").
        vm.warp(1_000_000);

        // ---- core dclex world (Factory / DID / Stock / dUSD / oracle) ----
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory c = deployer.run(ADMIN, MASTER_ADMIN);
        did = c.digitalIdentity;
        factory = c.stocksFactory;

        vm.startPrank(ADMIN);
        string[] memory names = new string[](2);
        string[] memory symbols = new string[](2);
        names[0] = "Apple";
        names[1] = "NVIDIA";
        symbols[0] = "AAPL";
        symbols[1] = "NVDA";
        factory.createStocks(names, symbols);
        vm.stopPrank();

        aaplStock = Stock(factory.stocks("AAPL"));
        nvdaStock = Stock(factory.stocks("NVDA"));

        DclexProtocolHelperConfig helperConfig = new DclexProtocolHelperConfig();
        DclexProtocolHelperConfig.NetworkConfig memory cfg = helperConfig.getConfig();
        dusd = USDCMock(address(cfg.dusdToken));
        oracle = MockPriceOracle(address(cfg.oracle));

        aaplFeed = keccak256(abi.encodePacked(address(aaplStock)));
        nvdaFeed = keccak256(abi.encodePacked(address(nvdaStock)));
        usdcFeed = helperConfig.getPriceFeedId("USDC");
        oracle.setPrice(aaplFeed, AAPL_PRICE);
        oracle.setPrice(nvdaFeed, NVDA_PRICE);
        oracle.setPrice(usdcFeed, USDC_PRICE);

        // ---- router + fee-free DCLEX pools ----
        router = new DclexRouter(IERC20(address(dusd)));

        DeployDclexPool poolDeployer = new DeployDclexPool();
        aaplPool = poolDeployer.run(IStock(address(aaplStock)), helperConfig, 0, 0, 0,
            address(this));
        nvdaPool = poolDeployer.run(IStock(address(nvdaStock)), helperConfig, 0, 0, 0,
            address(this));

        router.addPool(address(aaplStock), DclexRouter.PoolType.DCLEX, address(aaplPool), 0);
        router.addPool(address(nvdaStock), DclexRouter.PoolType.DCLEX, address(nvdaPool), 0);

        // DIDs: router (transient dUSD custody) + both pools (hold/transfer stock).
        vm.startPrank(ADMIN);
        did.mintAdmin(address(router), 0, bytes32(0));
        did.mintAdmin(address(aaplPool), 2, bytes32(0));
        did.mintAdmin(address(nvdaPool), 2, bytes32(0));
        vm.stopPrank();

        // ---- this contract seeds pool liquidity as the initial LP ----
        _fundAndApprovePools(address(this));
        aaplPool.initialize(STOCK_LIQ, AAPL_DUSD_LIQ, address(this), EMPTY);
        nvdaPool.initialize(STOCK_LIQ, NVDA_DUSD_LIQ, address(this), EMPTY);

        // (CP-3) capture value baselines at each pool's own price.
        aaplBaseValue = _poolValue(aaplPool, AAPL_PRICE);
        nvdaBaseValue = _poolValue(nvdaPool, NVDA_PRICE);

        // ---- DID-holding actors ----
        actors.push(makeAddr("trader_alice"));
        actors.push(makeAddr("trader_bob"));
        actors.push(makeAddr("trader_carol"));
        for (uint256 i = 0; i < actors.length; ++i) {
            _fundActor(actors[i]);
        }

        // ---- deploy the fuzz actor ----
        handler = new RouterCrossPoolHandler(
            router,
            IERC20(address(dusd)),
            oracle,
            address(aaplStock),
            address(nvdaStock),
            aaplPool,
            nvdaPool,
            actors
        );

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.crossSwapExactInput.selector;
        selectors[1] = handler.crossSwapExactOutput.selector;
        selectors[2] = handler.poke.selector;
        targetSelector(
            StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors})
        );
        targetContract(address(handler));
    }

    // Give `who` a valid DID + stock + dUSD and approve BOTH pools (used for
    // the LP that seeds liquidity — it transfers straight into the pools).
    function _fundAndApprovePools(address who) internal {
        vm.startPrank(ADMIN);
        did.mintAdmin(who, 0, bytes32(0));
        factory.forceMintStocks("AAPL", who, 100000 ether);
        factory.forceMintStocks("NVDA", who, 100000 ether);
        vm.stopPrank();
        dusd.mint(who, 1000000e6);
        vm.startPrank(who);
        aaplStock.approve(address(aaplPool), type(uint256).max);
        nvdaStock.approve(address(nvdaPool), type(uint256).max);
        dusd.approve(address(aaplPool), type(uint256).max);
        dusd.approve(address(nvdaPool), type(uint256).max);
        vm.stopPrank();
    }

    // Give a trader a valid DID + stock + dUSD and approve the ROUTER (the
    // router pulls input stock via the pool callback -> allowance is trader->router).
    function _fundActor(address who) internal {
        vm.startPrank(ADMIN);
        did.mintAdmin(who, 0, bytes32(0));
        factory.forceMintStocks("AAPL", who, 100000 ether);
        factory.forceMintStocks("NVDA", who, 100000 ether);
        vm.stopPrank();
        dusd.mint(who, 1000000e6);
        vm.startPrank(who);
        aaplStock.approve(address(router), type(uint256).max);
        nvdaStock.approve(address(router), type(uint256).max);
        dusd.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// Reserve value (18-dec stablecoin units) at price `p`: stock*p/1e18 + sc18.
    /// With protocolFeeRate == 0, getReserves() == raw balances.
    function _poolValue(DclexPool pool, uint256 p) internal view returns (uint256) {
        (uint256 stockR, uint256 scR18) = pool.getReserves();
        return Math.mulDiv(stockR, p, WAD) + scR18;
    }

    // =========================================================================
    // (CP-1) The router only custodies funds transiently within a single cross
    // swap; at rest (where invariants run) every balance is EXACTLY zero. In
    // the DCLEX two-hop path the router receives the precise dUSD pool A pays
    // out and forwards that exact amount into pool B — there is not even a dust
    // remainder to tolerate.
    // =========================================================================
    function invariant_routerHoldsNoResidualFunds() public view {
        assertEq(aaplStock.balanceOf(address(router)), 0, "router holds AAPL");
        assertEq(nvdaStock.balanceOf(address(router)), 0, "router holds NVDA");
        assertEq(dusd.balanceOf(address(router)), 0, "router holds dUSD");
        assertEq(address(router).balance, 0, "router holds ETH");
    }

    // =========================================================================
    // (CP-2) A trader that runs a cross swap always moves in the intended
    // direction: input token spent, output token received. The handler flips a
    // ghost flag (measured from real balance deltas) on any reversal, short
    // fill, or over-spend; it must stay false.
    // =========================================================================
    function invariant_traderDirectionRespected() public view {
        assertFalse(
            handler.ghost_traderDirectionViolated(),
            "a settled cross swap moved a trader's balances the wrong way"
        );
    }

    // =========================================================================
    // (CP-3) Neither pool is drained of value by cross swaps: each pool's
    // reserve value at its own oracle price is non-decreasing vs the baseline
    // captured right after initialization (rounding only ever favors the pool).
    // =========================================================================
    function invariant_poolsRemainSolvent() public view {
        assertGe(
            _poolValue(aaplPool, AAPL_PRICE),
            aaplBaseValue,
            "AAPL pool value fell below baseline"
        );
        assertGe(
            _poolValue(nvdaPool, NVDA_PRICE),
            nvdaBaseValue,
            "NVDA pool value fell below baseline"
        );
    }

    // Visibility only.
    function afterInvariant() public view {
        console.log("handler callCount (last seq):", handler.callCount());
        console.log("cross swaps settled (last seq):", handler.ghost_crossSwapsSettled());
    }

    // =========================================================================
    // Non-vacuity proof: drive concrete cross swaps once and confirm real
    // multi-hop router swaps execute (so the assertFalse/assertGe invariants
    // are not passing simply because nothing ever swapped). Re-asserts every
    // safety property after concrete swaps.
    // =========================================================================
    function test_crossPool_nonVacuous() public {
        address trader = actors[0];

        uint256 aaplBefore = aaplStock.balanceOf(trader);
        uint256 nvdaBefore = nvdaStock.balanceOf(trader);

        // AAPL -> NVDA, exact input (10 AAPL in), no min-out constraint.
        vm.prank(trader);
        router.swapExactInput(
            address(aaplStock),
            address(nvdaStock),
            10 ether,
            0,
            block.timestamp + 1000,
            EMPTY
        );
        assertEq(
            aaplBefore - aaplStock.balanceOf(trader),
            10 ether,
            "did not spend exactly 10 AAPL"
        );
        assertGt(
            nvdaStock.balanceOf(trader),
            nvdaBefore,
            "did not receive NVDA on cross swap"
        );

        // NVDA -> AAPL, exact output (want exactly 3 AAPL back).
        uint256 aaplMid = aaplStock.balanceOf(trader);
        uint256 nvdaMid = nvdaStock.balanceOf(trader);
        vm.prank(trader);
        router.swapExactOutput(
            address(nvdaStock),
            address(aaplStock),
            3 ether,
            100 ether,
            block.timestamp + 1000,
            EMPTY
        );
        assertEq(
            aaplStock.balanceOf(trader) - aaplMid,
            3 ether,
            "did not receive exactly 3 AAPL"
        );
        assertLt(
            nvdaStock.balanceOf(trader),
            nvdaMid,
            "did not spend NVDA on exact-output cross swap"
        );

        // Router drained of every asset after the concrete swap sequence.
        assertEq(aaplStock.balanceOf(address(router)), 0);
        assertEq(nvdaStock.balanceOf(address(router)), 0);
        assertEq(dusd.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);

        // Pools never dropped below their value baselines.
        assertGe(_poolValue(aaplPool, AAPL_PRICE), aaplBaseValue, "AAPL below baseline");
        assertGe(_poolValue(nvdaPool, NVDA_PRICE), nvdaBaseValue, "NVDA below baseline");
    }

    /// Drive the handler actions deterministically and confirm the ghost
    /// counter registers settled cross swaps (machinery non-vacuous).
    function test_crossPool_handlerSettlesSwaps() public {
        handler.crossSwapExactInput(0, 0, 5 ether, 0); // alice, AAPL->NVDA
        handler.crossSwapExactInput(1, 1, 5 ether, 0); // bob,   NVDA->AAPL
        handler.crossSwapExactOutput(2, 0, 2 ether);   // carol, AAPL->NVDA exact-out
        handler.crossSwapExactOutput(0, 1, 2 ether);   // alice, NVDA->AAPL exact-out

        assertGt(handler.ghost_crossSwapsSettled(), 0, "no cross swaps settled");
        assertFalse(
            handler.ghost_traderDirectionViolated(),
            "direction violated in meta-test"
        );
        assertEq(dusd.balanceOf(address(router)), 0, "router retained dUSD");
        assertEq(aaplStock.balanceOf(address(router)), 0, "router retained AAPL");
        assertEq(nvdaStock.balanceOf(address(router)), 0, "router retained NVDA");
    }
}
