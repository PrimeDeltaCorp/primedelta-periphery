// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {DclexPositionManager} from "../src/DclexPositionManager.sol";
import {DclexNFTDescriptor} from "../src/DclexNFTDescriptor.sol";
import {IDID} from "dclex-blockchain/contracts/interfaces/IDID.sol";

contract RedeployNPMWithDescriptor is Script {
    struct Result {
        address nftDescriptor;
        address positionManager;
    }

    function run(address v3Factory, address wdel, address did) external returns (Result memory result) {
        uint256 adminKey = vm.envUint("ADMIN_PRIVATE_KEY");
        address adminAddr = vm.addr(adminKey);
        string memory nftBaseURI = vm.envString("NFT_BASE_URI");

        console.log("\n=== Redeploying NPM + Descriptor ===");
        console.log("V3 Factory:", v3Factory);
        console.log("WDEL:", wdel);
        console.log("DID:", did);
        console.log("NFT_BASE_URI:", nftBaseURI);

        vm.startBroadcast(adminKey);

        DclexNFTDescriptor descriptor = new DclexNFTDescriptor(adminAddr, nftBaseURI);
        result.nftDescriptor = address(descriptor);
        console.log("DclexNFTDescriptor:", result.nftDescriptor);

        DclexPositionManager npm = new DclexPositionManager(v3Factory, wdel, result.nftDescriptor, IDID(did));
        result.positionManager = address(npm);
        console.log("DclexPositionManager:", result.positionManager);

        vm.stopBroadcast();

        console.log("\n=== Next steps ===");
        console.log("1. Bump UNISWAP_V3_POSITION_MANAGER_ADDRESS in primedelta-gitops");
        console.log("   extra-objects/<env>/primedelta-contracts/values.yaml");
        console.log("2. Existing positions on the old NPM are orphaned (their tokenURI keeps reverting);");
        console.log("   users must burn + remint to migrate.");
    }
}
