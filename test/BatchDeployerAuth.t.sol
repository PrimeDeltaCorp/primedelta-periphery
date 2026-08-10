// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BatchPoolDeployer} from "src/BatchPoolDeployer.sol";
import {FIOraclePoolBatchInitializer} from "src/FIOraclePoolBatchInitializer.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceOracle} from "dclex-protocol/src/IPriceOracle.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {USDCMock} from "dclex-blockchain/contracts/mocks/USDCMock.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {MockPriceOracle} from "dclex-protocol/test/MockPriceOracle.sol";
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
            finalOwner: address(0),
            initializer: address(0xbeef)
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
                feePerPool: 0,
                lpRecipient: address(this)
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
            finalOwner: address(0),
            initializer: address(0xbeef)
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
            finalOwner: admin,
            initializer: address(this)
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
            finalOwner: finalOwner,
            initializer: address(this)
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
                feePerPool: 0,
                lpRecipient: address(this)
            })
        );

        assertFalse(
            factory.hasRole(0x00, address(batchInit)),
            "initializeAll must drop its Factory admin on the way out"
        );
    }

    function testDeployAllPoolsRejectsZeroInitializer() external {
        BatchPoolDeployer batch = new BatchPoolDeployer(authorized);
        BatchPoolDeployer.DeployParams memory p = BatchPoolDeployer.DeployParams({
            router: DclexRouter(payable(address(0))),
            factory: Factory(address(0)),
            dusdToken: IERC20(address(0)),
            oracle: IPriceOracle(address(0)),
            stockAddresses: new address[](0),
            finalOwner: makeAddr("final_owner_zi"),
            initializer: address(0)
        });
        vm.prank(authorized);
        vm.expectRevert(BatchPoolDeployer.BatchPoolDeployer__ZeroAddress.selector);
        batch.deployAllPools(p);
    }

    function testDeployAllPoolsGrantsTheSeedingRoleToTheNamedInitializer() external {
        address master = makeAddr("master_admin5");
        address admin = makeAddr("admin5");
        address seeder = makeAddr("seeder5");
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory contracts = deployer.run(admin, master);

        vm.prank(admin);
        string[] memory names = new string[](1);
        string[] memory symbols = new string[](1);
        names[0] = "Apple";
        symbols[0] = "AAPL";
        contracts.stocksFactory.createStocks(names, symbols);
        address stock = contracts.stocksFactory.stocks("AAPL");

        USDCMock dusd = new USDCMock("dUSD", "dUSD");
        DclexRouter router = new DclexRouter(IERC20(address(dusd)));
        BatchPoolDeployer batch = new BatchPoolDeployer(address(this));
        router.transferOwnership(address(batch));
        vm.prank(master);
        contracts.digitalIdentity.grantRole(0x00, address(batch));

        address[] memory stocks = new address[](1);
        stocks[0] = stock;
        batch.deployAllPools(BatchPoolDeployer.DeployParams({
            router: router,
            factory: contracts.stocksFactory,
            dusdToken: IERC20(address(dusd)),
            oracle: IPriceOracle(address(0xbeef)),
            stockAddresses: stocks,
            finalOwner: admin,
            initializer: seeder
        }));

        DclexPool pool = DclexPool(router.stockToDclexPool(stock));
        assertTrue(
            pool.hasRole(pool.INITIALIZER_ROLE(), seeder),
            "the named initializer must be able to seed"
        );
        assertFalse(
            pool.hasRole(pool.INITIALIZER_ROLE(), address(batch)),
            "the deployer must not keep the seeding role"
        );
    }

    function testInitializeAllRejectsZeroLpRecipient() external {
        FIOraclePoolBatchInitializer batchInit =
            new FIOraclePoolBatchInitializer(address(this));
        vm.expectRevert(
            FIOraclePoolBatchInitializer.FIOraclePoolBatchInitializer__ZeroAddress.selector
        );
        batchInit.initializeAll(
            FIOraclePoolBatchInitializer.InitParams({
                factory: Factory(address(0)),
                dusdToken: IERC20(address(0)),
                pools: new address[](0),
                stockSymbols: new string[](0),
                priceUpdateData: new bytes[](0),
                stockAmount: 0,
                dusdAmount: 0,
                feePerPool: 0,
                lpRecipient: address(0)
            })
        );
    }

    /// End-to-end: the genesis LP must land on `lpRecipient`, not on the helper
    /// that pays for it. Mutating the parameter away leaves every other test green.
    struct SeedFixture {
        Factory factory;
        DigitalIdentity did;
        USDCMock dusd;
        DclexPool pool;
        FIOraclePoolBatchInitializer batchInit;
        MockPriceOracle oracle;
        address admin;
        address stock;
    }

    function _seedFixture(string memory tag) private returns (SeedFixture memory f) {
        address master = makeAddr(string.concat("master_", tag));
        f.admin = makeAddr(string.concat("admin_", tag));
        DeployDclex.DclexContracts memory contracts = (new DeployDclex()).run(f.admin, master);
        f.factory = contracts.stocksFactory;
        f.did = contracts.digitalIdentity;

        string[] memory names = new string[](1);
        string[] memory symbols = new string[](1);
        names[0] = "Apple";
        symbols[0] = "AAPL";
        vm.prank(f.admin);
        f.factory.createStocks(names, symbols);
        f.stock = f.factory.stocks("AAPL");

        f.dusd = new USDCMock("dUSD", "dUSD");
        f.oracle = new MockPriceOracle();
        f.oracle.setPrice(keccak256(abi.encodePacked(f.stock)), 20 ether);

        f.batchInit = new FIOraclePoolBatchInitializer(address(this));
        f.pool = new DclexPool(
            IStock(f.stock), IERC20(address(f.dusd)), f.oracle, 0, 0, 0, f.admin, address(f.batchInit)
        );

        vm.prank(master);
        f.factory.grantRole(0x00, address(f.batchInit));
        f.dusd.mint(address(f.batchInit), 1_000e6);
    }

    function testInitializeAllMintsTheGenesisLpToTheNamedRecipient() external {
        SeedFixture memory f = _seedFixture("seed6");
        address treasury = makeAddr("treasury6");
        Factory factory = f.factory;
        DigitalIdentity did = f.did;
        DclexPool pool = f.pool;
        FIOraclePoolBatchInitializer batchInit = f.batchInit;
        address admin = f.admin;

        string[] memory symbols = new string[](1);
        symbols[0] = "AAPL";

        vm.startPrank(admin);
        did.mintAdmin(address(pool), 0, bytes32(0));
        did.mintAdmin(address(batchInit), 0, bytes32(0));
        did.mintAdmin(treasury, 0, bytes32(0));
        vm.stopPrank();

        address[] memory pools = new address[](1);
        pools[0] = address(pool);
        bytes[] memory priceData = new bytes[](1);
        priceData[0] = f.oracle.getUpdatePriceData(keccak256(abi.encodePacked(f.stock)), 20 ether);

        batchInit.initializeAll(
            FIOraclePoolBatchInitializer.InitParams({
                factory: factory,
                dusdToken: IERC20(address(f.dusd)),
                pools: pools,
                stockSymbols: symbols,
                priceUpdateData: priceData,
                stockAmount: 10 ether,
                dusdAmount: 1_000e6,
                feePerPool: 0,
                lpRecipient: treasury
            })
        );

        assertGt(pool.balanceOf(treasury), 0, "the named recipient must hold the genesis LP");
        assertEq(pool.balanceOf(address(batchInit)), 0, "the paying helper must hold none");
    }
}
