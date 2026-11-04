// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// The floor under the pegged price, and what the pegged operations do at it.
///
/// While the pegged token is fully backed its price is exactly 1, so it mints at face value and a
/// redeem returns it. Below that the cap engages and the price falls with the collateral ratio,
/// at which point every operation that divides by it grows without bound and every operation that
/// multiplies by it collapses to nothing. These tests pin both edges.
///
/// Every market here opens from 140 wrapped collateral at a collateral price of 2000, giving
/// 200,000 pegged and 80,000 leveraged at a collateral ratio of 1.4.
abstract contract MinterPeggedPriceFloorBase is TestMinterSetUp {
    /// the largest wrapped holding for which the reported pegged price is still zero
    uint256 internal constant LAST_ZERO_HOLDING = 99;

    function _rate() internal view returns (uint256 rate) {
        (, , rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    function _price() internal view returns (uint256 price) {
        (price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    /// Scale the reported rate down and recognise the loss - the impairment path, as distinct from
    /// starving the holding outright. Until it is recognised the market is halted.
    function _impair(uint256 dropBps) internal {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(_price(), (_rate() * (10_000 - dropBps)) / 10_000);
        _recogniseImpairment();
    }

    /// Open the standard market, then reduce what the Minter holds to `held` wei and recognise the loss.
    function _setUpMarketHolding(uint256 held) internal {
        setUp_collateral(100 ether, 40 ether);
        assertGt(IMinter(minter).peggedTokenBalance(), 0, "pegged must be outstanding for any of this to bite");
        deal(wrappedCollateralToken, minter, held);
        _recogniseImpairment();
    }

    function _recogniseImpairment() internal {
        vm.startPrank(owner());
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                THE FREE REDEEM MUST NOT BURN FOR NOTHING
    //////////////////////////////////////////////////////////////*/

    /// The zero-fee redeem is the rebalance path. At a collateral price of nothing it returns no
    /// collateral, so burning the pegged against it would destroy the stability pool's deposit for
    /// nothing. It must revert with the same error the fee-paying redeem already uses.
    function test_underBacked_freeRedeemRevertsRatherThanBurnPeggedForNothing() public {
        _setUpMarketHolding(LAST_ZERO_HOLDING);
        uint256 supplyBefore = IMinter(minter).peggedTokenBalance();

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, 1_000 ether);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.ReturnZeroAmount.selector, wrappedCollateralToken));
        IMinter(minter).freeRedeemPeggedToken(1_000 ether, 0, zeroFee);
        vm.stopPrank();

        assertEq(IMinter(minter).peggedTokenBalance(), supplyBefore, "and no pegged was burned");
    }

    /// The guard is on returning nothing, not on being under-backed: a depegged market that still
    /// returns collateral must keep redeeming, or a rebalance could never run when it is needed.
    function test_underBacked_freeRedeemStillWorksWhileCollateralIsReturned() public {
        setUp_collateral(100 ether, 40 ether);
        _impair(3_000);
        assertLt(IMinter(minter).peggedTokenPrice(), 1 ether, "the market is depegged");
        assertGt(IMinter(minter).peggedTokenPrice(), 0, "but the pegged is still worth something");

        uint256 supplyBefore = IMinter(minter).peggedTokenBalance();
        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, 1_000 ether);
        (uint256 wrappedOut, ) = IMinter(minter).freeRedeemPeggedToken(1_000 ether, 0, zeroFee);
        vm.stopPrank();

        assertGt(wrappedOut, 0, "collateral is returned");
        assertEq(IMinter(minter).peggedTokenBalance(), supplyBefore - 1_000 ether, "and the pegged is burned for it");
    }

    /// The conversion leg burns pegged too, and in a market with nothing behind its pegged it
    /// reverts: far below the min CR no leverage is sold, so it reverts at the min CR before anything
    /// is priced, and nothing is burned.
    function test_underBacked_freeRedeemForLeveraged_revertsBelowTheMinimumAndBurnsNothing() public {
        _setUpMarketHolding(LAST_ZERO_HOLDING);
        uint256 supplyBefore = IMinter(minter).peggedTokenBalance();
        bytes memory belowMinimum = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            IMinter(minter).collateralRatio(),
            IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()
        );

        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, 1);
        vm.expectRevert(belowMinimum);
        IMinter(minter).freeRedeemPeggedToken(0, 1, zeroFee);
        vm.stopPrank();

        assertEq(IMinter(minter).peggedTokenBalance(), supplyBefore, "no pegged burned");
    }

    /*//////////////////////////////////////////////////////////////
              THE MINT MUST NOT DIVIDE BY A PRICE OF NOTHING
    //////////////////////////////////////////////////////////////*/

    /// With nothing behind an outstanding pegged supply the pegged is worth nothing, so the mint has
    /// no price to divide by. It must revert by name rather than reaching the band walk and panicking
    /// on the division: the market's ratio is zero, under the min CR, and the mint says so. Whether
    /// the band table happens to disallow minting at this ratio must not be what decides it.
    function test_noBacking_mintPeggedRevertsByNameRatherThanPanicking() public {
        _setUpMarketHolding(0);
        assertEq(IMinter(minter).collateralTokenBalance(), 0, "nothing stands behind the pegged claim");
        bytes memory belowMinimum = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            0,
            IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()
        );

        address peggedMinter = makeAddr("peggedMinter");
        deal(wrappedCollateralToken, peggedMinter, 1 ether);
        vm.startPrank(peggedMinter);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.expectRevert(belowMinimum);
        IMinter(minter).mintPeggedToken(1 ether, peggedMinter, 0);
        vm.stopPrank();
    }

    /// The dry run reports the mint its call makes: nothing used, no fee, nothing minted - without
    /// dividing by the price of nothing.
    function test_noBacking_mintPeggedDryRunReportsNothing() public {
        _setUpMarketHolding(0);

        (, uint256 fee, uint256 used, uint256 minted, , ) = IMinter_v3(minter).mintPeggedTokenDryRun(1 ether);
        assertEq(fee + used + minted, 0, "the dry run reports nothing");
    }
}

/// production-shaped config: pegged minting and leveraged redemption are disallowed at low ratios
contract MinterPeggedPriceFloorTest is MinterPeggedPriceFloorBase {
    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }
}

/// A config with no disallow band, so the band walk cannot break out before pricing. This is what
/// separates a structural guard from one the config happens to provide.
contract MinterPeggedPriceFloorNoDisallowTest is MinterPeggedPriceFloorBase {
    function setUpConfig() internal virtual override {
        setUp_config_likelyNoDisallow();
    }
}
