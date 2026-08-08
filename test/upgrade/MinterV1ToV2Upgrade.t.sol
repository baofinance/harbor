// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {Minter_v2} from "@harbor/minter/Minter_v2.sol";

/// @notice Upgrading a Minter from v1 to v2 preserves every value the contract exposes.
/// @dev Replayed against the state the upgrade ACTUALLY ran against, not a reconstruction. A synthetic v1
///      built by the test can only show the migration preserves data the test itself wrote, which is exactly
///      what a storage-layout mismatch slips past: the layout it writes and the layout it reads are both the
///      test's own.
///
///      This is the pattern for upgrade tests generally. Three things make it work:
///        1. Fork one block BEFORE the real upgrade, so the proxy holds genuine state — here three months of
///           it, the v1 implementations having gone live 2025-12-19 and been upgraded 2026-03-25.
///        2. Build the new implementation from THIS repo's source rather than pointing at the historical
///           address. Re-running history only re-confirms what already succeeded; compiling today's source
///           against real data is what catches a layout regression introduced today.
///        3. Read the constructor arguments and the owner off the live proxy, so the test states only what it
///           cannot derive.
///
///      What it deliberately does NOT do is construct scenarios. It verifies ONE real state very deeply,
///      where the suite it replaced verified several invented ones shallowly. Exercising operations against
///      migrated real state is a natural extension, and would need funding a user at the pinned block.
contract MinterV1ToV2UpgradeTest is BaoTest {
    /// @dev The real upgrade. All ELEVEN markets were upgraded atomically in ONE Safe transaction
    ///      (0x381725ca780bf953cc6f958d601795d2f5a89ba1d5abd00535c1e62e571ec1ca), so there is a single block
    ///      to fork from whichever market is under test. Recorded in deployments/mainnet/harbor_v1.state.json
    ///      and the Deploy_Minter_v2_mainnet_2026-03-24T16:44:50Z Safe batch.
    uint256 private constant UPGRADE_BLOCK = 24734630;

    /// @dev The BTC::stETH market's minter, whose v1 implementation was deployed 2025-12-19T21:17:47Z.
    address private constant MINTER = 0xF42516EB885E737780EB864dd07cEc8628000919;

    address private minterOwner;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), UPGRADE_BLOCK - 1);
        minterOwner = IBaoOwnable(MINTER).owner();
    }

    /// @dev Everything the minter exposes that the upgrade must not disturb.
    struct MinterState {
        uint256 peggedTokenBalance;
        uint256 collateralTokenBalance;
        uint256 collateralRatio;
        uint256 leverageRatio;
        uint256 peggedTokenPrice;
        uint256 leveragedTokenPrice;
        address feeReceiver;
        address owner;
        bytes config;
    }

    function _readMinterState() private view returns (MinterState memory state) {
        state.peggedTokenBalance = IMinter(MINTER).peggedTokenBalance();
        state.collateralTokenBalance = IMinter(MINTER).collateralTokenBalance();
        state.collateralRatio = IMinter(MINTER).collateralRatio();
        state.leverageRatio = IMinter(MINTER).leverageRatio();
        state.peggedTokenPrice = IMinter(MINTER).peggedTokenPrice();
        state.leveragedTokenPrice = IMinter(MINTER).leveragedTokenPrice();
        state.feeReceiver = IMinter(MINTER).feeReceiver();
        state.owner = IBaoOwnable(MINTER).owner();
        // Encoded whole rather than field by field: the config nests dynamic arrays, and comparing the
        // encoding covers every one of them without a comparator that can fall behind the struct.
        state.config = abi.encode(IMinter(MINTER).config());
    }

    /// @dev The ERC-1967 implementation slot, read directly so the upgrade can be proved to have happened.
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _implementation() private view returns (address) {
        return address(uint160(uint256(vm.load(MINTER, IMPLEMENTATION_SLOT))));
    }

    /// @dev The upgrade the multisig performed, with the implementation compiled from this repo's source.
    ///      Its constructor arguments are read off the proxy, so they cannot disagree with the deployment.
    function _upgradeToV2() private {
        address implementation = address(
            new Minter_v2(
                IMinter(MINTER).WRAPPED_COLLATERAL_TOKEN(),
                IMinter(MINTER).PEGGED_TOKEN(),
                IMinter(MINTER).LEVERAGED_TOKEN(),
                "burn(uint256)"
            )
        );
        address previous = _implementation();

        vm.startPrank(minterOwner);
        UUPSUpgradeable(MINTER).upgradeToAndCall(implementation, "");
        vm.stopPrank();

        // Without this the whole file could pass vacuously: an upgrade that silently did nothing would leave
        // every before/after comparison below trivially equal.
        assertEq(_implementation(), implementation, "the proxy points at the newly built implementation");
        assertNotEq(_implementation(), previous, "which is not the one it pointed at before");
    }

    /// The fork holds a real, live v1 minter — not an empty one. Without this, moving the fork block to
    /// somewhere the minter is unused would leave every assertion below comparing zero to zero and passing.
    function test_theForkHoldsALiveMinterCarryingRealPositions() public {
        MinterState memory state = _readMinterState();

        assertGt(state.peggedTokenBalance, 0, "the minter has pegged tokens outstanding");
        assertGt(state.collateralTokenBalance, 0, "and collateral backing them");
        assertGt(state.collateralRatio, 0, "so the collateral ratio is a real number");
        assertNotEq(state.owner, address(0), "and it is owned");
    }

    /// The upgrade preserves every exposed value. This is the whole point: the balances, the derived prices
    /// and the incentive config are all read from storage whose layout v2 must match exactly.
    function test_upgradingPreservesEveryExposedValue() public {
        MinterState memory before = _readMinterState();

        _upgradeToV2();

        MinterState memory afterUpgrade = _readMinterState();

        assertEq(afterUpgrade.peggedTokenBalance, before.peggedTokenBalance, "pegged token balance");
        assertEq(afterUpgrade.collateralTokenBalance, before.collateralTokenBalance, "collateral token balance");
        assertEq(afterUpgrade.collateralRatio, before.collateralRatio, "collateral ratio");
        assertEq(afterUpgrade.leverageRatio, before.leverageRatio, "leverage ratio");
        assertEq(afterUpgrade.peggedTokenPrice, before.peggedTokenPrice, "pegged token price");
        assertEq(afterUpgrade.leveragedTokenPrice, before.leveragedTokenPrice, "leveraged token price");
        assertEq(afterUpgrade.feeReceiver, before.feeReceiver, "fee receiver");
        assertEq(afterUpgrade.owner, before.owner, "owner");
        assertEq(afterUpgrade.config, before.config, "incentive config");
    }

    /// Preserved reads are not enough on their own: the upgraded proxy must still be writable through the
    /// same authority. A layout shift that left the owner slot intact but moved what follows it would satisfy
    /// the test above and fail here.
    function test_theUpgradedMinterIsStillOwnedAndWritable() public {
        _upgradeToV2();

        address newFeeReceiver = makeAddr("newFeeReceiver");
        vm.startPrank(minterOwner);
        IMinter(MINTER).updateFeeReceiver(newFeeReceiver);
        vm.stopPrank();

        assertEq(IMinter(MINTER).feeReceiver(), newFeeReceiver, "the owner can still configure the minter");
    }
}
