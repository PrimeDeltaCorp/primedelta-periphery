// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @notice Smoke-test helper: prints buyExactInput calldata for a small AMZN
/// buy, with a fresh price signed under keccak256("AMZN") (the slot the pool
/// reads). cast-send it (explicit --gas-limit, no estimation). If it does not
/// revert StalePrice, the redeployed pool's feedId wiring matches the system.
contract PrintSwapCalldata is Script {
    int64 constant MOCK_PRICE = 10_000_000_000; // $100, expo -8
    int32 constant EXPO = -8;

    function run() external view {
        uint256 adminKey = vm.envUint("ADMIN_PRIVATE_KEY");
        uint64 publishTime = uint64(vm.unixTime() / 1000);
        bytes32 fid = keccak256(bytes("AMZN"));

        bytes32 mh = keccak256(abi.encodePacked(fid, MOCK_PRICE, EXPO, publishTime));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(adminKey, MessageHashUtils.toEthSignedMessageHash(mh));
        bytes memory priceData = abi.encodePacked(fid, MOCK_PRICE, EXPO, publishTime, v, r, s);

        bytes[] memory arr = new bytes[](1);
        arr[0] = priceData;

        address amzn = Factory(vm.envAddress("DCLEX_FACTORY")).stocks("AMZN");
        // buyExactInput(token, exactInputAmount=10 dUSD, minOut=0, deadline, priceUpdateData)
        bytes memory cd = abi.encodeWithSignature(
            "buyExactInput(address,uint256,uint256,uint256,bytes[])",
            amzn, uint256(10_000_000), uint256(0), uint256(publishTime + 600), arr
        );
        console.log("AMZN:", amzn);
        console.log("CALLDATA:");
        console.logBytes(cd);
    }
}
