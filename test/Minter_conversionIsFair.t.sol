// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {TestConversionBoundReleaseSetUp} from "@harbor-test/TestConversionBoundReleaseSetUp.sol";

/// @notice What the pegged-to-leveraged conversion must satisfy, whatever rule bounds it.
///
/// These are the requirements the conversion satisfies, written as assertions so that "the redesign is
/// finished" has an answer that is not a matter of opinion. They were written BEFORE the rule that meets
/// them and failed against the count cap it replaced, each failure naming which requirement that cap
/// broke. A suite written afterwards could only have confirmed whatever was built.
///
/// The rule: the market sells no leverage below its floor `K/(K-1)` - refused by name on every route - and
/// above it prices every conversion on the residual, the same rate the retail route gets. So each property
/// below holds where the market sells, and where it does not sell the property is that nothing is taken.
///
/// The properties are quantified over the collateral ratio and the size of the conversion, so they are
/// fuzzed rather than sampled; the two that are about a particular point - where a bound engages, and
/// where the residual vanishes - are written at those points instead.
///
/// One detail decides whether the first of them can see the defect at all. The pegged given up is
/// measured from the SUPPLY DELTA, not from the amount passed in. The rule in use reduces what it pays
/// without reducing what it takes, so a test that measured the argument would find the exchange fair by
/// construction and prove nothing. That asymmetry is the defect, and the measurement has to be able to
/// see it.
contract TestMinterConversionIsFair is TestConversionBoundReleaseSetUp {
    /// @dev Above the peg, where a residual exists for the leveraged to be a claim on and a fair rate is
    ///      therefore defined at all.
    uint256 private constant LOWEST_RATIO = 1.002 ether;
    uint256 private constant HIGHEST_RATIO = 1.6 ether;

    /// @dev What the market reports before and after one conversion, and what moved.
    struct Conversion {
        uint256 peggedTaken; // measured from the supply, not from the request
        uint256 leveragedGiven;
        uint256 peggedPrice;
        uint256 leveragedPrice;
    }

    /// @dev Put `peggedIn` through the conversion and report what actually moved.
    function _convert(uint256 peggedIn) private returns (Conversion memory done) {
        done.peggedPrice = IMinter_v3(minter).peggedTokenPrice();
        done.leveragedPrice = IMinter_v3(minter).leveragedTokenPrice();

        uint256 peggedSupplyBefore = IMinter(minter).peggedTokenBalance();
        (, done.leveragedGiven) = IMinter_v3(minter).freeRedeemPeggedToken(0, peggedIn, address(this));
        done.peggedTaken = peggedSupplyBefore - IMinter(minter).peggedTokenBalance();
    }

    /// R1. THE EXCHANGE RETURNS WHAT IT TOOK. Leveraged worth what the pegged was worth, at the prices the
    /// market reports when the conversion is made, whatever the collateral ratio and whatever the size.
    /// This is the requirement the count cap broke: it reduced the leveraged it paid without reducing the
    /// pegged it took, so the difference was simply kept. Below the floor the exchange is refused, and
    /// what it took is nothing.
    function testFuzz_theConversionReturnsWhatItTook(uint256 ratioSeed, uint256 shareSeed) public {
        uint256 collateralRatio = bound(ratioSeed, LOWEST_RATIO, HIGHEST_RATIO);
        uint256 share = bound(shareSeed, 0.0001 ether, 0.5 ether);
        marketActions.setCollateralRatioByPrice(collateralRatio);
        uint256 peggedIn = Math.mulDiv(IMinter(minter).peggedTokenBalance(), share, 1 ether);
        vm.assume(peggedIn > 0 && IERC20(peggedToken).balanceOf(address(this)) >= peggedIn);

        if (!IMinter_v3(minter).leveragedMintable()) {
            uint256 peggedSupply = IMinter(minter).peggedTokenBalance();
            vm.expectRevert(
                abi.encodeWithSelector(
                    IMinter_v3.BelowMinimumCollateralRatio.selector,
                    IMinter(minter).collateralRatio(),
                    releaseCollateralRatio()
                )
            );
            IMinter_v3(minter).freeRedeemPeggedToken(0, peggedIn, address(this));
            assertEq(IMinter(minter).peggedTokenBalance(), peggedSupply, "below the floor nothing is taken");
            return;
        }

        Conversion memory done = _convert(peggedIn);

        uint256 valueIn = Math.mulDiv(done.peggedTaken, done.peggedPrice, 1 ether);
        uint256 valueOut = Math.mulDiv(done.leveragedGiven, done.leveragedPrice, 1 ether);

        // Leveraged is minted as a whole number of tokens, so the exchange can be out by less than one of
        // them; the pegged's own valuation floors once more.
        assertApproxEqAbs(valueOut, valueIn, done.leveragedPrice + 1, "the conversion must return what it took");
    }

    /// R2. THERE IS NO CLIFF IN THE PRICE, ONLY A DOOR. Either side of the floor at which the market starts
    /// selling leverage, one part in a million apart: just below it the conversion is refused by name and
    /// nothing changes hands; just above it the conversion is priced on the residual, which is the fair rate.
    /// The count cap this replaced paid a fifth of the fair rate on the low side of its release and stepped to
    /// the whole of it on the high side; a refusal has no rate to step from.
    function test_theConversionRateDoesNotJumpWhereTheFloorReleases() public {
        uint256 release = releaseCollateralRatio();
        uint256 nudge = release / 1_000_000;
        assertGt(nudge, 0, "the two samples must actually differ in collateral ratio");

        marketActions.setCollateralRatioByPrice(release - nudge);
        uint256 ratioBelow = IMinter(minter).collateralRatio();
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratioBelow, release));
        IMinter_v3(minter).freeRedeemPeggedToken(0, PEGGED_IN, address(this));

        (uint256 bounded, uint256 released) = ratesAcrossTheRelease();
        assertEq(bounded, 0, "below the floor nothing is minted");

        marketActions.setCollateralRatioByPrice(release + nudge);
        // The fair rate is one pegged at par over the leveraged price. The count is floored to a token, and the
        // price the market reports is floored to a wei of its scale, which at this price is under a token of
        // the count: two tokens covers both.
        uint256 fair = (1 ether * 1 ether) / IMinter_v3(minter).leveragedTokenPrice();
        assertApproxEqAbs(released, fair, 2, "above it the conversion is the fair rate");
    }

    /// R3. THE POOL IS NEVER PAID LESS THAN ANYONE ELSE. The same move is available to any holder as two
    /// ordinary calls - redeem the pegged for collateral, mint leveraged with it - and neither is bounded. A
    /// protocol route that pays less than the retail route is a penalty for using it.
    function testFuzz_thePoolIsNeverPaidLessThanTheRetailRoute(uint256 ratioSeed) public {
        uint256 collateralRatio = bound(ratioSeed, LOWEST_RATIO, HIGHEST_RATIO);
        uint256 peggedIn = 1 ether;
        vm.assume(IERC20(peggedToken).balanceOf(address(this)) >= peggedIn);

        marketActions.setCollateralRatioByPrice(collateralRatio);

        if (!IMinter_v3(minter).leveragedMintable()) {
            // Below the floor BOTH routes are refused, by the same name: neither is paid, so neither is paid
            // less. The retail route's redeem goes through and lifts the ratio a hair, so the mint is judged
            // at the ratio it finds.
            uint256 release = releaseCollateralRatio();
            vm.expectRevert(
                abi.encodeWithSelector(
                    IMinter_v3.BelowMinimumCollateralRatio.selector,
                    IMinter(minter).collateralRatio(),
                    release
                )
            );
            IMinter_v3(minter).freeRedeemPeggedToken(0, peggedIn, address(this));

            uint256 collateralOut = IMinter_v3(minter).redeemPeggedToken(peggedIn, address(this), 0);
            uint256 ratioAtTheMint = IMinter(minter).collateralRatio();
            vm.assume(ratioAtTheMint < release);
            vm.expectRevert(
                abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratioAtTheMint, release)
            );
            IMinter_v3(minter).mintLeveragedToken(collateralOut, address(this), 0);
            return;
        }

        uint256 snapshot = vm.snapshotState();
        (, uint256 throughTheConversion) = IMinter_v3(minter).freeRedeemPeggedToken(0, peggedIn, address(this));
        vm.revertToState(snapshot);

        snapshot = vm.snapshotState();
        uint256 theLongWayRound;
        uint256 collateralOut = IMinter_v3(minter).redeemPeggedToken(peggedIn, address(this), 0);
        if (collateralOut > 0) {
            theLongWayRound = IMinter_v3(minter).mintLeveragedToken(collateralOut, address(this), 0);
        }
        vm.revertToState(snapshot);

        assertGe(
            throughTheConversion,
            theLongWayRound,
            "the rebalance's route must not pay less than the one open to everyone"
        );
    }

    /// R4. MINTING PER CONVERSION STAYS WITHIN A BOUND. Whatever else changes, one conversion may not mint
    /// without limit - which is the reason a bound exists at all. The refusal bounds the LEVERAGE sold, and
    /// that bounds the count: at any ratio the market sells at, the residual is at least `n/(K-1)` for a
    /// pegged supply `n`, so a unit of pegged value buys at most `(K-1) x S/n` leveraged, `S` the leveraged supply
    /// before the conversion. Below the floor nothing is minted at all.
    function testFuzz_mintingStaysWithinTheBound(uint256 ratioSeed, uint256 shareSeed) public {
        uint256 collateralRatio = bound(ratioSeed, LOWEST_RATIO, HIGHEST_RATIO);
        uint256 share = bound(shareSeed, 0.0001 ether, 0.5 ether);
        marketActions.setCollateralRatioByPrice(collateralRatio);
        uint256 peggedIn = Math.mulDiv(IMinter(minter).peggedTokenBalance(), share, 1 ether);
        vm.assume(peggedIn > 0 && IERC20(peggedToken).balanceOf(address(this)) >= peggedIn);

        _assertOneConversionStaysWithinTheBound(peggedIn);
    }

    /// R4 AT ITS EDGE. The bound is tightest where the market only just sells leverage, and a fuzzed collateral ratio
    /// lands there only by chance, so the leverage floor itself is a case of its own.
    function test_mintingStaysWithinTheBound_atExactlyTheLeverageFloor() public {
        uint256 release = releaseCollateralRatio();
        marketActions.setCollateralRatioByPrice(release);
        assertEq(
            IMinter(minter).collateralRatio(),
            release,
            "precondition: the market sits exactly at the leverage floor"
        );
        assertTrue(IMinter_v3(minter).leveragedMintable(), "precondition: and sells leverage there");
        uint256 peggedIn = IMinter(minter).peggedTokenBalance() / 2;
        assertGe(
            IERC20(peggedToken).balanceOf(address(this)),
            peggedIn,
            "precondition: this contract holds the pegged it converts"
        );

        _assertOneConversionStaysWithinTheBound(peggedIn);
    }

    /// @dev Converts `peggedIn` at the collateral ratio the market already stands at, and holds the result to R4:
    ///      within the bound where the market sells leverage, and nothing minted where it does not.
    function _assertOneConversionStaysWithinTheBound(uint256 peggedIn) private {
        uint256 leveragedBefore = IMinter(minter).leveragedTokenBalance();
        uint256 peggedSupply = IMinter(minter).peggedTokenBalance();

        if (!IMinter_v3(minter).leveragedMintable()) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IMinter_v3.BelowMinimumCollateralRatio.selector,
                    IMinter(minter).collateralRatio(),
                    releaseCollateralRatio()
                )
            );
            IMinter_v3(minter).freeRedeemPeggedToken(0, peggedIn, address(this));
            assertEq(IMinter(minter).leveragedTokenBalance(), leveragedBefore, "nothing is minted below the floor");
            return;
        }

        Conversion memory done = _convert(peggedIn);

        uint256 valueIn = Math.mulDiv(done.peggedTaken, done.peggedPrice, 1 ether);
        // At any collateral ratio the market sells leverage at, the residual is at least `n/(K-1)` for a pegged supply
        // `n`, so `valueIn` of pegged value buys at most `valueIn x (K-1) x S/n` leveraged, `S` the leveraged supply
        // before the conversion. The count is floored, so it never exceeds that.
        assertLe(
            done.leveragedGiven,
            Math.mulDiv(
                valueIn * (IMinter_v3(minter).MAX_LEVERAGE_RATIO() - 1 ether),
                leveragedBefore,
                peggedSupply * 1 ether
            ),
            "one conversion must not mint without limit"
        );
        assertGe(IMinter(minter).leveragedTokenBalance(), leveragedBefore, "and the supply cannot go backwards");
    }

    /// R5. THE CONVERSION IS REFUSED WHERE THE RESIDUAL VANISHES. Approaching the collateral ratio where the
    /// leveraged is worth nothing the fair rate is unbounded, and no finite count is a fair one. The market does
    /// not pretend otherwise: at every ratio below its floor the conversion is refused by name, the pegged
    /// offered stays with its holder, and the leveraged supply is untouched. A rebalance in that condition is the
    /// manager's to route around, not the minter's to settle by minting.
    function test_theConversionIsRefusedWhereTheResidualVanishes() public {
        // Just under the leverage floor, just over the peg, the peg, and far below it.
        uint256[4] memory ratios = [
            marketActions.collateralRatioBandsAboveThePeg(0.9 ether),
            marketActions.collateralRatioBandsAboveThePeg(0.1 ether),
            1 ether,
            0.5 ether
        ];
        uint256 release = releaseCollateralRatio();

        for (uint256 i = 0; i < ratios.length; i++) {
            uint256 snapshot = vm.snapshotState();
            marketActions.setCollateralRatioByPrice(ratios[i]);
            uint256 peggedSupply = IMinter(minter).peggedTokenBalance();
            uint256 leveragedSupply = IMinter(minter).leveragedTokenBalance();
            uint256 ratio = IMinter(minter).collateralRatio();
            assertLt(ratio, release, "every ratio here is below the floor");

            vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, release));
            IMinter_v3(minter).freeRedeemPeggedToken(0, 1 ether, address(this));

            assertEq(IMinter(minter).peggedTokenBalance(), peggedSupply, "the pegged stays with its holder");
            assertEq(IMinter(minter).leveragedTokenBalance(), leveragedSupply, "and nothing is minted");
            vm.revertToStateAndDelete(snapshot);
        }
    }
}
