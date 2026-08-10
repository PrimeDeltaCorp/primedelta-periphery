// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {IDID} from "dclex-blockchain/contracts/interfaces/IDID.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {IPriceOracle} from "dclex-protocol/src/IPriceOracle.sol";
import {FIOracle} from "dclex-protocol/src/FIOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {DclexPositionManager} from "src/DclexPositionManager.sol";
import {FIOraclePoolBatchInitializer} from "src/FIOraclePoolBatchInitializer.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PoolAddress} from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";
import {UniswapV3Pool} from "@uniswap/v3-core/contracts/UniswapV3Pool.sol";

/// @notice Redeploy DclexRouter + DclexPositionManager + FIOracle + 44 DclexPools
///         after the dclex-protocol#10 + dclex-periphery#18 PRs landed.
///         Reuses live Factory, DID, dUSD, V3 infra (Factory/SwapRouter/Quoter/WDEL/Descriptor).
///         Re-mints stocks + dUSD into each new pool with two-sided seed liquidity.
///
/// Env required:
///   DEPLOYER_PRIVATE_KEY, ADMIN_PRIVATE_KEY, MASTER_ADMIN_PRIVATE_KEY
///   DCLEX_FACTORY, DCLEX_DID, DCLEX_DUSD, DCLEX_ADMIN, DCLEX_BACKEND_SIGNER
///   DCLEX_FIORACLE_SIGNER (optional — defaults to DCLEX_BACKEND_SIGNER)
///   V3_FACTORY, V3_WDEL, V3_DESCRIPTOR
///   AMMT1_STOCK, AMMT1_V3_POOL, AMMT2_STOCK, AMMT2_V3_POOL, WDEL_V3_POOL
contract RedeployRouterPoolsAndPM is Script {
    uint256 constant INITIAL_UPDATE_FEE  = 0.001 ether;
    int64   constant MOCK_PRICE          = 10_000_000_000;
    int32   constant EXPO                = -8;
    uint256 constant STOCK_AMOUNT        = 10e18;
    uint256 constant DUSD_AMOUNT         = 1_000e6;
    uint24  constant V3_FEE_TIER         = 3000;
    uint256 constant DEFAULT_FEE_CURVE_A = 0.0005 ether;
    uint256 constant DEFAULT_FEE_CURVE_B = 0.0005 ether;
    // Protocol-fee cut baked at deploy (dclex-infrastructure#256). Matches
    // BatchPoolDeployer.DEFAULT_PROTOCOL_FEE_RATE — keep in sync.
    uint256 constant DEFAULT_PROTOCOL_FEE_RATE = 0.15 ether;

    struct StockInfo {
        string symbol;
    }

    struct EnvCfg {
        address factory;
        address did;
        address dusd;
        address admin;
        address backendSigner;   // Factory/DID/Vault admin — signs vouchers
        address fiOracleSigner;  // FIOracle trustedSigner — signs prices ONLY
        address v3Factory;
        address wdel;
        address descriptor;
        address ammt1Stock;
        address ammt1V3Pool;
        address ammt2Stock;
        address ammt2V3Pool;
        address wdelV3Pool;
    }

    struct Phase1Output {
        FIOracle fiOracle;
        DclexRouter router;
        DclexPositionManager npm;
        FIOraclePoolBatchInitializer batchInit;
        address[] pools;
    }

    function getAllStocks() internal pure returns (StockInfo[] memory stocks) {
        stocks = new StockInfo[](44);
        stocks[0]  = StockInfo("AMZN");
        stocks[1]  = StockInfo("V");
        stocks[2]  = StockInfo("JPM");
        stocks[3]  = StockInfo("GE");
        stocks[4]  = StockInfo("AI");
        stocks[5]  = StockInfo("CPNG");
        stocks[6]  = StockInfo("DOW");
        stocks[7]  = StockInfo("CAT");
        stocks[8]  = StockInfo("MRK");
        stocks[9]  = StockInfo("AMGN");
        stocks[10] = StockInfo("KO");
        stocks[11] = StockInfo("MSTR");
        stocks[12] = StockInfo("GS");
        stocks[13] = StockInfo("DIS");
        stocks[14] = StockInfo("WMT");
        stocks[15] = StockInfo("NVDA");
        stocks[16] = StockInfo("IBM");
        stocks[17] = StockInfo("MCD");
        stocks[18] = StockInfo("BA");
        stocks[19] = StockInfo("AXP");
        stocks[20] = StockInfo("TRV");
        stocks[21] = StockInfo("CVX");
        stocks[22] = StockInfo("JNJ");
        stocks[23] = StockInfo("AMC");
        stocks[24] = StockInfo("CSCO");
        stocks[25] = StockInfo("HON");
        stocks[26] = StockInfo("BLK");
        stocks[27] = StockInfo("NKE");
        stocks[28] = StockInfo("INTC");
        stocks[29] = StockInfo("MMM");
        stocks[30] = StockInfo("VZ");
        stocks[31] = StockInfo("NFLX");
        stocks[32] = StockInfo("WBA");
        stocks[33] = StockInfo("UNH");
        stocks[34] = StockInfo("TSLA");
        stocks[35] = StockInfo("COIN");
        stocks[36] = StockInfo("AAPL");
        stocks[37] = StockInfo("GOOG");
        stocks[38] = StockInfo("MSFT");
        stocks[39] = StockInfo("META");
        stocks[40] = StockInfo("CRM");
        stocks[41] = StockInfo("GME");
        stocks[42] = StockInfo("PG");
        stocks[43] = StockInfo("HD");
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

    function _loadEnv() internal view returns (EnvCfg memory cfg) {
        cfg.factory       = vm.envAddress("DCLEX_FACTORY");
        cfg.did           = vm.envAddress("DCLEX_DID");
        cfg.dusd          = vm.envAddress("DCLEX_DUSD");
        cfg.admin         = vm.envAddress("DCLEX_ADMIN");
        cfg.backendSigner = vm.envAddress("DCLEX_BACKEND_SIGNER");
        require(cfg.backendSigner != address(0), "DCLEX_BACKEND_SIGNER is zero");
        // Optional dedicated FIOracle price signer; defaults to the backend
        // signer when unset (signers collapsed). A non-zero override is
        // enforced by FIOracle.setTrustedSigner itself.
        cfg.fiOracleSigner = vm.envOr("DCLEX_FIORACLE_SIGNER", cfg.backendSigner);
        cfg.v3Factory     = vm.envAddress("V3_FACTORY");
        cfg.wdel          = vm.envAddress("V3_WDEL");
        cfg.descriptor    = vm.envAddress("V3_DESCRIPTOR");
        require(cfg.descriptor != address(0), "V3_DESCRIPTOR must be set");
        cfg.ammt1Stock    = vm.envAddress("AMMT1_STOCK");
        cfg.ammt1V3Pool   = vm.envAddress("AMMT1_V3_POOL");
        cfg.ammt2Stock    = vm.envAddress("AMMT2_STOCK");
        cfg.ammt2V3Pool   = vm.envAddress("AMMT2_V3_POOL");
        cfg.wdelV3Pool    = vm.envAddress("WDEL_V3_POOL");
    }

    function run() external {
        require(
            PoolAddress.POOL_INIT_CODE_HASH == keccak256(type(UniswapV3Pool).creationCode),
            "POOL_INIT_CODE_HASH stale"
        );

        EnvCfg memory cfg = _loadEnv();
        uint256 deployerKey    = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 adminKey       = vm.envUint("ADMIN_PRIVATE_KEY");
        uint256 masterAdminKey = vm.envUint("MASTER_ADMIN_PRIVATE_KEY");
        require(vm.addr(adminKey) == cfg.admin, "ADMIN_PRIVATE_KEY != DCLEX_ADMIN");

        StockInfo[] memory stocks = getAllStocks();
        Phase1Output memory ph = _phase1Deploy(cfg, deployerKey, stocks);
        _phase2Configure(ph, cfg, stocks, adminKey, masterAdminKey);
        if (vm.envOr("SKIP_INIT", false)) {
            // Slow/flaky RPCs stretch the gap between price signing and tx
            // simulation past the 60s staleness window (StalePrice in sim even
            // though live txs would be fine). Skip phases 3-4 here and run
            // blockchain/scripts/initialize-dclex-pools.sh instead — it signs
            // per pool just-in-time via cast and does the same init + handoff.
            console.log("SKIP_INIT=true: phases 3-4 skipped; run initialize-dclex-pools.sh");
        } else {
            _phase3Initialize(ph, cfg, stocks, adminKey, masterAdminKey);
            _phase4HandoffOracle(ph, cfg, deployerKey);
        }
        _printSummary(ph, stocks);
    }

    // ============ Phase 1 (deployer): new FIOracle, router, PM, 44 pools, batch initializer ============
    function _phase1Deploy(
        EnvCfg memory cfg,
        uint256 deployerKey,
        StockInfo[] memory stocks
    ) internal returns (Phase1Output memory ph) {
        address deployer = vm.addr(deployerKey);
        ph.pools = new address[](stocks.length);

        vm.startBroadcast(deployerKey);
        ph.fiOracle = new FIOracle(deployer, deployer);
        ph.fiOracle.setPricePerUpdate(INITIAL_UPDATE_FEE);
        ph.fiOracle.setTrustedSigner(cfg.admin);
        console.log("FIOracle:", address(ph.fiOracle));

        ph.router = new DclexRouter(IERC20(cfg.dusd));
        console.log("DclexRouter:", address(ph.router));

        ph.npm = new DclexPositionManager(cfg.v3Factory, cfg.wdel, cfg.descriptor, IDID(cfg.did));
        console.log("DclexPositionManager:", address(ph.npm));

        ph.batchInit = new FIOraclePoolBatchInitializer(cfg.admin);
        console.log("BatchInitializer:", address(ph.batchInit));

        _deployPools(ph, cfg, stocks);

        // Hand router ownership to admin. Ownable2Step: this only sets
        // pendingOwner; _phase2Configure claims it as its first admin call.
        ph.router.transferOwnership(cfg.admin);
        console.log("Router ownership pending for admin:", cfg.admin);
        vm.stopBroadcast();
    }

    function _deployPools(
        Phase1Output memory ph,
        EnvCfg memory cfg,
        StockInfo[] memory stocks
    ) internal {
        for (uint256 i = 0; i < stocks.length; i++) {
            address stockAddr = Factory(cfg.factory).stocks(stocks[i].symbol);
            require(stockAddr != address(0), string.concat("stock not found: ", stocks[i].symbol));
            DclexPool pool = new DclexPool(
                IStock(stockAddr),
                IERC20(cfg.dusd),
                IPriceOracle(address(ph.fiOracle)),
                DEFAULT_FEE_CURVE_A,
                DEFAULT_FEE_CURVE_B,
                DEFAULT_PROTOCOL_FEE_RATE,
                cfg.admin
            );
            ph.pools[i] = address(pool);
        }
    }

    // ============ Phase 2 (admin): DIDs, pool wiring, V3 pool registry, fund batch initializer ============
    function _phase2Configure(
        Phase1Output memory ph,
        EnvCfg memory cfg,
        StockInfo[] memory stocks,
        uint256 adminKey,
        uint256 masterAdminKey
    ) internal {
        DigitalIdentity did = DigitalIdentity(cfg.did);
        Factory factory = Factory(cfg.factory);

        vm.startBroadcast(adminKey);

        // Ownable2Step: phase 1 only set pendingOwner. Claim it here or every
        // onlyOwner call below reverts OwnableUnauthorizedAccount.
        ph.router.acceptOwnership();

        did.mintAdmin(address(ph.router), 2, bytes32(0));
        did.mintAdmin(address(ph.npm), 2, bytes32(0));
        did.mintAdmin(address(ph.batchInit), 2, bytes32(0));

        for (uint256 i = 0; i < stocks.length; i++) {
            did.mintAdmin(ph.pools[i], 2, bytes32(0));
        }
        for (uint256 i = 0; i < stocks.length; i++) {
            address stockAddr = factory.stocks(stocks[i].symbol);
            ph.router.addPool(stockAddr, DclexRouter.PoolType.DCLEX, ph.pools[i], 0);
        }

        // V3 pools (AMMT1, AMMT2, WDEL). AMMT tokens are added manually
        // post-deploy on testnet/prod — skip registration when env vars
        // come in as address(0).
        if (cfg.ammt1Stock != address(0) && cfg.ammt1V3Pool != address(0)) {
            ph.router.addPool(cfg.ammt1Stock, DclexRouter.PoolType.V3, cfg.ammt1V3Pool, V3_FEE_TIER);
        }
        if (cfg.ammt2Stock != address(0) && cfg.ammt2V3Pool != address(0)) {
            ph.router.addPool(cfg.ammt2Stock, DclexRouter.PoolType.V3, cfg.ammt2V3Pool, V3_FEE_TIER);
        }
        ph.router.addPool(cfg.wdel, DclexRouter.PoolType.V3, cfg.wdelV3Pool, V3_FEE_TIER);

        // Fund the batch initializer ONLY when we will actually seed pools.
        // Under SKIP_INIT (testnet/mainnet — no synthetic supply) phase 3's
        // initializeAll never runs, so this mint would strand unbacked dUSD in
        // the helper and inflate dUSD.totalSupply. Guard it so SKIP_INIT deploys
        // leave dUSD.totalSupply == 0 (pools created uninitialized, seeded later
        // by real liquidity).
        if (!vm.envOr("SKIP_INIT", false)) {
            factory.forceMintStablecoin("dUSD", address(ph.batchInit), DUSD_AMOUNT * stocks.length);
        }
        vm.stopBroadcast();

        // Master admin grants DEFAULT_ADMIN_ROLE on Factory to batch initializer.
        vm.startBroadcast(masterAdminKey);
        factory.grantRole(0x00, address(ph.batchInit));
        vm.stopBroadcast();
    }

    // ============ Phase 3 (admin): build signed price payloads, batch init pools ============
    function _phase3Initialize(
        Phase1Output memory ph,
        EnvCfg memory cfg,
        StockInfo[] memory stocks,
        uint256 adminKey,
        uint256 masterAdminKey
    ) internal {
        Factory factory = Factory(cfg.factory);

        // Pin block.timestamp once so every signed publishTime is <60s when the single batch tx mines.
        uint64 publishTime = uint64(block.timestamp);
        vm.warp(publishTime);

        bytes[] memory priceUpdateData = new bytes[](stocks.length);
        string[] memory stockSymbols   = new string[](stocks.length);
        for (uint256 i = 0; i < stocks.length; i++) {
            bytes32 feedId = keccak256(abi.encodePacked(factory.stocks(stocks[i].symbol)));
            priceUpdateData[i] = _signedPriceData(
                adminKey, address(ph.fiOracle), feedId, MOCK_PRICE, EXPO, publishTime
            );
            stockSymbols[i] = stocks[i].symbol;
        }

        vm.startBroadcast(adminKey);
        ph.batchInit.initializeAll{value: INITIAL_UPDATE_FEE * stocks.length}(
            FIOraclePoolBatchInitializer.InitParams({
                factory:         factory,
                dusdToken:       IERC20(cfg.dusd),
                pools:           ph.pools,
                stockSymbols:    stockSymbols,
                priceUpdateData: priceUpdateData,
                stockAmount:     STOCK_AMOUNT,
                dusdAmount:      DUSD_AMOUNT,
                feePerPool:      INITIAL_UPDATE_FEE
            })
        );
        vm.stopBroadcast();

        // Master admin revokes the temporary admin role.
        vm.startBroadcast(masterAdminKey);
        factory.revokeRole(0x00, address(ph.batchInit));
        vm.stopBroadcast();
    }

    // ============ Phase 4 (deployer): hand FIOracle to production roles ============
    function _phase4HandoffOracle(
        Phase1Output memory ph,
        EnvCfg memory cfg,
        uint256 deployerKey
    ) internal {
        address deployer = vm.addr(deployerKey);
        vm.startBroadcast(deployerKey);
        // Hand the price authority to the configured FIOracle signer
        // (DCLEX_FIORACLE_SIGNER, or the backend signer when unset).
        ph.fiOracle.setTrustedSigner(cfg.fiOracleSigner);
        ph.fiOracle.grantRole(0x00, cfg.admin);
        ph.fiOracle.setFeeRecipient(cfg.admin);
        ph.fiOracle.renounceRole(0x00, deployer);
        vm.stopBroadcast();
    }

    function _printSummary(Phase1Output memory ph, StockInfo[] memory stocks) internal view {
        console.log("");
        console.log("=== REDEPLOY COMPLETE ===");
        console.log("FIOracle:            ", address(ph.fiOracle));
        console.log("DclexRouter:         ", address(ph.router));
        console.log("DclexPositionManager:", address(ph.npm));
        console.log("");
        console.log("New pool addresses (44, in stock order):");
        for (uint256 i = 0; i < stocks.length; i++) {
            console.log(stocks[i].symbol, ph.pools[i]);
        }
    }
}
