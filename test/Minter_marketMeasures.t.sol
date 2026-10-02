// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice What the market reports about itself - its collateral ratio, its two token prices, its leverage ratio and
/// the incentive band each action is in - is read at the middle of the oracle's price band, the half-up average of
/// its edges, whichever edge a trade reads; and an incentive getter reports the band a trade is priced in.
contract TestMinterMarketMeasures is TestMinterSetUp {
    /// @dev Every action's ratio differs from band to band, so a getter's answer names the band it read. Bounds at
    ///      1.0, 1.1, 1.2, 1.3 and 1.4.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100, 110, 120, 130, 140), ia(10, 20, 30, 40, 50, 60)), // mint pegged
            ic(ua(100, 110, 120, 130, 140), ia(-15, -25, -35, -45, -55, 65)), // redeem pegged
            ic(ua(100, 110, 120, 130, 140), ia(-12, -22, -32, -42, -52, 62)), // mint leveraged
            ic(ua(100, 110, 120, 130, 140), ia(14, 24, 34, 44, 54, 64)) // redeem leveraged
        );
    }

    /// @dev A market at a collateral ratio of 1.05 at the middle of a price band from 0.9 to 1.1 plus a wei: 0.945 at
    ///      the low edge, 1.155 at the high one - the edges and the middle in three different bands. The edges' sum is
    ///      odd, so the middle is 1 + 1 wei only when the average is rounded half up.
    function _marketOnAPriceBand() private returns (uint256 middle) {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1 ether, 1 ether);
        setUp_collateral(10 ether, 0.5 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0.9 ether, 1.1 ether + 1, 1 ether, 1 ether);
        middle = 1 ether + 1;
    }

    /// The collateral ratio is the backing valued at the middle of the price band, against the pegged supply.
    function test_collateralRatio_readsTheMiddleOfThePriceBand() public {
        uint256 middle = _marketOnAPriceBand();
        assertEq(
            IMinter(minter).collateralRatio(),
            Math.mulDiv(IMinter(minter).collateralTokenBalance(), middle, IMinter(minter).peggedTokenBalance()),
            "the backing at the middle price, per pegged token"
        );
    }

    /// The pegged token's price is its claim on the backing at the middle of the price band: the peg wherever the
    /// middle covers the supply, as it does here though the low edge would not.
    function test_peggedTokenPrice_readsTheMiddleOfThePriceBand() public {
        _marketOnAPriceBand();
        assertEq(IMinter(minter).peggedTokenPrice(), 1 ether, "at the peg: the middle covers the pegged supply");
    }

    /// The leveraged token's price is the residual at the middle of the price band - the backing's value less the
    /// pegged claim - over the leveraged supply.
    function test_leveragedTokenPrice_readsTheMiddleOfThePriceBand() public {
        uint256 middle = _marketOnAPriceBand();
        uint256 residualE36 = IMinter(minter).collateralTokenBalance() * middle -
            IMinter(minter).peggedTokenBalance() * 1 ether;
        assertEq(
            IMinter(minter).leveragedTokenPrice(),
            Math.mulDiv(residualE36, 1 ether, IMinter(minter).leveragedTokenBalance()) / 1 ether,
            "the residual at the middle price, per leveraged token"
        );
    }

    /// The leverage ratio is the backing's value at the middle of the price band over the residual there.
    function test_leverageRatio_readsTheMiddleOfThePriceBand() public {
        uint256 middle = _marketOnAPriceBand();
        uint256 collateralValueE36 = IMinter(minter).collateralTokenBalance() * middle;
        assertEq(
            IMinter(minter).leverageRatio(),
            Math.mulDiv(
                collateralValueE36,
                1 ether,
                collateralValueE36 - IMinter(minter).peggedTokenBalance() * 1 ether
            ),
            "the backing's value over the residual, both at the middle price"
        );
    }

    /// Each incentive getter reports the band the middle of the price band puts the market in - not the band either
    /// edge would.
    function test_incentiveRatioGetters_readTheMiddleOfThePriceBand() public {
        _marketOnAPriceBand();
        assertEq(
            IMinter(minter).mintPeggedTokenIncentiveRatio(),
            config.mintPeggedIncentiveConfig.incentiveRatios[1],
            "mint pegged: the band from 1.0 to 1.1"
        );
        assertEq(
            IMinter(minter).redeemPeggedTokenIncentiveRatio(),
            config.redeemPeggedIncentiveConfig.incentiveRatios[1],
            "redeem pegged: the band from 1.0 to 1.1"
        );
        assertEq(
            IMinter(minter).mintLeveragedTokenIncentiveRatio(),
            config.mintLeveragedIncentiveConfig.incentiveRatios[1],
            "mint leveraged: the band from 1.0 to 1.1"
        );
        assertEq(
            IMinter(minter).redeemLeveragedTokenIncentiveRatio(),
            config.redeemLeveragedIncentiveConfig.incentiveRatios[1],
            "redeem leveraged: the band from 1.0 to 1.1"
        );
    }

    /// A zero price is data, reported as the oracle gives it: with pegged outstanding the collateral ratio is zero,
    /// neither token is worth anything, and the leverage ratio reports a claim on nothing.
    function test_marketMeasures_atAZeroPrice_valueTheBackingAtNothing() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1 ether, 1 ether);
        setUp_collateral(10 ether, 0.5 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, 1 ether);
        assertEq(IMinter(minter).collateralRatio(), 0, "collateral ratio");
        assertEq(IMinter(minter).peggedTokenPrice(), 0, "pegged token price");
        assertEq(IMinter(minter).leveragedTokenPrice(), 0, "leveraged token price");
        assertEq(IMinter(minter).leverageRatio(), type(uint256).max, "leverage ratio: a claim on nothing");
    }

    /// With no pegged supply the pegged token is at the peg by definition, so its price is reported without reading
    /// the oracle - an oracle that cannot answer does not stop it.
    function test_peggedTokenPrice_withNoPeggedSupply_doesNotReadTheOracle() public {
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "no pegged supply");
        bytes memory oracleDown = abi.encodeWithSignature("OracleDown()");
        vm.mockCallRevert(priceOracle, abi.encodeWithSelector(IWrappedPriceOracle.latestAnswer.selector), oracleDown);
        vm.expectRevert(oracleDown);
        IMinter(minter).collateralRatio(); // the oracle really cannot answer
        assertEq(IMinter(minter).peggedTokenPrice(), 1 ether, "the peg, without the oracle");
    }

    /// At a collateral ratio of exactly one the backing covers the pegged claim and nothing more, so a leveraged token
    /// is worth nothing - not the price a market with no leveraged supply reports.
    function test_leveragedTokenPrice_atACollateralRatioOfExactlyOne_isZero() public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1 ether, 1 ether);
        setUp_collateral(10 ether, 10 ether);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0.5 ether, 1 ether); // the backing worth the pegged exactly
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "the market at exactly one");
        assertGt(IMinter(minter).leveragedTokenBalance(), 0, "with leveraged supply");
        assertEq(IMinter(minter).leveragedTokenPrice(), 0, "a claim on no residual");
    }

    /// @dev A market exactly on the bound at 1.3, at one price - so the middle the getters read is the edge every trade
    ///      reads - with a reserve that pays a small trade's subsidy in full.
    function _marketOnTheBound() private {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1 ether, 1 ether);
        setUp_collateral(10 ether, 3 ether);
        assertEq(IMinter(minter).collateralRatio(), 1.3 ether, "the market exactly on the bound at 1.3");
        deal(wrappedCollateralToken, reservePool, 1 ether);
    }

    /// @dev The getter reports the band the trade is priced in, and a small trade's dry run is priced there: within
    ///      what a whole-wei fee or subsidy over the collateral it is measured against can move it (a wei, then the
    ///      division floored), and clear of the ratio across the bound. The two share a sign, so their magnitudes
    ///      discriminate.
    function _assertPricedIn(
        int256 reported,
        int256 traded,
        uint256 measuredAgainst,
        int256 expected,
        int256 acrossTheBound,
        string memory action
    ) private pure {
        assertEq(reported, expected, string.concat(action, ": the getter reports the band the trade is priced in"));
        assertEq(traded < 0, expected < 0, string.concat(action, ": a small trade is subsidised or charged alike"));
        assertDiscriminates(
            traded < 0 ? uint256(-traded) : uint256(traded),
            expected < 0 ? uint256(-expected) : uint256(expected),
            1 ether / measuredAgainst + 1,
            acrossTheBound < 0 ? uint256(-acrossTheBound) : uint256(acrossTheBound),
            string.concat(action, ": a small trade is priced in that band")
        );
    }

    /// On a bound, minting pegged lowers the ratio from it, so it is priced in the band below: its getter says so.
    function test_mintPeggedTokenIncentiveRatio_onABandBound_reportsTheBandTheTradeIsPricedIn() public {
        _marketOnTheBound();
        (int256 traded, , uint256 used, , , ) = IMinter(minter).mintPeggedTokenDryRun(0.1 ether);
        _assertPricedIn(
            IMinter(minter).mintPeggedTokenIncentiveRatio(),
            traded,
            used,
            config.mintPeggedIncentiveConfig.incentiveRatios[3],
            config.mintPeggedIncentiveConfig.incentiveRatios[4],
            "mint pegged"
        );
    }

    /// On a bound, redeeming pegged raises the ratio from it, so it is priced in the band above: its getter says so.
    function test_redeemPeggedTokenIncentiveRatio_onABandBound_reportsTheBandTheTradeIsPricedIn() public {
        _marketOnTheBound();
        (int256 traded, , , uint256 redeemed, , , ) = IMinter(minter).redeemPeggedTokenDryRun(0.1 ether);
        _assertPricedIn(
            IMinter(minter).redeemPeggedTokenIncentiveRatio(),
            traded,
            redeemed,
            config.redeemPeggedIncentiveConfig.incentiveRatios[4],
            config.redeemPeggedIncentiveConfig.incentiveRatios[3],
            "redeem pegged"
        );
    }

    /// On a bound, minting leveraged raises the ratio from it, so it is priced in the band above: its getter says so.
    function test_mintLeveragedTokenIncentiveRatio_onABandBound_reportsTheBandTheTradeIsPricedIn() public {
        _marketOnTheBound();
        (int256 traded, , , uint256 used, , , ) = IMinter(minter).mintLeveragedTokenDryRun(0.1 ether);
        _assertPricedIn(
            IMinter(minter).mintLeveragedTokenIncentiveRatio(),
            traded,
            used,
            config.mintLeveragedIncentiveConfig.incentiveRatios[4],
            config.mintLeveragedIncentiveConfig.incentiveRatios[3],
            "mint leveraged"
        );
    }

    /// On a bound, redeeming leveraged lowers the ratio from it, so it is priced in the band below: its getter says so.
    function test_redeemLeveragedTokenIncentiveRatio_onABandBound_reportsTheBandTheTradeIsPricedIn() public {
        _marketOnTheBound();
        (int256 traded, uint256 fee, , uint256 returned, , ) = IMinter(minter).redeemLeveragedTokenDryRun(0.1 ether);
        _assertPricedIn(
            IMinter(minter).redeemLeveragedTokenIncentiveRatio(),
            traded,
            returned + fee,
            config.redeemLeveragedIncentiveConfig.incentiveRatios[3],
            config.redeemLeveragedIncentiveConfig.incentiveRatios[4],
            "redeem leveraged"
        );
    }
}
