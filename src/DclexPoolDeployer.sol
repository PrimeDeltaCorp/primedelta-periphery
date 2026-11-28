// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Security} from "dclex-blockchain/contracts/dclex/Security.sol";
import {IPoolDeployer} from "dclex-blockchain/contracts/interfaces/IPoolDeployer.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {IPriceOracle} from "dclex-protocol/src/IPriceOracle.sol";
import {DclexRouter} from "./DclexRouter.sol";

contract DclexPoolDeployer is Security, IPoolDeployer {
    uint256 public constant FEE_CURVE_A = 0.0005 ether;
    uint256 public constant FEE_CURVE_B = 0.0005 ether;
    uint256 public constant PROTOCOL_FEE_RATE = 0.15 ether;
    uint256 private constant DID_NOT_PRO = 2;

    DclexRouter public immutable router;
    address public poolAdmin;
    address public feeRecipient;
    address public initializer;

    constructor(
        DclexRouter _router,
        address _poolAdmin,
        address _feeRecipient,
        address _initializer
    ) {
        router = _router;
        poolAdmin = _poolAdmin;
        feeRecipient = _feeRecipient;
        initializer = _initializer;
    }

    function setPoolConfig(
        address _poolAdmin,
        address _feeRecipient,
        address _initializer
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        poolAdmin = _poolAdmin;
        feeRecipient = _feeRecipient;
        initializer = _initializer;
    }

    function deployPool(
        address stock
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (address) {
        return _deployPool(stock);
    }

    function deployPools(
        address[] calldata stocks
    ) external onlyRole(DEFAULT_ADMIN_ROLE) returns (address[] memory pools) {
        pools = new address[](stocks.length);
        for (uint256 i = 0; i < stocks.length; ++i) {
            pools[i] = _deployPool(stocks[i]);
        }
    }

    function _deployPool(address stock) private returns (address pool) {
        pool = address(
            new DclexPool(
                IStock(stock),
                router.stablecoin(),
                IPriceOracle(router.dclexOracle()),
                FEE_CURVE_A,
                FEE_CURVE_B,
                PROTOCOL_FEE_RATE,
                poolAdmin,
                feeRecipient,
                initializer
            )
        );
        IStock(stock).DID().mintAdmin(pool, DID_NOT_PRO, bytes32(0));
        router.registerDclexPool(stock, pool);
    }
}
