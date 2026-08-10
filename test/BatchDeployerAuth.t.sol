// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BatchPoolDeployer} from "src/BatchPoolDeployer.sol";
import {FIOraclePoolBatchInitializer} from "src/FIOraclePoolBatchInitializer.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceOracle} from "dclex-protocol/src/IPriceOracle.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {DeployDclex} from "dclex-protocol/script/DeployDclex.s.sol";

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

    function testDeployAllPoolsRejectsZeroFinalOwner() external {
        BatchPoolDeployer batch = new BatchPoolDeployer(authorized);
        BatchPoolDeployer.DeployParams memory p = BatchPoolDeployer.DeployParams({
            router: DclexRouter(payable(address(0))),
            factory: Factory(address(0)),
            dusdToken: IERC20(address(0)),
            oracle: IPriceOracle(address(0)),
            stockAddresses: new address[](0),
            finalOwner: address(0)
        });
        vm.prank(authorized);
        vm.expectRevert(BatchPoolDeployer.BatchPoolDeployer__ZeroAddress.selector);
        batch.deployAllPools(p);
    }


    /// The renounce that actually closes OOS-02 is the one inside deployAllPools.
    /// Without this, deleting that call leaves the whole suite green.
    function testDeployAllPoolsRenouncesDidAdminOnCompletion() external {
        address master = makeAddr("master_admin2");
        address admin = makeAddr("admin2");
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory contracts = deployer.run(admin, master);
        DigitalIdentity did = contracts.digitalIdentity;

        DclexRouter router = new DclexRouter(IERC20(address(0xdead)));
        BatchPoolDeployer batch = new BatchPoolDeployer(address(this));
        router.transferOwnership(address(batch));

        vm.prank(master);
        did.grantRole(0x00, address(batch));
        assertTrue(did.hasRole(0x00, address(batch)));

        batch.deployAllPools(BatchPoolDeployer.DeployParams({
            router: router,
            factory: contracts.stocksFactory,
            dusdToken: IERC20(address(0xdead)),
            oracle: IPriceOracle(address(0xbeef)),
            stockAddresses: new address[](0),
            finalOwner: admin
        }));

        assertFalse(
            did.hasRole(0x00, address(batch)),
            "deployAllPools must drop its DID admin on the way out"
        );
        assertEq(router.owner(), address(batch), "batch must have accepted ownership");
        assertEq(router.pendingOwner(), admin, "final owner must be pending");
    }

    function testRenounceEntryPointsAreRestrictedToTheDeployOwner() external {
        address master = makeAddr("master_admin3");
        address admin = makeAddr("admin3");
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory contracts = deployer.run(admin, master);
        DigitalIdentity did = contracts.digitalIdentity;

        BatchPoolDeployer batch = new BatchPoolDeployer(authorized);
        vm.prank(master);
        did.grantRole(0x00, address(batch));

        vm.prank(attacker);
        vm.expectRevert(BatchPoolDeployer.BatchPoolDeployer__Unauthorized.selector);
        batch.renounceDidAdmin(did);
        assertTrue(did.hasRole(0x00, address(batch)), "attacker must not strip the role");

        vm.prank(authorized);
        batch.renounceDidAdmin(did);
        assertFalse(did.hasRole(0x00, address(batch)));

        FIOraclePoolBatchInitializer init =
            new FIOraclePoolBatchInitializer(authorized);
        vm.prank(master);
        contracts.stocksFactory.grantRole(0x00, address(init));

        vm.prank(attacker);
        vm.expectRevert(FIOraclePoolBatchInitializer.FIOraclePoolBatchInitializer__Unauthorized.selector);
        init.renounceFactoryAdmin(contracts.stocksFactory);
        assertTrue(contracts.stocksFactory.hasRole(0x00, address(init)));

        vm.prank(authorized);
        init.renounceFactoryAdmin(contracts.stocksFactory);
        assertFalse(contracts.stocksFactory.hasRole(0x00, address(init)));
    }

    /// deployAllPools must claim the pending ownership before it registers
    /// anything, or every addPool below reverts OwnableUnauthorizedAccount.
    function testDeployAllPoolsAcceptsPendingRouterOwnership() external {
        address master = makeAddr("master_l01");
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory contracts =
            deployer.run(makeAddr("admin_l01"), master);

        DclexRouter router = new DclexRouter(IERC20(address(0xdead)));
        BatchPoolDeployer batch = new BatchPoolDeployer(address(this));
        address finalOwner = makeAddr("final_owner_l01");

        DigitalIdentity did = contracts.digitalIdentity;
        vm.prank(master);
        did.grantRole(0x00, address(batch));

        router.transferOwnership(address(batch));
        assertEq(router.owner(), address(this), "transfer must not take effect yet");
        assertEq(router.pendingOwner(), address(batch));

        batch.deployAllPools(BatchPoolDeployer.DeployParams({
            router: router,
            factory: contracts.stocksFactory,
            dusdToken: IERC20(address(0xdead)),
            oracle: IPriceOracle(address(0xbeef)),
            stockAddresses: new address[](0),
            finalOwner: finalOwner
        }));

        assertEq(router.owner(), address(batch), "batch did not accept ownership");
        assertEq(router.pendingOwner(), finalOwner, "final owner must be left pending");
    }

    function testInitializeAllRenouncesFactoryAdminOnCompletion() external {
        address master = makeAddr("master_admin4");
        address admin = makeAddr("admin4");
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory contracts = deployer.run(admin, master);
        Factory factory = contracts.stocksFactory;

        FIOraclePoolBatchInitializer batchInit =
            new FIOraclePoolBatchInitializer(address(this));

        vm.prank(master);
        factory.grantRole(0x00, address(batchInit));
        assertTrue(factory.hasRole(0x00, address(batchInit)));

        batchInit.initializeAll(
            FIOraclePoolBatchInitializer.InitParams({
                factory: factory,
                dusdToken: IERC20(address(0xdead)),
                pools: new address[](0),
                stockSymbols: new string[](0),
                priceUpdateData: new bytes[](0),
                stockAmount: 0,
                dusdAmount: 0,
                feePerPool: 0
            })
        );

        assertFalse(
            factory.hasRole(0x00, address(batchInit)),
            "initializeAll must drop its Factory admin on the way out"
        );
    }
}
