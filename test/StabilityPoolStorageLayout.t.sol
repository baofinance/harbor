// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {DecrementalFloatingPoint} from "@harbor/math/DecrementalFloatingPoint.sol";
import {LossProduct, LossProductLib} from "@harbor/math/LossProductLib.sol";
import {StabilityPool_v2} from "@harbor/minter/StabilityPool_v2.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
// the v2 accumulator, which the deployed v2 pools inherit; its contract is named without a version
import {MultipleRewardCompoundingAccumulator as MultipleRewardCompoundingAccumulator_v2} from "@harbor/reward/accumulator/MultipleRewardCompoundingAccumulator_v2.sol";
import {MultipleRewardCompoundingAccumulator_v3} from "@harbor/reward/accumulator/MultipleRewardCompoundingAccumulator_v3.sol";

import {MockStabilityPool} from "@harbor-test/mocks/MockStabilityPool.sol";

// ═══════════════════════════════════════════════════════════════════════════
// Runtime proof that StabilityPool_v3's records are storage-layout compatible with v2's: data written under the
// REAL StabilityPool_v2.TokenBalance reads back identically under each REAL v3 struct that took over its layout -
// StabilityPool_v3.TokenBalance (an account's record, the total supply, a fee-free record) and
// StabilityPool_v3.TimestampedBalance (a history row) - and v3 uses only bytes v2 left unused. And that the pool's
// reader and writer of a record's loss product put the pair where the layout says, and read v2's records as the
// pair they held. This complements bin/storage-successor, which proves the same byte-compatibility statically (in
// validate) against these same structs, with an EVM read/write proof, and references the real structs (not copies)
// so it tracks the contracts.
//
// Minimal contracts hold the real structs at the SAME ERC-7201 slot;
// vm.etch swaps the code while the storage persists, so a value written under
// one layout is read under the other.
//
// Field packing (compiler-determined):
//   v2:  slot0 = [product:0-15][amount(104):16-28][pad:29-31] ; slot1 = [updatedAt:0-4]
//   v3:  slot0 = [mantissa:0-15][amount(128):16-31]           ; slot1 = [unusedInV3 or updatedAt:0-4][exponent:5-12]
// The 3 pad bytes (29-31) of v2's slot0 become amount's high bytes in v3, and v3's exponent takes slot-1 bytes v2
// never wrote, so old data is unchanged and the new bytes only ever occupy what v2 left unused. v2's product was
// its exponent in byte 15 above a 15-byte magnitude; v3 reads the 16 bytes as the mantissa, which is v2's
// magnitude wherever v2's exponent is zero.
// ═══════════════════════════════════════════════════════════════════════════

// The real StabilityPool ERC-7201 location (`bao.storage.StabilityPool`); all mirrors
// share it so an etch preserves the slot across the code swap.
bytes32 constant LAYOUT_SLOT = 0xcb62d703974340239a82baeadff6ad7af3673eb85d9779bde2587fc9e0e3e400;

// The real accumulator ERC-7201 location (`bao.storage.MultipleRewardCompoundingAccumulator`), the same in v2 and v3.
bytes32 constant ACCUMULATOR_SLOT = 0x47ddc56aaabfe9761e2e64ce86720771c5fd1fd7ef0605da74e07d71de0e7900;

/// @dev The v2 mirror's calls: the uint104 layout's three fields.
interface IBalanceLayoutV104 {
    function write(uint128 product, uint104 amount, uint40 slot1Field) external;

    function read() external view returns (uint128 product, uint256 amount, uint40 slot1Field);
}

/// @dev Each v3 mirror's calls: the v3 layout's four fields, whatever the struct names the third.
interface IBalanceLayoutV3 {
    function write(uint128 mantissa, uint128 amount, uint40 slot1Field, uint64 exponent) external;

    function read() external view returns (uint128 mantissa, uint256 amount, uint40 slot1Field, uint64 exponent);
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

/// @dev Reads/writes the REAL StabilityPool_v3.TokenBalance at the same slot.
contract TokenBalanceLayoutV3 is IBalanceLayoutV3 {
    function _slot() private pure returns (StabilityPool_v3.TokenBalance storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := LAYOUT_SLOT
        }
    }

    function write(uint128 mantissa, uint128 amount, uint40 slot1Field, uint64 exponent) external {
        StabilityPool_v3.TokenBalance storage $ = _slot();
        $.mantissa = mantissa;
        $.amount = amount;
        $.unusedInV3 = slot1Field;
        $.exponent = exponent;
    }

    function read() external view returns (uint128 mantissa, uint256 amount, uint40 slot1Field, uint64 exponent) {
        StabilityPool_v3.TokenBalance storage $ = _slot();
        return ($.mantissa, $.amount, $.unusedInV3, $.exponent);
    }
}

/// @dev Reads/writes the REAL StabilityPool_v3.TimestampedBalance at the same slot.
contract TimestampedBalanceLayoutV3 is IBalanceLayoutV3 {
    function _slot() private pure returns (StabilityPool_v3.TimestampedBalance storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := LAYOUT_SLOT
        }
    }

    function write(uint128 mantissa, uint128 amount, uint40 slot1Field, uint64 exponent) external {
        StabilityPool_v3.TimestampedBalance storage $ = _slot();
        $.mantissa = mantissa;
        $.amount = amount;
        $.updatedAt = slot1Field;
        $.exponent = exponent;
    }

    function read() external view returns (uint128 mantissa, uint256 amount, uint40 slot1Field, uint64 exponent) {
        StabilityPool_v3.TimestampedBalance storage $ = _slot();
        return ($.mantissa, $.amount, $.updatedAt, $.exponent);
    }
}

/// @dev Writes a reward integral through the REAL v2 accumulator struct, whose exponent key is a uint8.
contract IntegralLayoutV2 {
    function _slot()
        private
        pure
        returns (MultipleRewardCompoundingAccumulator_v2.MultipleRewardCompoundingAccumulatorStorage storage $)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := ACCUMULATOR_SLOT
        }
    }

    function write(address token, uint8 exponent, uint256 integral) external {
        _slot().tokenToExponentToIntegral[token][exponent] = integral;
    }
}

/// @dev Reads a reward integral through the REAL v3 accumulator struct, whose exponent key is a uint64.
contract IntegralLayoutV3 {
    function _slot()
        private
        pure
        returns (MultipleRewardCompoundingAccumulator_v3.MultipleRewardCompoundingAccumulatorStorage storage $)
    {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := ACCUMULATOR_SLOT
        }
    }

    function read(address token, uint64 exponent) external view returns (uint256) {
        return _slot().tokenToExponentToIntegral[token][exponent];
    }
}

contract StabilityPoolStorageLayoutTest is Test {
    address internal slot;
    bytes internal v104Code;
    /// @dev The v3 structs that took over v2's TokenBalance layout, with their names for the assertion messages.
    bytes[2] internal v3Codes;
    string[2] internal v3Names = ["TokenBalance", "TimestampedBalance"];

    /// @dev A pool, not behind a proxy, whose own storage holds the records its reader and writer are tested on.
    address internal pool;
    address internal holder = makeAddr("holder");

    function setUp() public {
        slot = makeAddr("tokenBalanceSlot");
        v104Code = address(new TokenBalanceLayoutV104()).code;
        v3Codes[0] = address(new TokenBalanceLayoutV3()).code;
        v3Codes[1] = address(new TimestampedBalanceLayoutV3()).code;
        pool = address(
            new MockStabilityPool(makeAddr("minter"), makeAddr("pegged"), 1 days, 1 days, 1 ether, "pool", "POOL")
        );
    }

    /// @notice A TokenBalance written under the v2 (uint104) layout reads back byte-for-byte identical under each v3
    /// struct: v2's product as the mantissa, the amount and the slot-1 field all preserved, and the exponent zero.
    /// Uses amount = type(uint104).max (the boundary value most likely to expose a packing error).
    function test_v104WrittenReadsIdenticalUnderV3() public {
        uint128 product = uint128(1e36); // a product at exponent zero, its magnitude taking 120 bits
        uint104 amount = type(uint104).max;
        uint40 slot1Field = uint40(1_234_567_890);

        for (uint256 i = 0; i < v3Codes.length; i++) {
            vm.etch(slot, v104Code);
            IBalanceLayoutV104(slot).write(product, amount, slot1Field);

            vm.etch(slot, v3Codes[i]); // storage persists across the code swap
            (uint128 m, uint256 a, uint40 t, uint64 e) = IBalanceLayoutV3(slot).read();

            assertEq(m, product, string.concat(v3Names[i], ": v2's product reads as the mantissa"));
            assertEq(a, amount, string.concat(v3Names[i], ": v104 amount reads back exactly under uint128"));
            assertEq(t, slot1Field, string.concat(v3Names[i], ": the slot-1 field untouched by the widened amount"));
            assertEq(e, 0, string.concat(v3Names[i], ": the exponent is in bytes v2 never wrote"));
        }
    }

    /// @notice The new bytes are ones v2 left unused: a write through each v3 struct with an amount above the old
    /// uint104 ceiling and an exponent, read back under the v2 layout, yields only the low 104 bits of the amount,
    /// and the product and slot-1 field as written - proving the reclaimed high bytes are amount's, and the exponent's
    /// bytes are no neighbour's.
    function test_v3UsesOnlyBytesV2LeftUnused() public {
        uint128 mantissa = uint128(2e35);
        uint128 amount = uint128(uint256(type(uint104).max) + 7e30); // above uint104, inside uint128
        uint40 slot1Field = uint40(999_999);
        uint64 exponent = type(uint64).max;

        for (uint256 i = 0; i < v3Codes.length; i++) {
            vm.etch(slot, v3Codes[i]);
            IBalanceLayoutV3(slot).write(mantissa, amount, slot1Field, exponent);

            vm.etch(slot, v104Code); // read the same storage under the old layout
            (uint128 productUnderV2, uint256 aTruncated, uint40 slot1FieldUnderV2) = IBalanceLayoutV104(slot).read();
            assertEq(productUnderV2, mantissa, string.concat(v3Names[i], ": the v2 layout reads the mantissa written"));
            assertEq(slot1FieldUnderV2, slot1Field, string.concat(v3Names[i], ": and the slot-1 field"));
            assertEq(
                aTruncated,
                uint256(amount) & uint256(type(uint104).max),
                string.concat(
                    v3Names[i],
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

    function _slotV3() private pure returns (StabilityPool_v3.TokenBalance storage $) {
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

    /// @notice The v2 struct and both v3 structs pack identically over one physical slot: writing through the
    /// uint104 view and reading through each v3 view yields the same product, amount and slot-1 field (old data
    /// preserved), and v3 writes of a high amount and of an exponent are seen by the uint104 view only as the
    /// amount's low 104 bits (the widened bytes are amount's own former padding, the exponent's are no field's).
    /// Same proof as the etch tests, with the code swap removed.
    function test_v104AndV3StructViewsShareStorage() public {
        StabilityPool_v2.TokenBalance storage v104 = _slotV104();
        v104.product = uint128(1e36);
        v104.amount = type(uint104).max;
        v104.updatedAt = uint40(1_234_567_890);

        StabilityPool_v3.TokenBalance storage v3 = _slotV3();
        assertEq(v3.mantissa, uint128(1e36), "v2's product reads as the mantissa");
        assertEq(uint256(v3.amount), uint256(type(uint104).max), "v104-written amount reads identical under uint128");
        assertEq(v3.unusedInV3, uint40(1_234_567_890), "updatedAt reads identical as unusedInV3");
        assertEq(v3.exponent, 0, "the exponent is in bytes v2 never wrote");

        StabilityPool_v3.TimestampedBalance storage timestamped = _slotTimestamped();
        assertEq(timestamped.mantissa, uint128(1e36), "product identical under TimestampedBalance");
        assertEq(uint256(timestamped.amount), uint256(type(uint104).max), "amount identical under TimestampedBalance");
        assertEq(timestamped.updatedAt, uint40(1_234_567_890), "updatedAt identical under TimestampedBalance");
        assertEq(timestamped.exponent, 0, "and its exponent zero");

        // widen beyond the old ceiling and write an exponent through the v3 view; neighbours stay put and the v104
        // view sees only the low 104 bits, proving the reclaimed bytes are amount's own high bytes.
        v3.amount = uint128(uint256(type(uint104).max) + 7e30);
        v3.exponent = 300;
        assertEq(v3.mantissa, uint128(1e36), "mantissa neighbour untouched by the high amount bytes");
        assertEq(v3.unusedInV3, uint40(1_234_567_890), "unusedInV3 neighbour untouched by the exponent");
        assertEq(timestamped.exponent, 300, "TimestampedBalance reads the exponent at the same bytes");
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
        assertEq(v104.updatedAt, uint40(1_234_567_890), "v104 view sees its updatedAt, not the exponent");
    }

    // ── the pool's reader and writer of a record's loss product, on a real pool's storage ──

    /// @dev The first slot of `holder`'s record in the pool: `assetBalances` is the namespace struct's member after
    ///      `totalAssetSupply`, which takes two slots.
    function _holderRecordSlot() private view returns (bytes32) {
        return keccak256(abi.encode(holder, uint256(LAYOUT_SLOT) + 2));
    }

    /// @dev Writes `holder`'s record in the pool as v2 writes it: the two words the real v2 struct lays out.
    function _writeV2Record(uint128 product, uint104 amount, uint40 updatedAt) private {
        vm.etch(slot, v104Code);
        IBalanceLayoutV104(slot).write(product, amount, updatedAt);
        bytes32 recordSlot = _holderRecordSlot();
        vm.store(pool, recordSlot, vm.load(slot, LAYOUT_SLOT));
        vm.store(pool, bytes32(uint256(recordSlot) + 1), vm.load(slot, bytes32(uint256(LAYOUT_SLOT) + 1)));
    }

    /// @notice A record v2 wrote reads as the pair it held: exponent zero and v2's magnitude, whatever the magnitude.
    /// The magnitudes are a product of one, the smallest a deployed pool held when checked (ETH::fxUSD's collateral
    /// pool), and the least a product can hold.
    function test_aRecordWrittenByV2_readsAsThePairAtExponentZero() public {
        uint120[3] memory magnitudes = [uint120(1e36), uint120(1.405876e35), uint120(1)];
        for (uint256 i = 0; i < magnitudes.length; i++) {
            _writeV2Record(DecrementalFloatingPoint.encode(0, magnitudes[i]), 1_000 ether, 1_700_000_000);

            LossProduct product = MockStabilityPool(pool).__accountProduct(holder);

            assertEq(product.exponent(), 0, "the exponent is zero");
            assertEq(product.mantissa(), magnitudes[i], "the mantissa is v2's magnitude");
        }
    }

    /// @notice The writer puts the pair where the layout says, over a record v2 wrote: the mantissa in bytes 0 to 14
    /// of the first slot with byte 15 zero, the amount untouched, the exponent in bytes 5 to 12 of the second slot,
    /// and v2's timestamp in bytes 0 to 4 as it was.
    function test_aPairWrittenToARecord_isWhereTheLayoutSays() public {
        _writeV2Record(DecrementalFloatingPoint.encode(0, 1e36), 1_000 ether, 1_700_000_000);

        MockStabilityPool(pool).__setAccountProduct(holder, LossProductLib.from(300, 123_456_789e27));

        uint256 first = uint256(vm.load(pool, _holderRecordSlot()));
        uint256 second = uint256(vm.load(pool, bytes32(uint256(_holderRecordSlot()) + 1)));
        assertEq(first & type(uint120).max, 123_456_789e27, "the mantissa in bytes 0 to 14");
        assertEq((first >> 120) & 0xff, 0, "byte 15, v2's exponent, zero");
        assertEq(first >> 128, 1_000 ether, "the amount untouched");
        assertEq(second & type(uint40).max, 1_700_000_000, "v2's timestamp in bytes 0 to 4 as it was");
        assertEq((second >> 40) & type(uint64).max, 300, "the exponent in bytes 5 to 12");
        assertEq(second >> 104, 0, "nothing in bytes 13 to 31");
    }

    /// @notice A withdrawal request copies the holder's record into the fee-free record, laid out as a balance record:
    /// the amount and the mantissa in the first slot, the exponent in bytes 5 to 12 of the second, and bytes 0 to 4,
    /// a balance record's `unusedInV3`, never written. `withdrawalFeeFree` is the namespace struct's tenth slot member
    /// (`totalAssetSupply` takes two).
    function test_aFeeFreeRecord_isLaidOutAsABalanceRecord() public {
        _writeV2Record(DecrementalFloatingPoint.encode(0, 1e36), 1_000 ether, 1_700_000_000);
        MockStabilityPool(pool).__setAccountProduct(holder, LossProductLib.from(300, 123_456_789e27));

        vm.startPrank(holder);
        IStabilityPool_v3(pool).requestWithdrawal();
        vm.stopPrank();

        bytes32 feeFreeSlot = keccak256(abi.encode(holder, uint256(LAYOUT_SLOT) + 9));
        uint256 first = uint256(vm.load(pool, feeFreeSlot));
        uint256 second = uint256(vm.load(pool, bytes32(uint256(feeFreeSlot) + 1)));
        assertEq(first & type(uint128).max, 123_456_789e27, "the mantissa in bytes 0 to 15, byte 15 zero");
        assertEq(first >> 128, 1_000 ether, "the amount in bytes 16 to 31");
        assertEq(second & type(uint40).max, 0, "bytes 0 to 4 never written");
        assertEq(second >> 40, 300, "the exponent in bytes 5 to 12, nothing above");
    }

    /// @notice Any pair the writer writes, the reader reads back: every exponent, every mantissa.
    function testFuzz_aPairWrittenToARecord_readsBack(uint64 exponent, uint120 mantissa) public {
        MockStabilityPool(pool).__setAccountProduct(holder, LossProductLib.from(exponent, mantissa));

        LossProduct product = MockStabilityPool(pool).__accountProduct(holder);

        assertEq(product.exponent(), exponent, "the exponent read back");
        assertEq(product.mantissa(), mantissa, "the mantissa read back");
    }

    /// @notice The reward integrals' exponent key is widened in place: an integral v2 wrote under its uint8 key is the
    /// one v3 reads under its uint64 key, at every exponent a uint8 holds, and v3 reads nothing at an exponent v2 did
    /// not write.
    function test_anIntegralWrittenUnderTheByteKey_isReadUnderTheWideKey() public {
        address token = makeAddr("rewardToken");
        bytes memory v2Code = address(new IntegralLayoutV2()).code;
        bytes memory v3Code = address(new IntegralLayoutV3()).code;
        uint8[3] memory exponents = [0, 5, type(uint8).max];
        for (uint256 i = 0; i < exponents.length; i++) {
            vm.etch(slot, v2Code);
            IntegralLayoutV2(slot).write(token, exponents[i], 1e50 + i);
        }

        vm.etch(slot, v3Code);
        for (uint256 i = 0; i < exponents.length; i++) {
            assertEq(IntegralLayoutV3(slot).read(token, exponents[i]), 1e50 + i, "the integral v2 wrote");
        }
        assertEq(IntegralLayoutV3(slot).read(token, 256), 0, "and none where v2 wrote none");
    }
}
