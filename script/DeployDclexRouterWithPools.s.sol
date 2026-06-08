// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {
    HelperConfig as DclexProtocolHelperConfig
} from "dclex-protocol/script/HelperConfig.s.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {
    DigitalIdentity
} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {BatchPoolDeployer} from "src/BatchPoolDeployer.sol";
import {HelperConfig as DclexPeripheryHelperConfig} from "./HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

        result.router = _deployRouterAndPoolsViaBatchContract(
            stocksFactory,
            result.protocolHelperConfig,
            result.config.dusdToken,
            result.config.admin
        );
    }

    /// @notice Deploy router and all pools via batch contract (single tx for all pools)
    /// @dev Uses temporary permission delegation to enable single-transaction deployment
    struct BatchDeployParams {
        Factory stocksFactory;
        DclexProtocolHelperConfig protocolHelperConfig;
        IERC20 dusdToken;
        address admin;
    }

    function _deployRouterAndPoolsViaBatchContract(
        Factory stocksFactory,
        DclexProtocolHelperConfig protocolHelperConfig,
        IERC20 dusdToken,
        address admin
    ) private returns (DclexRouter) {
        return _executeBatchDeploy(BatchDeployParams(
            stocksFactory, protocolHelperConfig, dusdToken, admin
        ));
    }

    function _executeBatchDeploy(BatchDeployParams memory p) private returns (DclexRouter) {
        DclexProtocolHelperConfig.NetworkConfig memory cfg = p.protocolHelperConfig.getConfig();
        (address[] memory stocks, bytes32[] memory feeds) = _collectStockData(p.stocksFactory, p.protocolHelperConfig);

        vm.startBroadcast();

        DclexRouter router = new DclexRouter(p.dusdToken);
        BatchPoolDeployer batch = new BatchPoolDeployer();
        DigitalIdentity did = DigitalIdentity(address(p.stocksFactory.getDID()));

        router.transferOwnership(address(batch));
        did.grantRole(did.DEFAULT_ADMIN_ROLE(), address(batch));
        batch.deployAllPools(BatchPoolDeployer.DeployParams(
            router, p.stocksFactory, cfg.dusdToken, cfg.oracle,
            stocks, feeds, p.admin
        ));
        did.revokeRole(did.DEFAULT_ADMIN_ROLE(), address(batch));

        vm.stopBroadcast();
        return router;
    }

    function _collectStockData(
        Factory stocksFactory,
        DclexProtocolHelperConfig helperConfig
    ) private returns (address[] memory stocks, bytes32[] memory feeds) {
        uint256 n = stocksFactory.getStocksCount();
        stocks = new address[](n);
        feeds = new bytes32[](n);
        for (uint256 i = 0; i < n; ++i) {
            string memory sym = stocksFactory.symbols(i);
            stocks[i] = stocksFactory.stocks(sym);
            feeds[i] = helperConfig.getPriceFeedId(sym);
        }
    }

}
