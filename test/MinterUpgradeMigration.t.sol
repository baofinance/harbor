// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {Minter_v2} from "src/minter/Minter_v2.sol";
import {Minter_v3} from "src/minter/Minter_v3.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

import {TestMinterSetUp} from "test/Minter_base.t.sol";

/// @title TestMinterUpgradeMigration
/// @notice Tests that upgrading Minter_v2 → Minter_v3 via UUPS proxy preserves
///         all state and produces identical results at every lifecycle stage.
contract TestMinterUpgradeMigration is TestMinterSetUp {
    /// @dev Override to deploy with Minter_v2 implementation instead of Minter_v3
    function setUp_minter() internal override {
        minter = UnsafeUpgrades.deployUUPSProxy(
            address(new Minter_v2(wrappedCollateralToken, peggedToken, leveragedToken, peggedTokenBurnSig)),
            abi.encodeCall(Minter_v2.initialize, (owner))
        );
        vm.label(minter, "minter");
        zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
        IMinter(minter).updatePriceOracle(priceOracle);
        IMinter(minter).updateFeeReceiver(feeReceiver);
        IMinter(minter).updateReservePool(reservePool);
        if (isConfigSet) IMinter(minter).updateConfig(config);
        IBaoOwnable(minter).transferOwnership(owner);
    }
    function _upgradeToV3() internal {
        address v3Impl = address(
            new Minter_v3(wrappedCollateralToken, peggedToken, leveragedToken, peggedTokenBurnSig)
        );
        vm.prank(owner);
        UUPSUpgradeable(minter).upgradeToAndCall(v3Impl, "");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 1. FreshMinter — upgrade empty minter
    // ═══════════════════════════════════════════════════════════════════════

    function test_upgradeFromV2_FreshMinter() public {
        // Verify initial state
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "no pegged before upgrade");
        assertEq(IMinter(minter).collateralTokenBalance(), 0, "no collateral before upgrade");

        _upgradeToV3();

        // State preserved
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "no pegged after upgrade");
        assertEq(IMinter(minter).collateralTokenBalance(), 0, "no collateral after upgrade");
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "CR preserved");
        assertEq(IMinter(minter).leveragedTokenPrice(), 1 ether, "leveraged price preserved");

        // Post-upgrade: mint works
        setUp_collateral(1 ether, 0);
        assertGt(IMinter(minter).peggedTokenBalance(), 0, "mint works post-upgrade");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 2. AfterMint — upgrade after minting pegged and leveraged
    // ═══════════════════════════════════════════════════════════════════════

    function test_upgradeFromV2_AfterMint() public {
        setUp_collateral(5 ether, 5 ether);

        // Snapshot v2 state
        uint256 snap = vm.snapshotState();
        uint256 v2_pegged = IMinter(minter).peggedTokenBalance();
        uint256 v2_collateral = IMinter(minter).collateralTokenBalance();
        uint256 v2_cr = IMinter(minter).collateralRatio();
        uint256 v2_levPrice = IMinter(minter).leveragedTokenPrice();
        uint256 v2_pegPrice = IMinter(minter).peggedTokenPrice();
        uint256 v2_levRatio = IMinter(minter).leverageRatio();

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV3();

        // Assert identical state
        assertEq(IMinter(minter).peggedTokenBalance(), v2_pegged, "pegged balance preserved");
        assertEq(IMinter(minter).collateralTokenBalance(), v2_collateral, "collateral balance preserved");
        assertEq(IMinter(minter).collateralRatio(), v2_cr, "CR preserved");
        assertEq(IMinter(minter).leveragedTokenPrice(), v2_levPrice, "leveraged price preserved");
        assertEq(IMinter(minter).peggedTokenPrice(), v2_pegPrice, "pegged price preserved");
        assertEq(IMinter(minter).leverageRatio(), v2_levRatio, "leverage ratio preserved");

        // Post-upgrade: more minting works
        setUp_collateral(1 ether, 1 ether);
        assertGt(IMinter(minter).peggedTokenBalance(), v2_pegged, "more pegged minted post-upgrade");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 3. AfterRedeem — upgrade after minting then partially redeeming
    // ═══════════════════════════════════════════════════════════════════════

    function test_upgradeFromV2_AfterRedeem() public {
        setUp_collateral(5 ether, 5 ether);

        // Redeem some pegged
        uint256 peggedBal = IERC20(peggedToken).balanceOf(zeroFee);
        uint256 toRedeem = peggedBal / 4;
        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, toRedeem);
        IMinter(minter).freeRedeemPeggedToken(toRedeem, 0, zeroFee);
        vm.stopPrank();

        // Snapshot v2 state
        uint256 snap = vm.snapshotState();
        uint256 v2_pegged = IMinter(minter).peggedTokenBalance();
        uint256 v2_collateral = IMinter(minter).collateralTokenBalance();
        uint256 v2_cr = IMinter(minter).collateralRatio();
        uint256 v2_levPrice = IMinter(minter).leveragedTokenPrice();

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV3();

        // Assert identical
        assertEq(IMinter(minter).peggedTokenBalance(), v2_pegged, "pegged balance preserved after redeem");
        assertEq(IMinter(minter).collateralTokenBalance(), v2_collateral, "collateral preserved after redeem");
        assertEq(IMinter(minter).collateralRatio(), v2_cr, "CR preserved after redeem");
        assertEq(IMinter(minter).leveragedTokenPrice(), v2_levPrice, "leveraged price preserved after redeem");

        // Post-upgrade: redeem more works
        uint256 remaining = IERC20(peggedToken).balanceOf(zeroFee);
        uint256 toRedeemMore = remaining / 4;
        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, toRedeemMore);
        IMinter(minter).freeRedeemPeggedToken(toRedeemMore, 0, zeroFee);
        vm.stopPrank();
        assertLt(IMinter(minter).peggedTokenBalance(), v2_pegged, "redeem works post-upgrade");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 4. ConfigChange — upgrade preserves config
    // ═══════════════════════════════════════════════════════════════════════

    function test_upgradeFromV2_ConfigChange() public {
        // Change config on v2
        setUp_config_free();
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        IMinter.Config memory v2_config = IMinter(minter).config();

        _upgradeToV3();

        IMinter.Config memory v3_config = IMinter(minter).config();
        _assertEqConfig(v3_config, v2_config);

        // Post-upgrade: config update works
        setUp_config_flat();
        vm.prank(owner);
        IMinter(minter).updateConfig(config);
        IMinter.Config memory updated = IMinter(minter).config();
        _assertEqConfig(updated, config);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 5. MixedOperations — mint, redeem, price change, then upgrade
    // ═══════════════════════════════════════════════════════════════════════

    function test_upgradeFromV2_MixedOperations() public {
        // Mint pegged and leveraged
        setUp_collateral(5 ether, 5 ether);

        // Redeem some leveraged
        uint256 levBal = IERC20(leveragedToken).balanceOf(zeroFee);
        uint256 toRedeem = levBal / 3;
        vm.startPrank(zeroFee);
        IERC20(leveragedToken).approve(minter, toRedeem);
        IMinter(minter).freeRedeemLeveragedToken(toRedeem, zeroFee);
        vm.stopPrank();

        // Snapshot v2 state
        uint256 snap = vm.snapshotState();
        uint256 v2_pegged = IMinter(minter).peggedTokenBalance();
        uint256 v2_collateral = IMinter(minter).collateralTokenBalance();
        uint256 v2_cr = IMinter(minter).collateralRatio();
        uint256 v2_levPrice = IMinter(minter).leveragedTokenPrice();
        uint256 v2_pegPrice = IMinter(minter).peggedTokenPrice();

        // Revert and upgrade
        vm.revertToState(snap);
        _upgradeToV3();

        // Assert identical
        assertEq(IMinter(minter).peggedTokenBalance(), v2_pegged, "pegged preserved");
        assertEq(IMinter(minter).collateralTokenBalance(), v2_collateral, "collateral preserved");
        assertEq(IMinter(minter).collateralRatio(), v2_cr, "CR preserved");
        assertEq(IMinter(minter).leveragedTokenPrice(), v2_levPrice, "leveraged price preserved");
        assertEq(IMinter(minter).peggedTokenPrice(), v2_pegPrice, "pegged price preserved");
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 6. FreeRedeemBothPaths — the bug fix scenario
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The core bug fix: freeRedeemPeggedToken with both collateral and
    ///         leveraged paths. On v2, the leveraged path sees stale state.
    ///         On v3, both paths use consistent snapshots.
    function test_upgradeFromV2_FreeRedeemBothPaths() public {
        setUp_collateral(5 ether, 5 ether);

        _upgradeToV3();

        uint256 priceBefore = IMinter(minter).leveragedTokenPrice();
        uint256 peggedBal = IERC20(peggedToken).balanceOf(zeroFee);
        uint256 forCollateral = peggedBal / 4;
        uint256 forLeveraged = peggedBal / 4;

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, forCollateral + forLeveraged);
        IMinter(minter).freeRedeemPeggedToken(forCollateral, forLeveraged, zeroFee);
        vm.stopPrank();

        uint256 priceAfter = IMinter(minter).leveragedTokenPrice();
        // The v3 fix ensures leveraged token price doesn't drop from inconsistent state
        assertGe(priceAfter, priceBefore, "leveraged price must not decrease in freeRedeemPeggedToken");
    }
}
