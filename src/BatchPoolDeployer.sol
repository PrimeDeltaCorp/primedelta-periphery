// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DclexPool} from "dclex-protocol/src/DclexPool.sol";
import {DclexRouter} from "./DclexRouter.sol";
import {Factory} from "dclex-blockchain/contracts/dclex/Factory.sol";
import {DigitalIdentity} from "dclex-blockchain/contracts/dclex/DigitalIdentity.sol";
import {IStock} from "dclex-blockchain/contracts/interfaces/IStock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceOracle} from "dclex-protocol/src/IPriceOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @title BatchPoolDeployer
/// @notice Deploys all DclexPools in a single transaction
/// @dev Requires temporary ownership of router and DEFAULT_ADMIN_ROLE on DigitalIdentity
contract BatchPoolDeployer {
    /// @notice Default base fee rate applied to every newly-deployed pool (0.25%)
    /// @dev When the pool is perfectly balanced the effective fee equals this value
    uint256 public constant DEFAULT_BASE_FEE_RATE = 0.0025 ether;
    /// @notice Default sensitivity parameter (0.2%) controlling how fast the fee rises
    /// with pool imbalance. feeCurveA = sensitivity / 4, feeCurveB = baseFeeRate - sensitivity.
    /// Yields feeCurveA = feeCurveB = 0.0005 ether (5bps each).
    uint256 public constant DEFAULT_SENSITIVITY = 0.002 ether;
    /// @notice Default protocol-fee cut of the swap fee, baked at deploy
    /// so it doesn't need a separate post-deploy admin pass per pool
    /// (dclex-infrastructure#256).
    uint256 public constant DEFAULT_PROTOCOL_FEE_RATE = 0.15 ether;

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    struct DeployParams {
        DclexRouter router;
        Factory factory;
        IERC20 dusdToken;
        IPriceOracle oracle;
        address[] stockAddresses;
        bytes32[] priceFeedIds;
        address finalOwner;
    }

    function deployAllPools(DeployParams calldata params) external {
        require(params.stockAddresses.length == params.priceFeedIds.length, "Length mismatch");

        DigitalIdentity digitalIdentity = DigitalIdentity(address(params.factory.getDID()));
        digitalIdentity.mintAdmin(address(params.router), 2, bytes32(0));

        uint256 feeCurveA = DEFAULT_SENSITIVITY / 4;
        uint256 feeCurveB = DEFAULT_BASE_FEE_RATE - DEFAULT_SENSITIVITY;

        for (uint256 i = 0; i < params.stockAddresses.length; i++) {
            if (params.stockAddresses[i] == address(0)) continue;

            DclexPool pool = new DclexPool(
                IStock(params.stockAddresses[i]),
                params.dusdToken,
                params.oracle,
                params.priceFeedIds[i],
                feeCurveA,
                feeCurveB,
                DEFAULT_PROTOCOL_FEE_RATE,
                params.finalOwner
            );

            params.router.addPool(
                params.stockAddresses[i],
                DclexRouter.PoolType.DCLEX,
                address(pool),
                0
            );
            digitalIdentity.mintAdmin(address(pool), 2, bytes32(0));
        }

        params.router.transferOwnership(params.finalOwner);
    }
}
