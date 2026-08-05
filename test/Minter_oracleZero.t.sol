// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice The Minter must refuse to act on a zero collateral price or a zero wrapped-to-underlying rate.
/// Neither is an economic state: a collateral asset worth nothing and a units conversion of zero can only mean the
/// oracle is faulty. The values they produce are indistinguishable from real extremes that drive automated action -
/// a dead feed makes the collateral ratio read 0, which is "wholly undercollateralised, liquidate now" - so the
/// contract must revert rather than return a number that lies.
contract MinterOracleZeroTest is TestMinterSetUp {
    uint256 private constant COLLATERAL_FOR_PEGGED = 100 ether;
    uint256 private constant COLLATERAL_FOR_LEVERAGED = 40 ether;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    /// @dev Seeds the minter while the oracle is still healthy and reports the healthy readings, so each test can
    /// break exactly one of them. Makes external calls, so it must be called BEFORE any expectRevert.
    function _seedWhileHealthy() private returns (uint256 price, uint256 rate) {
        setUp_collateral(COLLATERAL_FOR_PEGGED, COLLATERAL_FOR_LEVERAGED);
        (price, , rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    /// @dev Gives an actor collateral and an allowance. Makes external calls, so it must be called BEFORE any
    /// expectRevert.
    function _fundAndApprove(address actor, uint256 amount) private {
        deal(wrappedCollateralToken, actor, amount);
        vm.startPrank(actor);
        IERC20(wrappedCollateralToken).approve(minter, amount);
        vm.stopPrank();
    }

    // Read paths -------------------------------------------------------------

    /// A zero price must not be reported as a zero collateral ratio, which reads as total undercollateralisation.
    function test_collateralRatio_zeroPrice_reverts() public {
        (, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, rate);

        vm.expectRevert(IMinter_v3.ZeroOraclePrice.selector);
        IMinter_v3(minter).collateralRatio();
    }

    /// A zero price must not be reported as a leveraged token price.
    function test_leveragedTokenPrice_zeroPrice_reverts() public {
        (, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, rate);

        vm.expectRevert(IMinter_v3.ZeroOraclePrice.selector);
        IMinter_v3(minter).leveragedTokenPrice();
    }

    /// A zero rate must not be reported as "nothing to harvest" - a false negative hides the fault.
    function test_harvestable_zeroRate_reverts() public {
        (uint256 price, ) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);

        vm.expectRevert(IMinter_v3.ZeroOracleRate.selector);
        IMinter_v3(minter).harvestable();
    }

    /// The oracle's raw readings are what must be checked, not the rounded mid. An oracle reporting min 0 and max 2x
    /// averages to a healthy-looking non-zero mid, so a check applied after rounding would pass this broken feed
    /// while the min reading is a hard zero.
    function test_collateralRatio_zeroMinPriceWithHealthyMid_reverts() public {
        (uint256 price, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, 2 * price, rate, rate);

        vm.expectRevert(IMinter_v3.ZeroOraclePrice.selector);
        IMinter_v3(minter).collateralRatio();
    }

    /// The max reading is checked independently of the min: an oracle can break in either direction, and here it is
    /// the max that is zero while the mid still rounds to something healthy-looking.
    function test_collateralRatio_zeroMaxPriceWithHealthyMid_reverts() public {
        (uint256 price, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2 * price, 0, rate, rate);

        vm.expectRevert(IMinter_v3.ZeroOraclePrice.selector);
        IMinter_v3(minter).collateralRatio();
    }

    /// The same holds for the rate's max reading.
    function test_harvestable_zeroMaxRateWithHealthyMid_reverts() public {
        (uint256 price, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, price, 2 * rate, 0);

        vm.expectRevert(IMinter_v3.ZeroOracleRate.selector);
        IMinter_v3(minter).harvestable();
    }

    /// collateralRatio() reads no rate, so a faulty rate must not stop it reporting - and must not change what it
    /// reports either.
    function test_collateralRatio_zeroRate_stillReports() public {
        (uint256 price, ) = _seedWhileHealthy();
        uint256 expected = IMinter_v3(minter).collateralRatio();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);

        assertEq(IMinter_v3(minter).collateralRatio(), expected, "a faulty rate must not block a price-only reading");
    }

    /// leverageRatio() likewise reads no rate.
    function test_leverageRatio_zeroRate_stillReports() public {
        (uint256 price, ) = _seedWhileHealthy();
        uint256 expected = IMinter_v3(minter).leverageRatio();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);

        assertEq(IMinter_v3(minter).leverageRatio(), expected, "a faulty rate must not block a price-only reading");
    }

    /// peggedTokenPrice() reaches the max-price fetch through the collateral-ratio line intercepts, so it covers the
    /// price-only path of that helper too.
    function test_peggedTokenPrice_zeroRate_stillReports() public {
        (uint256 price, ) = _seedWhileHealthy();
        uint256 expected = IMinter_v3(minter).peggedTokenPrice();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);

        assertEq(IMinter_v3(minter).peggedTokenPrice(), expected, "a faulty rate must not block a price-only reading");
    }

    /// harvestable() reads no price, so a faulty price must not stop it reporting.
    function test_harvestable_zeroPrice_stillReports() public {
        (, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, rate);

        assertEq(IMinter_v3(minter).harvestable(), 0, "a faulty price must not block a rate-only reading");
    }

    /// harvestable() takes the MIN rate, not the mid. It divides the recorded collateral by the rate, so the low
    /// reading under-reports what may be swept; the mid would over-report and risk sweeping collateral that backs
    /// users. Every other test sets min == max, where the two are indistinguishable - this one separates them.
    function test_harvestable_usesMinRateNotMid() public {
        (uint256 price, ) = _seedWhileHealthy();
        uint256 minRate = 1 ether;
        uint256 maxRate = 2 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, price, minRate, maxRate);

        uint256 collateral = IMinter_v3(minter).collateralTokenBalance();
        uint256 balance = IERC20(wrappedCollateralToken).balanceOf(minter);
        uint256 valueAtMin = (collateral * 1 ether) / minRate;
        uint256 valueAtMid = (collateral * 1 ether) / ((minRate + maxRate) / 2);
        uint256 expectedAtMin = balance > valueAtMin ? balance - valueAtMin : 0;
        uint256 expectedAtMid = balance > valueAtMid ? balance - valueAtMid : 0;

        assertTrue(expectedAtMin != expectedAtMid, "fixture must separate the min and mid results");
        assertEq(IMinter_v3(minter).harvestable(), expectedAtMin, "harvestable must use the min rate");
    }

    // Owner path -------------------------------------------------------------

    /// reset() rescales the recorded collateral by the rate; a zero rate must revert, not scale it to nothing.
    function test_reset_zeroRate_reverts() public {
        (uint256 price, ) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);

        vm.startPrank(owner);
        vm.expectRevert(IMinter_v3.ZeroOracleRate.selector);
        IMinter_v3(minter).reset();
        vm.stopPrank();
    }

    /// The refusal must leave the recorded collateral intact. Without the guard reset() writes it to zero, which is
    /// silent, permanent state corruption - observable here as a collapsed collateral ratio once the oracle recovers.
    function test_reset_zeroRate_leavesCollateralRatioUnchanged() public {
        (uint256 price, uint256 rate) = _seedWhileHealthy();
        uint256 collateralRatioBefore = IMinter_v3(minter).collateralRatio();

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);
        vm.startPrank(owner);
        vm.expectRevert(IMinter_v3.ZeroOracleRate.selector);
        IMinter_v3(minter).reset();
        vm.stopPrank();

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        assertEq(
            IMinter_v3(minter).collateralRatio(),
            collateralRatioBefore,
            "a refused reset must not alter the recorded collateral"
        );
    }

    // Mint and redeem paths --------------------------------------------------

    /// Minting must not price collateral at zero.
    function test_mintPeggedToken_zeroPrice_reverts() public {
        (, uint256 rate) = _seedWhileHealthy();
        _fundAndApprove(address(this), 10 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, rate);

        vm.expectRevert(IMinter_v3.ZeroOraclePrice.selector);
        IMinter_v3(minter).mintPeggedToken(1 ether, address(this), 0);
    }

    /// Minting must not convert wrapped to underlying collateral at a zero rate.
    function test_mintPeggedToken_zeroRate_reverts() public {
        (uint256 price, ) = _seedWhileHealthy();
        _fundAndApprove(address(this), 10 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);

        vm.expectRevert(IMinter_v3.ZeroOracleRate.selector);
        IMinter_v3(minter).mintPeggedToken(1 ether, address(this), 0);
    }

    /// Redeeming pegged tokens reads the max price; that path must reject a zero too.
    function test_redeemPeggedToken_zeroPrice_reverts() public {
        (, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, rate);

        vm.startPrank(zeroFee);
        vm.expectRevert(IMinter_v3.ZeroOraclePrice.selector);
        IMinter_v3(minter).redeemPeggedToken(1 ether, zeroFee, 0);
        vm.stopPrank();
    }

    /// Redeeming leveraged tokens reads the min price; that path must reject a zero too.
    function test_redeemLeveragedToken_zeroPrice_reverts() public {
        (, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, rate);

        vm.startPrank(zeroFee);
        vm.expectRevert(IMinter_v3.ZeroOraclePrice.selector);
        IMinter_v3(minter).redeemLeveragedToken(1 ether, zeroFee, 0);
        vm.stopPrank();
    }

    // Quote path -------------------------------------------------------------

    /// A quote must not return a zero-priced number the corresponding transaction would refuse to honour.
    function test_mintPeggedTokenDryRun_zeroPrice_reverts() public {
        (, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, rate);

        vm.expectRevert(IMinter_v3.ZeroOraclePrice.selector);
        IMinter_v3(minter).mintPeggedTokenDryRun(1 ether);
    }

    /// The same quote must reject a zero rate.
    function test_mintPeggedTokenDryRun_zeroRate_reverts() public {
        (uint256 price, ) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);

        vm.expectRevert(IMinter_v3.ZeroOracleRate.selector);
        IMinter_v3(minter).mintPeggedTokenDryRun(1 ether);
    }
}
