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
    }

    function getAllStocks() internal pure returns (StockInfo[] memory stocks) {
        stocks = new StockInfo[](44);
        stocks[0] = StockInfo("AMZN");
        stocks[1] = StockInfo("V");
        stocks[2] = StockInfo("JPM");
        stocks[3] = StockInfo("GE");
        stocks[4] = StockInfo("AI");
        stocks[5] = StockInfo("CPNG");
        stocks[6] = StockInfo("DOW");
        stocks[7] = StockInfo("CAT");
        stocks[8] = StockInfo("MRK");
        stocks[9] = StockInfo("AMGN");
        stocks[10] = StockInfo("KO");
        stocks[11] = StockInfo("MSTR");
        stocks[12] = StockInfo("GS");
        stocks[13] = StockInfo("DIS");
        stocks[14] = StockInfo("WMT");
        stocks[15] = StockInfo("NVDA");
        stocks[16] = StockInfo("IBM");
        stocks[17] = StockInfo("MCD");
        stocks[18] = StockInfo("BA");
        stocks[19] = StockInfo("AXP");
        stocks[20] = StockInfo("TRV");
        stocks[21] = StockInfo("CVX");
        stocks[22] = StockInfo("JNJ");
        stocks[23] = StockInfo("AMC");
        stocks[24] = StockInfo("CSCO");
        stocks[25] = StockInfo("HON");
        stocks[26] = StockInfo("BLK");
        stocks[27] = StockInfo("NKE");
        stocks[28] = StockInfo("INTC");
        stocks[29] = StockInfo("MMM");
        stocks[30] = StockInfo("VZ");
        stocks[31] = StockInfo("NFLX");
        stocks[32] = StockInfo("WBA");
        stocks[33] = StockInfo("UNH");
        stocks[34] = StockInfo("TSLA");
        stocks[35] = StockInfo("COIN");
        stocks[36] = StockInfo("AAPL");
        stocks[37] = StockInfo("GOOG");
        stocks[38] = StockInfo("MSFT");
        stocks[39] = StockInfo("META");
        stocks[40] = StockInfo("CRM");
        stocks[41] = StockInfo("GME");
        stocks[42] = StockInfo("PG");
        stocks[43] = StockInfo("HD");
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
