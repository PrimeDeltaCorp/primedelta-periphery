// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.12;

import "forge-std/Test.sol";
import {PoolAddress} from "@uniswap/v3-periphery/contracts/libraries/PoolAddress.sol";

/// @notice Pins PoolAddress.POOL_INIT_CODE_HASH to the canonical hash baked
/// into the live UniswapV3Factory.
///
/// Why this test exists (read before changing):
/// - Quoter / SwapRouter / NPM derive pool addresses via CREATE2 using the
///   PoolAddress.POOL_INIT_CODE_HASH literal.
/// - If the literal disagrees with whatever hash the live Factory ACTUALLY
///   used when it created the pools, every quote/swap/mint silently reverts
///   (the periphery contract calls a nonexistent address).
/// - This test does NOT compare against `keccak256(type(UniswapV3Pool).creationCode)`
///   from the local compile — that hash drifts every time lib/v3-core /
///   foundry.toml settings / solc bumps. The local hash is irrelevant for an
///   already-deployed Factory; what matters is the value the Factory was
///   compiled with.
/// - The "canonical" value is extracted ONCE from a live NPM bytecode (see
///   PoolAddress.sol natspec for the extraction recipe) and pinned here.
/// - Run `script/VerifyPoolInitCodeHashLive.s.sol --rpc-url <env>` BEFORE
///   any V3 periphery deploy to confirm it still matches that chain's
///   factory (covers the case where a NEW V3 factory was deployed and this
///   literal must be re-extracted + re-pinned).
contract PoolInitCodeHashTest is Test {
    /// @dev Canonical hash extracted 2026-06-21 from dev DclexPositionManager
    /// 0x02E55935757d38D8b223FE7A450D9a17594a5013 (factory 0x948b3c65…). See
    /// PoolAddress.sol natspec for extraction method. Same value pinned for
    /// testnet — re-verify with VerifyPoolInitCodeHashLive against testnet
    /// RPC before any testnet V3 periphery deploy.
    bytes32 internal constant CANONICAL =
        0x43b6d1c5e800cfcc51ee61b63a623f998e547b3dded375b884f2ae5bffdac20e;

    function test_poolInitCodeHashIsPinnedCanonical() public pure {
        assertEq(
            PoolAddress.POOL_INIT_CODE_HASH,
            CANONICAL,
            "PoolAddress.POOL_INIT_CODE_HASH literal does NOT match the canonical value pinned in this test. Either you mutated the literal without updating CANONICAL here (do not), or a fresh V3 factory was deployed and you must re-extract the canonical hash from the new NPM (see PoolAddress.sol natspec) and update BOTH this constant AND the literal."
        );
    }
}
