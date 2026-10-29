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
    /// @dev The hash is PER-FACTORY. Probed on-chain 2026-07-27 by CREATE2-deriving
    /// the WDEL/dUSD/3000 pool from a candidate hash and comparing it against what
    /// `Factory.getPool` returns:
    ///
    ///   dev      factory 0x778e8Cad0A010E5E40fE30E0e14e1E11Ee0b74c2 -> 0x717e89ac…
    ///   mainnet  factory 0x3FfFBb81bE72ABFEC5754501BCe441088CBE3e33 -> 0x717e89ac…
    ///   testnet  factory 0x28Fe900fc0Cc1749B132dCE753d5cB5bcA8cF678 -> 0xd1e22371…
    ///   retired dev factory 0x948B3c65… matches neither (a third lineage).
    ///
    /// Pinned to the pool that fixes its protocol fee at 7|7 (PrimeDeltaCorp/v3-core),
    /// which is what a clean, fully recursive checkout compiles to — so
    /// DeployV3Production's fresh-factory guard passes. The factories above predate it.
    ///
    /// ⚠ A periphery-only redeploy against one of the factories above needs that
    /// factory's hash instead; change both this constant and the literal for that run,
    /// or redeploy the factory from a clean checkout. Whatever you pin,
    /// VerifyPoolInitCodeHashLive against the TARGET rpc is the deciding guard.
    bytes32 internal constant CANONICAL =
        0x6c575a9a7db007127bc49abbe264c440708ebe4248bc2932900ebf5868e77134;

    function test_poolInitCodeHashIsPinnedCanonical() public pure {
        assertEq(
            PoolAddress.POOL_INIT_CODE_HASH,
            CANONICAL,
            "PoolAddress.POOL_INIT_CODE_HASH literal does NOT match the canonical value pinned in this test. Either you mutated the literal without updating CANONICAL here (do not), or a fresh V3 factory was deployed and you must re-extract the canonical hash from the new NPM (see PoolAddress.sol natspec) and update BOTH this constant AND the literal."
        );
    }
}
