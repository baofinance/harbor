// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice The rebalance sizing reaches its target as the market measures it.
///
/// A rebalance asks the minter how much pegged to redeem to bring the collateral ratio to a target, redeems it, and
/// then acts on the ratio `collateralRatio()` reports. So redeeming the sized amount must land the ratio AT OR ABOVE
/// the target by that measure. Landing a fraction short matters most where the target is the floor below which the
/// market sells no leverage: the rebalance cannot take its second step, and every later call sized from the state it
/// left finds nothing, or too little, to do.
///
/// Three things could each leave the redemption off its target, and each test isolates one: the prices the sizing and
/// the payout read against the price the ratio is reported at, the rounding of the amount itself, and the rounding of
/// the backing where the held collateral is what decides it. Each sizes the collateral route alone - the leg whose
/// redemption moves the backing - and redeems exactly what it was told.
contract MinterRebalanceSizingTest is TestMinterSetUp {
    /// @dev The highest target the sweeps ask for. Well inside what the supply can reach by the collateral route
    ///      from the ratios they start at, so no sized amount exceeds the pegged outstanding.
    uint256 private constant HIGHEST_TARGET = 1.5 ether;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function _collateralRouteTo(uint256 target) private view returns (uint256 pegged) {
        (pegged, ) = IMinter_v3(minter).redeemPeggedForCollateralRatio(target, type(uint256).max, 0, 1, 0);
    }

    function _redeemForCollateral(uint256 pegged) private {
        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, pegged);
        IMinter(minter).freeRedeemPeggedToken(pegged, 0, zeroFee);
        vm.stopPrank();
    }

    /// The sizing and the redemption read the same price, the one the ratio is reported at. The oracle quotes a band
    /// and the ratio is reported at its middle; the redemption pays the stability pool at that middle too. So the
    /// trade lands ON the target: at or above it, and above it only by the sizing's own roundings, not by the band's
    /// width - sized at one edge and paid at another, it would land short of the target or redeem past it.
    ///
    /// The roundings, bounded: the amount is rounded up (less than one pegged wei) and sized against one wei less
    /// backing (`price / (T − 1)` pegged wei), and the payout floors away less than one collateral wei. Each extra
    /// pegged wei redeemed lifts the ratio by `(T − 1) / left` and each collateral wei kept by `price / left`, where
    /// `left` is the pegged outstanding afterwards - so the ratio lands at most `(2·price + T − 1) / left` above the
    /// target, before its own division floors it.
    function testFuzz_landsOnItsTarget_acrossAnOracleSpread(uint256 halfSpreadBps, uint256 target) public {
        setUp_collateral(100 ether, 3 ether); // a ratio of 1.03 at the mock's price
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        halfSpreadBps = bound(halfSpreadBps, 1, 500);
        uint256 halfSpread = Math.mulDiv(price, halfSpreadBps, 10_000);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price - halfSpread, price + halfSpread, rate, rate);
        target = bound(target, IMinter(minter).collateralRatio() + 1, HIGHEST_TARGET);

        _redeemForCollateral(_collateralRouteTo(target));

        uint256 landed = IMinter(minter).collateralRatio();
        uint256 roundingBound = Math.ceilDiv(2 * price + target - 1 ether, IMinter(minter).peggedTokenBalance());
        assertGe(landed, target, "the collateral route reaches its target");
        assertLe(landed, target + roundingBound, "the collateral route redeems no more than reaching it takes");
    }

    /// Where every conversion is exact - collateral priced at one pegged, a wrapped token worth one unit of it - the
    /// backing falls by exactly what is paid out, so only the rounding of the amount stands between the trade and
    /// its target. Rounded down, the amount stops a fraction of a wei short and the ratio a fraction below the
    /// target, which the reported ratio rounds down again; rounded up, it reaches the target.
    function testFuzz_reachesItsTarget_whereEveryConversionIsExact(uint256 target) public {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1 ether, 1 ether);
        setUp_collateral(100 ether, 3 ether); // a ratio of 1.03
        target = bound(target, IMinter(minter).collateralRatio() + 1, HIGHEST_TARGET);

        _redeemForCollateral(_collateralRouteTo(target));

        assertGe(IMinter(minter).collateralRatio(), target, "the collateral route reaches its target");
    }

    /// Where the wrapped-to-underlying rate has fallen below what the record assumes, the backing is the wrapped
    /// balance valued at the rate, rounded down. A redemption debits whole wrapped tokens, and the rounded valuation
    /// of what is left can fall one wei further than the collateral paid out. The sizing allows for that wei.
    function testFuzz_reachesItsTarget_whereTheHeldCollateralDecidesTheBacking(
        uint256 dropBps,
        uint256 startRatio,
        uint256 target
    ) public {
        setUp_collateral(100 ether, 40 ether);
        (, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        dropBps = bound(dropBps, 1, 5_000);
        uint256 impairedRate = rate - Math.mulDiv(rate, dropBps, 10_000);
        startRatio = bound(startRatio, 1.001 ether, 1.2 ether);
        marketActions.setCollateralRatioByWrapRate(startRatio, impairedRate);
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            Math.mulDiv(IERC20(wrappedCollateralToken).balanceOf(minter), impairedRate, 1 ether),
            "the held collateral, valued at the rate, is what decides the backing"
        );
        target = bound(target, IMinter(minter).collateralRatio() + 1, HIGHEST_TARGET);

        _redeemForCollateral(_collateralRouteTo(target));

        assertGe(IMinter(minter).collateralRatio(), target, "the collateral route reaches its target");
    }
}
