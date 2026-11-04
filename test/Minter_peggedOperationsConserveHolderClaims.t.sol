// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestMinterMint} from "@harbor-test/Minter_mint.t.sol";

/// @notice A pegged mint or redeem must not move value between the person doing it and everyone else,
/// at any collateral ratio and whether or not the backing is impaired. Exact equality is not the claim:
/// the record credits a floored amount, the held backing is floored on every read, and the tokens minted
/// or the collateral returned are floored too, so each operation may shift a price by a few wei in
/// either direction. Each test below bounds that shift by counting those roundings, and pairs it with a
/// collateral price move that must exceed the bound - so a bound loose enough to hide a real move fails.
///
/// The two regions ask different questions. Above a ratio of 1 the pegged price is pinned at 1 and the
/// leveraged token holds the residual, so the residual is what must be conserved. At or below 1 the residual
/// is zero and stays zero, making a leveraged assertion vacuous; there the pegged price is the live quantity.
contract MinterPeggedOperationsConserveHolderClaimsTest is TestMinterMint {
    uint256 private startingRate;

    /// @dev A configuration that disallows nothing, so the fee-paying paths can be exercised at every
    ///      ratio rather than only where a disallow band happens to permit them. Its redeem incentives
    ///      are negative below a ratio of 1.15 - a bonus drawn from the reserve pool rather than a fee
    ///      charged - so those runs exercise that flow as well.
    function setUpConfig() internal virtual override {
        setUp_config_likelyNoDisallow();
    }

    function setUp() public virtual override {
        super.setUp();
        setUp_collateral(1 ether, 1 ether); // both tokens minted, so both prices are live
        (, , startingRate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    /// @dev Set what the reserve pool holds. The bonus a redeem asks for is capped to this balance
    ///      before it is requested, so the balance decides which case a run exercises: nothing at all
    ///      gives a bonus of zero, a little caps the bonus part way, and plenty leaves it uncapped.
    ///      The pool sits outside the backing, so its balance moves no price by itself.
    function _fundReservePool(uint256 balance) private {
        deal(wrappedCollateralToken, reservePool, balance);
    }

    /// @dev Put the market at `targetRatio` with the rate scaled to `rateBps` of its starting level.
    ///      The rate decides which figure the backing comes from, so the range spans both: below its
    ///      starting level the record overstates the holding, the helper recognises the impairment, and
    ///      the held collateral is what the record is written down to - the impairment a price move
    ///      cannot reach at any ratio; above it the collateral has accrued and the record stands as
    ///      credited. A range that stopped at the starting level would leave every run on the held
    ///      branch and never price off an unimpaired record at all.
    function _moveTo(uint256 targetRatio, uint256 rateBps) private {
        marketActions.setCollateralRatioByWrapRate(targetRatio, (startingRate * rateBps) / 10_000);
    }

    function _price() private view returns (uint256 price) {
        (price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    function _rate() private view returns (uint256 rate) {
        (, , rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    /// @dev The collateral value left once every pegged token is covered - what the leveraged tokens share.
    ///      Scaled by 1e36: collateral wei times an 18-decimal price, against pegged wei times 1e18.
    function _leveragedResidual() private view returns (uint256) {
        uint256 backingValue = IMinter_v3(minter).collateralTokenBalance() * _price();
        uint256 peggedValue = IMinter_v3(minter).peggedTokenBalance() * 1 ether;
        if (backingValue <= peggedValue) {
            return 0;
        }
        return backingValue - peggedValue;
    }

    /// @dev A mint credits the record with a floored collateral amount, so the backing moves by the
    ///      collateral paid in less an error strictly inside one collateral wei; the bound allows the
    ///      wei either way. The pegged minted is short of exact by under one pegged wei. Valuing those:
    ///      one collateral wei is `price`, one pegged wei is 1e18.
    function _mintResidualBounds() private view returns (uint256 upward, uint256 downward) {
        upward = _price() + 1 ether;
        downward = _price();
    }

    /// @dev A redeem is the mint's rounding plus the floor on the wrapped collateral paid out, which
    ///      leaves up to one wrapped wei - `rate / 1e18` collateral wei - behind. The pegged burnt is
    ///      exact. The `peggedIn` term covers the depegged case, where the pegged price the redeem
    ///      prices against is itself floored.
    function _redeemResidualBounds(uint256 peggedIn) private view returns (uint256 upward, uint256 downward) {
        uint256 price = _price();
        upward =
            Math.mulDiv(price, _rate(), 1 ether) +
            price +
            Math.ceilDiv(price, 1 ether) +
            Math.ceilDiv(peggedIn, 1 ether) +
            1;
        downward = price;
    }

    /// @dev A bound on a value shared across `supply` tokens becomes a bound on the price of one, plus a
    ///      wei for the price's own floor.
    function _perToken(uint256 valueBound, uint256 supply) private pure returns (uint256) {
        return Math.ceilDiv(valueBound, supply) + 1;
    }

    function _freeMint(uint256 collateralIn) private {
        deal(wrappedCollateralToken, zeroFee, collateralIn);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, collateralIn);
        IMinter_v3(minter).freeMintPeggedToken(collateralIn, receiver);
        vm.stopPrank();
    }

    function _freeRedeem(uint256 peggedIn) private {
        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, peggedIn);
        IMinter_v3(minter).freeRedeemPeggedToken(peggedIn, 0, receiver);
        vm.stopPrank();
    }

    /// @dev Raise the collateral price by a tenth. This is the one input that is supposed to move these
    ///      prices, so it is the control every test measures its tolerance against.
    function _raiseCollateralPrice() private {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer((_price() * 110) / 100, _rate());
    }

    /// @dev Lower the collateral price by a tenth. The control for the pegged price, which is capped at
    ///      1: at a ratio at or just under 1 a rise is absorbed by that cap and barely moves the price,
    ///      so only a fall measures what the pegged price does when the collateral behind it moves.
    function _lowerCollateralPrice() private {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer((_price() * 90) / 100, _rate());
    }

    /// @dev A fee-paying redeem is the free one plus a fee, paid to the fee receiver out of what the
    ///      redeemer would have received - so the market still parts with the pegged's par value and the
    ///      fee is a flow straight through it. It rounds twice more than the free path: the fee is a
    ///      separately floored wrapped amount, and the record is debited by a *ceiled* collateral
    ///      amount, which charges the market up to a wei more rather than less.
    ///
    ///      One part of this rests on the band loop rather than on a count: it pro-rates the fee band by
    ///      band, accumulating each division's remainder and rounding to nearest, so its contribution
    ///      should stay under one unit of the 1e36 scale per division. That claim is what the fuzz is
    ///      really testing here - a violation would show as this bound being exceeded.
    ///
    ///      Two extra wrapped amounts are floored rather than one, because a bonus is drawn from the
    ///      reserve pool and paid out alongside the redemption in the bands where the incentive is
    ///      negative. Like the fee it passes through the market rather than staying in it.
    function _feeRedeemResidualBounds(uint256 peggedIn) private view returns (uint256 upward, uint256 downward) {
        (uint256 freeUpward, uint256 freeDownward) = _redeemResidualBounds(peggedIn);
        uint256 twoWrappedWei = 2 * Math.mulDiv(_price(), _rate(), 1 ether);
        upward = freeUpward + twoWrappedWei;
        downward = freeDownward + _price() + twoWrappedWei;
    }

    /// @dev The most a fee-paying mint above a ratio of 1 credits the leveraged residual with, for the number of
    ///      wrapped amounts it rounds. It never debits it: the pegged minted is capped at what the collateral the
    ///      record gains buys. The record gains what the wrapped taken, less the wrapped fee, converts to, while the
    ///      pegged is minted against the exact collateral the bands add - so the residual keeps what rounding those
    ///      wrapped amounts leaves behind, under a wrapped wei each. The fee is floored on every mint: one rounding.
    ///      The wrapped taken is the offer exactly where the whole offer is taken, and where the mint is cut short of
    ///      it is rounded up to cover what the bands used: a second. The pegged minted is floored as well, short of
    ///      exact by under one pegged wei. Valuing those: one wrapped wei is `price * rate / 1e18`, rounded up so the
    ///      bound is never itself short; one pegged wei is 1e18.
    function _feeMintResidualCredit(uint256 wrappedRoundings) private view returns (uint256 upward) {
        upward = wrappedRoundings * Math.mulDiv(_price(), _rate(), 1 ether, Math.Rounding.Ceil) + 1 ether;
    }

    function _feeRedeem(uint256 peggedIn) private {
        vm.startPrank(zeroFee);
        IERC20(peggedToken).transfer(sender, peggedIn);
        vm.stopPrank();
        vm.startPrank(sender);
        IERC20(peggedToken).approve(minter, peggedIn);
        IMinter_v3(minter).redeemPeggedToken(peggedIn, sender, 0);
        vm.stopPrank();
    }

    function _feeMint(uint256 collateralIn) private {
        deal(wrappedCollateralToken, sender, collateralIn);
        vm.startPrank(sender);
        IERC20(wrappedCollateralToken).approve(minter, collateralIn);
        IMinter_v3(minter).mintPeggedToken(collateralIn, sender, 0);
        vm.stopPrank();
    }

    // ─── above a ratio of 1: the leveraged residual ───

    /// Minting pegged leaves the collateral value behind the leveraged tokens where it was, so a leveraged
    /// holder is not diluted by someone else buying pegged.
    function testFuzz_freeMintPeggedToken_conservesTheLeveragedResidual(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 collateralIn
    ) public {
        _moveTo(bound(ratioSeed, 1.0001 ether, 3 ether), bound(rateBps, 5_000, 20_000));
        collateralIn = bound(collateralIn, 1e6, 5 ether);

        uint256 leveragedSupply = IERC20(leveragedToken).totalSupply();
        uint256 residualBefore = _leveragedResidual();
        uint256 leveragedPriceBefore = IMinter_v3(minter).leveragedTokenPrice();
        (uint256 upward, uint256 downward) = _mintResidualBounds();

        _freeMint(collateralIn);

        uint256 residualAfter = _leveragedResidual();
        assertLe(residualAfter, residualBefore + upward, "mint credited the leveraged residual beyond rounding");
        assertGe(residualAfter + downward, residualBefore, "mint took from the leveraged residual beyond rounding");

        // the leveraged supply is untouched by a pegged mint, so the residual's bound divides straight through
        uint256 leveragedPriceAfter = IMinter_v3(minter).leveragedTokenPrice();
        assertLe(
            leveragedPriceAfter,
            leveragedPriceBefore + _perToken(upward, leveragedSupply),
            "leveraged price rose beyond rounding"
        );
        assertGe(
            leveragedPriceAfter + _perToken(downward, leveragedSupply),
            leveragedPriceBefore,
            "leveraged price fell beyond rounding"
        );

        _raiseCollateralPrice();
        assertGt(
            _leveragedResidual() - residualAfter,
            upward,
            "a collateral price move must exceed the tolerance, or the bounds above prove nothing"
        );
    }

    /// Redeeming pegged for collateral likewise leaves the leveraged tokens' residual alone.
    function testFuzz_freeRedeemPeggedToken_conservesTheLeveragedResidual(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 peggedSeed
    ) public {
        _moveTo(bound(ratioSeed, 1.0001 ether, 3 ether), bound(rateBps, 5_000, 20_000));
        uint256 peggedIn = bound(peggedSeed, 1e15, IERC20(peggedToken).balanceOf(zeroFee) / 2);

        uint256 leveragedSupply = IERC20(leveragedToken).totalSupply();
        uint256 residualBefore = _leveragedResidual();
        uint256 leveragedPriceBefore = IMinter_v3(minter).leveragedTokenPrice();
        (uint256 upward, uint256 downward) = _redeemResidualBounds(peggedIn);

        _freeRedeem(peggedIn);

        uint256 residualAfter = _leveragedResidual();
        assertLe(residualAfter, residualBefore + upward, "redeem credited the leveraged residual beyond rounding");
        assertGe(residualAfter + downward, residualBefore, "redeem took from the leveraged residual beyond rounding");

        uint256 leveragedPriceAfter = IMinter_v3(minter).leveragedTokenPrice();
        assertLe(
            leveragedPriceAfter,
            leveragedPriceBefore + _perToken(upward, leveragedSupply),
            "leveraged price rose beyond rounding"
        );
        assertGe(
            leveragedPriceAfter + _perToken(downward, leveragedSupply),
            leveragedPriceBefore,
            "leveraged price fell beyond rounding"
        );

        _raiseCollateralPrice();
        assertGt(
            _leveragedResidual() - residualAfter,
            upward,
            "a collateral price move must exceed the tolerance, or the bounds above prove nothing"
        );
    }

    // ─── at or below a ratio of 1: the pegged price ───

    /// While the market is depegged the pegged token is minted at its depressed price, so an existing
    /// pegged holder's claim on the collateral is no smaller after someone else mints than before.
    function testFuzz_depegged_freeMintPeggedToken_conservesThePeggedPrice(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 collateralIn
    ) public {
        _moveTo(bound(ratioSeed, 0.01 ether, 1 ether), bound(rateBps, 5_000, 20_000));
        collateralIn = bound(collateralIn, 1e6, 5 ether);

        uint256 peggedPriceBefore = IMinter_v3(minter).peggedTokenPrice();
        assertGt(peggedPriceBefore, 0, "the pegged token needs a price for this to assert anything");
        (uint256 upward, ) = _mintResidualBounds();

        _freeMint(collateralIn);

        // the claim is shared across the pegged supply the mint leaves behind
        uint256 tolerance = _perToken(upward, IMinter_v3(minter).peggedTokenBalance());
        uint256 peggedPriceAfter = IMinter_v3(minter).peggedTokenPrice();
        assertLe(peggedPriceAfter, peggedPriceBefore + tolerance, "mint raised the pegged price beyond rounding");
        assertGe(peggedPriceAfter + tolerance, peggedPriceBefore, "mint diluted the pegged price beyond rounding");

        _lowerCollateralPrice();
        assertGt(
            peggedPriceAfter - IMinter_v3(minter).peggedTokenPrice(),
            tolerance,
            "a collateral price move must exceed the tolerance, or the bounds above prove nothing"
        );
    }

    // ─── the same, with a fee paid ───

    /// A fee dilutes only the person paying it: the fee goes to the fee receiver out of what that person
    /// would have received, so the leveraged residual is left where it was - never lower, and higher only by the
    /// mint's rounding. From a ratio of 1.02 up: far enough above the min CR, where a fee-paying mint is cut short, for
    /// the mint to take enough to pay a whole wei of fee. Some runs are taken whole and some cut short, so the bound
    /// is the cut mint's two wrapped roundings.
    function testFuzz_mintPeggedToken_conservesTheLeveragedResidual_whenFeePaid(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 collateralIn
    ) public {
        _moveTo(bound(ratioSeed, 1.02 ether, 3 ether), bound(rateBps, 5_000, 20_000));
        collateralIn = bound(collateralIn, 1e6, 5 ether);

        (, uint256 fee, , , , ) = IMinter_v3(minter).mintPeggedTokenDryRun(collateralIn);
        assertGt(fee, 0, "a fee of zero would make this the free path under another name");

        uint256 residualBefore = _leveragedResidual();
        uint256 upward = _feeMintResidualCredit(2);

        _feeMint(collateralIn);

        uint256 residualAfter = _leveragedResidual();
        assertLe(residualAfter, residualBefore + upward, "fee'd mint credited the leveraged residual beyond rounding");
        assertGe(residualAfter, residualBefore, "fee'd mint took from the leveraged residual");

        _raiseCollateralPrice();
        assertGt(
            _leveragedResidual() - residualAfter,
            upward,
            "a collateral price move must exceed the tolerance, or the bounds above prove nothing"
        );
    }

    /// A mint cut short of its offer - by the min CR, as this configuration disallows nothing - conserves the
    /// leveraged residual too, and is where the second wrapped rounding shows: at this ratio, rate and offer the
    /// residual gains more than the one wrapped rounding of a mint taken whole can leave, and no more than the two.
    function test_mintPeggedToken_cutShort_conservesTheLeveragedResidual() public {
        _moveTo(1.02 ether + 3, 15_024);
        uint256 collateralIn = 5 ether - 9_252;

        (, , uint256 collateralUsed, , , ) = IMinter_v3(minter).mintPeggedTokenDryRun(collateralIn);
        assertLt(collateralUsed, collateralIn, "precondition: the mint is cut short of the offer");

        uint256 residualBefore = _leveragedResidual();
        uint256 takenWhole = _feeMintResidualCredit(1);
        uint256 cutShort = _feeMintResidualCredit(2);

        _feeMint(collateralIn);

        uint256 residualAfter = _leveragedResidual();
        assertGt(residualAfter, residualBefore + takenWhole, "the cut rounds a second wrapped amount");
        assertLe(residualAfter, residualBefore + cutShort, "and the residual gains no more than the two leave");
    }

    /// While depegged there is no fee-paying mint to conserve anything: at or below the min CR it reverts, naming the
    /// ratio and the minimum, at every ratio and rate, and so moves neither the pegged price nor a wei of collateral.
    function testFuzz_depegged_mintPeggedToken_reverts_whenFeePaid(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 collateralIn
    ) public {
        _moveTo(bound(ratioSeed, 0.01 ether, 1 ether), bound(rateBps, 5_000, 20_000));
        collateralIn = bound(collateralIn, 1e6, 5 ether);
        bytes memory belowMinimum = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            IMinter_v3(minter).collateralRatio(),
            IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()
        );

        deal(wrappedCollateralToken, sender, collateralIn);
        vm.startPrank(sender);
        IERC20(wrappedCollateralToken).approve(minter, collateralIn);
        vm.expectRevert(belowMinimum);
        IMinter_v3(minter).mintPeggedToken(collateralIn, sender, 0);
        vm.stopPrank();
    }

    /// A fee-paying redeem likewise leaves the leveraged residual alone, whether the incentive is a fee taken
    /// from the redeemer or a bonus drawn from the reserve pool and handed to them.
    function testFuzz_redeemPeggedToken_conservesTheLeveragedResidual_whenFeePaid(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 peggedSeed,
        uint256 reserveSeed
    ) public {
        _moveTo(bound(ratioSeed, 1.0001 ether, 3 ether), bound(rateBps, 5_000, 20_000));
        uint256 peggedIn = bound(peggedSeed, 1e15, IERC20(peggedToken).balanceOf(zeroFee) / 2);
        _fundReservePool(bound(reserveSeed, 0, 1000 ether));

        uint256 residualBefore = _leveragedResidual();
        (uint256 upward, uint256 downward) = _feeRedeemResidualBounds(peggedIn);

        _feeRedeem(peggedIn);

        uint256 residualAfter = _leveragedResidual();
        assertLe(
            residualAfter,
            residualBefore + upward,
            "fee'd redeem credited the leveraged residual beyond rounding"
        );
        assertGe(
            residualAfter + downward,
            residualBefore,
            "fee'd redeem took from the leveraged residual beyond rounding"
        );

        _raiseCollateralPrice();
        assertGt(
            _leveragedResidual() - residualAfter,
            upward,
            "a collateral price move must exceed the tolerance, or the bounds above prove nothing"
        );
    }

    /// And the same while depegged, which is also where this configuration pays a bonus rather than
    /// charging a fee.
    function testFuzz_depegged_redeemPeggedToken_conservesThePeggedPrice_whenFeePaid(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 peggedSeed,
        uint256 reserveSeed
    ) public {
        _moveTo(bound(ratioSeed, 0.01 ether, 1 ether), bound(rateBps, 5_000, 20_000));
        uint256 peggedIn = bound(peggedSeed, 1e15, IERC20(peggedToken).balanceOf(zeroFee) / 2);
        _fundReservePool(bound(reserveSeed, 0, 1000 ether));

        uint256 peggedPriceBefore = IMinter_v3(minter).peggedTokenPrice();
        assertGt(peggedPriceBefore, 0, "the pegged token needs a price for this to assert anything");
        (uint256 upward, ) = _feeRedeemResidualBounds(peggedIn);

        _feeRedeem(peggedIn);

        uint256 tolerance = _perToken(upward, IMinter_v3(minter).peggedTokenBalance());
        uint256 peggedPriceAfter = IMinter_v3(minter).peggedTokenPrice();
        assertLe(
            peggedPriceAfter,
            peggedPriceBefore + tolerance,
            "fee'd redeem raised the pegged price beyond rounding"
        );
        assertGe(
            peggedPriceAfter + tolerance,
            peggedPriceBefore,
            "fee'd redeem diluted the pegged price beyond rounding"
        );

        _lowerCollateralPrice();
        assertGt(
            peggedPriceAfter - IMinter_v3(minter).peggedTokenPrice(),
            tolerance,
            "a collateral price move must exceed the tolerance, or the bounds above prove nothing"
        );
    }

    /// And redeeming pegged while depegged returns that holder's share and no more, leaving the price
    /// for everyone still holding where it was.
    function testFuzz_depegged_freeRedeemPeggedToken_conservesThePeggedPrice(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 peggedSeed
    ) public {
        _moveTo(bound(ratioSeed, 0.01 ether, 1 ether), bound(rateBps, 5_000, 20_000));
        uint256 peggedIn = bound(peggedSeed, 1e15, IERC20(peggedToken).balanceOf(zeroFee) / 2);

        uint256 peggedPriceBefore = IMinter_v3(minter).peggedTokenPrice();
        assertGt(peggedPriceBefore, 0, "the pegged token needs a price for this to assert anything");
        (uint256 upward, ) = _redeemResidualBounds(peggedIn);

        _freeRedeem(peggedIn);

        uint256 tolerance = _perToken(upward, IMinter_v3(minter).peggedTokenBalance());
        uint256 peggedPriceAfter = IMinter_v3(minter).peggedTokenPrice();
        assertLe(peggedPriceAfter, peggedPriceBefore + tolerance, "redeem raised the pegged price beyond rounding");
        assertGe(peggedPriceAfter + tolerance, peggedPriceBefore, "redeem diluted the pegged price beyond rounding");

        _lowerCollateralPrice();
        assertGt(
            peggedPriceAfter - IMinter_v3(minter).peggedTokenPrice(),
            tolerance,
            "a collateral price move must exceed the tolerance, or the bounds above prove nothing"
        );
    }
}
