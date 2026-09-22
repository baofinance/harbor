// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {TestConversionBoundReleaseSetUp} from "@harbor-test/TestConversionBoundReleaseSetUp.sol";

/// @notice What the anchor-to-sail conversion must satisfy, whatever rule bounds it.
///
/// These are the requirements the conversion is being redesigned against, written as assertions so that
/// "the redesign is finished" has an answer that is not a matter of opinion. They are deliberately
/// written BEFORE the redesign and are expected to fail against the rule in use - each failure naming
/// which requirement that rule breaks. A suite written afterwards could only confirm whatever was built.
///
/// The properties are quantified over the collateral ratio and the size of the conversion, so they are
/// fuzzed rather than sampled; the two that are about a particular point - where a bound engages, and
/// where the residual vanishes - are written at those points instead.
///
/// One detail decides whether the first of them can see the defect at all. The anchor given up is
/// measured from the SUPPLY DELTA, not from the amount passed in. The rule in use reduces what it pays
/// without reducing what it takes, so a test that measured the argument would find the exchange fair by
/// construction and prove nothing. That asymmetry is the defect, and the measurement has to be able to
/// see it.
contract TestMinterConversionIsFair is TestConversionBoundReleaseSetUp {
    /// @dev Above the peg, where a residual exists for the sail to be a claim on and a fair rate is
    ///      therefore defined at all.
    uint256 private constant LOWEST_RATIO = 1.002 ether;
    uint256 private constant HIGHEST_RATIO = 1.6 ether;

    /// @dev The floor under the sail's price that the design owes, as a share of the price a sail token
    ///      is worth when first minted. Every bound below is ONE OVER IT, because a conversion rate is
    ///      the anchor's price over the sail's and the sail's cannot go lower - so a floor on the price
    ///      is a ceiling on the rate, with no rule on any transaction anywhere.
    ///
    ///      Stated as what the DESIGN must provide rather than as what the code currently does. Nothing
    ///      provides it at present: the leverage ratio cap that used to bound the rate has been removed,
    ///      being a ceiling on the wrong quantity, and the reserve that will provide this one is not
    ///      built. So the two requirements using it fail, which is what a requirement written ahead of
    ///      its implementation is for.
    uint256 private constant REQUIRED_SAIL_PRICE_FLOOR = 0.01 ether;

    /// @dev What the market reports before and after one conversion, and what moved.
    struct Conversion {
        uint256 anchorTaken; // measured from the supply, not from the request
        uint256 sailGiven;
        uint256 anchorPrice;
        uint256 sailPrice;
    }

    /// @dev Put `anchorIn` through the conversion and report what actually moved.
    function _convert(uint256 anchorIn) private returns (Conversion memory done) {
        done.anchorPrice = IMinter_v3(minter).peggedTokenPrice();
        done.sailPrice = IMinter_v3(minter).leveragedTokenPrice();

        uint256 anchorSupplyBefore = IMinter(minter).peggedTokenBalance();
        (, done.sailGiven) = IMinter_v3(minter).freeRedeemPeggedToken(0, anchorIn, address(this));
        done.anchorTaken = anchorSupplyBefore - IMinter(minter).peggedTokenBalance();
    }

    /// @dev A conversion sized as a share of the anchor outstanding, at `collateralRatio`.
    function _convertShareAt(uint256 collateralRatio, uint256 share) private returns (Conversion memory done) {
        setCollateralRatio(collateralRatio);
        uint256 anchorIn = Math.mulDiv(IMinter(minter).peggedTokenBalance(), share, 1 ether);
        vm.assume(anchorIn > 0 && IERC20(peggedToken).balanceOf(address(this)) >= anchorIn);
        done = _convert(anchorIn);
    }

    /// R1. THE EXCHANGE RETURNS WHAT IT TOOK. Sail worth what the anchor was worth, at the prices the
    /// market reports when the conversion is made, whatever the collateral ratio and whatever the size.
    /// This is the requirement the rule in use breaks: it reduces the sail it pays without reducing the
    /// anchor it takes, so the difference is simply kept.
    function testFuzz_theConversionReturnsWhatItTook(uint256 ratioSeed, uint256 shareSeed) public {
        uint256 collateralRatio = bound(ratioSeed, LOWEST_RATIO, HIGHEST_RATIO);
        uint256 share = bound(shareSeed, 0.0001 ether, 0.5 ether);

        Conversion memory done = _convertShareAt(collateralRatio, share);

        uint256 valueIn = Math.mulDiv(done.anchorTaken, done.anchorPrice, 1 ether);
        uint256 valueOut = Math.mulDiv(done.sailGiven, done.sailPrice, 1 ether);

        // Sail is issued as a whole number of tokens, so the exchange can be out by less than one of
        // them; the anchor's own valuation floors once more.
        assertApproxEqAbs(valueOut, valueIn, done.sailPrice + 1, "the conversion must return what it took");
    }

    /// R2. THE RATE DOES NOT JUMP WHERE A BOUND ENGAGES. A conversion made either side of the collateral
    /// ratio at which the bound lets go must be priced almost identically; a step there is a cliff for
    /// anyone whose transaction lands on the wrong side of it.
    function test_theConversionRateDoesNotJumpWhereTheBoundReleases() public {
        uint256 nudge = releaseCollateralRatio() / 1_000_000;

        (uint256 inside, uint256 outside) = ratesAcrossTheRelease();

        // A millionth of a collateral ratio apart: anything the market does across that distance should
        // be far smaller than a percent, and today's step is five.
        assertApproxEqRel(inside, outside, 0.001 ether, "the conversion rate must not step where a bound releases");
        assertGt(nudge, 0, "the two samples must actually differ in collateral ratio");
    }

    /// R3. THE POOL IS NEVER PAID LESS THAN ANYONE ELSE. The same move is available to any holder as two
    /// ordinary calls - redeem the anchor for collateral, mint sail with it - and neither is bounded. A
    /// protocol route that pays less than the retail route is a penalty for using it.
    function testFuzz_thePoolIsNeverPaidLessThanTheRetailRoute(uint256 ratioSeed) public {
        uint256 collateralRatio = bound(ratioSeed, LOWEST_RATIO, HIGHEST_RATIO);
        uint256 anchorIn = 1 ether;
        vm.assume(IERC20(peggedToken).balanceOf(address(this)) >= anchorIn);

        setCollateralRatio(collateralRatio);

        uint256 snapshot = vm.snapshotState();
        (, uint256 throughTheConversion) = IMinter_v3(minter).freeRedeemPeggedToken(0, anchorIn, address(this));
        vm.revertToState(snapshot);

        snapshot = vm.snapshotState();
        uint256 theLongWayRound;
        uint256 collateralOut = IMinter_v3(minter).redeemPeggedToken(anchorIn, address(this), 0);
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

    /// R4. ISSUANCE PER CONVERSION STAYS WITHIN THE BOUND. Whatever else changes, one conversion may not
    /// issue without limit - which is the reason a bound exists at all. This is the requirement the rule
    /// in use DOES meet, and it is here so that a redesign cannot quietly drop it while fixing the rest.
    function testFuzz_issuanceStaysWithinTheBound(uint256 ratioSeed, uint256 shareSeed) public {
        uint256 collateralRatio = bound(ratioSeed, LOWEST_RATIO, HIGHEST_RATIO);
        uint256 share = bound(shareSeed, 0.0001 ether, 0.5 ether);

        uint256 sailBefore = IMinter(minter).leveragedTokenBalance();
        Conversion memory done = _convertShareAt(collateralRatio, share);

        // The rule in use caps the RATE at the leverage cap, so the sail issued cannot exceed that many
        // per unit of anchor value. A supply-relative rule bounds the same quantity a different way; what
        // matters to this requirement is that some finite bound holds.
        uint256 valueIn = Math.mulDiv(done.anchorTaken, done.anchorPrice, 1 ether);
        assertLe(
            done.sailGiven,
            Math.mulDiv(valueIn, 1 ether, REQUIRED_SAIL_PRICE_FLOOR) + 1,
            "one conversion must not issue without limit"
        );
        assertGe(IMinter(minter).leveragedTokenBalance(), sailBefore, "and the supply cannot go backwards");
    }

    /// R5. THE CONVERSION DOES NOT DIVERGE AS THE RESIDUAL VANISHES. Approaching the collateral ratio
    /// where the sail is worth nothing, the fair rate is unbounded; the conversion must stay finite and
    /// must not revert, because a rebalance has to work in exactly that condition.
    function test_theConversionStaysFiniteAsTheResidualVanishes() public {
        uint256[4] memory ratios = [uint256(1.02 ether), 1.002 ether, 1 ether, 0.5 ether];

        for (uint256 i = 0; i < ratios.length; i++) {
            uint256 snapshot = vm.snapshotState();
            setCollateralRatio(ratios[i]);

            uint256 anchorSupply = IMinter(minter).peggedTokenBalance();
            Conversion memory done = _convert(1 ether);

            assertGt(done.anchorTaken, 0, "the conversion must consume the anchor it was given");
            assertLe(
                done.sailGiven,
                Math.mulDiv(anchorSupply, 1 ether, REQUIRED_SAIL_PRICE_FLOOR),
                "and must not issue an unbounded quantity of sail where the residual has gone"
            );
            vm.revertToStateAndDelete(snapshot);
        }
    }
}
