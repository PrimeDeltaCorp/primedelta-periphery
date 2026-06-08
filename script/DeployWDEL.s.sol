// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {WDEL} from "../src/WDEL.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";

contract DeployWDEL is Script {
    address constant DID = 0x09821e45E9F2Bbefbf85303970010C34d174fE11;

    function run() external {
        vm.startBroadcast();
        WDEL wdel = new WDEL();
        console.log("WDEL deployed:", address(wdel));

        // Mint DID for WDEL contract
        DigitalIdentity(DID).mintAdmin(address(wdel), 2, bytes32(0));
        console.log("DID minted for WDEL");
        vm.stopBroadcast();
    }
}
