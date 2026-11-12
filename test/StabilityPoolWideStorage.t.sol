// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {StabilityPool_v2} from "@harbor/minter/StabilityPool_v2.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";

// ═══════════════════════════════════════════════════════════════════════════
// Storage-level demonstration that StabilityPool_v3's REAL StabilityPoolStorage
// (uint128 amount) reads v2's deployed layout: a balance written through the real
// StabilityPool_v2 layout (uint104 amount) reads back byte-identical through the
// real StabilityPool_v3 layout — no migration.
//
// Both real structs are aliased over the SAME ERC-7201 slot. The byte-compatibility
// of the widen is proven at the field level by StabilityPoolStorageLayout.t.sol and
// statically (against the real structs) by bin/storage-successor in validate; this
// shows it at the whole-StabilityPoolStorage level, mappings included.
// ═══════════════════════════════════════════════════════════════════════════

contract StabilityPoolV3StorageMock {
    // The real StabilityPool ERC-7201 location (`bao.storage.StabilityPool`).
    bytes32 private constant STORAGE_SLOT = 0xcb62d703974340239a82baeadff6ad7af3673eb85d9779bde2587fc9e0e3e400;

    /// @dev v2's real storage (uint104 amount) at the slot — stands in for a live v2 pool pre-upgrade.
    function _v2Storage() private pure returns (StabilityPool_v2.StabilityPoolStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    /// @dev v3's real storage (uint128 amount) over the same slot.
    function _v3Storage() private pure returns (StabilityPool_v3.StabilityPoolStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // ─── v2 (uint104) access — stands in for what a live v2 pool wrote pre-upgrade ───

    function writeV2Balance(address account, uint128 product, uint104 amount, uint40 updatedAt) external {
        _v2Storage().assetBalances[account] = StabilityPool_v2.TokenBalance(product, amount, updatedAt);
    }

    function writeV2HistoryRow(uint256 index, uint128 product, uint104 amount, uint40 updatedAt) external {
        _v2Storage().totalAssetSupplyHistory[index] = StabilityPool_v2.TokenBalance(product, amount, updatedAt);
    }

    // ─── v3 (uint128) access ───

    function readV3Balance(
        address account
    ) external view returns (uint128 mantissa, uint256 amount, uint40 unusedInV3, uint64 exponent) {
        StabilityPool_v3.TokenBalance storage b = _v3Storage().assetBalances[account];
        return (b.mantissa, b.amount, b.unusedInV3, b.exponent);
    }

    function readV3HistoryRow(
        uint256 index
    ) external view returns (uint128 mantissa, uint256 amount, uint40 updatedAt, uint64 exponent) {
        StabilityPool_v3.TimestampedBalance storage row = _v3Storage().totalAssetSupplyHistory[index];
        return (row.mantissa, row.amount, row.updatedAt, row.exponent);
    }
}

contract StabilityPoolV3StorageTest is Test {
    StabilityPoolV3StorageMock internal mock;

    function setUp() public {
        mock = new StabilityPoolV3StorageMock();
    }

    /// @notice The zero-state upgrade. A balance written through the v2 (uint104) layout at
    /// the old boundary reads back byte-identical through the v3 (uint128) layout: v2's product as the mantissa, the
    /// amount and v2's updatedAt, now unusedInV3, all preserved, and the exponent zero. Nothing is migrated; v3 simply
    /// reinterprets the same bytes.
    function test_zeroStateUpgrade_v2DataReadsIdenticalUnderV3() public {
        address user = makeAddr("upgradeUser");

        // what a live v2 pool held before the impl was swapped to v3
        mock.writeV2Balance(user, uint128(1e36), type(uint104).max, uint40(1_700_000_000));

        (uint128 mantissa, uint256 amount, uint40 unusedInV3, uint64 exponent) = mock.readV3Balance(user);
        assertEq(mantissa, uint128(1e36), "v2's product reads as the mantissa across the upgrade");
        assertEq(exponent, 0, "and the exponent zero, in bytes v2 never wrote");
        assertEq(amount, uint256(type(uint104).max), "v2 amount reads identical under v3 - no migration");
        assertEq(unusedInV3, uint40(1_700_000_000), "updatedAt preserved as unusedInV3 across the upgrade");
    }

    /// @notice A history row written through the v2 layout, where rows were TokenBalances, reads back
    /// byte-identical through v3's TimestampedBalance rows: v2's product as the mantissa, the amount and updatedAt all
    /// preserved, and the exponent zero.
    function test_zeroStateUpgrade_v2HistoryRowReadsIdenticalUnderV3() public {
        mock.writeV2HistoryRow(3, uint128(1e36), type(uint104).max, uint40(1_700_000_000));

        (uint128 mantissa, uint256 amount, uint40 updatedAt, uint64 exponent) = mock.readV3HistoryRow(3);
        assertEq(mantissa, uint128(1e36), "row's product reads as the mantissa across the upgrade");
        assertEq(exponent, 0, "and the row's exponent zero");
        assertEq(amount, uint256(type(uint104).max), "row's v2 amount reads identical under v3");
        assertEq(updatedAt, uint40(1_700_000_000), "row's updatedAt preserved across the upgrade");
    }
}
