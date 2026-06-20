// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {
    DigitalIdentity
} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {IPriceOracle} from "dclex-protocol/src/IPriceOracle.sol";
import {FIOracle} from "dclex-protocol/src/FIOracle.sol";
import {DclexRouter} from "src/DclexRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deploys FIOracle + DclexPools for all 44 stocks and registers them with the router.
///         The deployer is used as temporary trusted signer for FIOracle during initialization.
///         After initialization, call setTrustedSigner() to switch to the backend signer.
contract DeployMissingPools is Script {
    // Chain 2028 — primelta-dev
    address payable constant DCLEX_ROUTER =
        payable(0x1FFbb4cF957630830A624Aca3f811FBB69d5A027);
    address constant FACTORY = 0x5d360D437c9bEd63B149435b11f5c5c5d41bb549;
    address constant DID = 0x399426509BE32e1ca682582CDF157ED050ED823B;
    address constant DUSD = 0x951c4871D16d953a3Fd64c17a756B1aA95D63E58;
    address constant ADMIN = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    // Backend signer — switch FIOracle to this after initialization
    address constant BACKEND_SIGNER =
        0x971b5a2872ec17EeDDED9fc4dd691D8B33B97031;

    struct StockInfo {
        string symbol;
        bytes32 priceFeedId;
    }

    function getAllStocks() internal pure returns (StockInfo[] memory stocks) {
        stocks = new StockInfo[](44);
        stocks[0] = StockInfo(
            "AMZN",
            0xb5d0e0fa58a1f8b81498ae670ce93c872d14434b72c364885d4fa1b257cbb07a
        );
        stocks[1] = StockInfo(
            "V",
            0xc719eb7bab9b2bc060167f1d1680eb34a29c490919072513b545b9785b73ee90
        );
        stocks[2] = StockInfo(
            "JPM",
            0x7f4f157e57bfcccd934c566df536f34933e74338fe241a5425ce561acdab164e
        );
        stocks[3] = StockInfo(
            "GE",
            0xe1d3115c6e7ac649faca875b3102f1000ab5e06b03f6903e0d699f0f5315ba86
        );
        stocks[4] = StockInfo(
            "AI",
            0xafb12c5ccf50495c7a7b04447410d7feb4b3218a663ecbd96aa82e676d3c4f1e
        );
        stocks[5] = StockInfo(
            "CPNG",
            0x5557d206aa0dd037fc082f03bbd78653f01465d280ea930bc93251f0eb60c707
        );
        stocks[6] = StockInfo(
            "DOW",
            0xf3b50961ff387a3d68217e2715637d0add6013e7ecb83c36ae8062f97c46929e
        );
        stocks[7] = StockInfo(
            "CAT",
            0xad04597ba688c350a97265fcb60585d6a80ebd37e147b817c94f101a32e58b4c
        );
        stocks[8] = StockInfo(
            "MRK",
            0xc81114e16ec3cbcdf20197ac974aed5a254b941773971260ce09e7caebd6af46
        );
        stocks[9] = StockInfo(
            "AMGN",
            0x10946973bfcc936b423d52ee2c5a538d96427626fe6d1a7dae14b1c401d1e794
        );
        stocks[10] = StockInfo(
            "KO",
            0x9aa471dccea36b90703325225ac76189baf7e0cc286b8843de1de4f31f9caa7d
        );
        stocks[11] = StockInfo(
            "MSTR",
            0xe1e80251e5f5184f2195008382538e847fafc36f751896889dd3d1b1f6111f09
        );
        stocks[12] = StockInfo(
            "GS",
            0x9c68c0c6999765cf6e27adf75ed551b34403126d3b0d5b686a2addb147ed4554
        );
        stocks[13] = StockInfo(
            "DIS",
            0x703e36203020ae6761e6298975764e266fb869210db9b35dd4e4225fa68217d0
        );
        stocks[14] = StockInfo(
            "WMT",
            0x327ae981719058e6fb44e132fb4adbf1bd5978b43db0661bfdaefd9bea0c82dc
        );
        stocks[15] = StockInfo(
            "NVDA",
            0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593
        );
        stocks[16] = StockInfo(
            "IBM",
            0xcfd44471407f4da89d469242546bb56f5c626d5bef9bd8b9327783065b43c3ef
        );
        stocks[17] = StockInfo(
            "MCD",
            0xd3178156b7c0f6ce10d6da7d347952a672467b51708baaf1a57ffe1fb005824a
        );
        stocks[18] = StockInfo(
            "BA",
            0x8419416ba640c8bbbcf2d464561ed7dd860db1e38e51cec9baf1e34c4be839ae
        );
        stocks[19] = StockInfo(
            "AXP",
            0x9ff7b9a93df40f6d7edc8184173c50f4ae72152c6142f001e8202a26f951d710
        );
        stocks[20] = StockInfo(
            "TRV",
            0xd45392f678a1287b8412ed2aaa326def204a5c234df7cb5552d756c332283d81
        );
        stocks[21] = StockInfo(
            "CVX",
            0xf464e36fd4ef2f1c3dc30801a9ab470dcdaaa0af14dd3cf6ae17a7fca9e051c5
        );
        stocks[22] = StockInfo(
            "JNJ",
            0x12848738d5db3aef52f51d78d98fc8b8b8450ffb19fb3aeeb67d38f8c147ff63
        );
        stocks[23] = StockInfo(
            "AMC",
            0x5b1703d7eb9dc8662a61556a2ca2f9861747c3fc803e01ba5a8ce35cb50a13a1
        );
        stocks[24] = StockInfo(
            "CSCO",
            0x3f4b77dd904e849f70e1e812b7811de57202b49bc47c56391275c0f45f2ec481
        );
        stocks[25] = StockInfo(
            "HON",
            0x107918baaaafb79cd9df1c8369e44ac21136d95f3ca33f2373b78f24ba1e3e6a
        );
        stocks[26] = StockInfo(
            "BLK",
            0x68d038affb5895f357d7b3527a6d3cd6a54edd0fe754a1248fb3462e47828b08
        );
        stocks[27] = StockInfo(
            "NKE",
            0x67649450b4ca4bfff97cbaf96d2fd9e40f6db148cb65999140154415e4378e14
        );
        stocks[28] = StockInfo(
            "INTC",
            0xc1751e085ee292b8b3b9dd122a135614485a201c35dfc653553f0e28c1baf3ff
        );
        stocks[29] = StockInfo(
            "MMM",
            0xfd05a384ba19863cbdfc6575bed584f041ef50554bab3ab482eabe4ea58d9f81
        );
        stocks[30] = StockInfo(
            "VZ",
            0x6672325a220c0ee1166add709d5ba2e51c185888360c01edc76293257ef68b58
        );
        stocks[31] = StockInfo(
            "NFLX",
            0x8376cfd7ca8bcdf372ced05307b24dced1f15b1afafdeff715664598f15a3dd2
        );
        stocks[32] = StockInfo(
            "WBA",
            0xed5c2a2711e2a638573add9a8aded37028aea4ac69f1431a1ced9d9db61b2225
        );
        stocks[33] = StockInfo(
            "UNH",
            0x05380f8817eb1316c0b35ac19c3caa92c9aa9ea6be1555986c46dce97fed6afd
        );
        stocks[34] = StockInfo(
            "TSLA",
            0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1
        );
        stocks[35] = StockInfo(
            "COIN",
            0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245
        );
        stocks[36] = StockInfo(
            "AAPL",
            0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688
        );
        stocks[37] = StockInfo(
            "GOOG",
            0xe65ff435be42630439c96396653a342829e877e2aafaeaf1a10d0ee5fd2cf3f2
        );
        stocks[38] = StockInfo(
            "MSFT",
            0xd0ca23c1cc005e004ccf1db5bf76aeb6a49218f43dac3d4b275e92de12ded4d1
        );
        stocks[39] = StockInfo(
            "META",
            0x78a3e3b8e676a8f73c439f5d749737034b139bbbe899ba5775216fba596607fe
        );
        stocks[40] = StockInfo(
            "CRM",
            0xfeff234600320f4d6bb5a01d02570a9725c1e424977f2b823f7231e6857bdae8
        );
        stocks[41] = StockInfo(
            "GME",
            0x6f9cd89ef1b7fd39f667101a91ad578b6c6ace4579d5f7f285a4b06aa4504be6
        );
        stocks[42] = StockInfo(
            "PG",
            0xad2fda41998f4e7be99a2a7b27273bd16f183d9adfc014a4f5e5d3d6cd519bf4
        );
        stocks[43] = StockInfo(
            "HD",
            0xb3a83dbe70b62241b0f916212e097465a1b31085fa30da3342dd35468ca17ca5
        );
    }

    function run() external {
        DclexRouter dclexRouter = DclexRouter(payable(DCLEX_ROUTER));
        Factory stocksFactory = Factory(FACTORY);
        DigitalIdentity digitalIdentity = DigitalIdentity(DID);
        IERC20 dusdToken = IERC20(DUSD);

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        uint256 adminKey = vm.envUint("ADMIN_PRIVATE_KEY");

        // Step 1: Deploy FIOracle with deployer as temporary trusted signer + admin
        vm.startBroadcast(deployerKey);
        FIOracle fiOracle = new FIOracle(
            vm.addr(deployerKey),
            vm.addr(deployerKey)
        );
        vm.stopBroadcast();
        console.log("FIOracle deployed at:", address(fiOracle));

        IPriceOracle oracle = IPriceOracle(address(fiOracle));

        // Step 2: Deploy pools (deployer deploys, admin registers + mints DID)
        StockInfo[] memory allStocks = getAllStocks();
        for (uint256 i = 0; i < allStocks.length; i++) {
            string memory symbol = allStocks[i].symbol;
            bytes32 priceFeedId = allStocks[i].priceFeedId;

            address stockAddress = stocksFactory.stocks(symbol);
            require(
                stockAddress != address(0),
                string.concat("Stock not found: ", symbol)
            );

            // Deploy pool with deployer. Fee curve is now constructor-bound
            // (setFeeCurve removed per issue #311 — legal requirement).
            // Raw values match the canonical (baseFee=0.25%, sens=0.2%) defaults
            // used by BatchPoolDeployer:
            //   feeCurveA = sensitivity / 4 = 0.002 / 4 = 0.0005 ether
            //   feeCurveB = baseFeeRate - sensitivity = 0.0025 - 0.002 = 0.0005 ether
            vm.startBroadcast(deployerKey);
            DclexPool dclexPool = new DclexPool(
                IStock(stockAddress),
                dusdToken,
                oracle,
                priceFeedId,
                0.0005 ether,
                0.0005 ether,
                0.15 ether, // protocol-fee cut, matches BatchPoolDeployer default (#256)
                ADMIN
            );
            vm.stopBroadcast();

            // Register pool + mint DID with admin.
            vm.startBroadcast(adminKey);
            dclexRouter.addPool(stockAddress, DclexRouter.PoolType.DCLEX, address(dclexPool), 0);
            digitalIdentity.mintAdmin(address(dclexPool), 2, bytes32(0));
            vm.stopBroadcast();

            console.log("Deployed pool for", symbol, "at", address(dclexPool));
        }

        // Step 3: Transfer FIOracle to production config
        vm.startBroadcast(deployerKey);
        fiOracle.setTrustedSigner(BACKEND_SIGNER);
        fiOracle.grantRole(fiOracle.DEFAULT_ADMIN_ROLE(), ADMIN);
        fiOracle.renounceRole(
            fiOracle.DEFAULT_ADMIN_ROLE(),
            vm.addr(deployerKey)
        );
        vm.stopBroadcast();
        console.log(
            "FIOracle: signer -> backend, admin -> ADMIN, deployer role revoked"
        );

        console.log("All 44 pools deployed and registered.");
    }
}
