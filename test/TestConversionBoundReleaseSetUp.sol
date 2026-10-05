// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {TestStabilityPool2SetUp} from "@harbor-test/TestStabilityPool2SetUp.sol";

/// @notice A market whose leveraged supply can be set, and the measurement of what the pegged-to-leveraged
/// conversion rate does at the collateral ratio where the market starts selling leverage.
///
/// A conversion rate is leveraged minted per unit of pegged value. The market sells no leverage below its floor,
/// `K/(K-1)` for a cap `K` on the leverage sold - a refusal, by name, on the conversion and the retail routes
/// alike - and above it prices every conversion on the residual, which is the fair rate: leveraged supply over
/// residual. So the release is a door, not a step: nothing below, the fair rate above.
///
/// The release is always at the same collateral ratio, since the floor is fixed by the cap alone. The leveraged
/// supply is a settable dimension because the fair rate above the floor scales with it.
abstract contract TestConversionBoundReleaseSetUp is TestStabilityPool2SetUp {
    /// @dev One pegged token, so the leveraged received IS the applied conversion rate.
    uint256 internal constant PEGGED_IN = 1 ether;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public virtual override {
        super.setUp();
        setUp_collateral(10 ether, 10 ether, address(this));
        // Enough to buy a leveraged supply a hundred times the pegged supply, which the sweep asks for.
        deal(address(wrappedCollateralToken), address(this), 100_000 ether);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        vm.startPrank(owner());
        IHarborRoles(minter).grantRoles(address(this), zeroFeeRole);
        vm.stopPrank();
    }

    /// @notice The collateral ratio at which the market starts selling leverage: the minter's own floor,
    ///         `K/(K-1)` for its cap `K`, read from it rather than restated.
    function releaseCollateralRatio() internal view returns (uint256) {
        return IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();
    }

    /// @dev Convert one pegged token at `collateralRatio` and report the conversion rate it was given,
    ///      then put the market back. Measured through the conversion rather than recomputed, so the
    ///      answer is the contract's and not this test's.
    /// @dev Zero where the market refuses to sell - `BelowMinimumCollateralRatio`, which is the rule's own answer and the
    ///      reading this helper exists to take. Anything else propagates unchanged.
    function appliedConversionRateAt(uint256 collateralRatio) internal returns (uint256 applied) {
        uint256 snapshot = vm.snapshotState();
        marketActions.setCollateralRatioByPrice(collateralRatio);
        try IMinter_v3(minter).freeRedeemPeggedToken(0, PEGGED_IN, address(this)) returns (
            uint256,
            uint256 leveragedOut
        ) {
            applied = (leveragedOut * 1 ether) / PEGGED_IN;
        } catch (bytes memory err) {
            if (bytes4(err) != IMinter_v3.BelowMinimumCollateralRatio.selector) {
                // solhint-disable-next-line no-inline-assembly
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
        }
        vm.revertToState(snapshot);
    }

    /// @notice The applied conversion rate either side of the release: below the floor, where the market
    ///         refuses and the rate is zero, and above it, where it is the fair rate.
    /// @dev One part in a million either side of the release - far inside the refusal, far outside the
    ///      rounding.
    function ratesAcrossTheRelease() internal returns (uint256 bounded, uint256 released) {
        uint256 release = releaseCollateralRatio();
        bounded = appliedConversionRateAt(release - release / 1_000_000);
        released = appliedConversionRateAt(release + release / 1_000_000);
    }

    /// @notice What the conversion rate does across the release, as a multiple. One would be a continuous
    ///         join; above one the bound over-mints right up to the release, below one it under-mints.
    function stepAcrossTheRelease() internal returns (uint256 stepAsMultiple) {
        (uint256 bounded, uint256 released) = ratesAcrossTheRelease();
        stepAsMultiple = Math.mulDiv(bounded, 1 ether, released);
    }

    /// @notice The collateral ratio at which the FAIR conversion rate meets the bound - where a ceiling
    ///         of `K` on the conversion rate would engage, as against where this one actually does.
    /// @dev Found by bisection on the market itself rather than computed: the fair conversion rate is the
    ///      reciprocal of the leveraged price the minter reports, and it falls as the collateral ratio rises,
    ///      so the crossing is bracketed and halved. Forty rounds takes a bracket of one to a fraction of
    ///      a wei, and each round is a price write and a view.
    function collateralRatioWhereTheFairRateMeetsTheBound() internal returns (uint256 crossing) {
        uint256 snapshot = vm.snapshotState();
        uint256 low = 1 ether + 1; // just above the peg, where the fair conversion rate is unbounded
        uint256 high = 2 ether; // well clear of it, where the fair conversion rate is small

        for (uint256 round = 0; round < 40; round++) {
            uint256 middle = (low + high) / 2;
            marketActions.setCollateralRatioByPrice(middle);
            uint256 leveragedPrice = IMinter_v3(minter).leveragedTokenPrice();
            // Above the bound the crossing is still higher; at or below it, lower.
            if (leveragedPrice == 0 || (1 ether * 1 ether) / leveragedPrice > IMinter_v3(minter).MAX_LEVERAGE_RATIO()) {
                low = middle;
            } else {
                high = middle;
            }
        }
        crossing = high;
        vm.revertToState(snapshot);
    }

    /// @notice The collateral ratio at which the refusal ACTUALLY engages, found the same way - by asking
    ///         the market, at each ratio, whether it sells.
    function collateralRatioWhereTheBoundEngages() internal returns (uint256 engagement) {
        uint256 snapshot = vm.snapshotState();
        uint256 low = 1 ether + 1;
        uint256 high = 2 ether;

        for (uint256 round = 0; round < 40; round++) {
            uint256 middle = (low + high) / 2;
            marketActions.setCollateralRatioByPrice(middle);
            if (!IMinter_v3(minter).leveragedMintable()) {
                low = middle;
            } else {
                high = middle;
            }
        }
        engagement = high;
        vm.revertToState(snapshot);
    }

    /// @notice What one leveraged token is worth at the collateral ratio where the bound releases.
    function leveragedPriceAtTheRelease() internal returns (uint256 leveragedPrice) {
        uint256 snapshot = vm.snapshotState();
        marketActions.setCollateralRatioByPrice(releaseCollateralRatio());
        leveragedPrice = IMinter_v3(minter).leveragedTokenPrice();
        vm.revertToState(snapshot);
    }
}
