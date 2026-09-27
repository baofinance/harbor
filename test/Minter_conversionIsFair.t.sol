// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {MinterEscrowFollowsCollateral} from "@harbor-test/candidates/MinterEscrowFollowsCollateral.sol";
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

    /// @dev The floor under the leveraged token's price that the design owes, AT A MARKET'S BIRTH, as a
    ///      share of what a leveraged token is worth when first minted. Every bound below is ONE OVER IT,
    ///      because a conversion rate is the pegged token's price over the leveraged token's and the
    ///      leveraged token's cannot go lower - so a floor on the price is a ceiling on the rate, with no
    ///      rule on any transaction anywhere.
    ///
    ///      "At a market's birth" is the whole of the difference between this and a constant. The escrow
    ///      that provides the floor is denominated in COLLATERAL, so what it is worth in pegged terms
    ///      moves with the collateral price: the floor is this share only while the collateral is worth
    ///      what it was when the first leveraged tokens were bought, and is this share times the price
    ///      move afterwards. A floor fixed in pegged terms would have to GROW as the collateral price
    ///      fell, which is the one thing a collateral-funded floor cannot do - so the design rejects it,
    ///      and a bound written here as a constant would be asserting a requirement that was considered
    ///      and declined rather than one not yet built.
    uint256 private constant REQUIRED_LEVERAGED_PRICE_FLOOR_AT_BIRTH = 0.01 ether;

    /// @dev The collateral price the conversion is settled at, taken from the edge the conversion reads.
    function _collateralPrice() private view returns (uint256 price) {
        // slither-disable-next-line unused-return the conversion settles at the high edge of the band
        (, price, , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

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

        // Taken before anything moves the price, so it is the price the first leveraged tokens were
        // bought at - which is what fixed the collateral escrowed per token, and so where the floor was
        // set. This market mints its whole supply in `setUp` and moves the price only afterwards.
        uint256 priceAtBirth = _collateralPrice();

        uint256 sailBefore = IMinter(minter).leveragedTokenBalance();
        Conversion memory done = _convertShareAt(collateralRatio, share);

        // The floor is a fixed quantity of COLLATERAL per leveraged token, so in the pegged terms this
        // bound is written in it is the birth share scaled by what the collateral price has done since.
        // Deriving it from the constant and the two prices rather than reading the escrow back from the
        // contract is what keeps this a statement of what the design OWES: a conversion that issued
        // against an escrow the contract had got wrong would still satisfy a bound read from that escrow.
        uint256 floorNow = Math.mulDiv(
            REQUIRED_LEVERAGED_PRICE_FLOOR_AT_BIRTH,
            _collateralPrice(),
            priceAtBirth
        );

        uint256 valueIn = Math.mulDiv(done.anchorTaken, done.anchorPrice, 1 ether);
        assertLe(
            done.sailGiven,
            Math.mulDiv(valueIn, 1 ether, floorNow) + 1,
            "one conversion must not issue without limit"
        );
        assertGe(IMinter(minter).leveragedTokenBalance(), sailBefore, "and the supply cannot go backwards");
    }

    /// R5. THE CONVERSION DOES NOT DIVERGE AS THE RESIDUAL VANISHES. Approaching the collateral ratio
    /// where the sail is worth nothing, the fair rate is unbounded; the conversion must stay finite and
    /// must not revert, because a rebalance has to work in exactly that condition.
    function test_theConversionStaysFiniteAsTheResidualVanishes() public {
        uint256[4] memory ratios = [uint256(1.02 ether), 1.002 ether, 1 ether, 0.5 ether];

        // Before the loop, and valid throughout it: each iteration reverts the price it set.
        uint256 priceAtBirth = _collateralPrice();

        for (uint256 i = 0; i < ratios.length; i++) {
            uint256 snapshot = vm.snapshotState();
            setCollateralRatio(ratios[i]);

            uint256 peggedSupply = IMinter(minter).peggedTokenBalance();
            Conversion memory done = _convert(1 ether);

            assertGt(done.anchorTaken, 0, "the conversion must consume the pegged it was given");
            assertLe(
                done.sailGiven,
                Math.mulDiv(
                    peggedSupply,
                    1 ether,
                    Math.mulDiv(REQUIRED_LEVERAGED_PRICE_FLOOR_AT_BIRTH, _collateralPrice(), priceAtBirth)
                ),
                "and must not issue an unbounded quantity of leveraged where the residual has gone"
            );
            vm.revertToStateAndDelete(snapshot);
        }
    }

    /// R6. BELOW A COLLATERAL RATIO OF ONE, THE CONVERSION MUST NOT OVERPAY AND MUST NOT MAKE THE RATIO
    /// WORSE.
    ///
    /// Below one the pegged token is worth less than par - its price is its share of the collateral, not
    /// its face value. A conversion that values what it burns at par therefore hands the converter more
    /// than they gave up, and the difference comes out of the pegged token's own backing: the holders a
    /// rebalance exists to rescue pay the premium to the party being rescued.
    ///
    /// Two assertions, because these are two distinct failures with one cause. The records between them
    /// claiming more than is held is a SOLVENCY statement - collateral has been promised twice. The
    /// collateral ratio falling is an EFFICACY one: a rebalance that lowers the ratio has done the
    /// opposite of its job.
    ///
    /// This regime only became reachable when the escrow was added. Before it, the leveraged claim below
    /// one was nothing, the conversion returned nothing, and `freeRedeemPeggedToken` refused to burn
    /// pegged for a zero return - so a valuation that is only correct at or above one was never evaluated
    /// anywhere else. The floor gave the claim a value here and the arithmetic came with it.
    function test_belowOne_theConversionNeitherOverpaysNorLowersTheRatio() public {
        setCollateralRatio(0.98 ether);

        uint256 ratioBefore = IMinter(minter).collateralRatio();
        _convert(IMinter(minter).peggedTokenBalance() / 100);

        (uint256 backing, uint256 escrow) = IMinter_v3(minter).collateralAccounts();
        // slither-disable-next-line unused-return only the conservative rate values the holding
        (, , uint256 minRate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 held = Math.mulDiv(IERC20(wrappedCollateralToken).balanceOf(minter), minRate, 1 ether);

        assertLe(backing + escrow, held, "the two records must not between them claim more than is held");
        assertGe(
            IMinter(minter).collateralRatio(),
            ratioBefore,
            "and the conversion must not lower the collateral ratio it exists to raise"
        );
    }

    /// R7. BELOW A COLLATERAL RATIO OF ONE, THE CONVERSION MUST RAISE THE RATIO. R6 asks only that it does
    /// not FALL, and a conversion that changes the ratio by nothing at all satisfies that while being
    /// useless: the rebalance's leveraged leg exists to recapitalise a market that is short, and below the
    /// peg it is the only leg that can. The collateral leg pays each pegged token its share of the backing,
    /// which is the average, so burning some leaves the ratio exactly where it was - arithmetic, not a
    /// defect. All the recapitalising below the peg has to come from here.
    ///
    /// The conversion is notionally a redemption of pegged followed by a mint of leveraged: the redemption
    /// frees the collateral backing that pegged, and the mint spends it on leveraged tokens - funding BOTH
    /// the backing and the escrow. Only the escrow's share leaves the pegged token's cover, so the backing
    /// falls by less than the claim does and the ratio rises. That holds at every collateral ratio above
    /// zero, because the escrow is a fraction of what is spent and never the whole of it.
    ///
    /// Measured across the ratio range rather than at a point: the requirement is that the leveraged leg
    /// works wherever a market can be, and a single sample cannot distinguish that from working at one
    /// ratio. `results/liquidate_partial_leveraged.csv` is the same measurement as a graph - the rows where
    /// a liquidation moves the ratio - and the count there is what this requirement is worth in practice.
    function testFuzz_belowOne_theConversionRaisesTheRatio(uint256 ratioSeed, uint256 shareSeed) public {
        // strictly below one, and above the dust where the market has nothing left to recapitalise with
        uint256 collateralRatio = bound(ratioSeed, 0.01 ether, 0.99 ether);
        uint256 share = bound(shareSeed, 0.01 ether, 0.5 ether);

        setCollateralRatio(collateralRatio);
        uint256 ratioBefore = IMinter(minter).collateralRatio();
        uint256 peggedIn = Math.mulDiv(IMinter(minter).peggedTokenBalance(), share, 1 ether);
        vm.assume(peggedIn > 0 && IERC20(peggedToken).balanceOf(address(this)) >= peggedIn);

        _convert(peggedIn);

        assertGt(
            IMinter(minter).collateralRatio(),
            ratioBefore,
            "a conversion below the peg must recapitalise, not merely decline to make things worse"
        );
    }
}

/// @notice The same requirements, asked of a candidate escrow rule instead of the rule in use.
///
/// This is what makes R1 to R7 an ACCEPTANCE TEST rather than a description of an intention: a candidate is
/// only a candidate if it satisfies the requirements the redesign was written against, and the two that
/// matter pull in opposite directions. R1 says the exchange must return what it took, which the rule in use
/// satisfies and which `main` breaks by capping what it pays. R7 says a conversion below the peg must raise
/// the collateral ratio, which `main` satisfies and which the rule in use breaks by moving collateral out of
/// the backing to fund an escrow. A candidate has to hold both at once, and nothing measured so far does.
contract TestMinterConversionIsFairFollowsCollateral is TestMinterConversionIsFair {
    function installEscrowRule() internal override {
        vm.startPrank(owner());
        UUPSUpgradeable(minter).upgradeToAndCall(
            address(new MinterEscrowFollowsCollateral(wrappedCollateralToken, peggedToken, leveragedToken)),
            ""
        );
        vm.stopPrank();
    }
}
