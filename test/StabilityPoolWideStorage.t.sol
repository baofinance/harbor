// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {StabilityPool_v2} from "@harbor/minter/StabilityPool_v2.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";

// ═══════════════════════════════════════════════════════════════════════════
// Storage-level demonstration that StabilityPool_v3's REAL StabilityPoolStorage
// (uint128 amount) works for BOTH deployment paths over v2's deployed layout:
//
//   * ZERO-STATE UPGRADE (v2 proxy -> v3): a balance written through the real
//     StabilityPool_v2 layout (uint104 amount) reads back byte-identical through
//     the real StabilityPool_v3 layout — no migration.
//   * FRESH DEPLOYMENT (new market): on storage never touched by v2, the v3
//     layout stores and reads a full uint128 amount above the old ceiling.
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

    // ─── v3 (uint128) access ───

    function writeV3Balance(address account, uint128 product, uint128 amount, uint40 updatedAt) external {
        _v3Storage().assetBalances[account] = StabilityPool_v3.TokenBalance(product, amount, updatedAt);
    }

    function readV3Balance(address account) external view returns (uint128 product, uint256 amount, uint40 updatedAt) {
        StabilityPool_v3.TokenBalance storage b = _v3Storage().assetBalances[account];
        return (b.product, b.amount, b.updatedAt);
    }
}

contract StabilityPoolV3StorageTest is Test {
    StabilityPoolV3StorageMock internal mock;

    function setUp() public {
        mock = new StabilityPoolV3StorageMock();
    }

    /// @notice Scenario 1 — zero-state upgrade. A balance written through the v2 (uint104) layout at
    /// the old boundary reads back byte-identical through the v3 (uint128) layout: product, amount and
    /// updatedAt all preserved. Nothing is migrated; v3 simply reinterprets the same bytes.
    function test_zeroStateUpgrade_v2DataReadsIdenticalUnderV3() public {
        address user = makeAddr("upgradeUser");

        // what a live v2 pool held before the impl was swapped to v3
        mock.writeV2Balance(user, uint128(1e36), type(uint104).max, uint40(1_700_000_000));

        (uint128 product, uint256 amount, uint40 updatedAt) = mock.readV3Balance(user);
        assertEq(product, uint128(1e36), "product preserved across the upgrade");
        assertEq(amount, uint256(type(uint104).max), "v2 amount reads identical under v3 - no migration");
        assertEq(updatedAt, uint40(1_700_000_000), "updatedAt preserved across the upgrade");
    }

    /// @notice Scenario 2 — fresh deployment. On storage never written by v2, the v3 layout stores a
    /// full uint128 amount above the old uint104 ceiling and reads it back exactly, with the
    /// product/updatedAt neighbours intact. This is v3 as an initial implementation for a new market.
    function test_freshDeployment_v3StoresFullWidth() public {
        address user = makeAddr("freshUser");

        uint128 bigAmount = uint128(uint256(type(uint104).max) + 9e30); // beyond uint104, inside uint128
        mock.writeV3Balance(user, uint128(3e35), bigAmount, uint40(1_800_000_000));

        (uint128 product, uint256 amount, uint40 updatedAt) = mock.readV3Balance(user);
        assertEq(amount, bigAmount, "fresh v3 stores a full uint128 amount");
        assertEq(product, uint128(3e35), "product neighbour intact");
        assertEq(updatedAt, uint40(1_800_000_000), "updatedAt neighbour intact");
        assertGt(amount, uint256(type(uint104).max), "the stored amount is genuinely beyond the old ceiling");
    }
}
