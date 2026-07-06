// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// PrimeDelta audit round-2 — STATEFUL INVARIANT FUZZING for DclexRouter.
//
// Implements the ROUTER invariants from audit-round2/testplan/01-invariants.md:
//   INV-RTR-01 : after every entry point returns, the router holds ZERO residual
//                stock / stablecoin / ETH (it only custodies funds transiently
//                within a single call).                → invariant_routerHoldsNoResidualFunds
//   INV-CB-01  : at idle (no swap in flight) the callback sentinels are 0, so a
//                direct call to dclexSwapCallback / uniswapV3SwapCallback reverts
//                DclexRouter__UnexpectedCallback.       → invariant_callbackSentinelsIdleRevert
//   INV-RTR-04 : slippage is honored — a *successful* exactInput swap delivers
//                >= minOutput, a *successful* exactOutput swap costs <= maxInput,
//                and an exactOutput swap delivers EXACTLY the requested output
//                (DCLEX pools never partial-fill; the R2-C-01 note is V3-only).
//                                                       → invariant_slippageRespected
//
// The world is built from the SAME production fixtures the unit harness uses
// (DeployDclex + HelperConfig + DeployDclexPool). DclexRouterTest.setUp() is NOT
// `virtual` and all its fields are `private`, so it cannot be inherited/overridden
// — the relevant setup is reconstructed here (DCLEX pools only; V3 is deliberately
// omitted to avoid POOL_INIT_CODE_HASH fragility, exactly as the brief allows).
//
// A DclexRouterHandler is the fuzz actor: it holds a valid DID, stock/dUSD
// balances and standing router approvals, and calls the router entry points with
// bounded random amounts. Ghost flags record any slippage/exactness breach; a
// ghost counter proves the campaign was non-vacuous.
//
// Run:
//   forge test --match-path 'test/invariant/Invariant_DclexRouter.t.sol' -vvv

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

/// @notice Bounded-action fuzz actor. Acts as the router *user*: holds a valid
///         DID, stock + dUSD balances, and standing approvals to the router.
///         Every action wraps a router entry point in try/catch, bounds the
///         random amount to a reachable range, and — on success — verifies the
///         real token deltas honor the min/max the user requested.
contract DclexRouterHandler is StdUtils {
    DclexRouter public immutable router;
    IERC20 public immutable dusd;
    MockPriceOracle public immutable oracle;

    address public immutable aaplStock;
    address public immutable nvdaStock;
    DclexPool public immutable aaplPool;
    DclexPool public immutable nvdaPool;
    bytes32 public immutable aaplFeed;
    bytes32 public immutable nvdaFeed;
    uint256 public immutable aaplPrice; // 1e18-scaled oracle price
    uint256 public immutable nvdaPrice;

    bytes[] internal EMPTY;

    // ---- ghost accounting ----
    // A *successful* exactInput swap returned less than the requested minOutput
    // (real balance delta), or a successful exactOutput swap cost more than the
    // requested maxInput. Either is an on-chain slippage-enforcement break.
    bool public ghost_slippageViolated;
    // A successful exactOutput swap delivered less than the requested exact
    // output amount (DCLEX pools must never partial-fill).
    bool public ghost_exactOutputShort;
    // Non-vacuity witness: number of router swaps that actually executed.
    uint256 public ghost_swapsExecuted;
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
        bytes32 _aaplFeed,
        bytes32 _nvdaFeed,
        uint256 _aaplPrice,
        uint256 _nvdaPrice
    ) {
        router = _router;
        dusd = _dusd;
        oracle = _oracle;
        aaplStock = _aaplStock;
        nvdaStock = _nvdaStock;
        aaplPool = _aaplPool;
        nvdaPool = _nvdaPool;
        aaplFeed = _aaplFeed;
        nvdaFeed = _nvdaFeed;
        aaplPrice = _aaplPrice;
        nvdaPrice = _nvdaPrice;
    }

    function _leg(uint256 seed) internal view returns (Leg memory) {
        if (seed % 2 == 0) {
            return Leg(aaplStock, aaplPool, aaplFeed, aaplPrice);
        }
        return Leg(nvdaStock, nvdaPool, nvdaFeed, nvdaPrice);
    }

    // Re-stamp the feed's publishTime to `now` so the pool never reads a stale
    // quote. The invariant campaign holds block.timestamp fixed, but this keeps
    // the suite robust even if a future handler warps time.
    function _refresh(Leg memory leg) internal {
        oracle.setPrice(leg.feed, leg.price);
    }

    function _dusdReserve6(DclexPool pool) internal view returns (uint256) {
        (, uint256 scR18) = pool.getReserves();
        return scR18 / 1e12;
    }

    function _stockReserve(DclexPool pool) internal view returns (uint256) {
        (uint256 stockR, ) = pool.getReserves();
        return stockR;
    }

    // ---------------- ACTIONS ----------------

    /// Buy stock with dUSD (exact dUSD in). Verifies stock received >= minOutput.
    function buyExactInput(uint256 legSeed, uint256 amtSeed, uint256 minSeed)
        external
    {
        callCount++;
        Leg memory leg = _leg(legSeed);
        _refresh(leg);
        uint256 cap = _dusdReserve6(leg.pool);
        uint256 scIn6 = bound(amtSeed, 0, cap == 0 ? 1 : cap / 10);
        uint256 expectedOut = (scIn6 * 1e12 * 1e18) / leg.price; // fee-free
        uint256 minOut = bound(minSeed, 0, expectedOut); // always satisfiable
        uint256 before = IERC20(leg.token).balanceOf(address(this));
        try
            router.buyExactInput(
                leg.token,
                scIn6,
                minOut,
                block.timestamp + 1000,
                EMPTY
            )
        {
            uint256 got = IERC20(leg.token).balanceOf(address(this)) - before;
            if (got < minOut) ghost_slippageViolated = true;
            ghost_swapsExecuted++;
        } catch {}
    }

    /// Sell stock for dUSD (exact stock in). Verifies dUSD received >= minOutput.
    function sellExactInput(uint256 legSeed, uint256 amtSeed, uint256 minSeed)
        external
    {
        callCount++;
        Leg memory leg = _leg(legSeed);
        _refresh(leg);
        uint256 cap = _stockReserve(leg.pool);
        uint256 stockIn = bound(amtSeed, 0, cap == 0 ? 1 : cap / 10);
        uint256 expectedOut6 = (stockIn * leg.price) / 1e18 / 1e12; // fee-free
        uint256 minOut6 = bound(minSeed, 0, expectedOut6);
        uint256 before = dusd.balanceOf(address(this));
        try
            router.sellExactInput(
                leg.token,
                stockIn,
                minOut6,
                block.timestamp + 1000,
                EMPTY
            )
        {
            uint256 got = dusd.balanceOf(address(this)) - before;
            if (got < minOut6) ghost_slippageViolated = true;
            ghost_swapsExecuted++;
        } catch {}
    }

    /// Buy an exact stock amount, paying dUSD. Verifies input <= maxInput AND
    /// exactly the requested stock was delivered.
    function buyExactOutput(uint256 legSeed, uint256 amtSeed) external {
        callCount++;
        Leg memory leg = _leg(legSeed);
        _refresh(leg);
        uint256 cap = _stockReserve(leg.pool);
        uint256 stockOut = bound(amtSeed, 0, cap == 0 ? 0 : cap / 10);
        if (stockOut == 0) return; // ZeroOutputAmount — nothing to assert
        uint256 expectedIn6 = (stockOut * leg.price) / 1e18 / 1e12;
        uint256 maxIn6 = expectedIn6 * 2 + 1e6; // generous, still a real bound
        uint256 dusdBefore = dusd.balanceOf(address(this));
        uint256 stockBefore = IERC20(leg.token).balanceOf(address(this));
        try
            router.buyExactOutput(
                leg.token,
                stockOut,
                maxIn6,
                block.timestamp + 1000,
                EMPTY
            )
        {
            uint256 spent = dusdBefore - dusd.balanceOf(address(this));
            uint256 recv = IERC20(leg.token).balanceOf(address(this)) - stockBefore;
            if (spent > maxIn6) ghost_slippageViolated = true;
            if (recv < stockOut) ghost_exactOutputShort = true;
            ghost_swapsExecuted++;
        } catch {}
    }

    /// Sell stock for an exact dUSD amount. Verifies input <= maxInput AND
    /// exactly the requested dUSD was delivered.
    function sellExactOutput(uint256 legSeed, uint256 amtSeed) external {
        callCount++;
        Leg memory leg = _leg(legSeed);
        _refresh(leg);
        uint256 cap = _dusdReserve6(leg.pool);
        uint256 scOut6 = bound(amtSeed, 0, cap == 0 ? 0 : cap / 10);
        if (scOut6 == 0) return;
        uint256 expectedIn = (scOut6 * 1e12 * 1e18) / leg.price;
        uint256 maxIn = expectedIn * 2 + 1e18;
        uint256 stockBefore = IERC20(leg.token).balanceOf(address(this));
        uint256 dusdBefore = dusd.balanceOf(address(this));
        try
            router.sellExactOutput(
                leg.token,
                scOut6,
                maxIn,
                block.timestamp + 1000,
                EMPTY
            )
        {
            uint256 spent = stockBefore - IERC20(leg.token).balanceOf(address(this));
            uint256 recv = dusd.balanceOf(address(this)) - dusdBefore;
            if (spent > maxIn) ghost_slippageViolated = true;
            if (recv < scOut6) ghost_exactOutputShort = true;
            ghost_swapsExecuted++;
        } catch {}
    }

    /// Cross-pool stock->stock, exact input. Exercises the nested DCLEX callback
    /// + sentinel save/restore. Verifies output stock received >= minOutput.
    function crossSwapExactInput(uint256 dirSeed, uint256 amtSeed, uint256 minSeed)
        external
    {
        callCount++;
        Leg memory inLeg = _leg(dirSeed);
        Leg memory outLeg = _leg(dirSeed + 1); // the other token
        _refresh(inLeg);
        _refresh(outLeg);
        uint256 cap = _stockReserve(inLeg.pool);
        uint256 stockIn = bound(amtSeed, 0, cap == 0 ? 1 : cap / 10);
        // value-conserving estimate; middle 6-dec truncation makes actual <=
        // this, so cap minOut at 90% to avoid rounding false positives.
        uint256 expectedOut = (stockIn * inLeg.price) / outLeg.price;
        uint256 minOut = bound(minSeed, 0, (expectedOut * 9) / 10);
        uint256 before = IERC20(outLeg.token).balanceOf(address(this));
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
            uint256 got = IERC20(outLeg.token).balanceOf(address(this)) - before;
            if (got < minOut) ghost_slippageViolated = true;
            ghost_swapsExecuted++;
        } catch {}
    }

    /// Cross-pool stock->stock, exact output. Verifies input <= maxInput AND
    /// exactly the requested output stock was delivered.
    function crossSwapExactOutput(uint256 dirSeed, uint256 amtSeed) external {
        callCount++;
        Leg memory inLeg = _leg(dirSeed);
        Leg memory outLeg = _leg(dirSeed + 1);
        _refresh(inLeg);
        _refresh(outLeg);
        uint256 cap = _stockReserve(outLeg.pool);
        uint256 stockOut = bound(amtSeed, 0, cap == 0 ? 0 : cap / 10);
        if (stockOut == 0) return;
        uint256 expectedIn = (stockOut * outLeg.price) / inLeg.price;
        uint256 maxIn = expectedIn * 2 + 1e18;
        uint256 inBefore = IERC20(inLeg.token).balanceOf(address(this));
        uint256 outBefore = IERC20(outLeg.token).balanceOf(address(this));
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
            uint256 spent = inBefore - IERC20(inLeg.token).balanceOf(address(this));
            uint256 recv = IERC20(outLeg.token).balanceOf(address(this)) - outBefore;
            if (spent > maxIn) ghost_slippageViolated = true;
            if (recv < stockOut) ghost_exactOutputShort = true;
            ghost_swapsExecuted++;
        } catch {}
    }

    /// Cheap no-op action: keep both feeds fresh so the fuzzer can interleave
    /// observation between trades without wasting the depth budget on reverts.
    function poke() external {
        callCount++;
        _refresh(_leg(0));
        _refresh(_leg(1));
    }
}

contract Invariant_DclexRouter is StdInvariant, Test {
    // Prices mirror the DclexRouter unit harness (AAPL $20, NVDA $30, USDC $1).
    uint256 internal constant AAPL_PRICE = 20 ether;
    uint256 internal constant NVDA_PRICE = 30 ether;
    uint256 internal constant USDC_PRICE = 1 ether;
    uint256 internal constant STOCK_LIQ = 100 ether;
    uint256 internal constant DUSD_LIQ = 2000e6;

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

    DclexRouterHandler internal handler;

    bytes[] internal EMPTY;

    receive() external payable {}

    function setUp() public {
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

        // ---- router + fee-free DCLEX pools (exactly the unit-harness setup) ----
        router = new DclexRouter(IERC20(address(dusd)));

        DeployDclexPool poolDeployer = new DeployDclexPool();
        aaplPool = poolDeployer.run(IStock(address(aaplStock)), helperConfig, 0, 0, 0);
        nvdaPool = poolDeployer.run(IStock(address(nvdaStock)), helperConfig, 0, 0, 0);

        router.addPool(address(aaplStock), DclexRouter.PoolType.DCLEX, address(aaplPool), 0);
        router.addPool(address(nvdaStock), DclexRouter.PoolType.DCLEX, address(nvdaPool), 0);

        // DIDs for the router + pools (router custodies dUSD transiently in
        // cross-pool legs; pools hold/transfer stock).
        vm.startPrank(ADMIN);
        did.mintAdmin(address(router), 0, bytes32(0));
        did.mintAdmin(address(aaplPool), 2, bytes32(0));
        did.mintAdmin(address(nvdaPool), 2, bytes32(0));
        vm.stopPrank();

        // ---- this contract seeds pool liquidity as the initial LP ----
        _fundAndApprovePools(address(this));
        aaplPool.initialize(STOCK_LIQ, DUSD_LIQ, EMPTY);
        nvdaPool.initialize(STOCK_LIQ, DUSD_LIQ, EMPTY);

        // ---- deploy + fund the fuzz actor ----
        handler = new DclexRouterHandler(
            router,
            IERC20(address(dusd)),
            oracle,
            address(aaplStock),
            address(nvdaStock),
            aaplPool,
            nvdaPool,
            aaplFeed,
            nvdaFeed,
            AAPL_PRICE,
            NVDA_PRICE
        );
        _fundActor(address(handler));

        // Target only the handler's action selectors for the campaign.
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.buyExactInput.selector;
        selectors[1] = handler.sellExactInput.selector;
        selectors[2] = handler.buyExactOutput.selector;
        selectors[3] = handler.sellExactOutput.selector;
        selectors[4] = handler.crossSwapExactInput.selector;
        selectors[5] = handler.crossSwapExactOutput.selector;
        selectors[6] = handler.poke.selector;
        targetSelector(
            StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors})
        );
        targetContract(address(handler));
    }

    // Give `who` a valid DID + stock + dUSD and approve BOTH pools (used for the
    // LP that seeds liquidity — it transfers straight into the pools).
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

    // Give `who` a valid DID + stock + dUSD and approve the ROUTER (the router
    // pulls the user's input via the pool callback -> allowance is user->router).
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

    // =========================================================================
    // INV-RTR-01 — the router never accumulates funds. It custodies stock/dUSD/
    // ETH only for the duration of a single entry-point call; at rest (which is
    // where invariants are evaluated) all its balances must be exactly zero.
    // =========================================================================
    function invariant_routerHoldsNoResidualFunds() public view {
        assertEq(aaplStock.balanceOf(address(router)), 0, "router holds AAPL");
        assertEq(nvdaStock.balanceOf(address(router)), 0, "router holds NVDA");
        assertEq(dusd.balanceOf(address(router)), 0, "router holds dUSD");
        assertEq(address(router).balance, 0, "router holds ETH");
    }

    // =========================================================================
    // INV-CB-01 — at idle both callback sentinels are address(0), so a direct
    // call to either swap callback reverts DclexRouter__UnexpectedCallback. This
    // is the anti-drain property: no one can invoke the callback out-of-band to
    // trigger a safeTransferFrom against a cached approval.
    // =========================================================================
    function invariant_callbackSentinelsIdleRevert() public {
        bytes memory dclexData = abi.encode(
            DclexRouter.DclexSwapCallbackData(address(0xdead), false, address(0), 0)
        );
        (bool okDclex, bytes memory retDclex) = address(router).call(
            abi.encodeWithSelector(
                router.dclexSwapCallback.selector,
                address(aaplStock),
                uint256(1 ether),
                dclexData
            )
        );
        assertFalse(okDclex, "idle dclexSwapCallback must revert");
        assertTrue(
            bytes4(retDclex) == DclexRouter.DclexRouter__UnexpectedCallback.selector,
            "dclex callback wrong revert reason"
        );

        (bool okV3, bytes memory retV3) = address(router).call(
            abi.encodeWithSelector(
                router.uniswapV3SwapCallback.selector,
                int256(1),
                int256(0),
                bytes("")
            )
        );
        assertFalse(okV3, "idle uniswapV3SwapCallback must revert");
        assertTrue(
            bytes4(retV3) == DclexRouter.DclexRouter__UnexpectedCallback.selector,
            "v3 callback wrong revert reason"
        );
    }

    // =========================================================================
    // INV-RTR-04 — slippage/exactness are enforced on-chain: no *successful*
    // swap ever delivered less output than minOutput, cost more than maxInput,
    // or short-filled an exact-output request. The handler flips a ghost flag on
    // any breach measured from real balance deltas; it must stay false.
    // =========================================================================
    function invariant_slippageRespected() public view {
        assertFalse(
            handler.ghost_slippageViolated(),
            "a successful swap violated its min-out / max-in bound"
        );
        assertFalse(
            handler.ghost_exactOutputShort(),
            "an exact-output swap delivered less than requested"
        );
    }

    // Visibility only.
    function afterInvariant() public view {
        console.log("handler callCount (last seq):", handler.callCount());
        console.log("swaps executed (last seq):", handler.ghost_swapsExecuted());
    }

    // =========================================================================
    // Non-vacuity proof: drive the handler's actions deterministically once and
    // confirm real router swaps execute, so the assertFalse-style invariants are
    // not passing simply because nothing ever swapped. Also re-asserts the two
    // safety invariants after concrete swaps.
    // =========================================================================
    function test_router_handlerNonVacuous() public {
        // buy AAPL with 200 dUSD (leg 0), no min-out constraint.
        handler.buyExactInput(0, 200e6, 0);
        // sell 2 AAPL back.
        handler.sellExactInput(0, 2 ether, 0);
        // buy exactly 1 NVDA (leg 1).
        handler.buyExactOutput(1, 1 ether);
        // sell for exactly 20 dUSD of AAPL.
        handler.sellExactOutput(0, 20e6);
        // cross AAPL -> NVDA exact input.
        handler.crossSwapExactInput(0, 1 ether, 0);
        // cross NVDA -> AAPL exact output.
        handler.crossSwapExactOutput(1, 1 ether);

        assertGt(handler.ghost_swapsExecuted(), 0, "no router swaps executed");
        assertFalse(handler.ghost_slippageViolated(), "slippage violated in meta-test");
        assertFalse(handler.ghost_exactOutputShort(), "exact-output short in meta-test");

        // Router is drained of every asset after the concrete swap sequence.
        assertEq(aaplStock.balanceOf(address(router)), 0);
        assertEq(nvdaStock.balanceOf(address(router)), 0);
        assertEq(dusd.balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
    }
}
