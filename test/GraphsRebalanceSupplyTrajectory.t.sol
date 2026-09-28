// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {HarborTestActions} from "@harbor-test/HarborTestActions.sol";
import {TestStabilityPoolManagerSetUp} from "@harbor-test/StabilityPoolManager.t.sol";

/// @notice Graphs what repeated rebalances do to a market over time: the sail supply, the sail price, and
/// the rate each successive conversion is given against the fair one.
///
/// This is the only graph here whose points are not independent. Every other one measures a market at a
/// collateral ratio and puts it back; this one lets the consequences accumulate, because the question is
/// whether they do. Each cycle drops the collateral ratio below the rebalance threshold and rebalances out
/// of it again, which is the loop a market in a falling collateral market actually runs.
///
/// Where the dip lands relative to the minter's `MINIMUM_COLLATERAL_RATIO` decides the rebalance's route:
/// at or above it the rebalance converts anchor into sail, growing the sail supply; below it no sail can be
/// minted, the rebalance is to collateral, and the conversion rate is graphed as zero.
abstract contract TestGraphsRebalanceSupplyTrajectoryBase is
    GraphTestBase,
    TestStabilityPoolManagerSetUp,
    HarborTestActions
{
    /// @dev One anchor token, so the sail received IS the applied conversion rate.
    uint256 private constant ANCHOR_IN = 1 ether;

    uint256 private constant CYCLES = 40;

    /// @notice How far each cycle lets the collateral ratio fall before the rebalance fires. This is the
    ///         whole experiment: whether the dip reaches below the floor decides whether the rebalance
    ///         converts into sail or into collateral, and the two cases are graphed against each other.
    function distressedCollateralRatio() internal pure virtual returns (uint256);

    function graphName() internal pure virtual returns (string memory);

    string private file;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public virtual override {
        super.setUp();
        setUp_collateral(1000 ether, 1000 ether, address(this));
        deal(address(wrappedCollateralToken), address(this), 100_000 ether);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        // The probe puts one anchor token through the conversion to read the rate it is given, on the
        // same free path the rebalance itself uses.
        vm.prank(owner());
        IHarborRoles(minter).grantRoles(address(this), zeroFeeRole);

        _refillThePools();

        file = openFile(
            graphName(),
            sa(
                "rebalance",
                "sail supply",
                "sail price at the distressed ratio",
                "applied over fair conversion rate",
                "collateral ratio after the rebalance",
                "anchor supply"
            )
        );
    }

    /// @dev Bring each pool back to a quarter of the anchor outstanding, minting the anchor to do it with.
    ///      A rebalance spends the pools' anchor, so without depositors returning between cycles the pools
    ///      are empty after two and every later rebalance takes nothing - which is a real outcome, and one
    ///      `rebalance_binding_limits` already graphs. This loop is about the other case: what happens to a
    ///      market whose pools keep being replenished, so that the bound goes on being applied.
    function _refillThePools() private {
        uint256 target = IMinter(minter).peggedTokenBalance() / 4;
        address[2] memory pools = [stabilityPoolCollateral, stabilityPoolLeveraged];

        for (uint256 i = 0; i < pools.length; i++) {
            uint256 held = IERC20(peggedToken).balanceOf(pools[i]);
            if (held >= target) {
                continue;
            }
            uint256 wanted = target - held;
            uint256 anchorHeld = IERC20(peggedToken).balanceOf(address(this));
            if (anchorHeld < wanted) {
                // Buy the shortfall with collateral, which is what a returning depositor does.
                IMinter_v3(minter).freeMintPeggedToken(
                    Math.min(
                        IERC20(wrappedCollateralToken).balanceOf(address(this)),
                        (wanted - anchorHeld) / 1000 + 1 ether
                    ),
                    address(this)
                );
                anchorHeld = IERC20(peggedToken).balanceOf(address(this));
            }
            uint256 depositing = Math.min(wanted, anchorHeld);
            if (depositing > 0) {
                IStabilityPool(pools[i]).deposit(depositing, address(this), 0);
            }
        }
    }

    /// @dev What the conversion is being given at the market's current state, measured by putting one
    ///      anchor token through it and undoing that - the same measurement the trigger graph makes. Zero
    ///      where the minter refuses to mint sail, since no conversion is given anything there.
    function _appliedOverFair() private returns (uint256 appliedOverFair) {
        if (!IMinter_v3(minter).leveragedMintable()) {
            return 0;
        }
        uint256 sailPrice = IMinter_v3(minter).leveragedTokenPrice();
        if (sailPrice == 0) {
            return 0;
        }
        uint256 fair = (1 ether * 1 ether) / sailPrice;

        uint256 snapshot = vm.snapshotState();
        (, uint256 sailOut) = IMinter_v3(minter).freeRedeemPeggedToken(0, ANCHOR_IN, address(this));
        uint256 applied = (sailOut * 1 ether) / ANCHOR_IN;
        vm.revertToState(snapshot);

        appliedOverFair = Math.mulDiv(applied, 1 ether, fair);
    }

    function test_repeatedBoundedRebalances() public {
        for (uint256 cycle = 1; cycle <= CYCLES; cycle++) {
            _refillThePools();

            // The dip. Priced, not rate-impaired: a falling collateral market, with the market holding
            // everything it was given.
            setCollateralRatioByPrice(minter, priceOracle, distressedCollateralRatio());

            uint256 sailPrice = IMinter_v3(minter).leveragedTokenPrice();
            uint256 appliedOverFair = _appliedOverFair();

            IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);

            writeLine(
                file,
                ua(
                    cycle * 1 ether,
                    IMinter(minter).leveragedTokenBalance(),
                    sailPrice,
                    appliedOverFair,
                    IMinter(minter).collateralRatio(),
                    IMinter(minter).peggedTokenBalance()
                )
            );
        }
        vm.closeFile(file);
    }
}

/// @notice The dip stops above the floor, so every rebalance converts anchor into sail. This is the
/// control: whatever the market does here, it does for reasons that have nothing to do with the floor.
contract TestGraphsRebalanceSupplyTrajectory is TestGraphsRebalanceSupplyTrajectoryBase {
    /// @dev Below the rebalance threshold so a rebalance fires, and far above the floor - the leverage
    ///      ratio at 1.2 is six, against a cap of twenty - so sail can always be minted.
    function distressedCollateralRatio() internal pure override returns (uint256) {
        return 1.2 ether;
    }

    function graphName() internal pure override returns (string memory) {
        return "rebalance_supply_trajectory";
    }
}

/// @notice The dip reaches below the floor, so no sail can be minted and every rebalance is to collateral.
/// Same market, same threshold, same number of cycles - the only difference is how far the collateral
/// ratio was let fall before the keeper fired.
contract TestGraphsRebalanceSupplyTrajectoryBounded is TestGraphsRebalanceSupplyTrajectoryBase {
    /// @dev The leverage ratio here is about fifty, well past the cap of twenty.
    function distressedCollateralRatio() internal pure override returns (uint256) {
        return 1.02 ether;
    }

    function graphName() internal pure override returns (string memory) {
        return "rebalance_supply_trajectory_bounded";
    }
}
