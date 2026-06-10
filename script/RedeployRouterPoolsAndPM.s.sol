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
///   DEPLOYER_PRIVATE_KEY, ADMIN_PRIVATE_KEY
///   DCLEX_FACTORY, DCLEX_DID, DCLEX_DUSD, DCLEX_ADMIN, DCLEX_BACKEND_SIGNER
///   V3_FACTORY, V3_WDEL, V3_DESCRIPTOR
///   AMMT1_STOCK, AMMT1_V3_POOL, AMMT2_STOCK, AMMT2_V3_POOL, WDEL_V3_POOL
contract RedeployRouterPoolsAndPM is Script {
    uint256 constant INITIAL_UPDATE_FEE  = 0.001 ether;
    int64   constant MOCK_PRICE          = 10_000_000_000;
    int32   constant EXPO                = -8;
    uint256 constant STOCK_AMOUNT        = 10e18;
    uint256 constant DUSD_AMOUNT         = 1_000e6;
    uint24  constant V3_FEE_TIER         = 3000;
    uint256 constant DEFAULT_FEE_CURVE_A = 0.00025 ether;
    uint256 constant DEFAULT_FEE_CURVE_B = 0.009 ether;
    // Protocol-fee cut baked at deploy (dclex-infrastructure#256). Matches
    // BatchPoolDeployer.DEFAULT_PROTOCOL_FEE_RATE — keep in sync.
    uint256 constant DEFAULT_PROTOCOL_FEE_RATE = 0.15 ether;

    struct StockInfo {
        string  symbol;
        bytes32 priceFeedId;
    }

    struct EnvCfg {
        address factory;
        address did;
        address dusd;
        address admin;
        address backendSigner;
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
        stocks[0]  = StockInfo("AMZN", 0xb5d0e0fa58a1f8b81498ae670ce93c872d14434b72c364885d4fa1b257cbb07a);
        stocks[1]  = StockInfo("V",    0xc719eb7bab9b2bc060167f1d1680eb34a29c490919072513b545b9785b73ee90);
        stocks[2]  = StockInfo("JPM",  0x7f4f157e57bfcccd934c566df536f34933e74338fe241a5425ce561acdab164e);
        stocks[3]  = StockInfo("GE",   0xe1d3115c6e7ac649faca875b3102f1000ab5e06b03f6903e0d699f0f5315ba86);
        stocks[4]  = StockInfo("AI",   0xafb12c5ccf50495c7a7b04447410d7feb4b3218a663ecbd96aa82e676d3c4f1e);
        stocks[5]  = StockInfo("CPNG", 0x5557d206aa0dd037fc082f03bbd78653f01465d280ea930bc93251f0eb60c707);
        stocks[6]  = StockInfo("DOW",  0xf3b50961ff387a3d68217e2715637d0add6013e7ecb83c36ae8062f97c46929e);
        stocks[7]  = StockInfo("CAT",  0xad04597ba688c350a97265fcb60585d6a80ebd37e147b817c94f101a32e58b4c);
        stocks[8]  = StockInfo("MRK",  0xc81114e16ec3cbcdf20197ac974aed5a254b941773971260ce09e7caebd6af46);
        stocks[9]  = StockInfo("AMGN", 0x10946973bfcc936b423d52ee2c5a538d96427626fe6d1a7dae14b1c401d1e794);
        stocks[10] = StockInfo("KO",   0x9aa471dccea36b90703325225ac76189baf7e0cc286b8843de1de4f31f9caa7d);
        stocks[11] = StockInfo("MSTR", 0xe1e80251e5f5184f2195008382538e847fafc36f751896889dd3d1b1f6111f09);
        stocks[12] = StockInfo("GS",   0x9c68c0c6999765cf6e27adf75ed551b34403126d3b0d5b686a2addb147ed4554);
        stocks[13] = StockInfo("DIS",  0x703e36203020ae6761e6298975764e266fb869210db9b35dd4e4225fa68217d0);
        stocks[14] = StockInfo("WMT",  0x327ae981719058e6fb44e132fb4adbf1bd5978b43db0661bfdaefd9bea0c82dc);
        stocks[15] = StockInfo("NVDA", 0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593);
        stocks[16] = StockInfo("IBM",  0xcfd44471407f4da89d469242546bb56f5c626d5bef9bd8b9327783065b43c3ef);
        stocks[17] = StockInfo("MCD",  0xd3178156b7c0f6ce10d6da7d347952a672467b51708baaf1a57ffe1fb005824a);
        stocks[18] = StockInfo("BA",   0x8419416ba640c8bbbcf2d464561ed7dd860db1e38e51cec9baf1e34c4be839ae);
        stocks[19] = StockInfo("AXP",  0x9ff7b9a93df40f6d7edc8184173c50f4ae72152c6142f001e8202a26f951d710);
        stocks[20] = StockInfo("TRV",  0xd45392f678a1287b8412ed2aaa326def204a5c234df7cb5552d756c332283d81);
        stocks[21] = StockInfo("CVX",  0xf464e36fd4ef2f1c3dc30801a9ab470dcdaaa0af14dd3cf6ae17a7fca9e051c5);
        stocks[22] = StockInfo("JNJ",  0x12848738d5db3aef52f51d78d98fc8b8b8450ffb19fb3aeeb67d38f8c147ff63);
        stocks[23] = StockInfo("AMC",  0x5b1703d7eb9dc8662a61556a2ca2f9861747c3fc803e01ba5a8ce35cb50a13a1);
        stocks[24] = StockInfo("CSCO", 0x3f4b77dd904e849f70e1e812b7811de57202b49bc47c56391275c0f45f2ec481);
        stocks[25] = StockInfo("HON",  0x107918baaaafb79cd9df1c8369e44ac21136d95f3ca33f2373b78f24ba1e3e6a);
        stocks[26] = StockInfo("BLK",  0x68d038affb5895f357d7b3527a6d3cd6a54edd0fe754a1248fb3462e47828b08);
        stocks[27] = StockInfo("NKE",  0x67649450b4ca4bfff97cbaf96d2fd9e40f6db148cb65999140154415e4378e14);
        stocks[28] = StockInfo("INTC", 0xc1751e085ee292b8b3b9dd122a135614485a201c35dfc653553f0e28c1baf3ff);
        stocks[29] = StockInfo("MMM",  0xfd05a384ba19863cbdfc6575bed584f041ef50554bab3ab482eabe4ea58d9f81);
        stocks[30] = StockInfo("VZ",   0x6672325a220c0ee1166add709d5ba2e51c185888360c01edc76293257ef68b58);
        stocks[31] = StockInfo("NFLX", 0x8376cfd7ca8bcdf372ced05307b24dced1f15b1afafdeff715664598f15a3dd2);
        stocks[32] = StockInfo("WBA",  0xed5c2a2711e2a638573add9a8aded37028aea4ac69f1431a1ced9d9db61b2225);
        stocks[33] = StockInfo("UNH",  0x05380f8817eb1316c0b35ac19c3caa92c9aa9ea6be1555986c46dce97fed6afd);
        stocks[34] = StockInfo("TSLA", 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1);
        stocks[35] = StockInfo("COIN", 0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245);
        stocks[36] = StockInfo("AAPL", 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688);
        stocks[37] = StockInfo("GOOG", 0xe65ff435be42630439c96396653a342829e877e2aafaeaf1a10d0ee5fd2cf3f2);
        stocks[38] = StockInfo("MSFT", 0xd0ca23c1cc005e004ccf1db5bf76aeb6a49218f43dac3d4b275e92de12ded4d1);
        stocks[39] = StockInfo("META", 0x78a3e3b8e676a8f73c439f5d749737034b139bbbe899ba5775216fba596607fe);
        stocks[40] = StockInfo("CRM",  0xfeff234600320f4d6bb5a01d02570a9725c1e424977f2b823f7231e6857bdae8);
        stocks[41] = StockInfo("GME",  0x6f9cd89ef1b7fd39f667101a91ad578b6c6ace4579d5f7f285a4b06aa4504be6);
        stocks[42] = StockInfo("PG",   0xad2fda41998f4e7be99a2a7b27273bd16f183d9adfc014a4f5e5d3d6cd519bf4);
        stocks[43] = StockInfo("HD",   0xb3a83dbe70b62241b0f916212e097465a1b31085fa30da3342dd35468ca17ca5);
    }

    function _signedPriceData(
        uint256 signerKey,
        bytes32 feedId,
        int64 price,
        int32 expo,
        uint64 publishTime
    ) internal pure returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encodePacked(feedId, price, expo, publishTime));
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
        cfg.v3Factory     = vm.envAddress("V3_FACTORY");
        cfg.wdel          = vm.envAddress("V3_WDEL");
        cfg.descriptor    = vm.envAddress("V3_DESCRIPTOR");
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
        _phase3Initialize(ph, cfg, stocks, adminKey, masterAdminKey);
        _phase4HandoffOracle(ph, cfg, deployerKey);
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

        ph.batchInit = new FIOraclePoolBatchInitializer();
        console.log("BatchInitializer:", address(ph.batchInit));

        _deployPools(ph, cfg, stocks);

        // Hand router ownership to admin so admin can configure pools/V3 in phase 2.
        ph.router.transferOwnership(cfg.admin);
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
                stocks[i].priceFeedId,
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

        factory.forceMintStablecoin("dUSD", address(ph.batchInit), DUSD_AMOUNT * stocks.length);
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
            priceUpdateData[i] = _signedPriceData(
                adminKey, stocks[i].priceFeedId, MOCK_PRICE, EXPO, publishTime
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
        ph.fiOracle.setTrustedSigner(cfg.backendSigner);
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
