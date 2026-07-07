// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// PrimeDelta audit — STATEFUL INVARIANT FUZZING for WDEL (wrapped-native).
//
// WDEL (src/WDEL.sol) is a canonical WETH9-style wrapper: deposit() mints WDEL
// 1:1 against msg.value, withdraw() burns and returns native 1:1, plus an
// ERC20 surface (transfer/transferFrom) and a `depositAndApprove` convenience.
// It ALSO ships a public, unauthenticated `mint(to, amount)` faucet that is
// gated to `block.chainid == 31337` (audit finding R2-C-35). Forge's default
// test chainid IS 31337, so the faucet is REACHABLE here and mints WDEL with NO
// backing native — the one and only way totalSupply can diverge from the
// contract's native balance. This suite models that precisely.
//
// Handler-based, multi-actor. A WDELHandler drives bounded random deposit /
// withdraw / transfer / depositAndApprove / faucet-mint actions across several
// EOAs, maintaining ghost accounting. The invariant_* methods encode:
//
//   INV-SUP   ERC20 supply identity : totalSupply() == sum of every holder's
//             balance (no wei escapes the ERC20 ledger).                 -> invariant_supplyEqualsHolderSum
//   INV-SOLV  wrapped-native solvency: address(wdel).balance ==
//             totalSupply() - ghost_faucetMinted, i.e. EVERY WDEL is backed
//             1:1 by native EXCEPT the (chainid-gated) faucet mints. With the
//             faucet unused this is the pure WETH invariant nativeBal ==
//             totalSupply.                                               -> invariant_nativeBacksSupply
//   INV-DEP   deposit exactness      : a deposit/depositAndApprove of value V
//             credits the caller EXACTLY V WDEL (never more, never less). -> invariant_depositCreditsExactly
//   INV-WD    withdraw never overpays: a withdraw(amount) returns EXACTLY
//             `amount` native and burns EXACTLY `amount` WDEL — the caller
//             can never pull out more native than the WDEL it wrapped/held. -> invariant_withdrawNeverOverpays
//
// Run:
//   FOUNDRY_EVM_VERSION=cancun forge test \
//       --match-path 'test/invariant/Invariant_WDEL.t.sol' -vvv

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {WDEL} from "../../src/WDEL.sol";

// =============================================================================
//                                  HANDLER
// =============================================================================

/// @notice Bounded-action handler that orchestrates a fixed set of EOA actors
///         against a single WDEL instance. It pranks each actor for
///         deposit/withdraw/transfer so native flows in and out on behalf of a
///         real msg.sender, and calls the unauthenticated faucet directly. Every
///         external call is bounded and wrapped in try/catch; only *successful*
///         calls mutate ghost state. Does NOT inherit forge-std Test so forge
///         doesn't treat it as a test contract.
contract WDELHandler {
    Vm internal constant vm =
        Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    WDEL internal immutable wdel;
    address[] public actors;

    // ---- ghost accounting ----
    // Cumulative WDEL created by the unbacked faucet (the ONLY source of
    // totalSupply that is not covered by native in the contract).
    uint256 public ghost_faucetMinted;

    // Safety flags — must stay false for every invariant to hold.
    bool public ghost_depositMismatch; // INV-DEP: credited != value deposited
    bool public ghost_withdrawOverpaid; // INV-WD : native out > amount burned
    bool public ghost_withdrawMismatch; // INV-WD : native out != WDEL burned

    // Non-vacuity witnesses.
    uint256 public ghost_depositCount;
    uint256 public ghost_withdrawCount;
    uint256 public ghost_transferCount;
    uint256 public ghost_faucetCount;
    uint256 public callCount;

    constructor(WDEL _wdel, address[] memory _actors) {
        wdel = _wdel;
        for (uint256 i = 0; i < _actors.length; ++i) {
            actors.push(_actors[i]);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // ---- local bounding (avoid StdUtils `vm` name clash) ----
    function _bound(
        uint256 x,
        uint256 min,
        uint256 max
    ) internal pure returns (uint256) {
        if (min >= max) return min;
        uint256 size = max - min + 1;
        return min + (x % size);
    }

    function _actor(uint256 s) internal view returns (address) {
        return actors[s % actors.length];
    }

    // ============================ ACTIONS ============================

    /// Wrap native: deposit V and assert the caller was credited EXACTLY V.
    function deposit(uint256 actorSeed, uint256 amtSeed) external {
        callCount++;
        address a = _actor(actorSeed);
        uint256 cap = a.balance;
        if (cap > 1_000 ether) cap = 1_000 ether;
        uint256 v = _bound(amtSeed, 0, cap);

        uint256 balBefore = wdel.balanceOf(a);
        vm.prank(a);
        try wdel.deposit{value: v}() {
            uint256 credited = wdel.balanceOf(a) - balBefore;
            if (credited != v) ghost_depositMismatch = true; // INV-DEP
            ghost_depositCount++;
        } catch {}
    }

    /// Wrap native via the approve-in-one-tx path — same crediting property.
    function depositAndApprove(
        uint256 actorSeed,
        uint256 spenderSeed,
        uint256 amtSeed
    ) external {
        callCount++;
        address a = _actor(actorSeed);
        address spender = _actor(spenderSeed);
        uint256 cap = a.balance;
        if (cap > 1_000 ether) cap = 1_000 ether;
        uint256 v = _bound(amtSeed, 0, cap);

        uint256 balBefore = wdel.balanceOf(a);
        vm.prank(a);
        try wdel.depositAndApprove{value: v}(spender) {
            uint256 credited = wdel.balanceOf(a) - balBefore;
            if (credited != v) ghost_depositMismatch = true; // INV-DEP
            ghost_depositCount++;
        } catch {}
    }

    /// Unwrap native: withdraw `amount` and assert EXACTLY `amount` native came
    /// back and EXACTLY `amount` WDEL was burned (never more).
    function withdraw(uint256 actorSeed, uint256 amtSeed) external {
        callCount++;
        address a = _actor(actorSeed);
        uint256 amount = _bound(amtSeed, 0, wdel.balanceOf(a));

        uint256 nativeBefore = a.balance;
        uint256 wdelBefore = wdel.balanceOf(a);
        vm.prank(a);
        try wdel.withdraw(amount) {
            uint256 nativeOut = a.balance - nativeBefore;
            uint256 wdelBurned = wdelBefore - wdel.balanceOf(a);
            if (nativeOut > amount) ghost_withdrawOverpaid = true; // INV-WD
            if (nativeOut != wdelBurned) ghost_withdrawMismatch = true; // INV-WD
            ghost_withdrawCount++;
        } catch {}
    }

    /// Move WDEL between actors (pure ERC20 transfer — supply/native invariant).
    function transfer(
        uint256 fromSeed,
        uint256 toSeed,
        uint256 amtSeed
    ) external {
        callCount++;
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = _bound(amtSeed, 0, wdel.balanceOf(from));
        vm.prank(from);
        try wdel.transfer(to, amount) {
            ghost_transferCount++;
        } catch {}
    }

    /// The unauthenticated, chainid-gated faucet (R2-C-35). On chainid 31337
    /// (forge default) this SUCCEEDS and mints WDEL with NO backing native — we
    /// record it so the solvency invariant accounts for it exactly.
    function faucetMint(uint256 actorSeed, uint256 amtSeed) external {
        callCount++;
        address a = _actor(actorSeed);
        uint256 amount = _bound(amtSeed, 0, 1_000 ether);
        try wdel.mint(a, amount) {
            ghost_faucetMinted += amount;
            ghost_faucetCount++;
        } catch {}
    }
}

// =============================================================================
//                              INVARIANT SUITE
// =============================================================================

contract Invariant_WDEL is Test {
    WDEL internal wdel;
    WDELHandler internal handler;
    address[] internal actors;

    function setUp() public {
        wdel = new WDEL();

        actors.push(makeAddr("alice"));
        actors.push(makeAddr("bob"));
        actors.push(makeAddr("carol"));
        for (uint256 i = 0; i < actors.length; ++i) {
            vm.deal(actors[i], 1_000_000 ether);
        }

        handler = new WDELHandler(wdel, actors);
        // Fund the handler too — belt-and-suspenders in case a prank routes the
        // value transfer through the executing frame in some forge version.
        vm.deal(address(handler), 1_000_000 ether);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.transfer.selector;
        selectors[3] = handler.depositAndApprove.selector;
        selectors[4] = handler.faucetMint.selector;
        selectors[5] = handler.deposit.selector; // extra weight on wrapping
        targetSelector(
            StdInvariant.FuzzSelector({
                addr: address(handler),
                selectors: selectors
            })
        );
        targetContract(address(handler));
    }

    // ---- shared holder enumeration ----
    function _holderSum() internal view returns (uint256 sum) {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; ++i) {
            sum += wdel.balanceOf(handler.actors(i));
        }
        // Include the two non-actor addresses that could conceivably hold WDEL.
        sum += wdel.balanceOf(address(handler));
        sum += wdel.balanceOf(address(wdel));
    }

    // ---------------------------- INVARIANTS ----------------------------

    /// INV-SUP: the ERC20 ledger is closed — totalSupply equals the sum of every
    /// holder's balance. No wei is minted/burned outside a tracked balance.
    function invariant_supplyEqualsHolderSum() public view {
        assertEq(
            wdel.totalSupply(),
            _holderSum(),
            "SUP: totalSupply != sum of holder balances"
        );
    }

    /// INV-SOLV (core wrapped-native solvency): the native the contract holds
    /// backs the WDEL supply 1:1, EXCEPT for whatever the chainid-gated faucet
    /// (R2-C-35) minted unbacked. i.e. nativeBalance == totalSupply - faucetMinted.
    /// With the faucet unused this is the pure WETH invariant nativeBal == supply.
    function invariant_nativeBacksSupply() public view {
        uint256 supply = wdel.totalSupply();
        uint256 faucet = handler.ghost_faucetMinted();
        assertGe(supply, faucet, "SOLV: faucetMinted exceeds totalSupply");
        assertEq(
            address(wdel).balance,
            supply - faucet,
            "SOLV: native balance != backed supply"
        );
    }

    /// INV-DEP: every deposit credited the caller EXACTLY the value wrapped.
    function invariant_depositCreditsExactly() public view {
        assertFalse(
            handler.ghost_depositMismatch(),
            "DEP: deposit credited != value"
        );
    }

    /// INV-WD: no withdraw ever returned more native than the WDEL it burned.
    function invariant_withdrawNeverOverpays() public view {
        assertFalse(
            handler.ghost_withdrawOverpaid(),
            "WD: withdraw returned more native than burned"
        );
        assertFalse(
            handler.ghost_withdrawMismatch(),
            "WD: native out != WDEL burned"
        );
    }

    function afterInvariant() public view {
        console.log("callCount       :", handler.callCount());
        console.log("depositCount    :", handler.ghost_depositCount());
        console.log("withdrawCount   :", handler.ghost_withdrawCount());
        console.log("transferCount   :", handler.ghost_transferCount());
        console.log("faucetCount     :", handler.ghost_faucetCount());
        console.log("faucetMinted    :", handler.ghost_faucetMinted());
    }

    // ------------------------ DETERMINISTIC PROOFS ------------------------

    /// Non-vacuity: drive every handler action once with fixed seeds so the
    /// assertFalse-style invariants above cannot pass on a no-op campaign, and
    /// confirm the supply/solvency identities hold after a real mixed sequence.
    function test_wdel_handlerNonVacuous() public {
        // wrap 100 native from alice (seed 0) — exact credit.
        handler.deposit(0, 100 ether);
        assertGt(handler.ghost_depositCount(), 0, "no deposit executed");

        // wrap-and-approve 50 native from bob (seed 1) to carol (seed 2).
        handler.depositAndApprove(1, 2, 50 ether);
        assertGt(handler.ghost_depositCount(), 1, "no depositAndApprove executed");

        // move 20 WDEL alice -> bob.
        handler.transfer(0, 1, 20 ether);
        assertGt(handler.ghost_transferCount(), 0, "no transfer executed");

        // unwrap 30 from alice — exact native back.
        handler.withdraw(0, 30 ether);
        assertGt(handler.ghost_withdrawCount(), 0, "no withdraw executed");

        // hit the faucet (chainid 31337) — mints unbacked WDEL to carol.
        handler.faucetMint(2, 500 ether);
        assertGt(handler.ghost_faucetCount(), 0, "faucet did not mint");
        assertEq(
            handler.ghost_faucetMinted(),
            500 ether,
            "faucet ghost mis-tracked"
        );

        // all safety flags clean.
        assertFalse(handler.ghost_depositMismatch(), "deposit mismatch");
        assertFalse(handler.ghost_withdrawOverpaid(), "withdraw overpaid");
        assertFalse(handler.ghost_withdrawMismatch(), "withdraw mismatch");

        // supply + solvency identities hold after the scripted run.
        invariant_supplyEqualsHolderSum();
        invariant_nativeBacksSupply();
    }

    /// R2-C-35 (documented, gated): the unauthenticated faucet mints WDEL with
    /// NO backing native, so it BREAKS the raw WETH solvency invariant
    /// (nativeBalance == totalSupply). This test PROVES that break exists on a
    /// chainid-31337 chain (which is exactly what forge simulates), while
    /// showing it is impossible on the production chains (mint reverts). This is
    /// a latent hazard, not a live product bug: prod chainids (2028/7357) can
    /// never reach the faucet.
    function test_wdel_faucetBreaksRawSolvency() public {
        address a = actors[0];

        // Honest wrap: fully backed.
        vm.prank(a);
        wdel.deposit{value: 10 ether}();
        assertEq(address(wdel).balance, wdel.totalSupply(), "wrap must be backed");

        // Faucet mint on chainid 31337 succeeds and creates UNBACKED supply.
        assertEq(block.chainid, 31337, "forge default chainid changed");
        wdel.mint(a, 7 ether);
        assertEq(wdel.totalSupply(), 17 ether, "faucet did not add supply");
        assertEq(address(wdel).balance, 10 ether, "faucet must not add native");
        // The raw WETH invariant is now BROKEN by exactly the faucet amount.
        assertLt(
            address(wdel).balance,
            wdel.totalSupply(),
            "R2-C-35: faucet should leave supply unbacked"
        );
        assertEq(
            wdel.totalSupply() - address(wdel).balance,
            7 ether,
            "unbacked gap must equal faucet mint"
        );

        // On any production chainid the faucet is unreachable -> raw solvency
        // can never be broken this way.
        vm.chainId(2028);
        vm.expectRevert("WDEL: mint only on local");
        wdel.mint(a, 1 ether);
    }

    /// Deterministic INV-WD edge: withdrawing MORE than balance reverts (caller
    /// can never over-withdraw), and a full-balance withdraw returns exactly the
    /// wrapped native and zeroes both ledgers.
    function test_wdel_withdrawCannotExceedBalance() public {
        address a = actors[1];
        vm.startPrank(a);
        wdel.deposit{value: 5 ether}();

        vm.expectRevert("WDEL: insufficient balance");
        wdel.withdraw(5 ether + 1);

        uint256 nativeBefore = a.balance;
        wdel.withdraw(5 ether);
        vm.stopPrank();
        assertEq(a.balance, nativeBefore + 5 ether, "native out != wrapped");
        assertEq(wdel.balanceOf(a), 0, "WDEL not fully burned");
    }
}
