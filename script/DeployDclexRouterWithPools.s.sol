// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {
    HelperConfig as DclexProtocolHelperConfig
} from "dclex-protocol/script/HelperConfig.s.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {
    DigitalIdentity
} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {DclexPoolDeployer} from "src/DclexPoolDeployer.sol";
import {HelperConfig as DclexPeripheryHelperConfig} from "./HelperConfig.s.sol";

contract DeployRouterWithPools is Script {
    struct DeploymentResult {
        DclexRouter router;
        DclexPeripheryHelperConfig.NetworkConfig config;
        address oracleAddress;
        DclexProtocolHelperConfig protocolHelperConfig;
        DclexPeripheryHelperConfig peripheryHelperConfig;
    }

    function run(Factory stocksFactory)
        external
        returns (
            DclexRouter,
            DclexPeripheryHelperConfig.NetworkConfig memory,
            address,
            DclexProtocolHelperConfig,
            DclexPeripheryHelperConfig
        )
    {
        DeploymentResult memory result = _deploy(stocksFactory);
        return (
            result.router,
            result.config,
            result.oracleAddress,
            result.protocolHelperConfig,
            result.peripheryHelperConfig
        );
    }

    function _deploy(Factory stocksFactory)
        private
        returns (DeploymentResult memory result)
    {
        vm.startBroadcast();
        result.peripheryHelperConfig = new DclexPeripheryHelperConfig();
        vm.stopBroadcast();

        result.protocolHelperConfig = new DclexProtocolHelperConfig();
        DclexProtocolHelperConfig.NetworkConfig memory protocolConfig = result.protocolHelperConfig.getConfig();
        result.config = result.peripheryHelperConfig.getConfig(protocolConfig.dusdToken);
        result.oracleAddress = address(protocolConfig.oracle);

        result.router = _deployRouterAndPools(stocksFactory, protocolConfig, result.config.admin);
    }

    function _deployRouterAndPools(
        Factory stocksFactory,
        DclexProtocolHelperConfig.NetworkConfig memory cfg,
        address admin
    ) private returns (DclexRouter router) {
        address[] memory stocks = _collectStockData(stocksFactory);
        DigitalIdentity did = DigitalIdentity(address(stocksFactory.getDID()));
        uint256 adminKey = vm.envUint("ADMIN_PRIVATE_KEY");
        uint256 masterKey = vm.envUint("MASTER_ADMIN_PRIVATE_KEY");
        require(vm.addr(adminKey) == admin, "ADMIN_PRIVATE_KEY != admin");
        require(cfg.feeRecipient != vm.addr(masterKey), "POOL_FEE_RECIPIENT must differ from the master");
        address oldPoolDeployer = stocksFactory.getPoolDeployer();

        vm.startBroadcast(adminKey);
        if (did.balanceOf(cfg.feeRecipient) == 0) {
            did.mintAdmin(cfg.feeRecipient, 2, bytes32(0));
        }
        vm.stopBroadcast();

        vm.startBroadcast(masterKey);
        router = new DclexRouter(cfg.dusdToken);
        router.setDclexOracle(address(cfg.oracle));
        DclexPoolDeployer poolDeployer = new DclexPoolDeployer(router, admin, cfg.feeRecipient, admin);
        router.setPoolRegistrar(address(poolDeployer));
        if (oldPoolDeployer != address(0)) did.revokeRole(did.DEFAULT_ADMIN_ROLE(), oldPoolDeployer);
        did.grantRole(did.DEFAULT_ADMIN_ROLE(), address(poolDeployer));
        poolDeployer.deployPools(stocks);
        poolDeployer.grantRole(poolDeployer.DEFAULT_ADMIN_ROLE(), admin);
        poolDeployer.grantRole(poolDeployer.DEFAULT_ADMIN_ROLE(), address(stocksFactory));
        poolDeployer.renounceRole(poolDeployer.DEFAULT_ADMIN_ROLE(), vm.addr(masterKey));
        router.transferOwnership(admin);
        vm.stopBroadcast();

        vm.startBroadcast(adminKey);
        did.mintAdmin(address(router), 2, bytes32(0));
        stocksFactory.setPoolDeployer(address(poolDeployer));
        vm.stopBroadcast();

        console.log("DclexPoolDeployer:", address(poolDeployer));
        console.log("Pool fee recipient:", cfg.feeRecipient);
        console.log("ACTION REQUIRED: admin must acceptOwnership() on the router");
    }

    function _collectStockData(
        Factory stocksFactory
    ) private returns (address[] memory stocks) {
        uint256 n = stocksFactory.getStocksCount();
        stocks = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            stocks[i] = stocksFactory.stocks(stocksFactory.symbols(i));
        }
    }

}
