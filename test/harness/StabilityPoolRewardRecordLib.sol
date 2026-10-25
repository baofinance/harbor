// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {VmSafe} from "forge-std/Vm.sol";

/// @notice Where a stability pool keeps each holder's reward record for each token, and the record read from there.
/// @dev The accumulator's ERC-7201 namespace holds three per-holder mappings, one per layout: V1 (StabilityPool_v1's),
///      V2 (`uint128` pending and claimed, StabilityPool_v2's) and V3 (`uint256` each, StabilityPool_v3's). V2 and V3
///      agree on the namespace's first four members, so the V2 mapping sits at member 3 under both and V3 adds its
///      own at member 4. Read from storage because no version has a view of a record's checkpoint integral.
library StabilityPoolRewardRecordLib {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev The accumulator's ERC-7201 namespace.
    bytes32 internal constant ACCUMULATOR_STORAGE = 0x47ddc56aaabfe9761e2e64ce86720771c5fd1fd7ef0605da74e07d71de0e7900;
    uint256 internal constant V1_OFFSET = 2;
    uint256 internal constant V2_OFFSET = 3;
    uint256 internal constant V3_OFFSET = 4;

    /// @notice One holder's reward record for one token, whatever its layout.
    struct RewardRecord {
        uint256 pending;
        uint256 claimed;
        uint256 timestamp;
        uint256 integral;
    }

    /// @notice First slot of the `[holder][token]` entry of the mapping at member `offset` of the namespace.
    function recordSlot(uint256 offset, address holder, address token) internal pure returns (uint256 slot) {
        bytes32 inner = keccak256(abi.encode(holder, uint256(ACCUMULATOR_STORAGE) + offset));
        slot = uint256(keccak256(abi.encode(token, inner)));
    }

    /// @notice `holder`'s V2 record for `token` in `pool`: pending and claimed packed in one slot, then the timestamp,
    ///         then the integral.
    function v2Record(address pool, address holder, address token) internal view returns (RewardRecord memory record) {
        uint256 base = recordSlot(V2_OFFSET, holder, token);
        uint256 rewards = uint256(vm.load(pool, bytes32(base)));
        record.pending = uint128(rewards);
        record.claimed = rewards >> 128;
        record.timestamp = uint256(vm.load(pool, bytes32(base + 1)));
        record.integral = uint256(vm.load(pool, bytes32(base + 2)));
    }

    /// @notice `holder`'s V3 record for `token` in `pool`: pending, claimed, timestamp and integral, a slot each.
    function v3Record(address pool, address holder, address token) internal view returns (RewardRecord memory record) {
        uint256 base = recordSlot(V3_OFFSET, holder, token);
        record.pending = uint256(vm.load(pool, bytes32(base)));
        record.claimed = uint256(vm.load(pool, bytes32(base + 1)));
        record.timestamp = uint256(vm.load(pool, bytes32(base + 2)));
        record.integral = uint256(vm.load(pool, bytes32(base + 3)));
    }
}
