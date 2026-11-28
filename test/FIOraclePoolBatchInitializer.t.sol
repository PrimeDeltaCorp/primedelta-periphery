// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FIOraclePoolBatchInitializer} from "src/FIOraclePoolBatchInitializer.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {USDCMock} from "dclex-blockchain/contracts/mocks/USDCMock.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {MockPriceOracle} from "dclex-protocol/test/MockPriceOracle.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {DeployDclex} from "dclex-protocol/script/DeployDclex.s.sol";

contract FIOraclePoolBatchInitializerTest is Test {
    address private authorized = makeAddr("authorized");
    address private attacker = makeAddr("attacker");

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
        address feeRecipient = makeAddr(string.concat("fee_recipient_", tag));
        vm.prank(f.admin);
        f.did.mintAdmin(feeRecipient, 0, bytes32(0));
        f.pool = new DclexPool(
            IStock(f.stock), IERC20(address(f.dusd)), f.oracle, 0, 0, 0, f.admin, feeRecipient, address(f.batchInit)
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
