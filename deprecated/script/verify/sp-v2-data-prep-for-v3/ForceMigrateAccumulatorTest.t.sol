// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ForceMigrateAccumulator_v1} from "@harbor-script/Migrate_StabilityPool_v2_Data_mainnet/ForceMigrateAccumulator_v1.sol";

/// @notice Minimal UUPS implementation standing in for the deployed StabilityPool_v2 —
/// the "original" impl the migration upgrades away from and restores to. It only needs to
/// look like a UUPS-upgradeable, owned contract (owner() + proxiableUUID() via UUPSUpgradeable).
contract MockV2 is UUPSUpgradeable {
    function owner() external pure returns (address) {
        return address(0xBEEF);
    }

    // Mock: allow any upgrade (the real auth path is exercised by the fork tests).
    function _authorizeUpgrade(address) internal override {} // solhint-disable-line no-empty-blocks
}

/// @title ForceMigrateAccumulatorTest
/// @notice Fast, fork-free unit test of the EXACT production calldata:
///   proxy.upgradeToAndCall(migImpl, remediate(tokens, holders, originalImpl))
/// in one atomic transaction. Asserts the V1->V2 copy AND that the proxy is restored to its
/// original implementation. Complements the fork-based prongs (which only see this end-to-end
/// through claimable/claimed) by isolating the combined upgrade+remediate+self-restore path
/// with synthetic storage.
contract ForceMigrateAccumulatorTest is Test {
    /// @dev ERC-1967 implementation slot.
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev MultipleRewardCompoundingAccumulator ERC-7201 base (matches ForceMigrateAccumulator_v1).
    bytes32 internal constant ACC_BASE = 0x47ddc56aaabfe9761e2e64ce86720771c5fd1fd7ef0605da74e07d71de0e7900;
    /// @dev Hardcoded Harbor multisig (HarborPauser_v1._OWNER) — remediate's onlyOwner.
    address internal constant HARBOR_OWNER = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    address internal migImpl;
    address internal mockV2Impl;
    address internal proxy;

    function setUp() public {
        migImpl = address(new ForceMigrateAccumulator_v1());
        mockV2Impl = address(new MockV2());
        proxy = address(new ERC1967Proxy(mockV2Impl, ""));
    }

    // ── storage-slot helpers (mirror AccumulatorStorage layout) ──────────────

    /// @dev userRewardSnapshot[account][token].checkpoint slot (timestamp | integral<<64).
    function _v1CheckpointSlot(address account, address token) internal pure returns (bytes32) {
        bytes32 base = bytes32(uint256(ACC_BASE) + 2); // userRewardSnapshot (V1)
        bytes32 accSlot = keccak256(abi.encode(account, base));
        bytes32 entry = keccak256(abi.encode(token, accSlot));
        return bytes32(uint256(entry) + 1); // ClaimData (slot 0), checkpoint (slot 1)
    }

    /// @dev userRewardSnapshotV2[account][token].integral slot.
    function _v2IntegralSlot(address account, address token) internal pure returns (bytes32) {
        bytes32 base = bytes32(uint256(ACC_BASE) + 3); // userRewardSnapshotV2 (V2)
        bytes32 accSlot = keccak256(abi.encode(account, base));
        bytes32 entry = keccak256(abi.encode(token, accSlot));
        return bytes32(uint256(entry) + 2); // rewards (0), timestamp (1), integral (2)
    }

    function _runProductionCall(address[] memory tokens, address[] memory holders) internal {
        // The exact tx the Safe batch contains: atomic upgrade + remediate + self-restore.
        vm.prank(HARBOR_OWNER);
        UUPSUpgradeable(proxy).upgradeToAndCall(
            migImpl,
            abi.encodeCall(ForceMigrateAccumulator_v1.remediate, (tokens, holders, mockV2Impl))
        );
    }

    /// @notice The production combined call copies V1->V2 for every holder/token and restores
    /// the proxy to its original implementation, all in one transaction.
    function test_productionCall_copiesV1ToV2_andRestoresImpl() public {
        address holder = makeAddr("holder");
        address token = makeAddr("token");
        uint192 integral = 12_345e6;
        uint64 timestamp = 1000;

        // Seed synthetic V1 checkpoint data (RewardSnapshot: uint64 timestamp | uint192 integral).
        vm.store(proxy, _v1CheckpointSlot(holder, token), bytes32((uint256(integral) << 64) | timestamp));

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        address[] memory holders = new address[](1);
        holders[0] = holder;

        _runProductionCall(tokens, holders);

        // Gap #4: proxy restored to the original implementation.
        assertEq(address(uint160(uint256(vm.load(proxy, IMPL_SLOT)))), mockV2Impl, "impl not restored");

        // Gap #3: V1 integral copied into V2.
        assertEq(uint256(vm.load(proxy, _v2IntegralSlot(holder, token))), uint256(integral), "V1 not copied to V2");
    }

    /// @notice Multiple holders are all migrated in the single production call (guards against
    /// an upgrade/restore that fires mid-loop and aborts after the first holder).
    function test_productionCall_handlesMultipleHolders() public {
        uint256 n = 3;
        address token = makeAddr("token");
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        address[] memory holders = new address[](n);
        uint192[] memory integrals = new uint192[](n);
        for (uint256 i = 0; i < n; i++) {
            holders[i] = makeAddr(string.concat("holder", vm.toString(i)));
            integrals[i] = uint192((i + 1) * 1e18);
            vm.store(proxy, _v1CheckpointSlot(holders[i], token), bytes32((uint256(integrals[i]) << 64) | uint64(1)));
        }

        _runProductionCall(tokens, holders);

        assertEq(address(uint160(uint256(vm.load(proxy, IMPL_SLOT)))), mockV2Impl, "impl not restored");
        for (uint256 i = 0; i < n; i++) {
            assertEq(
                uint256(vm.load(proxy, _v2IntegralSlot(holders[i], token))),
                uint256(integrals[i]),
                string.concat("holder ", vm.toString(i), " not copied")
            );
        }
    }
}
