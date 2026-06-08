// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    NonfungiblePositionManager
} from "@uniswap/v3-periphery/contracts/NonfungiblePositionManager.sol";
import {
    IDID
} from "dclex-blockchain/contracts/interfaces/IDID.sol";

/// @title DclexPositionManager
/// @notice Extends NonfungiblePositionManager with DID gating: mints require
///         the recipient to hold a valid DID; transfers require both sides;
///         burns are exempt.
contract DclexPositionManager is NonfungiblePositionManager {
    IDID public immutable did;

    error DclexPositionManager__TransferNotAllowed();

    constructor(
        address _factory,
        address _WETH9,
        address _tokenDescriptor,
        IDID _did
    ) NonfungiblePositionManager(_factory, _WETH9, _tokenDescriptor) {
        did = _did;
    }

    // OZ 5.x exposes only `_update` as virtual on ERC721 — `_mint`/`_transfer`
    // are non-virtual, so DID checks must happen here.
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override returns (address from) {
        from = super._update(to, tokenId, auth);
        if (to == address(0)) {
            return from;
        }
        bool allowed = from == address(0)
            ? did.isValid(did.getId(to))
            : did.verifyTransfer(from, to);
        if (!allowed) {
            revert DclexPositionManager__TransferNotAllowed();
        }
    }
}
