// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DclexPoolDeployer} from "src/DclexPoolDeployer.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {MockPriceOracle} from "dclex-protocol/test/MockPriceOracle.sol";
import {DeployDclex} from "dclex-protocol/script/DeployDclex.s.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {USDCMock} from "dclex-blockchain/contracts/mocks/USDCMock.sol";

contract DclexPoolDeployerTest is Test {
    address private admin = makeAddr("admin");
    address private master = makeAddr("master");
    address private poolAdmin = makeAddr("pool_admin");
    address private feeRecipient = makeAddr("fee_recipient");
    address private seeder = makeAddr("seeder");
    address private stranger = makeAddr("stranger");

    Factory private factory;
    DigitalIdentity private did;
    DclexRouter private router;
    MockPriceOracle private oracle;
    DclexPoolDeployer private poolDeployer;

    function setUp() external {
        DeployDclex.DclexContracts memory contracts = (new DeployDclex()).run(admin, master);
        factory = contracts.stocksFactory;
        did = contracts.digitalIdentity;
        router = new DclexRouter(IERC20(address(new USDCMock("dUSD", "dUSD"))));
        oracle = new MockPriceOracle();
        router.setDclexOracle(address(oracle));
        poolDeployer = new DclexPoolDeployer(router, poolAdmin, feeRecipient, seeder);
        router.setPoolRegistrar(address(poolDeployer));
        vm.prank(master);
        did.grantRole(bytes32(0), address(poolDeployer));
        vm.prank(admin);
        did.mintAdmin(feeRecipient, 2, bytes32(0));
    }

    function _stock(string memory symbol) private returns (address) {
        string[] memory names = new string[](1);
        names[0] = symbol;
        vm.prank(admin);
        factory.createStocks(names, names);
        return factory.stocks(symbol);
    }

    function testDeployPoolCreatesIdentifiesAndRegistersThePool() external {
        address stock = _stock("AAPL");

        DclexPool pool = DclexPool(poolDeployer.deployPool(stock));

        assertEq(address(router.stockToDclexPool(stock)), address(pool));
        assertEq(address(pool.stockToken()), stock);
        assertEq(address(pool.stablecoinToken()), address(router.stablecoin()));
        assertEq(address(pool.oracle()), address(oracle));
        assertEq(pool.feeRecipient(), feeRecipient);
        assertTrue(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), poolAdmin));
        assertTrue(pool.hasRole(pool.INITIALIZER_ROLE(), seeder));
        (uint256 a, uint256 b) = pool.getFeeCurve();
        assertEq(a, poolDeployer.FEE_CURVE_A());
        assertEq(b, poolDeployer.FEE_CURVE_B());
        assertEq(pool.getProtocolFeeRate(), poolDeployer.PROTOCOL_FEE_RATE());
        uint256 id = did.getId(address(pool));
        assertTrue(did.isValid(id) && did.isContract(id) && !did.isPro(id));
    }

    function testDeployPoolsDeploysOnePoolPerStock() external {
        address[] memory stocks = new address[](2);
        stocks[0] = _stock("AAPL");
        stocks[1] = _stock("TSLA");

        address[] memory pools = poolDeployer.deployPools(stocks);

        assertEq(address(router.stockToDclexPool(stocks[0])), pools[0]);
        assertEq(address(router.stockToDclexPool(stocks[1])), pools[1]);
        assertEq(router.dclexPoolCount(), 2);
    }

    function testFactoryDeploysAPoolForEveryNewStock() external {
        poolDeployer.grantRole(poolDeployer.DEFAULT_ADMIN_ROLE(), address(factory));
        vm.prank(admin);
        factory.setPoolDeployer(address(poolDeployer));

        address stock = _stock("AAPL");

        assertTrue(address(router.stockToDclexPool(stock)) != address(0));
    }

    function testOnlyAdminsCanDeployOrConfigure() external {
        address stock = _stock("AAPL");
        bytes memory unauthorized = abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector,
            stranger,
            poolDeployer.DEFAULT_ADMIN_ROLE()
        );
        vm.startPrank(stranger);
        vm.expectRevert(unauthorized);
        poolDeployer.deployPool(stock);
        vm.expectRevert(unauthorized);
        poolDeployer.deployPools(new address[](0));
        vm.expectRevert(unauthorized);
        poolDeployer.setPoolConfig(stranger, stranger, stranger);
        vm.stopPrank();
    }

    function testPoolConfigAppliesToTheNextPool() external {
        address newRecipient = makeAddr("new_fee_recipient");
        vm.prank(admin);
        did.mintAdmin(newRecipient, 2, bytes32(0));
        poolDeployer.setPoolConfig(admin, newRecipient, admin);

        DclexPool pool = DclexPool(poolDeployer.deployPool(_stock("AAPL")));

        assertEq(pool.feeRecipient(), newRecipient);
        assertTrue(pool.hasRole(pool.DEFAULT_ADMIN_ROLE(), admin));
    }

    function testRegistrarCanOnlyAddAPoolForAStockWithout() external {
        address stock = _stock("AAPL");
        address pool = poolDeployer.deployPool(stock);

        vm.expectRevert(DclexRouter.DclexRouter__NotPoolRegistrar.selector);
        router.registerDclexPool(stock, pool);
        vm.expectRevert(DclexRouter.DclexRouter__PoolAlreadyRegistered.selector);
        poolDeployer.deployPool(stock);
    }
}
