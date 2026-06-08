// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DclexPositionManager} from "../src/DclexPositionManager.sol";
import {IDID} from "dclex-blockchain/contracts/interfaces/IDID.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {DeployDclex} from "dclex-protocol/script/DeployDclex.s.sol";

// Exposes internal mint/transfer/burn so the DID gate can be exercised
// without spinning up the full V3 factory + pool stack.
contract DclexPositionManagerHarness is DclexPositionManager {
    constructor(
        address factory,
        address weth,
        address descriptor,
        IDID _did
    ) DclexPositionManager(factory, weth, descriptor, _did) {}

    function harness_mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function harness_transfer(address from, address to, uint256 tokenId) external {
        _transfer(from, to, tokenId);
    }

    function harness_burn(uint256 tokenId) external {
        _burn(tokenId);
    }
}

contract DclexPositionManagerTest is Test {
    address constant ADMIN = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    address constant MASTER_ADMIN = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    DclexPositionManagerHarness private npm;
    DigitalIdentity private did;
    address private verifiedA;
    address private verifiedB;
    address private notVerified;

    function setUp() public {
        DeployDclex deployer = new DeployDclex();
        DeployDclex.DclexContracts memory c = deployer.run(ADMIN, MASTER_ADMIN);
        did = c.digitalIdentity;

        npm = new DclexPositionManagerHarness(
            makeAddr("v3Factory"),
            makeAddr("weth"),
            makeAddr("descriptor"),
            IDID(address(did))
        );

        verifiedA = makeAddr("verifiedA");
        verifiedB = makeAddr("verifiedB");
        notVerified = makeAddr("notVerified");

        vm.startPrank(ADMIN);
        did.mintAdmin(verifiedA, 0, bytes32(0));
        did.mintAdmin(verifiedB, 0, bytes32(0));
        vm.stopPrank();
    }

    function testMintToVerifiedSucceeds() public {
        npm.harness_mint(verifiedA, 1);
        assertEq(npm.ownerOf(1), verifiedA);
    }

    function testMintToUnverifiedReverts() public {
        vm.expectRevert(
            DclexPositionManager.DclexPositionManager__TransferNotAllowed.selector
        );
        npm.harness_mint(notVerified, 1);
    }

    function testTransferBetweenVerifiedSucceeds() public {
        npm.harness_mint(verifiedA, 1);
        npm.harness_transfer(verifiedA, verifiedB, 1);
        assertEq(npm.ownerOf(1), verifiedB);
    }

    function testTransferToUnverifiedReverts() public {
        npm.harness_mint(verifiedA, 1);
        vm.expectRevert(
            DclexPositionManager.DclexPositionManager__TransferNotAllowed.selector
        );
        npm.harness_transfer(verifiedA, notVerified, 1);
    }

    function testBurnSkipsDIDCheck() public {
        npm.harness_mint(verifiedA, 1);
        // Burning doesn't require a DID — the position is leaving the system.
        npm.harness_burn(1);
        vm.expectRevert();
        npm.ownerOf(1);
    }
}
