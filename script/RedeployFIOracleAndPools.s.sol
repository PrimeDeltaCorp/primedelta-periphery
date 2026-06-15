// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {IPriceOracle} from "dclex-protocol/src/IPriceOracle.sol";
import {FIOracle} from "dclex-protocol/src/FIOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {FIOraclePoolBatchInitializer} from "src/FIOraclePoolBatchInitializer.sol";
import {DclexStockList} from "./DclexStockList.sol";

/// @notice Redeploy FIOracle + canonical DclexPools on a target chain.
/// Address inputs come from env vars so the same script targets any
/// chain (primelta-dev, staging, etc.). Stock addresses resolved
/// dynamically via `Factory.stocks(symbol)`.
///
/// Seeding is NOT done here: the pools' MAX_PRICE_STALENESS is 60s, but a
/// full broadcast takes ~30 min on Besu, so a publishTime signed at the
/// start would be stale by the time initializeAll mines. This script only
/// deploys + wires + funds the batch initializer and writes the addresses
/// to `out/redeploy-fioracle-pools.json`; SeedDclexPoolsBatch.s.sol then
/// signs a fresh price and seeds all 44 pools in one quick tx.
///
/// Required env: DEPLOYER_PRIVATE_KEY, ADMIN_PRIVATE_KEY, MASTER_ADMIN_PRIVATE_KEY,
/// DCLEX_ROUTER, DCLEX_FACTORY, DCLEX_DID, DCLEX_ADMIN, DCLEX_BACKEND_SIGNER.
/// Optional env: DCLEX_DUSD_SYMBOL (defaults to "dUSD").
contract RedeployFIOracleAndPools is DclexStockList {
    address payable internal DCLEX_ROUTER;
    address internal FACTORY;
    address internal DID;
    address internal ADMIN;
    address internal BACKEND_SIGNER;
    string  internal DUSD_SYMBOL;

    uint256 constant INITIAL_UPDATE_FEE = 0.001 ether;
    uint256 constant DUSD_AMOUNT = 1_000e6;

    function _loadEnv() internal {
        DCLEX_ROUTER   = payable(vm.envAddress("DCLEX_ROUTER"));
        FACTORY        = vm.envAddress("DCLEX_FACTORY");
        DID            = vm.envAddress("DCLEX_DID");
        ADMIN          = vm.envAddress("DCLEX_ADMIN");
        BACKEND_SIGNER = vm.envAddress("DCLEX_BACKEND_SIGNER");
        DUSD_SYMBOL    = vm.envOr("DCLEX_DUSD_SYMBOL", string("dUSD"));
    }

    function run() external {
        _loadEnv();
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 adminKey    = vm.envUint("ADMIN_PRIVATE_KEY");
        uint256 masterKey   = vm.envUint("MASTER_ADMIN_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);

        Factory factory     = Factory(FACTORY);
        DigitalIdentity did = DigitalIdentity(DID);
        DclexRouter router  = DclexRouter(DCLEX_ROUTER);
        IERC20 dusdToken    = IERC20(factory.stablecoins(DUSD_SYMBOL));
        require(address(dusdToken) != address(0), "dUSD not registered on Factory");
        console.log("Resolved dUSD:", address(dusdToken));

        StockInfo[] memory stocks = getAllStocks();

        // Phase 1 (deployer): deploy FIOracle, set fee, set admin as
        // temporary trustedSigner so the script can sign price updates.
        vm.startBroadcast(deployerKey);
        FIOracle fiOracle = new FIOracle(deployer, deployer);
        fiOracle.setPricePerUpdate(INITIAL_UPDATE_FEE);
        fiOracle.setTrustedSigner(vm.addr(adminKey));
        vm.stopBroadcast();
        console.log("New FIOracle:", address(fiOracle));

        // Phase 2 (deployer): deploy 44 new DclexPools.
        address[] memory newPools = new address[](stocks.length);
        vm.startBroadcast(deployerKey);
        for (uint256 i = 0; i < stocks.length; i++) {
            address stockAddr = factory.stocks(stocks[i].symbol);
            require(stockAddr != address(0), string.concat("stock not found: ", stocks[i].symbol));
            DclexPool pool = new DclexPool(
                IStock(stockAddr),
                dusdToken,
                IPriceOracle(address(fiOracle)),
                stocks[i].priceFeedId,
                0.00025 ether,
                0.009 ether,
                0.15 ether, // protocol-fee cut baked at deploy (#256)
                ADMIN
            );
            newPools[i] = address(pool);
        }
        vm.stopBroadcast();

        // Phase 3a (admin): deploy batch initializer, mint DIDs for it and
        // each new pool, route stock→newPool, fund the initializer with dUSD.
        vm.startBroadcast(adminKey);
        FIOraclePoolBatchInitializer batchInit = new FIOraclePoolBatchInitializer();
        did.mintAdmin(address(batchInit), 2, bytes32(0));
        for (uint256 i = 0; i < stocks.length; i++) {
            did.mintAdmin(newPools[i], 2, bytes32(0));
        }
        for (uint256 i = 0; i < stocks.length; i++) {
            address stockAddr = factory.stocks(stocks[i].symbol);
            router.addPool(stockAddr, DclexRouter.PoolType.DCLEX, newPools[i], 0);
        }
        factory.forceMintStablecoin(DUSD_SYMBOL, address(batchInit), DUSD_AMOUNT * stocks.length);
        vm.stopBroadcast();

        // Phase 3b (master): grant DEFAULT_ADMIN_ROLE so the initializer can
        // forceMintStocks. getRoleAdmin(DEFAULT_ADMIN_ROLE)=MASTER_ADMIN_ROLE.
        vm.startBroadcast(masterKey);
        factory.grantRole(0x00, address(batchInit));
        vm.stopBroadcast();

        string memory json = "redeploy";
        vm.serializeAddress(json, "fiOracle", address(fiOracle));
        vm.serializeAddress(json, "batchInit", address(batchInit));
        string memory out = vm.serializeAddress(json, "pools", newPools);
        vm.writeJson(out, "out/redeploy-fioracle-pools.json");

        console.log("New FIOracle:", address(fiOracle));
        console.log("BatchInitializer:", address(batchInit));
        console.log("Deploy done. Run SeedDclexPoolsBatch.s.sol to seed + hand off FIOracle.");
    }
}
