// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {FIOraclePoolBatchInitializer} from "src/FIOraclePoolBatchInitializer.sol";

/// @notice Prints freshly-signed initializeAll calldata to be cast-sent
/// directly. Bypasses forge --broadcast/eth_estimateGas, which evaluate the
/// 60s price staleness at an unpredictable block.timestamp and revert; a
/// cast send with an explicit --gas-limit does no estimation, so publishTime
/// (vm.unixTime) stays well under 60s when the single tx mines (~10s).
/// Pool list comes from out/redeploy-fioracle-pools.json (deploy output).
///
/// Flow: forge script RedeployFIOracleAndPools --broadcast  (deploy + wire)
///   ->  FOUNDRY_PROFILE=router-deploy forge script PrintInitCalldata --rpc-url <rpc> --via-ir
///   ->  cast send <batchInit> <CALLDATA> --value <fee*44> --gas-limit 60000000 ...
///   ->  forge script FinalizeFIOracleRedeploy --broadcast  (revoke + handoff)
contract PrintInitCalldata is Script {
    int64 constant MOCK_PRICE = 10_000_000_000;
    int32 constant EXPO = -8;
    uint256 constant STOCK_AMOUNT = 10e18;
    uint256 constant DUSD_AMOUNT = 1_000e6;
    uint256 constant INITIAL_UPDATE_FEE = 0.001 ether;

    function run() external view {
        Factory factory = Factory(vm.envAddress("DCLEX_FACTORY"));
        address dusdAddr = factory.stablecoins("dUSD");
        uint256 adminKey = vm.envUint("ADMIN_PRIVATE_KEY");
        address[] memory poolsJson = vm.parseJsonAddressArray(
            vm.readFile("out/redeploy-fioracle-pools.json"), ".pools"
        );

        string[44] memory syms = ["AMZN","V","JPM","GE","AI","CPNG","DOW","CAT","MRK","AMGN","KO","MSTR","GS","DIS","WMT","NVDA","IBM","MCD","BA","AXP","TRV","CVX","JNJ","AMC","CSCO","HON","BLK","NKE","INTC","MMM","VZ","NFLX","WBA","UNH","TSLA","COIN","AAPL","GOOG","MSFT","META","CRM","GME","PG","HD"];

        address[] memory pools = new address[](44);
        string[] memory symbols = new string[](44);
        bytes32[] memory feedIds = new bytes32[](44);
        bytes[] memory priceUpdateData = new bytes[](44);

        uint64 publishTime = uint64(vm.unixTime() / 1000);
        for (uint256 i = 0; i < 44; i++) {
            // feedId = keccak256(symbol) — the slot the pool reads and the
            // backend signs under. NEVER the FI-broker feed-id.
            bytes32 fid = keccak256(bytes(syms[i]));
            pools[i] = poolsJson[i];
            symbols[i] = syms[i];
            feedIds[i] = fid;
            bytes32 messageHash = keccak256(abi.encodePacked(fid, MOCK_PRICE, EXPO, publishTime));
            bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(adminKey, ethSignedHash);
            priceUpdateData[i] = abi.encodePacked(fid, MOCK_PRICE, EXPO, publishTime, v, r, s);
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
