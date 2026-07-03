// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BatchPoolDeployer} from "src/BatchPoolDeployer.sol";
import {FIOraclePoolBatchInitializer} from "src/FIOraclePoolBatchInitializer.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceOracle} from "dclex-protocol/src/IPriceOracle.sol";

contract BatchDeployerAuthTest is Test {
    address private authorized = makeAddr("authorized");
    address private attacker = makeAddr("attacker");

    function testDeployAllPoolsRejectsUnauthorizedCaller() external {
        BatchPoolDeployer batch = new BatchPoolDeployer(authorized);
        BatchPoolDeployer.DeployParams memory p = BatchPoolDeployer.DeployParams({
            router: DclexRouter(payable(address(0))),
            factory: Factory(address(0)),
            dusdToken: IERC20(address(0)),
            oracle: IPriceOracle(address(0)),
            stockAddresses: new address[](0),
            finalOwner: address(0)
        });
        vm.prank(attacker);
        vm.expectRevert(BatchPoolDeployer.BatchPoolDeployer__Unauthorized.selector);
        batch.deployAllPools(p);
    }

    function testInitializeAllRejectsUnauthorizedCaller() external {
        FIOraclePoolBatchInitializer batchInit =
            new FIOraclePoolBatchInitializer(authorized);
        FIOraclePoolBatchInitializer.InitParams memory p =
            FIOraclePoolBatchInitializer.InitParams({
                factory: Factory(address(0)),
                dusdToken: IERC20(address(0)),
                pools: new address[](0),
                stockSymbols: new string[](0),
                priceUpdateData: new bytes[](0),
                stockAmount: 0,
                dusdAmount: 0,
                feePerPool: 0
            });
        vm.prank(attacker);
        vm.expectRevert(FIOraclePoolBatchInitializer.FIOraclePoolBatchInitializer__Unauthorized.selector);
        batchInit.initializeAll(p);
    }
}
