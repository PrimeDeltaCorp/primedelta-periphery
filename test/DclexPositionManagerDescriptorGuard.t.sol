// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DclexPositionManager} from "../src/DclexPositionManager.sol";
import {DclexNFTDescriptor} from "../src/DclexNFTDescriptor.sol";
import {IDID} from "dclex-blockchain/contracts/interfaces/IDID.sol";

contract DclexPositionManagerDescriptorGuardTest is Test {
    address factory = address(0xF00);
    address weth = address(0xBEEF);
    IDID did = IDID(address(0xD1D));

    function test_constructor_revertsOnZeroDescriptor() public {
        vm.expectRevert(DclexPositionManager.DclexPositionManager__ZeroTokenDescriptor.selector);
        new DclexPositionManager(factory, weth, address(0), did);
    }

    function test_constructor_acceptsAnyNonZeroDescriptor() public {
        DclexNFTDescriptor descriptor = new DclexNFTDescriptor(address(this), "https://x/");
        DclexPositionManager npm = new DclexPositionManager(factory, weth, address(descriptor), did);
        assertEq(address(npm.did()), address(did));
    }
}
