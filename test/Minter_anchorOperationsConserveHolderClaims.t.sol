// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {HarborTestActions} from "@harbor-test/HarborTestActions.sol";
import {TestMinterMint} from "@harbor-test/Minter_mint.t.sol";

/// @notice An anchor mint or redeem must not move value between the person doing it and everyone else,
/// at any collateral ratio and whether or not the backing is impaired. Exact equality is not the claim:
/// the record credits a floored amount, the held backing is floored on every read, and the tokens issued
/// or the collateral returned are floored too, so each operation may shift a price by a few wei in
/// either direction. Each test below bounds that shift by counting those roundings, and pairs it with a
/// collateral price move that must exceed the bound - so a bound loose enough to hide a real move fails.
///
/// The two regions ask different questions. Above a ratio of 1 the anchor price is pinned at 1 and the
/// sail token holds the residual, so the residual is what must be conserved. At or below 1 the residual
/// is zero and stays zero, making a sail assertion vacuous; there the anchor price is the live quantity.
contract MinterAnchorOperationsConserveHolderClaimsTest is TestMinterMint, HarborTestActions {
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
        setUp_collateral(1 ether, 1 ether); // both tokens issued, so both prices are live
        (, , startingRate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    /// @dev Set what the reserve pool holds. The bonus a redeem asks for is capped to this balance
    ///      before it is requested, so the balance decides which case a run exercises: nothing at all
    ///      gives a bonus of zero, a little caps the bonus part way, and plenty leaves it uncapped.
    ///      The pool sits outside the recognised backing, so its balance moves no price by itself.
    function _fundReservePool(uint256 balance) private {
        deal(wrappedCollateralToken, reservePool, balance);
    }

    /// @dev Put the market at `targetRatio` with the rate scaled to `rateBps` of its starting level.
    ///      The rate decides which figure the recognised backing comes from, so the range spans both:
    ///      below its starting level the record is overstated and RECOGNISING it brings the record down to
    ///      the held collateral, which is the impairment a price move cannot reach at any ratio; above it
    ///      the collateral has accrued and the record binds instead. A range that stopped at the starting
    ///      level would leave every run on the held branch and never price off the record at all.
    ///
    ///      Recognising the impairment a low rate creates is what the contract used to do implicitly, by
    ///      flooring the record against the holding on every read. That flooring has gone, so
    ///      `setCollateralRatioByRate` does it explicitly - and does it BEFORE deriving the price, since a
    ///      price aimed at a record that is about to be written down lands on the target only until it is.
    function _moveTo(uint256 targetRatio, uint256 rateBps) private {
        setCollateralRatioByRate(minter, priceOracle, targetRatio, (startingRate * rateBps) / 10_000);
    }

    function _price() private view returns (uint256 price) {
        (price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    function _rate() private view returns (uint256 rate) {
        (, , rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    /// @dev The collateral value left once every anchor token is covered - what the sail tokens share.
    ///      Scaled by 1e36: collateral wei times an 18-decimal price, against anchor wei times 1e18.
    function _sailResidual() private view returns (uint256) {
        uint256 backingValue = IMinter_v3(minter).collateralTokenBalance() * _price();
        uint256 anchorValue = IMinter_v3(minter).peggedTokenBalance() * 1 ether;
        if (backingValue <= anchorValue) {
            return 0;
        }
        return backingValue - anchorValue;
    }

    /// @dev A mint credits the record with a floored collateral amount while the held figure's own floor
    ///      may carry, so the backing moves by the collateral paid in plus an error strictly inside one
    ///      collateral wei either way; `min(record, held)` always moves between its two branches, so it
    ///      inherits that. The anchor issued is short of exact by under one anchor wei. Valuing those:
    ///      one collateral wei is `price`, one anchor wei is 1e18.
    function _mintResidualBounds() private view returns (uint256 upward, uint256 downward) {
        upward = _price() + 1 ether;
        downward = _price();
    }

    /// @dev A redeem is the mint's rounding plus the floor on the wrapped collateral paid out, which
    ///      leaves up to one wrapped wei - `rate / 1e18` collateral wei - behind. The anchor burnt is
    ///      exact. The `anchorIn` term covers the depegged case, where the anchor price the redeem
    ///      prices against is itself floored.
    function _redeemResidualBounds(uint256 anchorIn) private view returns (uint256 upward, uint256 downward) {
        uint256 price = _price();
        upward =
            Math.mulDiv(price, _rate(), 1 ether) +
            price +
            Math.ceilDiv(price, 1 ether) +
            Math.ceilDiv(anchorIn, 1 ether) +
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

    function _freeRedeem(uint256 anchorIn) private {
        vm.startPrank(zeroFee);
        IERC20(peggedToken).approve(minter, anchorIn);
        IMinter_v3(minter).freeRedeemPeggedToken(anchorIn, 0, receiver);
        vm.stopPrank();
    }

    /// @dev Raise the collateral price by a tenth. This is the one input that is supposed to move these
    ///      prices, so it is the control every test measures its tolerance against.
    function _raiseCollateralPrice() private {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer((_price() * 110) / 100, _rate());
    }

    /// @dev Lower the collateral price by a tenth. The control for the anchor price, which is capped at
    ///      1: at a ratio at or just under 1 a rise is absorbed by that cap and barely moves the price,
    ///      so only a fall measures what the anchor price does when the collateral behind it moves.
    function _lowerCollateralPrice() private {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer((_price() * 90) / 100, _rate());
    }

    /// @dev A fee-paying redeem is the free one plus a fee, paid to the fee receiver out of what the
    ///      redeemer would have received - so the market still parts with the anchor's par value and the
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
    function _feeRedeemResidualBounds(uint256 anchorIn) private view returns (uint256 upward, uint256 downward) {
        (uint256 freeUpward, uint256 freeDownward) = _redeemResidualBounds(anchorIn);
        uint256 twoWrappedWei = 2 * Math.mulDiv(_price(), _rate(), 1 ether);
        upward = freeUpward + twoWrappedWei;
        downward = freeDownward + _price() + twoWrappedWei;
    }

    /// @dev A fee-paying mint is the free one less the fee, which is taken from the collateral coming in
    ///      and sent to the fee receiver, so the market is credited with - and issues anchor against -
    ///      what is left. One more wrapped amount is floored than on the free path.
    function _feeMintResidualBounds() private view returns (uint256 upward, uint256 downward) {
        (uint256 freeUpward, uint256 freeDownward) = _mintResidualBounds();
        uint256 oneWrappedWei = Math.mulDiv(_price(), _rate(), 1 ether);
        upward = freeUpward + oneWrappedWei;
        downward = freeDownward + oneWrappedWei;
    }

    function _feeRedeem(uint256 anchorIn) private {
        vm.startPrank(zeroFee);
        IERC20(peggedToken).transfer(sender, anchorIn);
        vm.stopPrank();
        vm.startPrank(sender);
        IERC20(peggedToken).approve(minter, anchorIn);
        IMinter_v3(minter).redeemPeggedToken(anchorIn, sender, 0);
        vm.stopPrank();
    }

    function _feeMint(uint256 collateralIn) private {
        deal(wrappedCollateralToken, sender, collateralIn);
        vm.startPrank(sender);
        IERC20(wrappedCollateralToken).approve(minter, collateralIn);
        IMinter_v3(minter).mintPeggedToken(collateralIn, sender, 0);
        vm.stopPrank();
    }

    // ─── above a ratio of 1: the sail residual ───

    /// Minting anchor leaves the collateral value behind the sail tokens where it was, so a sail holder
    /// is not diluted by someone else buying anchor.
    function testFuzz_freeMintPeggedToken_conservesTheSailResidual(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 collateralIn
    ) public {
        _moveTo(bound(ratioSeed, 1.0001 ether, 3 ether), bound(rateBps, 5_000, 20_000));
        collateralIn = bound(collateralIn, 1e6, 5 ether);

        uint256 sailSupply = IERC20(leveragedToken).totalSupply();
        uint256 residualBefore = _sailResidual();
        uint256 sailPriceBefore = IMinter_v3(minter).leveragedTokenPrice();
        (uint256 upward, uint256 downward) = _mintResidualBounds();

        _freeMint(collateralIn);

        uint256 residualAfter = _sailResidual();
        assertLe(residualAfter, residualBefore + upward, "mint credited the sail residual beyond rounding");
        assertGe(residualAfter + downward, residualBefore, "mint took from the sail residual beyond rounding");

        // the sail supply is untouched by an anchor mint, so the residual's bound divides straight through
        uint256 sailPriceAfter = IMinter_v3(minter).leveragedTokenPrice();
        assertLe(sailPriceAfter, sailPriceBefore + _perToken(upward, sailSupply), "sail price rose beyond rounding");
        assertGe(sailPriceAfter + _perToken(downward, sailSupply), sailPriceBefore, "sail price fell beyond rounding");

        _raiseCollateralPrice();
        assertGt(
            _sailResidual() - residualAfter,
            upward,
            "a collateral price move must exceed the tolerance, or the bounds above prove nothing"
        );
    }

    /// Redeeming anchor for collateral likewise leaves the sail tokens' residual alone.
    function testFuzz_freeRedeemPeggedToken_conservesTheSailResidual(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 anchorSeed
    ) public {
        _moveTo(bound(ratioSeed, 1.0001 ether, 3 ether), bound(rateBps, 5_000, 20_000));
        uint256 anchorIn = bound(anchorSeed, 1e15, IERC20(peggedToken).balanceOf(zeroFee) / 2);

        uint256 sailSupply = IERC20(leveragedToken).totalSupply();
        uint256 residualBefore = _sailResidual();
        uint256 sailPriceBefore = IMinter_v3(minter).leveragedTokenPrice();
        (uint256 upward, uint256 downward) = _redeemResidualBounds(anchorIn);

        _freeRedeem(anchorIn);

        uint256 residualAfter = _sailResidual();
        assertLe(residualAfter, residualBefore + upward, "redeem credited the sail residual beyond rounding");
        assertGe(residualAfter + downward, residualBefore, "redeem took from the sail residual beyond rounding");

        uint256 sailPriceAfter = IMinter_v3(minter).leveragedTokenPrice();
        assertLe(sailPriceAfter, sailPriceBefore + _perToken(upward, sailSupply), "sail price rose beyond rounding");
        assertGe(sailPriceAfter + _perToken(downward, sailSupply), sailPriceBefore, "sail price fell beyond rounding");

        _raiseCollateralPrice();
        assertGt(
            _sailResidual() - residualAfter,
            upward,
            "a collateral price move must exceed the tolerance, or the bounds above prove nothing"
        );
    }

    // ─── at or below a ratio of 1: the anchor price ───

    /// While the market is depegged the anchor token is issued at its depressed price, so an existing
    /// anchor holder's claim on the collateral is no smaller after someone else mints than before.
    function testFuzz_depegged_freeMintPeggedToken_conservesTheAnchorPrice(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 collateralIn
    ) public {
        _moveTo(bound(ratioSeed, 0.01 ether, 1 ether), bound(rateBps, 5_000, 20_000));
        collateralIn = bound(collateralIn, 1e6, 5 ether);

        uint256 anchorPriceBefore = IMinter_v3(minter).peggedTokenPrice();
        assertGt(anchorPriceBefore, 0, "the anchor needs a price for this to assert anything");
        (uint256 upward, ) = _mintResidualBounds();

        _freeMint(collateralIn);

        // the claim is shared across the anchor supply the mint leaves behind
        uint256 tolerance = _perToken(upward, IMinter_v3(minter).peggedTokenBalance());
        uint256 anchorPriceAfter = IMinter_v3(minter).peggedTokenPrice();
        assertLe(anchorPriceAfter, anchorPriceBefore + tolerance, "mint raised the anchor price beyond rounding");
        assertGe(anchorPriceAfter + tolerance, anchorPriceBefore, "mint diluted the anchor price beyond rounding");

        _lowerCollateralPrice();
        assertGt(
            anchorPriceAfter - IMinter_v3(minter).peggedTokenPrice(),
            tolerance,
            "a collateral price move must exceed the tolerance, or the bounds above prove nothing"
        );
    }

    // ─── the same, with a fee paid ───

    /// A fee dilutes only the person paying it: the fee goes to the fee receiver out of what that person
    /// would have received, so the sail residual is left where it was.
    function testFuzz_mintPeggedToken_conservesTheSailResidual_whenFeePaid(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 collateralIn
    ) public {
        _moveTo(bound(ratioSeed, 1.0001 ether, 3 ether), bound(rateBps, 5_000, 20_000));
        collateralIn = bound(collateralIn, 1e6, 5 ether);

        (, uint256 fee, , , , ) = IMinter_v3(minter).mintPeggedTokenDryRun(collateralIn);
        assertGt(fee, 0, "a fee of zero would make this the free path under another name");

        uint256 residualBefore = _sailResidual();
        (uint256 upward, uint256 downward) = _feeMintResidualBounds();

        _feeMint(collateralIn);

        uint256 residualAfter = _sailResidual();
        assertLe(residualAfter, residualBefore + upward, "fee'd mint credited the sail residual beyond rounding");
        assertGe(residualAfter + downward, residualBefore, "fee'd mint took from the sail residual beyond rounding");

        _raiseCollateralPrice();
        assertGt(
            _sailResidual() - residualAfter,
            upward,
            "a collateral price move must exceed the tolerance, or the bounds above prove nothing"
        );
    }

    /// The same while depegged, where the anchor price is the live quantity.
    function testFuzz_depegged_mintPeggedToken_conservesTheAnchorPrice_whenFeePaid(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 collateralIn
    ) public {
        _moveTo(bound(ratioSeed, 0.01 ether, 1 ether), bound(rateBps, 5_000, 20_000));
        collateralIn = bound(collateralIn, 1e6, 5 ether);

        uint256 anchorPriceBefore = IMinter_v3(minter).peggedTokenPrice();
        assertGt(anchorPriceBefore, 0, "the anchor needs a price for this to assert anything");
        (uint256 upward, ) = _feeMintResidualBounds();

        _feeMint(collateralIn);

        uint256 tolerance = _perToken(upward, IMinter_v3(minter).peggedTokenBalance());
        uint256 anchorPriceAfter = IMinter_v3(minter).peggedTokenPrice();
        assertLe(anchorPriceAfter, anchorPriceBefore + tolerance, "fee'd mint raised the anchor price beyond rounding");
        assertGe(
            anchorPriceAfter + tolerance,
            anchorPriceBefore,
            "fee'd mint diluted the anchor price beyond rounding"
        );

        _lowerCollateralPrice();
        assertGt(
            anchorPriceAfter - IMinter_v3(minter).peggedTokenPrice(),
            tolerance,
            "a collateral price move must exceed the tolerance, or the bounds above prove nothing"
        );
    }

    /// A fee-paying redeem likewise leaves the sail residual alone, whether the incentive is a fee taken
    /// from the redeemer or a bonus drawn from the reserve pool and handed to them.
    function testFuzz_redeemPeggedToken_conservesTheSailResidual_whenFeePaid(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 anchorSeed,
        uint256 reserveSeed
    ) public {
        _moveTo(bound(ratioSeed, 1.0001 ether, 3 ether), bound(rateBps, 5_000, 20_000));
        uint256 anchorIn = bound(anchorSeed, 1e15, IERC20(peggedToken).balanceOf(zeroFee) / 2);
        _fundReservePool(bound(reserveSeed, 0, 1000 ether));

        uint256 residualBefore = _sailResidual();
        (uint256 upward, uint256 downward) = _feeRedeemResidualBounds(anchorIn);

        _feeRedeem(anchorIn);

        uint256 residualAfter = _sailResidual();
        assertLe(residualAfter, residualBefore + upward, "fee'd redeem credited the sail residual beyond rounding");
        assertGe(residualAfter + downward, residualBefore, "fee'd redeem took from the sail residual beyond rounding");

        _raiseCollateralPrice();
        assertGt(
            _sailResidual() - residualAfter,
            upward,
            "a collateral price move must exceed the tolerance, or the bounds above prove nothing"
        );
    }

    /// And the same while depegged, which is also where this configuration pays a bonus rather than
    /// charging a fee.
    function testFuzz_depegged_redeemPeggedToken_conservesTheAnchorPrice_whenFeePaid(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 anchorSeed,
        uint256 reserveSeed
    ) public {
        _moveTo(bound(ratioSeed, 0.01 ether, 1 ether), bound(rateBps, 5_000, 20_000));
        uint256 anchorIn = bound(anchorSeed, 1e15, IERC20(peggedToken).balanceOf(zeroFee) / 2);
        _fundReservePool(bound(reserveSeed, 0, 1000 ether));

        uint256 anchorPriceBefore = IMinter_v3(minter).peggedTokenPrice();
        assertGt(anchorPriceBefore, 0, "the anchor needs a price for this to assert anything");
        (uint256 upward, ) = _feeRedeemResidualBounds(anchorIn);

        _feeRedeem(anchorIn);

        uint256 tolerance = _perToken(upward, IMinter_v3(minter).peggedTokenBalance());
        uint256 anchorPriceAfter = IMinter_v3(minter).peggedTokenPrice();
        assertLe(
            anchorPriceAfter,
            anchorPriceBefore + tolerance,
            "fee'd redeem raised the anchor price beyond rounding"
        );
        assertGe(
            anchorPriceAfter + tolerance,
            anchorPriceBefore,
            "fee'd redeem diluted the anchor price beyond rounding"
        );

        _lowerCollateralPrice();
        assertGt(
            anchorPriceAfter - IMinter_v3(minter).peggedTokenPrice(),
            tolerance,
            "a collateral price move must exceed the tolerance, or the bounds above prove nothing"
        );
    }

    /// And redeeming anchor while depegged returns that holder's share and no more, leaving the price
    /// for everyone still holding where it was.
    function testFuzz_depegged_freeRedeemPeggedToken_conservesTheAnchorPrice(
        uint256 ratioSeed,
        uint256 rateBps,
        uint256 anchorSeed
    ) public {
        _moveTo(bound(ratioSeed, 0.01 ether, 1 ether), bound(rateBps, 5_000, 20_000));
        uint256 anchorIn = bound(anchorSeed, 1e15, IERC20(peggedToken).balanceOf(zeroFee) / 2);

        uint256 anchorPriceBefore = IMinter_v3(minter).peggedTokenPrice();
        assertGt(anchorPriceBefore, 0, "the anchor needs a price for this to assert anything");
        (uint256 upward, ) = _redeemResidualBounds(anchorIn);

        _freeRedeem(anchorIn);

        uint256 tolerance = _perToken(upward, IMinter_v3(minter).peggedTokenBalance());
        uint256 anchorPriceAfter = IMinter_v3(minter).peggedTokenPrice();
        assertLe(anchorPriceAfter, anchorPriceBefore + tolerance, "redeem raised the anchor price beyond rounding");
        assertGe(anchorPriceAfter + tolerance, anchorPriceBefore, "redeem diluted the anchor price beyond rounding");

        _lowerCollateralPrice();
        assertGt(
            anchorPriceAfter - IMinter_v3(minter).peggedTokenPrice(),
            tolerance,
            "a collateral price move must exceed the tolerance, or the bounds above prove nothing"
        );
    }
}
