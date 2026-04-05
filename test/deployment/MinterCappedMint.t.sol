// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {Deploy_ETH_Minter} from "script/src/v3/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IMinter_v3} from "src/interfaces/IMinter_v3.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {MockWrappedPriceOracle} from "test/mocks/MockWrappedPriceOracle.sol";

/// @title MinterCappedMintTest
/// @notice Tests for Minter_v3 fee-capped minting, deployed via production deployment scripts.
contract MinterCappedMintSetUp is BaoTest, Deploy_ETH_Minter {
    address minter;
    address pegged;
    address wrappedCollateral;

    MockWrappedPriceOracle mockOracle;

    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }

    function setUp() public virtual {
        address factory = _ensureBaoFactory();
        // Pinned after latest Harbor deployment (SPL remediation, 2026-03-25) for caching
        vm.createSelectFork(vm.rpcUrl("mainnet"), 24699497);

        vm.prank(IBaoFactory(factory).owner());
        IBaoFactory(factory).setOperator(address(this), 365 days);

        // Deploy ETH::fxUSD market via production deployment scripts (now deploys Minter_v3)
        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        Config_MinterMarket[] memory toDeploy = new Config_MinterMarket[](1);
        toDeploy[0] = mktConfigs[0];
        deployForPeg("capped_test", peg, mktConfigs, "mainnet", true, toDeploy);

        // Resolve addresses
        _setSaltPrefix("capped_test");
        minter = _predictAddress(_key("ETH", "fxUSD", "minter"));
        pegged = _predictAddress(_key("ETH", "pegged"));
        wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();

        // Install mock oracle (price=1, rate=1 for simplicity)
        mockOracle = new MockWrappedPriceOracle();
        mockOracle.setLatestAnswer(1 ether, 1 ether);
        vm.prank(HARBOR_MULTISIG);
        IMinter(minter).updatePriceOracle(address(mockOracle));

        // Grant zero-fee role for free minting in bootstrap
        uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
        vm.prank(HARBOR_MULTISIG);
        IBaoRoles(minter).grantRoles(address(this), zeroFeeRole);
    }

    /// @dev Mint pegged + leveraged to create a collateral ratio where minting is allowed with fees.
    /// Target: CR around 1.5-2.0 where fee bands are active.
    function _bootstrapCollateralRatio() internal {
        // Mint 500 pegged → CR starts very high (all collateral, small pegged supply)
        deal(wrappedCollateral, address(this), 500 ether);
        IERC20(wrappedCollateral).approve(minter, 500 ether);
        IMinter(minter).freeMintPeggedToken(500 ether, address(this));

        // Mint 500 leveraged → absorbs collateral, lowering effective CR
        deal(wrappedCollateral, address(this), 500 ether);
        IERC20(wrappedCollateral).approve(minter, 500 ether);
        IMinter(minter).freeMintLeveragedToken(500 ether, address(this));

        // CR = totalCollateral * price / peggedBalance = 1000 * 1 / 500 = 2.0
    }
}

contract MinterCappedMintTest is MinterCappedMintSetUp {
    // ═══════════════════════════════════════════════════════════════
    // Uncapped mint (3-arg) behavior unchanged
    // ═══════════════════════════════════════════════════════════════

    function test_uncappedMint_matchesV2Behavior() public {
        _bootstrapCollateralRatio();

        address alice = makeAddr("alice");
        uint256 collateralIn = 10 ether;
        deal(wrappedCollateral, alice, collateralIn);

        // Dry run
        (, , uint256 dryCollUsed, uint256 dryPegged, , ) = IMinter(minter).mintPeggedTokenDryRun(collateralIn);

        // Actual mint
        vm.startPrank(alice);
        IERC20(wrappedCollateral).approve(minter, collateralIn);
        uint256 peggedOut = IMinter(minter).mintPeggedToken(collateralIn, alice, 0);
        vm.stopPrank();

        assertEq(peggedOut, dryPegged, "pegged matches dry run");
        // Collateral used = what was taken from alice
        uint256 aliceRemaining = IERC20(wrappedCollateral).balanceOf(alice);
        assertEq(collateralIn - aliceRemaining, dryCollUsed, "collateral used matches dry run");
    }

    // ═══════════════════════════════════════════════════════════════
    // Capped mint (4-arg) — full mint when fee below cap
    // ═══════════════════════════════════════════════════════════════

    function test_cappedMint_fullMint_feeBelowCap() public {
        _bootstrapCollateralRatio();

        address alice = makeAddr("alice");
        uint256 collateralIn = 10 ether;
        deal(wrappedCollateral, alice, collateralIn);

        // Get current fee ratio
        (int256 incentiveRatio, , , , , ) = IMinter(minter).mintPeggedTokenDryRun(collateralIn);

        // Set cap well above current fee
        uint256 maxFeeRatio = uint256(incentiveRatio) * 2;

        // Capped dry run
        (, , uint256 dryCollUsed, uint256 dryPegged, , ) = IMinter_v3(minter).mintPeggedTokenDryRun(
            collateralIn,
            maxFeeRatio
        );

        // Actual capped mint
        vm.startPrank(alice);
        IERC20(wrappedCollateral).approve(minter, collateralIn);
        (uint256 peggedOut, uint256 collUsed) = IMinter_v3(minter).mintPeggedToken(collateralIn, alice, 0, maxFeeRatio);
        vm.stopPrank();

        assertEq(peggedOut, dryPegged, "pegged matches capped dry run");
        assertEq(collUsed, dryCollUsed, "collateral used matches capped dry run");
        // Full mint — all collateral used (fee is below cap)
        assertEq(collUsed, collateralIn, "all collateral used when fee below cap");
    }

    // ═══════════════════════════════════════════════════════════════
    // Capped mint — no mint when fee exceeds cap from start
    // ═══════════════════════════════════════════════════════════════

    function test_cappedMint_noMint_feeExceedsCap() public {
        _bootstrapCollateralRatio();

        address alice = makeAddr("alice");
        uint256 collateralIn = 10 ether;
        deal(wrappedCollateral, alice, collateralIn);

        // Set cap to 0 — any fee exceeds it
        vm.startPrank(alice);
        IERC20(wrappedCollateral).approve(minter, collateralIn);
        (uint256 peggedOut, uint256 collUsed) = IMinter_v3(minter).mintPeggedToken(collateralIn, alice, 0, 0);
        vm.stopPrank();

        assertEq(peggedOut, 0, "no pegged minted");
        assertEq(collUsed, 0, "no collateral used");
        // Alice still has all her collateral
        assertEq(IERC20(wrappedCollateral).balanceOf(alice), collateralIn, "collateral returned");
    }

    // ═══════════════════════════════════════════════════════════════
    // Capped mint — partial mint when fee exceeds cap mid-band
    // ═══════════════════════════════════════════════════════════════

    function test_cappedMint_partialMint() public {
        _bootstrapCollateralRatio();

        address alice = makeAddr("alice");
        uint256 collateralIn = 100 ether;
        deal(wrappedCollateral, alice, collateralIn);

        // Get uncapped result
        (, , uint256 uncappedCollUsed, uint256 uncappedPegged, , ) = IMinter(minter).mintPeggedTokenDryRun(
            collateralIn
        );

        // Set cap to half the uncapped fee ratio — should produce a partial mint
        (int256 incentiveRatio, , , , , ) = IMinter(minter).mintPeggedTokenDryRun(collateralIn);
        uint256 maxFeeRatio = uint256(incentiveRatio) / 2;

        // Capped dry run
        (, , uint256 dryCollUsed, uint256 dryPegged, , ) = IMinter_v3(minter).mintPeggedTokenDryRun(
            collateralIn,
            maxFeeRatio
        );

        // Actual capped mint
        vm.startPrank(alice);
        IERC20(wrappedCollateral).approve(minter, collateralIn);
        (uint256 peggedOut, uint256 collUsed) = IMinter_v3(minter).mintPeggedToken(collateralIn, alice, 0, maxFeeRatio);
        vm.stopPrank();

        assertEq(peggedOut, dryPegged, "pegged matches capped dry run");
        assertEq(collUsed, dryCollUsed, "collateral used matches capped dry run");

        // Partial: used less collateral, minted less pegged
        if (maxFeeRatio > 0) {
            assertGt(collUsed, 0, "some collateral used");
            assertLt(collUsed, uncappedCollUsed, "less than uncapped");
            assertGt(peggedOut, 0, "some pegged minted");
            assertLt(peggedOut, uncappedPegged, "less than uncapped pegged");
        }

        // Alice keeps the unused portion
        assertEq(IERC20(wrappedCollateral).balanceOf(alice), collateralIn - collUsed, "remaining collateral");
    }

    // ═══════════════════════════════════════════════════════════════
    // Fuzz: dry run always matches actual mint
    // ═══════════════════════════════════════════════════════════════

    function test_fuzz_dryRunMatchesActualMint(uint256 collateralIn, uint256 maxFeeRatio) public {
        _bootstrapCollateralRatio();

        // Bound inputs to reasonable ranges
        collateralIn = bound(collateralIn, 0.01 ether, 100 ether);
        maxFeeRatio = bound(maxFeeRatio, 0, 0.5 ether); // 0% to 50%

        address alice = makeAddr("alice");
        deal(wrappedCollateral, alice, collateralIn);

        // Capped dry run
        (, , uint256 dryCollUsed, uint256 dryPegged, , ) = IMinter_v3(minter).mintPeggedTokenDryRun(
            collateralIn,
            maxFeeRatio
        );

        // Actual capped mint
        vm.startPrank(alice);
        IERC20(wrappedCollateral).approve(minter, collateralIn);
        (uint256 peggedOut, uint256 collUsed) = IMinter_v3(minter).mintPeggedToken(collateralIn, alice, 0, maxFeeRatio);
        vm.stopPrank();

        assertEq(peggedOut, dryPegged, "pegged matches dry run");
        assertEq(collUsed, dryCollUsed, "collateral used matches dry run");
    }

    // ═══════════════════════════════════════════════════════════════
    // Fuzz: capped mint uses <= uncapped mint collateral
    // ═══════════════════════════════════════════════════════════════

    function test_fuzz_cappedUsesLessOrEqualCollateral(uint256 collateralIn, uint256 maxFeeRatio) public {
        _bootstrapCollateralRatio();

        collateralIn = bound(collateralIn, 0.01 ether, 100 ether);
        maxFeeRatio = bound(maxFeeRatio, 0, 1 ether); // 0% to 100%

        // Uncapped dry run
        (, , uint256 uncappedCollUsed, uint256 uncappedPegged, , ) = IMinter(minter).mintPeggedTokenDryRun(
            collateralIn
        );

        // Capped dry run
        (, , uint256 cappedCollUsed, uint256 cappedPegged, , ) = IMinter_v3(minter).mintPeggedTokenDryRun(
            collateralIn,
            maxFeeRatio
        );

        assertLe(cappedCollUsed, uncappedCollUsed, "capped uses <= uncapped collateral");
        assertLe(cappedPegged, uncappedPegged, "capped mints <= uncapped pegged");
    }

    // ═══════════════════════════════════════════════════════════════
    // Fuzz: fee never exceeds the cap
    // ═══════════════════════════════════════════════════════════════

    function test_fuzz_feeNeverExceedsCap(uint256 collateralIn, uint256 maxFeeRatio) public {
        _bootstrapCollateralRatio();

        collateralIn = bound(collateralIn, 0.01 ether, 100 ether);
        maxFeeRatio = bound(maxFeeRatio, 0.001 ether, 0.5 ether); // 0.1% to 50%

        // Capped dry run
        (, uint256 dryFee, , , , ) = IMinter_v3(minter).mintPeggedTokenDryRun(collateralIn, maxFeeRatio);

        // Absolute fee must not exceed the budget (maxFeeRatio * collateralIn)
        uint256 maxFee = (collateralIn * maxFeeRatio) / 1 ether;
        assertLe(dryFee, maxFee, "fee <= maxFeeRatio * collateralIn");
    }

    // ═══════════════════════════════════════════════════════════════
    // Uncapped via type(uint256).max matches 3-arg version
    // ═══════════════════════════════════════════════════════════════

    function test_cappedWithMaxUint_matchesUncapped() public {
        _bootstrapCollateralRatio();

        uint256 collateralIn = 50 ether;

        // Uncapped dry run (3-arg)
        (int256 ir1, uint256 fee1, uint256 coll1, uint256 peg1, uint256 p1, uint256 r1) = IMinter(minter)
            .mintPeggedTokenDryRun(collateralIn);

        // Capped with max (4-arg)
        (int256 ir2, uint256 fee2, uint256 coll2, uint256 peg2, uint256 p2, uint256 r2) = IMinter_v3(minter)
            .mintPeggedTokenDryRun(collateralIn, type(uint256).max);

        assertEq(ir1, ir2, "incentive ratio matches");
        assertEq(fee1, fee2, "fee matches");
        assertEq(coll1, coll2, "collateral used matches");
        assertEq(peg1, peg2, "pegged minted matches");
        assertEq(p1, p2, "price matches");
        assertEq(r1, r2, "rate matches");
    }
}
