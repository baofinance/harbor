// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {HarborTestActions} from "@harbor-test/HarborTestActions.sol";
import {TestStabilityPoolManagerSetUp} from "@harbor-test/StabilityPoolManager.t.sol";

/// @notice Graphs what stops a rebalance short, against the size of the stability pools.
///
/// A rebalance asks the minter how much anchor it must give up to bring the collateral ratio back to the
/// rebalance threshold, and then three things can make it give up less: a pool can only be taken down to
/// its minimum supply (`maxAssetLoss`), its reward accounting can only absorb so much in one go
/// (`maxLiquidationReward`), and neither pool can hand over anchor it does not hold. This graph sweeps
/// the pools' anchor holdings over a four-hundredfold range and records, at each size, what was asked
/// for, what the pools could lose, what was actually taken, and where the collateral ratio ended up.
///
/// It exists to answer a question about a DIFFERENT bound. The conversion bound over-issues only while
/// the leverage ratio is at its cap, which is at and below a collateral ratio of `K/(K-1)` - about
/// 1.0526. A rebalance that succeeds lifts the market to the threshold, far above that, so the bound is
/// binding in practice only when a rebalance CANNOT lift the market out. That makes "is this bound ever
/// the binding one" a question about how small the pools are, which is what is plotted here.
///
/// The market starts each point inside the band, at a collateral ratio the bound is engaged at, so every
/// point is a rebalance attempting that escape. Every number is measured: the amounts come from the
/// contracts' own views before the call and from the call's own return afterwards.
contract TestGraphsRebalanceBindingLimits is GraphTestBase, TestStabilityPoolManagerSetUp, HarborTestActions {
    /// @dev A collateral ratio inside the band where the conversion bound is engaged: the leverage ratio
    ///      here is about 51, well past the cap of 20, so every rebalance graphed is one that converts at
    ///      the bound rather than at a fair conversion rate.
    uint256 private constant DISTRESSED_COLLATERAL_RATIO = 1.02 ether;

    /// @dev Collateral behind each side at deployment. Large against the pools' minimum supply, so that
    ///      pool size has a four-hundredfold range to be swept over rather than the tenfold one a small
    ///      market would allow.
    uint256 private constant COLLATERAL_EACH_SIDE = 1000 ether;

    uint256 private constant FIRST_POOL_SHARE = 0.002 ether;
    uint256 private constant LAST_POOL_SHARE = 1 ether;

    string private file;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public virtual override {
        super.setUp();
        setUp_collateral(COLLATERAL_EACH_SIDE, COLLATERAL_EACH_SIDE, address(this));
        deal(address(wrappedCollateralToken), address(this), 100_000 ether);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        vm.prank(owner());
        IHarborRoles(minter).grantRoles(address(this), zeroFeeRole);

        file = openFile(
            "rebalance_binding_limits",
            sa(
                "pool anchor holdings per anchor token outstanding",
                "anchor needed to reach the threshold",
                "anchor the pools are allowed to lose",
                "anchor actually taken",
                "collateral ratio after the rebalance"
            )
        );
    }

    function test_whatStopsARebalanceShort() public {
        // The band this graph is about: the bound is engaged at and below here, so the distressed ratio
        // each point starts from has to be inside it for the escape to be the one being measured.
        assertLt(
            DISTRESSED_COLLATERAL_RATIO,
            IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO(),
            "the sweep must start inside the band where the conversion bound is engaged"
        );

        for (uint256 share = FIRST_POOL_SHARE; share <= LAST_POOL_SHARE; share = (share * 3) / 2) {
            uint256 snapshot = vm.snapshotState();

            uint256 anchorOutstanding = IMinter(minter).peggedTokenBalance();
            uint256 perPool = Math.mulDiv(anchorOutstanding, share, 2 ether);
            IStabilityPool(stabilityPoolCollateral).deposit(perPool, address(this), 0);
            IStabilityPool(stabilityPoolLeveraged).deposit(perPool, address(this), 0);

            setCollateralRatioByPrice(minter, priceOracle, DISTRESSED_COLLATERAL_RATIO);

            // What the threshold asks for, with the pools' own limits taken off: the same view the
            // rebalance uses, against the manager's own threshold, with the headroom arguments opened up
            // so the answer is the full ask.
            (uint256 askCollateral, uint256 askLeveraged) = IMinter_v3(minter).redeemPeggedForCollateralRatio(
                IStabilityPoolManager(stabilityPoolManager).rebalanceThreshold(),
                type(uint256).max,
                type(uint256).max,
                IERC20(peggedToken).balanceOf(stabilityPoolCollateral),
                IERC20(peggedToken).balanceOf(stabilityPoolLeveraged)
            );
            uint256 allowedToLose = IStabilityPool_v3(stabilityPoolCollateral).maxAssetLoss() +
                IStabilityPool_v3(stabilityPoolLeveraged).maxAssetLoss();

            uint256 taken = IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);

            writeLine(
                file,
                ua(
                    Math.mulDiv(
                        IERC20(peggedToken).balanceOf(stabilityPoolCollateral) +
                            IERC20(peggedToken).balanceOf(stabilityPoolLeveraged) +
                            taken,
                        1 ether,
                        anchorOutstanding
                    ),
                    askCollateral + askLeveraged,
                    allowedToLose,
                    taken,
                    IMinter(minter).collateralRatio()
                )
            );

            vm.revertToStateAndDelete(snapshot);
        }
        vm.closeFile(file);
    }
}
