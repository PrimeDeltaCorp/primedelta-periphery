// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    INonfungibleTokenPositionDescriptor
} from "@uniswap/v3-periphery/contracts/interfaces/INonfungibleTokenPositionDescriptor.sol";
import {
    INonfungiblePositionManager
} from "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

contract DclexNFTDescriptor is INonfungibleTokenPositionDescriptor {
    using Strings for uint256;

    address public admin;
    string public baseURI;

    event BaseURISet(string newBaseURI);
    event AdminTransferred(address indexed from, address indexed to);

    error DclexNFTDescriptor__NotAdmin();
    error DclexNFTDescriptor__ZeroAdmin();
    error DclexNFTDescriptor__MissingTrailingSlash();

    constructor(address _admin, string memory _baseURI) {
        if (_admin == address(0)) revert DclexNFTDescriptor__ZeroAdmin();
        _requireTrailingSlash(_baseURI);
        admin = _admin;
        baseURI = _baseURI;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert DclexNFTDescriptor__NotAdmin();
        _;
    }

    function setBaseURI(string calldata newBaseURI) external onlyAdmin {
        _requireTrailingSlash(newBaseURI);
        baseURI = newBaseURI;
        emit BaseURISet(newBaseURI);
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert DclexNFTDescriptor__ZeroAdmin();
        emit AdminTransferred(admin, newAdmin);
        admin = newAdmin;
    }

    function tokenURI(INonfungiblePositionManager, uint256 tokenId)
        external
        view
        override
        returns (string memory)
    {
        return string(abi.encodePacked(baseURI, tokenId.toString(), "/"));
    }

    function _requireTrailingSlash(string memory uri) private pure {
        bytes memory b = bytes(uri);
        if (b.length == 0 || b[b.length - 1] != "/") {
            revert DclexNFTDescriptor__MissingTrailingSlash();
        }
    }
}
