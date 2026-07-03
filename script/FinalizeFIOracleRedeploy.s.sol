// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {FIOracle} from "dclex-protocol/src/FIOracle.sol";

/// @notice Final step of the FIOracle-only redeploy, run AFTER the pools are
/// seeded (see PrintInitCalldata.s.sol + cast send). Revokes the batch
/// initializer's temporary Factory admin role and hands FIOracle to the
/// configured price signer (DCLEX_FIORACLE_SIGNER, or the backend signer
/// when unset). None of these calls touch the price staleness path, so a
/// plain forge --broadcast is fine here (unlike seeding).
///
/// Reads addresses from out/redeploy-fioracle-pools.json. Required env:
/// DEPLOYER_PRIVATE_KEY, MASTER_ADMIN_PRIVATE_KEY, DCLEX_FACTORY, DCLEX_ADMIN,
/// DCLEX_BACKEND_SIGNER. Optional: DCLEX_FIORACLE_SIGNER (defaults to
/// DCLEX_BACKEND_SIGNER; set it to separate the price signer from the
/// voucher admin on testnet/prod).
contract FinalizeFIOracleRedeploy is Script {
    function run() external {
        Factory factory = Factory(vm.envAddress("DCLEX_FACTORY"));
        string memory j = vm.readFile("out/redeploy-fioracle-pools.json");
        address batchInit = vm.parseJsonAddress(j, ".batchInit");
        FIOracle fiOracle = FIOracle(vm.parseJsonAddress(j, ".fiOracle"));
        address admin = vm.envAddress("DCLEX_ADMIN");

        vm.startBroadcast(vm.envUint("MASTER_ADMIN_PRIVATE_KEY"));
        factory.revokeRole(0x00, batchInit);
        vm.stopBroadcast();

        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address fiOracleSigner = vm.envOr(
            "DCLEX_FIORACLE_SIGNER", vm.envAddress("DCLEX_BACKEND_SIGNER")
        );
        require(fiOracleSigner != address(0), "DCLEX_FIORACLE_SIGNER is zero");
        vm.startBroadcast(deployerKey);
        fiOracle.setTrustedSigner(fiOracleSigner);
        fiOracle.grantRole(0x00, admin);
        fiOracle.setFeeRecipient(admin);
        fiOracle.renounceRole(0x00, vm.addr(deployerKey));
        vm.stopBroadcast();

        console.log("FIOracle handed to price signer; batch initializer role revoked.");
    }
}
