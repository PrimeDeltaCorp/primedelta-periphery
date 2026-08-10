// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.12;

import "forge-std/Test.sol";

/// @notice Derives the DclexRouter callback-sentinel slots from the compiler's
/// own storage layout and pins them to the literals the behavioral sentinel
/// tests write into.
///
/// Why this test exists (read before changing):
/// - `DclexRouter.t.sol::test{Dclex,V3}CallbackRevertsWhileOnly*SentinelSet`
///   guard cross-callback isolation by `vm.store`-ing a fake pool into the
///   the sentinel slots and asserting the wiring took effect. Those are
///   hardcoded slot literals — if the storage layout drifts (an OZ repin, a
///   new state variable, a reorder) the literals silently point at the wrong
///   slot and the "sanity" tests stop testing what they claim to.
/// - This guard reads the ACTUAL layout emitted by the compile
///   (`extra_output = ["storageLayout"]`) and asserts, by variable name, that
///   the sentinels still live where the behavioral tests write. A drift fails
///   here loudly, naming the new slot to reconcile — instead of turning the
///   behavioral guards into no-ops.
/// - No FFI: the artifact is read from ./out (already in fs_permissions).
contract StorageLayoutGuardTest is Test {
    uint256 internal constant DCLEX_SENTINEL_SLOT = 8;
    uint256 internal constant V3_SENTINEL_SLOT = 9;

    function test_sentinelSlotsMatchCompiledLayout() public view {
        string memory json = vm.readFile("out/DclexRouter.sol/DclexRouter.json");
        string[] memory labels = abi.decode(vm.parseJson(json, ".storageLayout.storage[*].label"), (string[]));
        string[] memory slots = abi.decode(vm.parseJson(json, ".storageLayout.storage[*].slot"), (string[]));
        assertEq(labels.length, slots.length, "malformed storageLayout in artifact");

        assertEq(
            _slotOf(labels, slots, "_expectedDclexCallbackPool"),
            DCLEX_SENTINEL_SLOT,
            "_expectedDclexCallbackPool moved: reconcile DCLEX_SENTINEL_SLOT here and the vm.store slot in testV3CallbackRevertsWhileOnlyDclexSentinelSet"
        );
        assertEq(
            _slotOf(labels, slots, "_expectedV3CallbackPool"),
            V3_SENTINEL_SLOT,
            "_expectedV3CallbackPool moved: reconcile V3_SENTINEL_SLOT here and the vm.store slot in testDclexCallbackRevertsWhileOnlyV3SentinelSet"
        );
    }

    function _slotOf(string[] memory labels, string[] memory slots, string memory name)
        internal
        pure
        returns (uint256)
    {
        bytes32 target = keccak256(bytes(name));
        for (uint256 i = 0; i < labels.length; i++) {
            if (keccak256(bytes(labels[i])) == target) return vm.parseUint(slots[i]);
        }
        revert(string.concat(name, " not found in DclexRouter storage layout"));
    }
}
