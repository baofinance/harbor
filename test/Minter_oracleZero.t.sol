// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IPriceOracleErrors} from "@bao/interfaces/IPriceOracleErrors.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice The Minter must not act on a zero collateral price or a zero wrapped-to-underlying rate, and must let
/// the refusal through rather than answering anyway.
///
/// Neither is an economic state. A collateral asset worth nothing and a units conversion of zero can only mean the
/// source is faulty - and that is true of a leveraged token used as collateral too, now that the collateral
/// escrowed for it puts a floor under its price. No product this protocol issues is worth nothing while any of it
/// exists, so a zero can only have come from something broken.
///
/// The REFUSAL ITSELF belongs to the oracle, which rejects a reading that is stale, negative or zero and a rate at
/// or below zero. What is asserted here is that the Minter consumes that refusal rather than swallowing it: the
/// values a faulty source produces are indistinguishable from real extremes that drive automated action - a dead
/// feed makes the collateral ratio read 0, which is "wholly undercollateralised, liquidate now" - so every path
/// that reads the oracle must carry the revert out to its caller rather than return a number that lies.
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

        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.ZeroPrice.selector, priceOracle, int256(0)));
        IMinter_v3(minter).collateralRatio();
    }

    /// A zero price must not be reported as a leveraged token price.
    function test_leveragedTokenPrice_zeroPrice_reverts() public {
        (, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, rate);

        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.ZeroPrice.selector, priceOracle, int256(0)));
        IMinter_v3(minter).leveragedTokenPrice();
    }

    /// A zero rate must not be reported as "nothing to harvest" - a false negative hides the fault.
    function test_harvestable_zeroRate_reverts() public {
        (uint256 price, ) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);

        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.InvalidRate.selector, uint256(0)));
        IMinter_v3(minter).harvestable();
    }

    /// The oracle's raw readings are what must be checked, not the rounded mid. An oracle reporting min 0 and max 2x
    /// averages to a healthy-looking non-zero mid, so a check applied after rounding would pass this broken feed
    /// while the min reading is a hard zero.
    function test_collateralRatio_zeroMinPriceWithHealthyMid_reverts() public {
        (uint256 price, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, 2 * price, rate, rate);

        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.ZeroPrice.selector, priceOracle, int256(0)));
        IMinter_v3(minter).collateralRatio();
    }

    /// The max reading is checked independently of the min: an oracle can break in either direction, and here it is
    /// the max that is zero while the mid still rounds to something healthy-looking.
    function test_collateralRatio_zeroMaxPriceWithHealthyMid_reverts() public {
        (uint256 price, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(2 * price, 0, rate, rate);

        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.ZeroPrice.selector, priceOracle, int256(0)));
        IMinter_v3(minter).collateralRatio();
    }

    /// The same holds for the rate's max reading.
    function test_harvestable_zeroMaxRateWithHealthyMid_reverts() public {
        (uint256 price, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, price, 2 * rate, 0);

        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.InvalidRate.selector, uint256(0)));
        IMinter_v3(minter).harvestable();
    }

    /// Every view of the collateral now needs the rate, because the recorded backing is only meaningful once
    /// measured against what is held — and the holding is wrapped collateral, which only the rate converts. With no
    /// usable rate there is no way to tell whether the record still stands up, and reporting it anyway is the
    /// overstatement these views exist to avoid. So they refuse, on the same principle as a faulty price: better no
    /// answer than a wrong one.
    function test_collateralRatio_zeroRate_reverts() public {
        (uint256 price, ) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);

        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.InvalidRate.selector, uint256(0)));
        IMinter_v3(minter).collateralRatio();
    }

    function test_leverageRatio_zeroRate_reverts() public {
        (uint256 price, ) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);

        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.InvalidRate.selector, uint256(0)));
        IMinter_v3(minter).leverageRatio();
    }

    function test_peggedTokenPrice_zeroRate_reverts() public {
        (uint256 price, ) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);

        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.InvalidRate.selector, uint256(0)));
        IMinter_v3(minter).peggedTokenPrice();
    }

    /// harvestable() reads no price, but a faulty one still stops it - because a conforming oracle refuses to
    /// answer AT ALL rather than handing back a zero for the reading it cannot make. There is no such thing as a
    /// faulty price arriving alongside a sound rate, so nothing is lost by the whole answer being refused.
    function test_harvestable_zeroPrice_reverts() public {
        (, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, rate);

        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.ZeroPrice.selector, priceOracle, int256(0)));
        IMinter_v3(minter).harvestable();
    }

    /// harvestable() takes the MIN rate, not the mid. It divides the recorded collateral by the rate, so the low
    /// reading under-reports what may be swept; the mid would over-report and risk sweeping collateral that backs
    /// users. Every other test sets min == max, where the two are indistinguishable - this one separates them.
    function test_harvestable_usesMinRateNotMid() public {
        (uint256 price, ) = _seedWhileHealthy();
        uint256 minRate = 1 ether;
        uint256 maxRate = 2 ether;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, price, minRate, maxRate);

        // Both accounts, because the surplus is what the holding exceeds the pair by: the escrow is spoken for,
        // so leaving it out would model it as yield and expect a harvest to carry the leveraged floor away.
        (uint256 backing, uint256 escrow) = IMinter_v3(minter).collateralAccounts();
        uint256 collateral = backing + escrow;
        uint256 balance = IERC20(wrappedCollateralToken).balanceOf(minter);
        uint256 valueAtMin = (collateral * 1 ether) / minRate;
        uint256 valueAtMid = (collateral * 1 ether) / ((minRate + maxRate) / 2);
        uint256 expectedAtMin = balance > valueAtMin ? balance - valueAtMin : 0;
        uint256 expectedAtMid = balance > valueAtMid ? balance - valueAtMid : 0;

        assertTrue(expectedAtMin != expectedAtMid, "fixture must separate the min and mid results");
        assertEq(IMinter_v3(minter).harvestable(), expectedAtMin, "harvestable must use the min rate");
    }

    // Owner path -------------------------------------------------------------

    /// A donation values the collateral supplied at the rate; a zero rate must revert, not credit it as nothing.
    function test_donateWrappedCollateral_zeroRate_reverts() public {
        (uint256 price, ) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);

        address donor = makeAddr("donor");
        deal(wrappedCollateralToken, donor, 1 ether);
        vm.startPrank(donor);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.InvalidRate.selector, uint256(0)));
        IMinter_v3(minter).donateWrappedCollateral(1 ether);
        vm.stopPrank();
    }

    /// The refusal must leave the record intact. Crediting a donation at a zero rate would add nothing while taking
    /// the collateral, and the donor's collateral would sit in the contract as unattributed surplus.
    function test_donateWrappedCollateral_zeroRate_leavesCollateralRatioUnchanged() public {
        (uint256 price, uint256 rate) = _seedWhileHealthy();
        uint256 collateralRatioBefore = IMinter_v3(minter).collateralRatio();

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);
        address donor = makeAddr("donor");
        deal(wrappedCollateralToken, donor, 1 ether);
        vm.startPrank(donor);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.InvalidRate.selector, uint256(0)));
        IMinter_v3(minter).donateWrappedCollateral(1 ether);
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

        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.ZeroPrice.selector, priceOracle, int256(0)));
        IMinter_v3(minter).mintPeggedToken(1 ether, address(this), 0);
    }

    /// Minting must not convert wrapped to underlying collateral at a zero rate.
    function test_mintPeggedToken_zeroRate_reverts() public {
        (uint256 price, ) = _seedWhileHealthy();
        _fundAndApprove(address(this), 10 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);

        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.InvalidRate.selector, uint256(0)));
        IMinter_v3(minter).mintPeggedToken(1 ether, address(this), 0);
    }

    /// Redeeming pegged tokens reads the max price; that path must reject a zero too.
    function test_redeemPeggedToken_zeroPrice_reverts() public {
        (, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, rate);

        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.ZeroPrice.selector, priceOracle, int256(0)));
        IMinter_v3(minter).redeemPeggedToken(1 ether, zeroFee, 0);
        vm.stopPrank();
    }

    /// Redeeming leveraged tokens reads the min price; that path must reject a zero too.
    function test_redeemLeveragedToken_zeroPrice_reverts() public {
        (, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, rate);

        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.ZeroPrice.selector, priceOracle, int256(0)));
        IMinter_v3(minter).redeemLeveragedToken(1 ether, zeroFee, 0);
        vm.stopPrank();
    }

    // Quote path -------------------------------------------------------------

    /// A quote must not return a zero-priced number the corresponding transaction would refuse to honour.
    function test_mintPeggedTokenDryRun_zeroPrice_reverts() public {
        (, uint256 rate) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, rate);

        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.ZeroPrice.selector, priceOracle, int256(0)));
        IMinter_v3(minter).mintPeggedTokenDryRun(1 ether);
    }

    /// The same quote must reject a zero rate.
    function test_mintPeggedTokenDryRun_zeroRate_reverts() public {
        (uint256 price, ) = _seedWhileHealthy();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0);

        vm.expectRevert(abi.encodeWithSelector(IPriceOracleErrors.InvalidRate.selector, uint256(0)));
        IMinter_v3(minter).mintPeggedTokenDryRun(1 ether);
    }
}
