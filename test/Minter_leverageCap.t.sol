// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

import {LocalMarket} from "@harbor-test/harness/LocalMarket.sol";

/// @notice The leverage cap: the minter refuses to sell leverage below `K/(K-1)`, on every route alike, judged
///         on the state the sale is priced at; above the floor it sells at the residual's price, uncapped.
///
/// The market is the one the liquidate graph measures - `0.4` of the founding pegged in EACH stability pool -
/// because a rebalance with both legs is the case that separates "the state the sale is priced at" from "the
/// record as the redeem has so far updated it". With only a leveraged pool the two never differ.
contract MinterLeverageCapTest is LocalMarket {
    address internal keeper;

    function setUp() public override {
        super.setUp();
        // Named for the provenance file: forge runs suites in parallel, and two markets writing under one name
        // would race on it.
        standUpMarket(0.4 ether, 0.4 ether, string.concat(marketLabel(), "_leverageCapUnitTest"));
        keeper = makeAddr("keeper");
    }

    /// The floor is the cap: `K/(K-1)`, so that the leverage sold at the floor is exactly `K`.
    function test_theFloorIsWhereTheLeverageSoldWouldBeTheCap() public view {
        uint256 cap = IMinter_v3(market.minter).MAX_LEVERAGE_RATIO();
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        // `beta = CR/(CR-1)` at the floor. The floor is `K/(K-1)` floored to its 1e18 scale, so it is short of
        // the exact ratio by less than one unit, and `beta` moves by `1e36 / (floor - 1e18)^2` per unit of
        // the floor - about 361 here - so that is the most the two can differ by. The measured 19 is inside
        // it; a floor derived from the wrong cap would miss by orders of magnitude.
        uint256 betaAtFloor = (floor * 1 ether) / (floor - 1 ether);
        uint256 tolerance = 1e36 / ((floor - 1 ether) * (floor - 1 ether));
        assertApproxEqAbs(betaAtFloor, cap, tolerance, "the leverage sold at the floor is the cap");
    }

    /// A rebalance from ABOVE the floor proceeds and lands on the threshold, when its collateral leg alone would
    /// have moved a half-applied record below the floor.
    ///
    /// A rebalance with both legs takes the collateral leg first. That leg debits the recorded backing before
    /// the conversion is reached, while the pegged it burned is recorded only once both legs are done - so a
    /// rule reading the record at the conversion would see `CR - x`, `x` being the collateral leg's share of
    /// the supply. From 1.10 with these pools that reads 0.975, which is below the floor; the market stands at
    /// 1.10, which is above it. The sale is priced on the market, so the rule judges the market.
    function test_rebalanceAboveTheFloorProceeds_judgedOnThePricedStateNotAHalfAppliedRecord() public {
        setMarketCollateralRatio(1.1 ether);
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        assertGe(IMinter(market.minter).collateralRatio(), floor, "precondition: the market is above the floor");
        uint256 leveragedPoolPeggedBefore = IERC20(market.pegged).balanceOf(market.leveragedPool);
        uint256 threshold = IStabilityPoolManager(market.manager).rebalanceThreshold();

        vm.startPrank(keeper);
        IStabilityPoolManager(market.manager).rebalance(keeper, 0);
        vm.stopPrank();

        // The sizing floors the pegged it burns to the wei, and the ratio it lands on is `backing x price /
        // pegged` floored to the wei of its 1e18 scale - so the landing is at most one unit under the target.
        assertApproxEqAbs(
            IMinter(market.minter).collateralRatio(),
            threshold,
            1,
            "the rebalance lands on the threshold"
        );
        assertLt(
            IERC20(market.pegged).balanceOf(market.leveragedPool),
            leveragedPoolPeggedBefore,
            "the leveraged leg converted"
        );
    }

    /// Below the floor the rule refuses the conversion - the free redeem's leveraged leg, the route a rebalance
    /// converts by - reporting the ratio the market is priced at, the figure `collateralRatio()` prints, and the
    /// floor it wanted; and refusing takes nothing from the holder. A rebalance never asks for a conversion there,
    /// taking the collateral route instead, so this is the minter's own guard, reached directly.
    function test_conversionBelowTheFloorIsRefused_namingTheRatioTheMarketIsPricedAt() public {
        setMarketCollateralRatio(1.05 ether);
        uint256 ratio = IMinter(market.minter).collateralRatio();
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        assertLt(ratio, floor, "precondition: the market is below the floor");
        uint256 held = IERC20(market.pegged).balanceOf(address(this));
        assertGt(held, 0, "precondition: there is pegged to convert");
        IERC20(market.pegged).approve(market.minter, held);

        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.LeverageAboveCap.selector, ratio, floor));
        IMinter(market.minter).freeRedeemPeggedToken(0, held, address(this));

        assertEq(IERC20(market.pegged).balanceOf(address(this)), held, "refusing takes nothing");
    }

    /// Below the floor BOTH retail routes are refused, by the same name and with the same figures as the
    /// conversion - the rule is a fact about the market, not about who asked.
    function test_retailMintBelowTheFloorIsRefused_onBothRoutesByTheSameName() public {
        setMarketCollateralRatio(1.05 ether);
        uint256 ratio = IMinter(market.minter).collateralRatio();
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        assertLt(ratio, floor, "precondition: the market is below the floor");
        // The harness approved the minter for everything at founding; only the collateral itself is needed.
        deal(market.wrappedCollateral, address(this), 2 ether);
        bytes memory refusal = abi.encodeWithSelector(IMinter_v3.LeverageAboveCap.selector, ratio, floor);

        vm.expectRevert(refusal);
        IMinter(market.minter).freeMintLeveragedToken(1 ether, address(this));

        vm.expectRevert(refusal);
        IMinter_v3(market.minter).mintLeveragedToken(1 ether, address(this), 0);
    }

    /// Above the floor a retail mint is served: the refusal is a floor, not a closure.
    function test_retailMintAboveTheFloorIsServed() public {
        setMarketCollateralRatio(1.1 ether);
        assertGe(
            IMinter(market.minter).collateralRatio(),
            IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO(),
            "precondition: the market is above the floor"
        );
        deal(market.wrappedCollateral, address(this), 1 ether);

        uint256 leveragedOut = IMinter(market.minter).freeMintLeveragedToken(1 ether, address(this));

        assertGt(leveragedOut, 0, "the mint is served");
    }

    /// `leveragedMintable()` is the refusal as a view: true exactly where a mint is served, false exactly where
    /// it is refused, on either side of the floor and at the ratio the churn sweep bracketed it to.
    function test_leveragedMintableAgreesWithTheRefusal() public {
        uint256[6] memory ratios = [uint256(0.9 ether), 1 ether, 1.0525 ether, 1.0529 ether, 1.1 ether, 1.5 ether];
        uint256 floor = IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO();
        deal(market.wrappedCollateral, address(this), 6 ether);

        for (uint256 i = 0; i < ratios.length; i++) {
            setMarketCollateralRatio(ratios[i]);
            uint256 ratio = IMinter(market.minter).collateralRatio();
            bool mintable = IMinter_v3(market.minter).leveragedMintable();
            assertEq(mintable, ratio >= floor, "the view is the comparison with the floor");
            if (mintable) {
                assertGt(IMinter(market.minter).freeMintLeveragedToken(1 ether, address(this)), 0, "served");
            } else {
                vm.expectRevert(abi.encodeWithSelector(IMinter_v3.LeverageAboveCap.selector, ratio, floor));
                IMinter(market.minter).freeMintLeveragedToken(1 ether, address(this));
            }
        }
    }

    /// The cap bounds the leverage SOLD, not the leverage held. Between the peg and the floor no leverage is sold,
    /// yet the tokens already minted carry more than the cap, and `leverageRatio()` reports that true figure -
    /// `CR/(CR-1)`, about 51 at 1.02 - rather than the cap, which would understate the exposure it describes.
    function test_leverageRatioReportsTheTrueFigureBetweenThePegAndTheFloor() public {
        setMarketCollateralRatio(1.02 ether);
        uint256 ratio = IMinter(market.minter).collateralRatio();
        assertGt(ratio, 1 ether, "precondition: the residual is not gone");
        assertLt(ratio, IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO(), "precondition: below the floor");

        // `beta = CR/(CR-1)`, from the ratio the market reports. That ratio is floored to its 1e18 scale, short of
        // the exact one by less than a unit, and `beta` moves by `1e36 / (CR - 1e18)^2` per unit of it - about 2500
        // here - so that, plus one for the floor on each side, is the most the two can differ by. The cap, 20
        // against about 51, is far outside it.
        uint256 expected = Math.mulDiv(ratio, 1 ether, ratio - 1 ether);
        uint256 tolerance = Math.ceilDiv(1e36, (ratio - 1 ether) * (ratio - 1 ether)) + 1;
        assertDiscriminates(
            IMinter(market.minter).leverageRatio(),
            expected,
            tolerance,
            IMinter_v3(market.minter).MAX_LEVERAGE_RATIO(),
            "the true leverage is reported, not the cap"
        );
    }
}

/// @notice The founding exception: the FIRST leveraged token is not judged, every later one is.
///
/// A market is founded by minting pegged first, which puts the ratio at exactly one, and then leveraged. Judged
/// against that pre-deposit state the founding mint is always refused. On an empty leveraged supply there is
/// nothing the cap protects - no existing price to diverge, no existing holder to dilute - so the first mint
/// is served and the deposit creates the residual it buys. The next mint, at the same ratio, is judged.
contract MinterLeverageCapFoundingTest is LocalMarket {
    /// @dev Pegged only: the leveraged supply is left empty for the tests to found.
    function _foundMarket() internal override {
        deal(address(wrappedCollateralToken), address(this), 2 * FOUNDING_TRANCHE);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IMinter(minter).freeMintPeggedToken(FOUNDING_TRANCHE, address(this));
    }

    function setUp() public override {
        super.setUp();
        standUpMarket(0, 0, string.concat(marketLabel(), "_leverageCapFoundingUnitTest"));
    }

    function test_theFirstLeveragedTokenIsNotJudged_theSecondIs() public {
        assertEq(IERC20(market.leveraged).totalSupply(), 0, "precondition: no leveraged token exists");
        assertEq(IMinter(market.minter).collateralRatio(), 1 ether, "precondition: pegged alone, at exactly one");
        assertTrue(
            IMinter_v3(market.minter).leveragedMintable(),
            "a ratio of one is below the floor, and the empty supply is mintable regardless"
        );

        uint256 founded = IMinter(market.minter).freeMintLeveragedToken(FOUNDING_TRANCHE / 2, address(this));

        assertGt(founded, 0, "the founding mint is served");
        // The founding deposit lifted the ratio well above the floor. Put it back at one - the same state the
        // first mint was served in - so that the only thing that differs for the second is that a holder now
        // exists.
        setMarketCollateralRatio(1 ether);
        uint256 ratio = IMinter(market.minter).collateralRatio();
        assertLt(ratio, IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO(), "back below the floor");
        assertFalse(IMinter_v3(market.minter).leveragedMintable(), "and now there is a holder to protect");
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter_v3.LeverageAboveCap.selector,
                ratio,
                IMinter_v3(market.minter).MINIMUM_COLLATERAL_RATIO()
            )
        );
        IMinter(market.minter).freeMintLeveragedToken(FOUNDING_TRANCHE / 2, address(this));
    }
}
