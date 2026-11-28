// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {FIOracle} from "dclex-protocol/src/FIOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {DclexPoolDeployer} from "src/DclexPoolDeployer.sol";
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
/// DCLEX_ROUTER, DCLEX_POOL_DEPLOYER, DCLEX_FACTORY, DCLEX_DID, DCLEX_ADMIN, POOL_FEE_RECIPIENT.
/// Optional env: DCLEX_DUSD_SYMBOL (defaults to "dUSD").
/// The trusted-signer handoff happens in FinalizeFIOracleRedeploy, not here.
contract RedeployFIOracleAndPools is DclexStockList {
    address payable internal DCLEX_ROUTER;
    address internal POOL_DEPLOYER;
    address internal FACTORY;
    address internal DID;
    address internal ADMIN;
    address internal POOL_FEE_RECIPIENT;
    string  internal DUSD_SYMBOL;

    uint256 constant INITIAL_UPDATE_FEE = 0.001 ether;
    uint256 constant DUSD_AMOUNT = 1_000e6;

    function _loadEnv() internal {
        DCLEX_ROUTER   = payable(vm.envAddress("DCLEX_ROUTER"));
        POOL_DEPLOYER  = vm.envAddress("DCLEX_POOL_DEPLOYER");
        FACTORY        = vm.envAddress("DCLEX_FACTORY");
        DID            = vm.envAddress("DCLEX_DID");
        ADMIN          = vm.envAddress("DCLEX_ADMIN");
        POOL_FEE_RECIPIENT = vm.envAddress("POOL_FEE_RECIPIENT");
        require(POOL_FEE_RECIPIENT != address(0), "POOL_FEE_RECIPIENT is zero");
        require(POOL_FEE_RECIPIENT != ADMIN, "POOL_FEE_RECIPIENT must differ from DCLEX_ADMIN");
        DUSD_SYMBOL    = vm.envOr("DCLEX_DUSD_SYMBOL", string("dUSD"));
    }

    function run() external {
        _loadEnv();
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 adminKey    = vm.envUint("ADMIN_PRIVATE_KEY");
        require(vm.addr(adminKey) == ADMIN, "ADMIN_PRIVATE_KEY != DCLEX_ADMIN");
        uint256 masterKey   = vm.envUint("MASTER_ADMIN_PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        require(POOL_FEE_RECIPIENT != deployer, "POOL_FEE_RECIPIENT must differ from the deployer");

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

        // Phase 2 (admin, then deployer): the batch initializer is deployed first
        // because it is the account that calls initialize later, so it has to be
        // named as the pools' seeder at construction.
        vm.startBroadcast(adminKey);
        FIOraclePoolBatchInitializer batchInit = new FIOraclePoolBatchInitializer(ADMIN);
        if (did.balanceOf(POOL_FEE_RECIPIENT) == 0) {
            did.mintAdmin(POOL_FEE_RECIPIENT, 2, bytes32(0));
        }
        vm.stopBroadcast();
        require(did.verifyTransfer(POOL_FEE_RECIPIENT, POOL_FEE_RECIPIENT), "POOL_FEE_RECIPIENT has no valid DID");

        address[] memory stockAddrs = _dclexStocks(factory, router, stocks);

        // Phase 3a (admin): deregister, repoint the router's oracle pin, then
        // create and register the new pools. Registering first reverts
        // DclexRouter__OracleMismatch.
        DclexPoolDeployer poolDeployer = DclexPoolDeployer(POOL_DEPLOYER);
        vm.startBroadcast(adminKey);
        did.mintAdmin(address(batchInit), 2, bytes32(0));
        for (uint256 i = 0; i < stockAddrs.length; i++) {
            if (router.getPoolType(stockAddrs[i]) == DclexRouter.PoolType.DCLEX) {
                router.removePool(stockAddrs[i], DclexRouter.PoolType.DCLEX);
            }
        }
        router.setDclexOracle(address(fiOracle));
        poolDeployer.setPoolConfig(ADMIN, POOL_FEE_RECIPIENT, address(batchInit));
        address[] memory newPools = poolDeployer.deployPools(stockAddrs);
        poolDeployer.setPoolConfig(ADMIN, POOL_FEE_RECIPIENT, ADMIN);
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

    function _dclexStocks(
        Factory factory,
        DclexRouter router,
        StockInfo[] memory stocks
    ) internal view returns (address[] memory stockAddrs) {
        address[] memory registered = router.allStockTokens();
        stockAddrs = new address[](stocks.length + registered.length);
        uint256 n;
        for (uint256 i = 0; i < stocks.length; i++) {
            stockAddrs[n] = factory.stocks(stocks[i].symbol);
            require(stockAddrs[n] != address(0), string.concat("stock not found: ", stocks[i].symbol));
            n++;
        }
        for (uint256 i = 0; i < registered.length; i++) {
            if (router.getPoolType(registered[i]) != DclexRouter.PoolType.DCLEX) continue;
            bool listed;
            for (uint256 j = 0; j < stocks.length; j++) {
                if (stockAddrs[j] == registered[i]) listed = true;
            }
            if (!listed) stockAddrs[n++] = registered[i];
        }
        assembly {
            mstore(stockAddrs, n)
        }
    }
}
