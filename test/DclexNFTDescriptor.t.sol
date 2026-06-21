// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DclexNFTDescriptor} from "../src/DclexNFTDescriptor.sol";
import {INonfungiblePositionManager} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

contract DclexNFTDescriptorTest is Test {
    address admin = address(0xA11CE);
    address other = address(0xB0B);

    function test_tokenURI_concatenatesBaseURIAndTokenId() public {
        DclexNFTDescriptor d = new DclexNFTDescriptor(admin, "https://api-dev.primedelta.io/nft/positions/");
        string memory uri = d.tokenURI(INonfungiblePositionManager(address(0)), 42);
        assertEq(uri, "https://api-dev.primedelta.io/nft/positions/42/");
    }

    function test_constructor_rejectsBaseURIWithoutTrailingSlash() public {
        vm.expectRevert(DclexNFTDescriptor.DclexNFTDescriptor__MissingTrailingSlash.selector);
        new DclexNFTDescriptor(admin, "https://api-dev.primedelta.io/nft/positions");
    }

    function test_constructor_rejectsZeroAdmin() public {
        vm.expectRevert(DclexNFTDescriptor.DclexNFTDescriptor__ZeroAdmin.selector);
        new DclexNFTDescriptor(address(0), "https://x/");
    }

    function test_setBaseURI_onlyAdmin() public {
        DclexNFTDescriptor d = new DclexNFTDescriptor(admin, "https://a/");
        vm.prank(other);
        vm.expectRevert(DclexNFTDescriptor.DclexNFTDescriptor__NotAdmin.selector);
        d.setBaseURI("https://b/");

        vm.prank(admin);
        d.setBaseURI("https://b/");
        assertEq(d.baseURI(), "https://b/");
    }

    function test_setBaseURI_rejectsMissingSlash() public {
        DclexNFTDescriptor d = new DclexNFTDescriptor(admin, "https://a/");
        vm.prank(admin);
        vm.expectRevert(DclexNFTDescriptor.DclexNFTDescriptor__MissingTrailingSlash.selector);
        d.setBaseURI("https://b");
    }

    function test_transferAdmin_rotatesControl() public {
        DclexNFTDescriptor d = new DclexNFTDescriptor(admin, "https://a/");
        vm.prank(admin);
        d.transferAdmin(other);
        assertEq(d.admin(), other);

        vm.prank(admin);
        vm.expectRevert(DclexNFTDescriptor.DclexNFTDescriptor__NotAdmin.selector);
        d.setBaseURI("https://b/");

        vm.prank(other);
        d.setBaseURI("https://b/");
        assertEq(d.baseURI(), "https://b/");
    }
}
