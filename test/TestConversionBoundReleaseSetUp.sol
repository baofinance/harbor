// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {HarborTestActions} from "@harbor-test/HarborTestActions.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestStabilityPool2SetUp} from "@harbor-test/TestStabilityPool2SetUp.sol";

/// @notice A market whose sail supply can be set, and the measurement of what the anchor-to-sail
/// conversion rate does at the collateral ratio where the bound lets go.
///
/// A conversion rate is sail issued per unit of anchor value. The bound is a ceiling on it, but it is
/// tested against the reported LEVERAGE ratio - collateral value over residual - rather than against the
/// conversion rate whose fair value is sail supply over residual. Those carry different numerators, so
/// the ceiling releases where the applied conversion rate has not yet met the fair one and the applied
/// rate steps across the gap instead of joining it.
///
/// The release is always at the same collateral ratio: the leverage ratio reaches the cap `K` at
/// `K/(K-1)`, and the leverage ratio is a function of the collateral ratio alone. The size of the step
/// there is not fixed, which is what the sail supply is a settable dimension for.
abstract contract TestConversionBoundReleaseSetUp is TestStabilityPool2SetUp, HarborTestActions {
    /// @dev One anchor token, so the sail received IS the applied conversion rate.
    uint256 internal constant ANCHOR_IN = 1 ether;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    /// @dev Put a candidate escrow rule behind the minter's address before the market is founded, so the rule
    /// governs the founding mint as well as everything after it. The default installs nothing and the suite
    /// measures the rule in use; a subclass overriding this measures its candidate against the SAME
    /// requirements, which is what makes those requirements an acceptance test rather than a description.
    ///
    /// Before founding rather than after, because the escrow per leveraged token is written by the first mint
    /// into an empty supply - a rule installed later would inherit a figure the rule in use chose.
    function installEscrowRule() internal virtual {} // solhint-disable-line no-empty-blocks

    function setUp() public virtual override {
        super.setUp();
        installEscrowRule();
        setUp_collateral(10 ether, 10 ether, address(this));
        // Enough to buy a sail supply a hundred times the anchor supply, which the sweep asks for.
        deal(address(wrappedCollateralToken), address(this), 100_000 ether);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        vm.prank(owner());
        IHarborRoles(minter).grantRoles(address(this), zeroFeeRole);
    }

    /// @notice The collateral ratio where the leverage ratio cap used to let go.
    ///
    /// @dev A TERMINAL coordinate, with no successor. It is twenty over nineteen: the leverage ratio
    /// `C/(C-P)` reaches twenty at `C/P = 20/19`, so it was a function of that cap and of nothing else. A
    /// literal rather than a derivation because the cap it derived from no longer exists.
    ///
    /// Its one remaining job is to let the callers sample the conversion just inside and just outside the
    /// point where a five percent step used to be, and find no step - the measurement that records the
    /// removal. Nothing replaces it: a price floor adds to the sail's claim rather than clamping it, so
    /// there is no collateral ratio at which anything engages and no release to measure across. This
    /// function retires with the tests that call it.
    function releaseCollateralRatio() internal pure returns (uint256) {
        return 1052631578947368421;
    }

    /// @dev Price the collateral so the market reports `requested`, derived from where the market is now
    ///      rather than from where it was deployed - the sail supply is moved here, and the collateral
    ///      ratio moves with it.
    function setCollateralRatio(uint256 requested) internal {
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(
            Math.mulDiv(requested, IMinter(minter).peggedTokenBalance(), IMinter(minter).collateralTokenBalance())
        );
        assertApproxEqAbs(
            IMinter(minter).collateralRatio(),
            requested,
            Math.ceilDiv(IMinter(minter).collateralTokenBalance(), IMinter(minter).peggedTokenBalance()) + 1,
            "the derived price must put the market at the requested collateral ratio"
        );
    }

    /// @notice Buy or sell sail until the supply is `multiple` of the anchor supply, and report what was
    ///         actually reached.
    /// @dev Convert one anchor token at `collateralRatio` and report the conversion rate it was given,
    ///      then put the market back. Measured through the conversion rather than recomputed, so the
    ///      answer is the contract's and not this test's.
    function appliedConversionRateAt(uint256 collateralRatio) internal returns (uint256 applied) {
        uint256 snapshot = vm.snapshotState();
        setCollateralRatio(collateralRatio);
        (, uint256 sailOut) = IMinter_v3(minter).freeRedeemPeggedToken(0, ANCHOR_IN, address(this));
        applied = (sailOut * 1 ether) / ANCHOR_IN;
        vm.revertToState(snapshot);
    }

    /// @notice The applied conversion rate either side of the collateral ratio where the leverage ratio cap
    ///         used to let go.
    /// @dev One part in a million either side of it - far inside the step the cap produced, far outside the
    ///      rounding. With the cap gone both readings are the fair rate and the pair is a continuity probe;
    ///      the names are kept because what makes them worth reading is that the two used to differ.
    function ratesAcrossTheRelease() internal returns (uint256 bounded, uint256 released) {
        uint256 release = releaseCollateralRatio();
        bounded = appliedConversionRateAt(release - release / 1_000_000);
        released = appliedConversionRateAt(release + release / 1_000_000);
    }

    /// @notice What the conversion rate does across that coordinate, as a multiple. ONE is a continuous
    ///         join, which is what it now reads everywhere; above one the cap over-issued right up to the
    ///         release, below one it under-issued, and which of those a market got depended on how many
    ///         leveraged tokens it carried rather than on the cap.
    function stepAcrossTheRelease() internal returns (uint256 stepAsMultiple) {
        (uint256 bounded, uint256 released) = ratesAcrossTheRelease();
        stepAsMultiple = Math.mulDiv(bounded, 1 ether, released);
    }

    /// @notice The collateral ratio at which the FAIR conversion rate falls to `rateBound` - where a
    ///         ceiling on the conversion rate itself would engage.
    /// @dev Found by bisection on the market rather than computed: the fair conversion rate is the
    ///      reciprocal of the sail price the minter reports, and it falls as the collateral ratio rises,
    ///      so the crossing is bracketed and halved. Forty rounds takes a bracket of one to a fraction of
    ///      a wei, and each round is a price write and a view.
    ///
    ///      Paired with `collateralRatioWhereTheLeverageRatioReaches` below, and the two take the SAME
    ///      number and return DIFFERENT collateral ratios. That difference is the whole defect: a bound
    ///      meant as a ceiling on the conversion rate, tested instead against the leverage ratio, engages
    ///      where the fair rate has not yet reached it. The gap between the two answers is the band in
    ///      which the conversion is bounded but unfair, and measuring it is what this pair is for.
    function collateralRatioWhereTheFairRateMeetsTheBound(uint256 rateBound) internal returns (uint256 crossing) {
        uint256 snapshot = vm.snapshotState();
        uint256 low = 1 ether + 1; // just above the peg, where the fair conversion rate is unbounded
        uint256 high = 2 ether; // well clear of it, where the fair conversion rate is small

        for (uint256 round = 0; round < 40; round++) {
            uint256 middle = (low + high) / 2;
            setCollateralRatio(middle);
            uint256 sailPrice = IMinter_v3(minter).leveragedTokenPrice();
            // Above the bound the crossing is still higher; at or below it, lower.
            if (sailPrice == 0 || (1 ether * 1 ether) / sailPrice > rateBound) {
                low = middle;
            } else {
                high = middle;
            }
        }
        crossing = high;
        vm.revertToState(snapshot);
    }

    /// @notice The collateral ratio at which the reported LEVERAGE ratio falls to `leverageBound`, found
    ///         the same way - by asking the market rather than by computing it.
    /// @dev Where a bound tested against the leverage ratio actually engages, as against where the
    ///      function above says it ought to.
    function collateralRatioWhereTheLeverageRatioReaches(uint256 leverageBound) internal returns (uint256 engagement) {
        uint256 snapshot = vm.snapshotState();
        uint256 low = 1 ether + 1;
        uint256 high = 2 ether;

        for (uint256 round = 0; round < 40; round++) {
            uint256 middle = (low + high) / 2;
            setCollateralRatio(middle);
            if (IMinter_v3(minter).leverageRatio() >= leverageBound) {
                low = middle;
            } else {
                high = middle;
            }
        }
        engagement = high;
        vm.revertToState(snapshot);
    }

    /// @notice What one sail token is worth at the collateral ratio where the bound releases.
    function sailPriceAtTheRelease() internal returns (uint256 sailPrice) {
        uint256 snapshot = vm.snapshotState();
        setCollateralRatio(releaseCollateralRatio());
        sailPrice = IMinter_v3(minter).leveragedTokenPrice();
        vm.revertToState(snapshot);
    }
}
