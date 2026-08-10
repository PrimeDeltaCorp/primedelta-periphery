// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {DeployDclex} from "dclex-protocol/script/DeployDclex.s.sol";
import {
    HelperConfig as DclexProtocolHelperConfig
} from "dclex-protocol/script/HelperConfig.s.sol";
import {DeployDclexPool} from "dclex-protocol/script/DeployDclexPool.s.sol";
import {MockPriceOracle} from "dclex-protocol/test/MockPriceOracle.sol";
import {TestBalance} from "dclex-protocol/test/TestBalance.sol";
import {
    DigitalIdentity
} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {Stock} from "dclex-blockchain/contracts/dclex/Stock.sol";
import {USDCMock} from "dclex-blockchain/contracts/mocks/USDCMock.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal contract that has code but reverts on stockToken() — used to
///      prove addPool's try/catch treats a reverting pool as a mismatch.
contract RevertingStockPool {
    error Boom();

    function stockToken() external pure returns (address) {
        revert Boom();
    }

    function stablecoinToken() external pure returns (address) {
        return address(0);
    }
}

/// @title Regression suite proving prior-audit fixes on DclexRouter hold.
/// @notice Covers:
///   F-008          addPool rejects mismatched / non-contract / reverting DCLEX
///                  pools; a correctly-matched pool registers.
///   F-008 / R2-C-14 dclexSwapCallback (and uniswapV3SwapCallback) fired at idle
///                  revert DclexRouter__UnexpectedCallback — the callback can't
///                  be abused to drain a victim's token approval.
///   F-026          Factory.changeSymbol does NOT brick a DclexPool: the pool
///                  prices by keccak256(stockToken ADDRESS) which is immutable,
///                  so a swap still works after a stock is renamed.
///
/// Reconstructs the periphery DCLEX-only world (DeployDclex + DeployDclexPool +
/// DclexRouter), mirroring test/DclexRouter.t.sol's setUp. No V3 leg needed.
contract Regression_AuditFixes is Test, TestBalance {
    bytes[] internal PRICE_DATA = new bytes[](0);

    bytes32 internal AAPL_PRICE_FEED_ID;
    bytes32 internal NVDA_PRICE_FEED_ID;

    address private ADMIN = makeAddr("admin");
    address private immutable MASTER_ADMIN = makeAddr("master_admin");
    address private immutable USER_1 = makeAddr("user_1");
    address private immutable ATTACKER = makeAddr("attacker");

    DigitalIdentity internal digitalIdentity;
    Factory private stocksFactory;
    MockPriceOracle private priceOracle;
    USDCMock internal dusdToken;

    Stock internal aaplStock;
    Stock internal nvdaStock;
    Stock internal amznStock; // deployed + pooled but NOT registered on router

    DclexRouter private dclexRouter;
    DclexPool private aaplPool;
    DclexPool internal nvdaPool;
    DclexPool internal amznPool;

    receive() external payable {}

    function setUp() public {
        // ----- Dclex core -----
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory contracts = deployer.run(
            ADMIN,
            MASTER_ADMIN
        );
        digitalIdentity = contracts.digitalIdentity;
        stocksFactory = contracts.stocksFactory;

        vm.startPrank(ADMIN);
        string[] memory names = new string[](3);
        string[] memory symbols = new string[](3);
        names[0] = "Apple";
        names[1] = "NVIDIA";
        names[2] = "Amazon";
        symbols[0] = "AAPL";
        symbols[1] = "NVDA";
        symbols[2] = "AMZN";
        stocksFactory.createStocks(names, symbols);
        vm.stopPrank();

        aaplStock = Stock(stocksFactory.stocks("AAPL"));
        nvdaStock = Stock(stocksFactory.stocks("NVDA"));
        amznStock = Stock(stocksFactory.stocks("AMZN"));

        // ----- dUSD + oracle (shared, cached) -----
        DclexProtocolHelperConfig helper = new DclexProtocolHelperConfig();
        DclexProtocolHelperConfig.NetworkConfig memory cfg = helper.getConfig();
        dusdToken = USDCMock(address(cfg.dusdToken));
        priceOracle = MockPriceOracle(address(cfg.oracle));

        // ----- Router -----
        dclexRouter = new DclexRouter(IERC20(address(dusdToken)));

        // Pool prices by keccak256(stockToken ADDRESS) — feed IDs derived the
        // same way (independent of symbol). This is the crux of F-026.
        AAPL_PRICE_FEED_ID = keccak256(abi.encodePacked(address(aaplStock)));
        NVDA_PRICE_FEED_ID = keccak256(abi.encodePacked(address(nvdaStock)));
        priceOracle.setPrice(AAPL_PRICE_FEED_ID, 20 ether);
        priceOracle.setPrice(NVDA_PRICE_FEED_ID, 30 ether);

        // ----- Pools -----
        DeployDclexPool poolDeployer = new DeployDclexPool();
        aaplPool = poolDeployer.run(IStock(address(aaplStock)), helper, 0, 0, 0,
            address(this));
        nvdaPool = poolDeployer.run(IStock(address(nvdaStock)), helper, 0, 0, 0,
            address(this));
        amznPool = poolDeployer.run(IStock(address(amznStock)), helper, 0, 0, 0,
            address(this));

        // Register AAPL + NVDA. AMZN stays unregistered on purpose.
        dclexRouter.addPool(
            address(aaplStock),
            DclexRouter.PoolType.DCLEX,
            address(aaplPool),
            0
        );
        dclexRouter.addPool(
            address(nvdaStock),
            DclexRouter.PoolType.DCLEX,
            address(nvdaPool),
            0
        );

        // ----- Accounts + DID -----
        _setupAccount(address(this));
        _setupAccount(USER_1);
        vm.startPrank(ADMIN);
        digitalIdentity.mintAdmin(address(dclexRouter), 0, bytes32(0));
        digitalIdentity.mintAdmin(address(aaplPool), 2, bytes32(0));
        digitalIdentity.mintAdmin(address(nvdaPool), 2, bytes32(0));
        digitalIdentity.mintAdmin(address(amznPool), 2, bytes32(0));
        vm.stopPrank();

        // ----- Seed liquidity -----
        vm.startPrank(address(this));
        aaplStock.approve(address(aaplPool), 100000 ether);
        nvdaStock.approve(address(nvdaPool), 100000 ether);
        dusdToken.approve(address(aaplPool), 100000e6);
        dusdToken.approve(address(nvdaPool), 100000e6);
        vm.stopPrank();
        aaplPool.initialize(100 ether, 2000e6, address(this), PRICE_DATA);
        nvdaPool.initialize(100 ether, 2000e6, address(this), PRICE_DATA);

        vm.deal(address(this), 1 ether);

        // Hand ownership to ADMIN — matches production + the periphery harness.
        dclexRouter.transferOwnership(ADMIN);
        vm.prank(ADMIN);
        dclexRouter.acceptOwnership();
    }

    function _setupAccount(address account) private {
        dusdToken.mint(account, 1000000e6);
        vm.startPrank(ADMIN);
        digitalIdentity.mintAdmin(account, 0, bytes32(0));
        stocksFactory.forceMintStocks("AAPL", account, 100000 ether);
        stocksFactory.forceMintStocks("NVDA", account, 10000 ether);
        vm.stopPrank();
        vm.startPrank(account);
        aaplStock.approve(address(dclexRouter), 100000 ether);
        nvdaStock.approve(address(dclexRouter), 100000 ether);
        dusdToken.approve(address(dclexRouter), 100000e6); // dUSD is 6-decimal
        vm.stopPrank();
    }

    // =====================================================================
    // F-008 — addPool validates the DCLEX pool it is being asked to register
    // =====================================================================

    /// A DCLEX pool whose stockToken() != token must be rejected. Registering
    /// nvdaPool (stockToken == NVDA) under the AMZN token is a token mismatch.
    function test_F008_AddPool_RevertsOnStockTokenMismatch() external {
        vm.prank(ADMIN);
        vm.expectRevert(DclexRouter.DclexRouter__PoolMismatch.selector);
        dclexRouter.addPool(
            address(amznStock),
            DclexRouter.PoolType.DCLEX,
            address(nvdaPool),
            0
        );
    }

    /// A DCLEX pool whose stablecoinToken() != router.stablecoin must be
    /// rejected even when the stock side matches. Build a pool for AMZN wired
    /// to a *different* 6-decimal stablecoin.
    function test_F008_AddPool_RevertsOnStablecoinMismatch() external {
        USDCMock otherStable = new USDCMock("Other USD", "oUSD");
        DclexPool mismatchedPool = new DclexPool(
            IStock(address(amznStock)),
            IERC20(address(otherStable)),
            priceOracle,
            0,
            0,
            0,
            ADMIN,
            ADMIN
        );
        // Sanity: stock side genuinely matches, so we isolate the stablecoin check.
        assertEq(address(mismatchedPool.stockToken()), address(amznStock));
        assertTrue(
            address(mismatchedPool.stablecoinToken()) != address(dusdToken)
        );

        vm.prank(ADMIN);
        vm.expectRevert(DclexRouter.DclexRouter__PoolMismatch.selector);
        dclexRouter.addPool(
            address(amznStock),
            DclexRouter.PoolType.DCLEX,
            address(mismatchedPool),
            0
        );
    }

    /// A non-contract "pool" (EOA, no code) must be rejected before any call.
    function test_F008_AddPool_RevertsOnNonContractPool() external {
        address eoaPool = makeAddr("eoa_pool");
        assertEq(eoaPool.code.length, 0);

        vm.prank(ADMIN);
        vm.expectRevert(DclexRouter.DclexRouter__PoolMismatch.selector);
        dclexRouter.addPool(
            address(amznStock),
            DclexRouter.PoolType.DCLEX,
            eoaPool,
            0
        );
    }

    /// A contract that reverts on stockToken() must be caught and rejected.
    function test_F008_AddPool_RevertsWhenPoolStockTokenReverts() external {
        RevertingStockPool badPool = new RevertingStockPool();

        vm.prank(ADMIN);
        vm.expectRevert(DclexRouter.DclexRouter__PoolMismatch.selector);
        dclexRouter.addPool(
            address(amznStock),
            DclexRouter.PoolType.DCLEX,
            address(badPool),
            0
        );
    }

    /// A correctly-matched pool (stock + stablecoin both line up) registers.
    function test_F008_AddPool_RegistersMatchingPool() external {
        assertEq(
            uint256(dclexRouter.getPoolType(address(amznStock))),
            uint256(DclexRouter.PoolType.NONE)
        );

        vm.prank(ADMIN);
        dclexRouter.addPool(
            address(amznStock),
            DclexRouter.PoolType.DCLEX,
            address(amznPool),
            0
        );

        assertEq(
            uint256(dclexRouter.getPoolType(address(amznStock))),
            uint256(DclexRouter.PoolType.DCLEX)
        );
        assertEq(
            address(dclexRouter.stockToDclexPool(address(amznStock))),
            address(amznPool)
        );
    }

    // =====================================================================
    // F-008 / R2-C-14 — callbacks fired at idle cannot drain approvals
    // =====================================================================

    /// With no swap in flight the DCLEX callback sentinel is address(0), so a
    /// crafted call — even one that tries to pull a victim's approved tokens —
    /// reverts DclexRouter__UnexpectedCallback and touches nothing.
    function test_F008_DclexSwapCallback_RevertsAtIdleAndCannotDrain()
        external
    {
        // USER_1 approved the router 100000 AAPL in setUp. A malicious callback
        // payload names USER_1 as payer so an unguarded callback would
        // safeTransferFrom(USER_1 -> attacker).
        bytes memory maliciousData = abi.encode(
            USER_1, // payer
            false, // payWithSwapExactOutput
            address(0), // inputToken
            uint256(0) // maxInputAmount
        );

        uint256 victimBefore = aaplStock.balanceOf(USER_1);

        vm.prank(ATTACKER);
        vm.expectRevert(DclexRouter.DclexRouter__UnexpectedCallback.selector);
        dclexRouter.dclexSwapCallback(
            address(aaplStock),
            1000 ether,
            maliciousData
        );

        // Approval untouched: victim balance unchanged.
        assertEq(aaplStock.balanceOf(USER_1), victimBefore);
    }

    /// Same guarantee for the Uniswap V3 callback: idle-time invocation reverts.
    function test_F008_UniswapV3SwapCallback_RevertsAtIdle() external {
        bytes memory anyData = abi.encode(uint256(0));

        vm.prank(ATTACKER);
        vm.expectRevert(DclexRouter.DclexRouter__UnexpectedCallback.selector);
        dclexRouter.uniswapV3SwapCallback(int256(1000 ether), int256(0), anyData);
    }

    // =====================================================================
    // F-026 — Factory.changeSymbol does NOT brick a DclexPool
    // =====================================================================

    /// The pool derives its price feed from keccak256(stockToken ADDRESS),
    /// which is immutable and independent of the (mutable) symbol. Renaming
    /// AAPL -> AAPLX must leave pricing/swaps intact. If the pool keyed pricing
    /// off the symbol, the post-rename swap would revert with the oracle's
    /// PriceFeedNotFound (no price set under keccak256("AAPLX")).
    function test_F026_ChangeSymbol_DoesNotBrickPool() external {
        // Baseline: a buy works before the rename.
        recordBalance(address(aaplStock), USER_1);
        vm.prank(USER_1);
        dclexRouter.buyExactInput(
            address(aaplStock),
            100e6,
            0,
            block.timestamp + 1,
            PRICE_DATA
        );
        int256 outBefore = getBalanceChange();
        assertGt(outBefore, 0);

        // Rename the stock. Address is unchanged; only the symbol string moves.
        address stockAddrBefore = address(aaplStock);
        vm.prank(ADMIN);
        stocksFactory.changeSymbol("AAPL", "AAPLX");

        assertEq(aaplStock.symbol(), "AAPLX");
        assertEq(address(aaplStock), stockAddrBefore);
        // Factory symbol registry moved; the token ADDRESS is unchanged, which
        // is all the router (keyed by address) and pool (feedId by address) use.
        assertEq(stocksFactory.stocks("AAPLX"), stockAddrBefore);
        assertEq(stocksFactory.stocks("AAPL"), address(0));

        // The router registration is keyed by address — still intact.
        assertEq(
            uint256(dclexRouter.getPoolType(address(aaplStock))),
            uint256(DclexRouter.PoolType.DCLEX)
        );

        // Post-rename swap must still price + settle. This is the core property:
        // the swap succeeding proves the pool used the ADDRESS-derived feedId,
        // not the (now-changed) symbol.
        recordBalance(address(aaplStock), USER_1);
        vm.prank(USER_1);
        dclexRouter.buyExactInput(
            address(aaplStock),
            100e6,
            0,
            block.timestamp + 1,
            PRICE_DATA
        );
        int256 outAfter = getBalanceChange();
        assertGt(outAfter, 0);

        // Same price in, same (fee-free) pool math out — pricing unaffected by rename.
        assertEq(outAfter, outBefore);
    }

    /// A DCLEX pool reading from a different FIOracle than the already
    /// registered pools must be rejected. A cross-pool DCLEX swap carries one
    /// priceUpdateData payload and can refresh only one oracle, so a split
    /// registry makes that route revert with StalePrice.
    function test_L03_AddPool_RevertsOnOracleMismatch() external {
        MockPriceOracle otherOracle = new MockPriceOracle();
        DclexPool mismatchedPool = new DclexPool(
            IStock(address(amznStock)),
            IERC20(address(dusdToken)),
            otherOracle,
            0,
            0,
            0,
            ADMIN,
            ADMIN
        );
        assertEq(address(mismatchedPool.stockToken()), address(amznStock));
        assertEq(address(mismatchedPool.stablecoinToken()), address(dusdToken));
        assertTrue(address(mismatchedPool.oracle()) != dclexRouter.dclexOracle());

        vm.prank(ADMIN);
        vm.expectRevert(DclexRouter.DclexRouter__OracleMismatch.selector);
        dclexRouter.addPool(
            address(amznStock),
            DclexRouter.PoolType.DCLEX,
            address(mismatchedPool),
            0
        );
    }

    function test_L03_AddPool_PinsOracleAndAcceptsMatchingPool() external {
        assertEq(
            dclexRouter.dclexOracle(),
            address(priceOracle),
            "oracle must be pinned by the first DCLEX registration"
        );

        vm.prank(ADMIN);
        dclexRouter.addPool(
            address(amznStock),
            DclexRouter.PoolType.DCLEX,
            address(amznPool),
            0
        );

        assertEq(
            uint256(dclexRouter.getPoolType(address(amznStock))),
            uint256(DclexRouter.PoolType.DCLEX)
        );
        assertEq(dclexRouter.dclexOracle(), address(priceOracle));
    }

    function test_L03_SetDclexOracle_OnlyOwnerAndValidated() external {
        MockPriceOracle otherOracle = new MockPriceOracle();

        vm.prank(USER_1);
        vm.expectRevert();
        dclexRouter.setDclexOracle(address(otherOracle));

        vm.prank(ADMIN);
        vm.expectRevert(DclexRouter.DclexRouter__ZeroAddress.selector);
        dclexRouter.setDclexOracle(address(0));

        vm.prank(ADMIN);
        vm.expectRevert(DclexRouter.DclexRouter__NotAContract.selector);
        dclexRouter.setDclexOracle(USER_1);
    }

    /// Repointing the pin while DCLEX pools are still registered would recreate
    /// the split-oracle state the pin exists to prevent — a pool's oracle is
    /// immutable and cannot be re-validated after the fact.
    function test_L03_SetDclexOracle_RejectedWhileDclexPoolsRegistered() external {
        MockPriceOracle otherOracle = new MockPriceOracle();
        assertEq(dclexRouter.dclexPoolCount(), 2);

        vm.prank(ADMIN);
        vm.expectRevert(DclexRouter.DclexRouter__PoolsStillRegistered.selector);
        dclexRouter.setDclexOracle(address(otherOracle));

        vm.startPrank(ADMIN);
        dclexRouter.removePool(address(aaplStock), DclexRouter.PoolType.DCLEX);
        dclexRouter.removePool(address(nvdaStock), DclexRouter.PoolType.DCLEX);
        assertEq(dclexRouter.dclexPoolCount(), 0);
        dclexRouter.setDclexOracle(address(otherOracle));
        vm.stopPrank();

        assertEq(dclexRouter.dclexOracle(), address(otherOracle));
    }

    function test_L03_DclexPoolCountTracksReplacement() external {
        assertEq(dclexRouter.dclexPoolCount(), 2);

        vm.prank(ADMIN);
        dclexRouter.addPool(
            address(aaplStock),
            DclexRouter.PoolType.DCLEX,
            address(aaplPool),
            0
        );
        assertEq(
            dclexRouter.dclexPoolCount(),
            2,
            "re-registering the same token must not double count"
        );

        vm.prank(ADMIN);
        dclexRouter.removePool(address(aaplStock), DclexRouter.PoolType.DCLEX);
        assertEq(dclexRouter.dclexPoolCount(), 1);
    }

    function test_L01_RenounceOwnershipDisabled() external {
        vm.prank(ADMIN);
        vm.expectRevert(DclexRouter.DclexRouter__RenounceDisabled.selector);
        dclexRouter.renounceOwnership();

        assertEq(dclexRouter.owner(), ADMIN, "owner must survive a renounce attempt");
    }

    function test_L01_TransferOwnershipRejectsZeroAddress() external {
        vm.prank(ADMIN);
        vm.expectRevert(DclexRouter.DclexRouter__ZeroAddress.selector);
        dclexRouter.transferOwnership(address(0));

        assertEq(dclexRouter.owner(), ADMIN);
    }

    function test_L01_OwnershipTransferRequiresAcceptance() external {
        address newOwner = makeAddr("new_router_owner");

        vm.prank(ADMIN);
        dclexRouter.transferOwnership(newOwner);
        assertEq(dclexRouter.owner(), ADMIN, "owner must not change before acceptance");
        assertEq(dclexRouter.pendingOwner(), newOwner);

        vm.prank(USER_1);
        vm.expectRevert();
        dclexRouter.acceptOwnership();

        vm.prank(newOwner);
        dclexRouter.acceptOwnership();
        assertEq(dclexRouter.owner(), newOwner);
        assertEq(dclexRouter.pendingOwner(), address(0));
    }

    function test_R05_RegistryHasNoDuplicatesAndRemovesCleanly() external {
        address[] memory before = dclexRouter.allStockTokens();
        assertEq(before.length, 2, "AAPL + NVDA registered in setUp");

        vm.prank(ADMIN);
        dclexRouter.addPool(
            address(aaplStock),
            DclexRouter.PoolType.DCLEX,
            address(aaplPool),
            0
        );
        assertEq(
            dclexRouter.allStockTokens().length,
            2,
            "re-registering must not duplicate the entry"
        );

        vm.prank(ADMIN);
        dclexRouter.removePool(address(aaplStock), DclexRouter.PoolType.DCLEX);
        address[] memory after_ = dclexRouter.allStockTokens();
        assertEq(after_.length, 1);
        assertEq(after_[0], address(nvdaStock), "surviving entry must be NVDA");

        vm.prank(ADMIN);
        dclexRouter.removePool(address(nvdaStock), DclexRouter.PoolType.DCLEX);
        assertEq(dclexRouter.allStockTokens().length, 0);
    }

    function test_R07_CrossPoolSwapRejectsSameToken() external {
        vm.startPrank(USER_1);

        vm.expectRevert(DclexRouter.DclexRouter__SameToken.selector);
        dclexRouter.swapExactInput(
            address(aaplStock),
            address(aaplStock),
            1 ether,
            0,
            block.timestamp + 1,
            PRICE_DATA
        );

        vm.expectRevert(DclexRouter.DclexRouter__SameToken.selector);
        dclexRouter.swapExactOutput(
            address(aaplStock),
            address(aaplStock),
            1 ether,
            type(uint256).max,
            block.timestamp + 1,
            PRICE_DATA
        );

        vm.stopPrank();
    }
}
