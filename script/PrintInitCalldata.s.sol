// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {FIOraclePoolBatchInitializer} from "src/FIOraclePoolBatchInitializer.sol";

interface IRouter { function stockToCustomPool(address) external view returns (address); }

/// @notice Prints freshly-signed initializeAll calldata to be cast-sent
/// directly. Bypasses forge --broadcast overhead so publishTime is
/// minutes-fresh at chain mining (well under 60s staleness).
contract PrintInitCalldata is Script {
    int64 constant MOCK_PRICE = 10_000_000_000;
    int32 constant EXPO = -8;
    uint256 constant STOCK_AMOUNT = 10e18;
    uint256 constant DUSD_AMOUNT = 1_000e6;
    uint256 constant INITIAL_UPDATE_FEE = 0.001 ether;

    function run() external view {
        Factory factory = Factory(vm.envAddress("DCLEX_FACTORY"));
        address router = vm.envAddress("DCLEX_ROUTER");
        address dusdAddr = factory.stablecoins("dUSD");
        uint256 adminKey = vm.envUint("ADMIN_PRIVATE_KEY");

        string[44] memory syms = ["AMZN","V","JPM","GE","AI","CPNG","DOW","CAT","MRK","AMGN","KO","MSTR","GS","DIS","WMT","NVDA","IBM","MCD","BA","AXP","TRV","CVX","JNJ","AMC","CSCO","HON","BLK","NKE","INTC","MMM","VZ","NFLX","WBA","UNH","TSLA","COIN","AAPL","GOOG","MSFT","META","CRM","GME","PG","HD"];
        bytes32[44] memory feeds = [
            bytes32(0xb5d0e0fa58a1f8b81498ae670ce93c872d14434b72c364885d4fa1b257cbb07a),
            bytes32(0xc719eb7bab9b2bc060167f1d1680eb34a29c490919072513b545b9785b73ee90),
            bytes32(0x7f4f157e57bfcccd934c566df536f34933e74338fe241a5425ce561acdab164e),
            bytes32(0xe1d3115c6e7ac649faca875b3102f1000ab5e06b03f6903e0d699f0f5315ba86),
            bytes32(0xafb12c5ccf50495c7a7b04447410d7feb4b3218a663ecbd96aa82e676d3c4f1e),
            bytes32(0x5557d206aa0dd037fc082f03bbd78653f01465d280ea930bc93251f0eb60c707),
            bytes32(0xf3b50961ff387a3d68217e2715637d0add6013e7ecb83c36ae8062f97c46929e),
            bytes32(0xad04597ba688c350a97265fcb60585d6a80ebd37e147b817c94f101a32e58b4c),
            bytes32(0xc81114e16ec3cbcdf20197ac974aed5a254b941773971260ce09e7caebd6af46),
            bytes32(0x10946973bfcc936b423d52ee2c5a538d96427626fe6d1a7dae14b1c401d1e794),
            bytes32(0x9aa471dccea36b90703325225ac76189baf7e0cc286b8843de1de4f31f9caa7d),
            bytes32(0xe1e80251e5f5184f2195008382538e847fafc36f751896889dd3d1b1f6111f09),
            bytes32(0x9c68c0c6999765cf6e27adf75ed551b34403126d3b0d5b686a2addb147ed4554),
            bytes32(0x703e36203020ae6761e6298975764e266fb869210db9b35dd4e4225fa68217d0),
            bytes32(0x327ae981719058e6fb44e132fb4adbf1bd5978b43db0661bfdaefd9bea0c82dc),
            bytes32(0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593),
            bytes32(0xcfd44471407f4da89d469242546bb56f5c626d5bef9bd8b9327783065b43c3ef),
            bytes32(0xd3178156b7c0f6ce10d6da7d347952a672467b51708baaf1a57ffe1fb005824a),
            bytes32(0x8419416ba640c8bbbcf2d464561ed7dd860db1e38e51cec9baf1e34c4be839ae),
            bytes32(0x9ff7b9a93df40f6d7edc8184173c50f4ae72152c6142f001e8202a26f951d710),
            bytes32(0xd45392f678a1287b8412ed2aaa326def204a5c234df7cb5552d756c332283d81),
            bytes32(0xf464e36fd4ef2f1c3dc30801a9ab470dcdaaa0af14dd3cf6ae17a7fca9e051c5),
            bytes32(0x12848738d5db3aef52f51d78d98fc8b8b8450ffb19fb3aeeb67d38f8c147ff63),
            bytes32(0x5b1703d7eb9dc8662a61556a2ca2f9861747c3fc803e01ba5a8ce35cb50a13a1),
            bytes32(0x3f4b77dd904e849f70e1e812b7811de57202b49bc47c56391275c0f45f2ec481),
            bytes32(0x107918baaaafb79cd9df1c8369e44ac21136d95f3ca33f2373b78f24ba1e3e6a),
            bytes32(0x68d038affb5895f357d7b3527a6d3cd6a54edd0fe754a1248fb3462e47828b08),
            bytes32(0x67649450b4ca4bfff97cbaf96d2fd9e40f6db148cb65999140154415e4378e14),
            bytes32(0xc1751e085ee292b8b3b9dd122a135614485a201c35dfc653553f0e28c1baf3ff),
            bytes32(0xfd05a384ba19863cbdfc6575bed584f041ef50554bab3ab482eabe4ea58d9f81),
            bytes32(0x6672325a220c0ee1166add709d5ba2e51c185888360c01edc76293257ef68b58),
            bytes32(0x8376cfd7ca8bcdf372ced05307b24dced1f15b1afafdeff715664598f15a3dd2),
            bytes32(0xed5c2a2711e2a638573add9a8aded37028aea4ac69f1431a1ced9d9db61b2225),
            bytes32(0x05380f8817eb1316c0b35ac19c3caa92c9aa9ea6be1555986c46dce97fed6afd),
            bytes32(0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1),
            bytes32(0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245),
            bytes32(0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688),
            bytes32(0xe65ff435be42630439c96396653a342829e877e2aafaeaf1a10d0ee5fd2cf3f2),
            bytes32(0xd0ca23c1cc005e004ccf1db5bf76aeb6a49218f43dac3d4b275e92de12ded4d1),
            bytes32(0x78a3e3b8e676a8f73c439f5d749737034b139bbbe899ba5775216fba596607fe),
            bytes32(0xfeff234600320f4d6bb5a01d02570a9725c1e424977f2b823f7231e6857bdae8),
            bytes32(0x6f9cd89ef1b7fd39f667101a91ad578b6c6ace4579d5f7f285a4b06aa4504be6),
            bytes32(0xad2fda41998f4e7be99a2a7b27273bd16f183d9adfc014a4f5e5d3d6cd519bf4),
            bytes32(0xb3a83dbe70b62241b0f916212e097465a1b31085fa30da3342dd35468ca17ca5)
        ];

        address[] memory pools = new address[](44);
        string[] memory symbols = new string[](44);
        bytes32[] memory feedIds = new bytes32[](44);
        bytes[] memory priceUpdateData = new bytes[](44);

        uint64 publishTime = uint64(vm.unixTime() / 1000);
        for (uint256 i = 0; i < 44; i++) {
            address stockAddr = factory.stocks(syms[i]);
            pools[i] = IRouter(router).stockToCustomPool(stockAddr);
            symbols[i] = syms[i];
            feedIds[i] = feeds[i];
            bytes32 messageHash = keccak256(abi.encodePacked(feeds[i], MOCK_PRICE, EXPO, publishTime));
            bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(adminKey, ethSignedHash);
            priceUpdateData[i] = abi.encodePacked(feeds[i], MOCK_PRICE, EXPO, publishTime, v, r, s);
        }

        bytes memory calldata_ = abi.encodeCall(
            FIOraclePoolBatchInitializer.initializeAll,
            (FIOraclePoolBatchInitializer.InitParams({
                factory: factory,
                dusdToken: IERC20(dusdAddr),
                pools: pools,
                stockSymbols: symbols,
                priceUpdateData: priceUpdateData,
                stockAmount: STOCK_AMOUNT,
                dusdAmount: DUSD_AMOUNT,
                feePerPool: INITIAL_UPDATE_FEE
            }))
        );

        console.log("publishTime:", publishTime);
        console.log("CALLDATA:");
        console.logBytes(calldata_);
    }
}
