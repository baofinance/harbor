// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {StabilityPool_v2} from "@harbor/minter/StabilityPool_v2.sol";

// ═══════════════════════════════════════════════════════════════════════════
// Storage-level demonstration that a uint128-`amount` StabilityPool_v3 layout
// works for BOTH deployment paths, without renaming or touching v2's structs:
//
//   * the "old" layout is StabilityPool_v2's ACTUAL storage (imported, uint104
//     amount) — never copied or renamed;
//   * the "new" layout is a `_v3`-suffixed struct (uint128 amount) aliased over
//     the SAME ERC-7201 slot, reclaiming only amount's former zero padding
//     (slot-0 bytes 29-31), proven compatible by test/StabilityPoolStorageLayout.t.sol.
//
// Two scenarios:
//   1. ZERO-STATE UPGRADE (v2 proxy -> v3): a balance written by v2 (uint104)
//      reads back byte-identical through the v3 layout — no migration.
//   2. FRESH DEPLOYMENT (new market): on storage never touched by v2, the v3
//      layout stores and reads a full uint128 amount above the old ceiling.
// ═══════════════════════════════════════════════════════════════════════════

contract StabilityPoolV3StorageMock {
    // The real StabilityPool ERC-7201 location (`bao.storage.StabilityPool`).
    bytes32 private constant STORAGE_SLOT = 0xcb62d703974340239a82baeadff6ad7af3673eb85d9779bde2587fc9e0e3e400;

    // New v3 TokenBalance: identical fields and 2-slot footprint to v2's, amount widened
    // uint104 -> uint128 (reclaiming the 3 padding bytes of slot 0).
    struct TokenBalance_v3 {
        uint128 product;
        uint128 amount;
        uint40 updatedAt;
    }

    // New v3 storage: same member order/offsets as v2's StabilityPoolStorage, with TokenBalance_v3
    // for the balance members; the unchanged tail reuses v2's ACTUAL types (no copies).
    struct StabilityPoolStorage_v3 {
        TokenBalance_v3 totalAssetSupply;
        mapping(address => TokenBalance_v3) assetBalances;
        mapping(uint256 => TokenBalance_v3) totalAssetSupplyHistory;
        uint256 totalAssetSupplyHistoryLength;
        uint256 lastAssetLossError;
        mapping(address => StabilityPool_v2.WithdrawalRequest) withdrawalRequests;
        StabilityPool_v2.FeePayment feePayment;
    }

    /// @dev v2's ACTUAL storage (uint104 amount) — the layout OZ validation checks; imported, not copied.
    function _v2Storage() private pure returns (StabilityPool_v2.StabilityPoolStorage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    /// @dev v3's wide storage (uint128 amount) over the same slot.
    function _v3Storage() private pure returns (StabilityPoolStorage_v3 storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := STORAGE_SLOT
        }
    }

    // ─── v2 (uint104) access — stands in for what a live v2 pool wrote pre-upgrade ───

    function writeV2Balance(address account, uint128 product, uint104 amount, uint40 updatedAt) external {
        _v2Storage().assetBalances[account] = StabilityPool_v2.TokenBalance(product, amount, updatedAt);
    }

    function readV2Amount(address account) external view returns (uint256 amount) {
        return _v2Storage().assetBalances[account].amount;
    }

    // ─── v3 (uint128) access ───

    function writeV3Balance(address account, uint128 product, uint128 amount, uint40 updatedAt) external {
        _v3Storage().assetBalances[account] = TokenBalance_v3(product, amount, updatedAt);
    }

    function readV3Balance(address account) external view returns (uint128 product, uint256 amount, uint40 updatedAt) {
        TokenBalance_v3 storage b = _v3Storage().assetBalances[account];
        return (b.product, b.amount, b.updatedAt);
    }
}

contract StabilityPoolV3StorageTest is Test {
    StabilityPoolV3StorageMock internal mock;

    function setUp() public {
        mock = new StabilityPoolV3StorageMock();
    }

    /// @notice Scenario 1 — zero-state upgrade. A balance written by v2 (uint104 amount, at the old
    /// boundary) reads back byte-identical through the v3 (uint128) layout: product, amount and
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

    /// @notice The reason the v2 and v3 views must NOT both be used to access amount once it exceeds
    /// uint104: a v3 write above the ceiling is seen by the v2 view as only its low 104 bits — a
    /// valid uint104 (< type(uint104).max), but the wrong value. big = uint104.max + 5e30, so its low
    /// 104 bits are 5e30 - 1. (In v3 the code uses the v3 view exclusively; the v2 layout is retained
    /// only as the OZ-checked declaration.)
    function test_v3WriteAboveCeiling_v2ViewTruncates() public {
        address user = makeAddr("truncateUser");

        uint128 big = uint128(uint256(type(uint104).max) + 5e30);
        mock.writeV3Balance(user, uint128(2e35), big, uint40(222));

        uint256 v2View = mock.readV2Amount(user);
        assertEq(v2View, uint256(big) & uint256(type(uint104).max), "v2 view reads only amount's low 104 bits");
        assertEq(v2View, 5e30 - 1, "the low 104 bits of (uint104.max + 5e30) are 5e30 - 1");
        assertLt(v2View, uint256(type(uint104).max), "the truncated value is itself a valid uint104");
    }
}
