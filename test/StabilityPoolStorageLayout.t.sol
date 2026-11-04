// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {StabilityPool_v2} from "@harbor/minter/StabilityPool_v2.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";

// ═══════════════════════════════════════════════════════════════════════════
// Runtime proof that widening StabilityPool's TokenBalance.amount from uint104
// (v2, live) to uint128 (v3) is storage-layout compatible: data written under
// the REAL StabilityPool_v2.TokenBalance reads back identically under each REAL
// v3 struct that took over its layout - StabilityPool_v3.TokenBalance (an
// account's record and the total supply) and StabilityPool_v3.TimestampedBalance
// (a history row) - and v3 uses only the bytes that were zero padding in v2.
// This complements bin/storage-successor — which proves the same
// byte-compatibility statically (in validate) against these same structs — with
// an EVM read/write proof, and references the real structs (not copies) so it
// tracks the contracts.
//
// Minimal contracts hold the real structs at the SAME ERC-7201 slot;
// vm.etch swaps the code while the storage persists, so a value written under
// one layout is read under the other.
//
// Field packing (compiler-determined):
//   v2:  slot0 = [product:0-15][amount(104):16-28][pad:29-31] ; slot1 = [updatedAt:0-4]
//   v3:  slot0 = [product:0-15][amount(128):16-31]            ; slot1 = [unusedInV3 or updatedAt:0-4]
// The 3 pad bytes (29-31) of v2's slot0 become amount's high bytes in v3, and
// the slot1 field keeps its own slot in both — so old data is unchanged and the
// widened amount only ever occupies the former padding.
// ═══════════════════════════════════════════════════════════════════════════

// The real StabilityPool ERC-7201 location (`bao.storage.StabilityPool`); all mirrors
// share it so an etch preserves the slot across the code swap.
bytes32 constant LAYOUT_SLOT = 0xcb62d703974340239a82baeadff6ad7af3673eb85d9779bde2587fc9e0e3e400;

/// @dev The v2 mirror's calls: the uint104 layout's three fields.
interface IBalanceLayoutV104 {
    function write(uint128 product, uint104 amount, uint40 slot1Field) external;

    function read() external view returns (uint128 product, uint256 amount, uint40 slot1Field);
}

/// @dev Each v3 mirror's calls: the uint128 layout's three fields, whatever the struct names the third.
interface IBalanceLayoutV128 {
    function write(uint128 product, uint128 amount, uint40 slot1Field) external;

    function read() external view returns (uint128 product, uint256 amount, uint40 slot1Field);
}

/// @dev Reads/writes the REAL StabilityPool_v2.TokenBalance (uint104 amount) at the named-storage slot.
contract TokenBalanceLayoutV104 is IBalanceLayoutV104 {
    function _slot() private pure returns (StabilityPool_v2.TokenBalance storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := LAYOUT_SLOT
        }
    }

    function write(uint128 product, uint104 amount, uint40 slot1Field) external {
        StabilityPool_v2.TokenBalance storage $ = _slot();
        $.product = product;
        $.amount = amount;
        $.updatedAt = slot1Field;
    }

    function read() external view returns (uint128 product, uint256 amount, uint40 slot1Field) {
        StabilityPool_v2.TokenBalance storage $ = _slot();
        return ($.product, $.amount, $.updatedAt);
    }
}

/// @dev Reads/writes the REAL StabilityPool_v3.TokenBalance (uint128 amount) at the same slot.
contract TokenBalanceLayoutV128 is IBalanceLayoutV128 {
    function _slot() private pure returns (StabilityPool_v3.TokenBalance storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := LAYOUT_SLOT
        }
    }

    function write(uint128 product, uint128 amount, uint40 slot1Field) external {
        StabilityPool_v3.TokenBalance storage $ = _slot();
        $.product = product;
        $.amount = amount;
        $.unusedInV3 = slot1Field;
    }

    function read() external view returns (uint128 product, uint256 amount, uint40 slot1Field) {
        StabilityPool_v3.TokenBalance storage $ = _slot();
        return ($.product, $.amount, $.unusedInV3);
    }
}

/// @dev Reads/writes the REAL StabilityPool_v3.TimestampedBalance (uint128 amount) at the same slot.
contract TimestampedBalanceLayoutV128 is IBalanceLayoutV128 {
    function _slot() private pure returns (StabilityPool_v3.TimestampedBalance storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := LAYOUT_SLOT
        }
    }

    function write(uint128 product, uint128 amount, uint40 slot1Field) external {
        StabilityPool_v3.TimestampedBalance storage $ = _slot();
        $.product = product;
        $.amount = amount;
        $.updatedAt = slot1Field;
    }

    function read() external view returns (uint128 product, uint256 amount, uint40 slot1Field) {
        StabilityPool_v3.TimestampedBalance storage $ = _slot();
        return ($.product, $.amount, $.updatedAt);
    }
}

contract StabilityPoolStorageLayoutTest is Test {
    address internal slot;
    bytes internal v104Code;
    /// @dev The v3 structs that took over v2's TokenBalance layout, with their names for the assertion messages.
    bytes[2] internal v128Codes;
    string[2] internal v128Names = ["TokenBalance", "TimestampedBalance"];

    function setUp() public {
        slot = makeAddr("tokenBalanceSlot");
        v104Code = address(new TokenBalanceLayoutV104()).code;
        v128Codes[0] = address(new TokenBalanceLayoutV128()).code;
        v128Codes[1] = address(new TimestampedBalanceLayoutV128()).code;
    }

    /// @notice A TokenBalance written under the v2 (uint104) layout reads back byte-for-byte
    /// identical under each v3 (uint128) struct — product, amount and the slot-1 field all preserved.
    /// Uses amount = type(uint104).max (the boundary value most likely to expose a packing error).
    function test_v104WrittenReadsIdenticalUnderV128() public {
        uint128 product = uint128(1e36); // DFP-scale product occupying the full low 128 bits
        uint104 amount = type(uint104).max;
        uint40 slot1Field = uint40(1_234_567_890);

        for (uint256 i = 0; i < v128Codes.length; i++) {
            vm.etch(slot, v104Code);
            IBalanceLayoutV104(slot).write(product, amount, slot1Field);

            vm.etch(slot, v128Codes[i]); // storage persists across the code swap
            (uint128 p, uint256 a, uint40 t) = IBalanceLayoutV128(slot).read();

            assertEq(p, product, string.concat(v128Names[i], ": product identical across the widening"));
            assertEq(a, amount, string.concat(v128Names[i], ": v104 amount reads back exactly under uint128"));
            assertEq(t, slot1Field, string.concat(v128Names[i], ": the slot-1 field untouched by the widened amount"));
        }
    }

    /// @notice The widened field uses exactly the bytes that were zero padding in v2: a write through
    /// each v3 struct above the old uint104 ceiling, read back under the v2 layout, yields only the low
    /// 104 bits of the amount and the product and slot-1 field as written — proving the reclaimed high
    /// bytes are amount's, not a neighbour's.
    function test_v128UsesReclaimedPaddingBytes() public {
        uint128 product = uint128(2e35);
        uint128 amount = uint128(uint256(type(uint104).max) + 7e30); // above uint104, inside uint128
        uint40 slot1Field = uint40(999_999);

        for (uint256 i = 0; i < v128Codes.length; i++) {
            vm.etch(slot, v128Codes[i]);
            IBalanceLayoutV128(slot).write(product, amount, slot1Field);

            vm.etch(slot, v104Code); // read the same storage under the old layout
            (uint128 productUnderV2, uint256 aTruncated, uint40 slot1FieldUnderV2) = IBalanceLayoutV104(slot).read();
            assertEq(productUnderV2, product, string.concat(v128Names[i], ": the v2 layout reads the product written"));
            assertEq(slot1FieldUnderV2, slot1Field, string.concat(v128Names[i], ": and the slot-1 field"));
            assertEq(
                aTruncated,
                uint256(amount) & uint256(type(uint104).max),
                string.concat(
                    v128Names[i],
                    ": v2 layout sees only amount's low 104 bits - the reclaimed bytes are its own"
                )
            );
        }
    }

    // Views of the SAME storage slot, one per real struct — the layout claim reduced to its
    // essence: no etch, no code swap, just the compiler's packing of the structs against one slot.

    function _slotV104() private pure returns (StabilityPool_v2.TokenBalance storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := LAYOUT_SLOT
        }
    }

    function _slotV128() private pure returns (StabilityPool_v3.TokenBalance storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := LAYOUT_SLOT
        }
    }

    function _slotTimestamped() private pure returns (StabilityPool_v3.TimestampedBalance storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := LAYOUT_SLOT
        }
    }

    /// @notice The v2 struct and both v3 structs pack identically over one physical slot: writing through
    /// the uint104 view and reading through each uint128 view yields the same product/amount/slot-1 field
    /// (old data preserved), and a uint128 write above the old ceiling is seen by the uint104 view as
    /// only its low 104 bits (the widened bytes are amount's own former padding). Same proof as the
    /// etch tests, with the code swap removed.
    function test_v104AndV128StructViewsShareStorage() public {
        StabilityPool_v2.TokenBalance storage v104 = _slotV104();
        v104.product = uint128(1e36);
        v104.amount = type(uint104).max;
        v104.updatedAt = uint40(1_234_567_890);

        StabilityPool_v3.TokenBalance storage v128 = _slotV128();
        assertEq(v128.product, uint128(1e36), "product identical across the two struct views");
        assertEq(uint256(v128.amount), uint256(type(uint104).max), "v104-written amount reads identical under uint128");
        assertEq(v128.unusedInV3, uint40(1_234_567_890), "updatedAt reads identical as unusedInV3");

        StabilityPool_v3.TimestampedBalance storage timestamped = _slotTimestamped();
        assertEq(timestamped.product, uint128(1e36), "product identical under TimestampedBalance");
        assertEq(uint256(timestamped.amount), uint256(type(uint104).max), "amount identical under TimestampedBalance");
        assertEq(timestamped.updatedAt, uint40(1_234_567_890), "updatedAt identical under TimestampedBalance");

        // widen beyond the old ceiling through the v128 view; neighbours stay put and the v104 view
        // sees only the low 104 bits, proving the reclaimed bytes are amount's own high bytes.
        v128.amount = uint128(uint256(type(uint104).max) + 7e30);
        assertEq(v128.product, uint128(1e36), "product neighbour untouched by the high amount bytes");
        assertEq(v128.unusedInV3, uint40(1_234_567_890), "unusedInV3 neighbour untouched by the high amount bytes");
        assertEq(
            uint256(timestamped.amount),
            uint256(type(uint104).max) + 7e30,
            "TimestampedBalance reads the whole widened amount"
        );
        assertEq(
            uint256(v104.amount),
            (uint256(type(uint104).max) + 7e30) & uint256(type(uint104).max),
            "v104 view sees only amount's low 104 bits"
        );
    }
}
