// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IMultipleRewardAccumulator_v3} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {HarborTestActions} from "@harbor-test/HarborTestActions.sol";
import {MinterSupplyRelativeBound} from "@harbor-test/mocks/MinterSupplyRelativeBound.sol";
import {TestStabilityPoolManagerSetUp} from "@harbor-test/StabilityPoolManager.t.sol";

/// @notice Whether a conversion bound has anything left to do once the pool's own reward ceiling is
/// accounted for.
///
/// `maxLiquidationReward` and a supply-relative conversion bound limit the SAME quantity: the sail handed
/// to the leveraged pool in one event. The first is not a policy - it is the reward integral's field
/// width, scaled by the pool's share, and a liquidation above it would overflow the accounting. The
/// second would be chosen. If the first is always the lower of the two then the second never decides
/// anything, and the conversion bound is left with only the job doc section 3 gives it: keeping the
/// arithmetic finite where the residual has gone.
///
/// All four quantities are in sail, at one distressed collateral ratio, against the size of the pools:
///
/// - what a FAIR conversion would issue, which is what the rebalance is asking for;
/// - `maxLiquidationReward`, the pool's own ceiling;
/// - a supply-relative bound at two candidate values.
///
/// Whichever is lowest at a given pool size is the one that binds there.
contract TestGraphsWhichLimitBindsFirst is GraphTestBase, TestStabilityPoolManagerSetUp, HarborTestActions {
    uint256 private constant DISTRESSED_COLLATERAL_RATIO = 1.02 ether;

    uint256 private constant FIRST_POOL_SHARE = 0.002 ether;
    uint256 private constant LAST_POOL_SHARE = 1 ether;

    string private file;

    /// @dev The candidate minter, run with a bound too loose to engage, so that the dry run reports what
    ///      a FAIR conversion would issue rather than what any rule would allow.
    function deployMinterImplementation(
        DeploymentTypes.State memory stateData,
        string memory key,
        address wrappedCollateral,
        address peggedToken_,
        address leveragedToken_
    ) internal override returns (address impl) {
        _reportContract(key);
        impl = address(new MinterSupplyRelativeBound(wrappedCollateral, peggedToken_, leveragedToken_));
        _reportImplementation(impl);
        _recordImplementation(
            stateData,
            key,
            "@harbor-test/mocks/MinterSupplyRelativeBound.sol",
            "MinterSupplyRelativeBound",
            impl
        );
    }

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
        vm.prank(owner());
        IHarborRoles(minter).grantRoles(address(this), zeroFeeRole);

        MinterSupplyRelativeBound(minter).setGamma(type(uint128).max);

        file = openFile(
            "which_limit_binds_first",
            sa(
                "pool anchor holdings per anchor token outstanding",
                "sail a fair conversion would issue",
                "maxLiquidationReward - the pool's reward ceiling",
                "a supply-relative bound at 0.25",
                "a supply-relative bound at 1"
            )
        );
    }

    function test_whichLimitBindsFirst() public {
        for (uint256 share = FIRST_POOL_SHARE; share <= LAST_POOL_SHARE; share = (share * 3) / 2) {
            uint256 snapshot = vm.snapshotState();

            uint256 anchorOutstanding = IMinter(minter).peggedTokenBalance();
            uint256 perPool = Math.mulDiv(anchorOutstanding, share, 2 ether);
            IStabilityPool(stabilityPoolCollateral).deposit(perPool, address(this), 0);
            IStabilityPool(stabilityPoolLeveraged).deposit(perPool, address(this), 0);

            setCollateralRatioByPrice(minter, priceOracle, DISTRESSED_COLLATERAL_RATIO);

            // What the rebalance is asking the leveraged leg for, and what a fair conversion pays for it.
            (, uint256 askLeveraged) = IMinter_v3(minter).redeemPeggedForCollateralRatio(
                IStabilityPoolManager(stabilityPoolManager).rebalanceThreshold(),
                type(uint256).max,
                type(uint256).max,
                IERC20(peggedToken).balanceOf(stabilityPoolCollateral),
                IERC20(peggedToken).balanceOf(stabilityPoolLeveraged)
            );
            (, uint256 fairSail) = IMinter_v3(minter).freeRedeemDryRun(0, askLeveraged);

            uint256 sailSupply = IMinter(minter).leveragedTokenBalance();

            writeLine(
                file,
                ua(
                    Math.mulDiv(
                        IERC20(peggedToken).balanceOf(stabilityPoolCollateral) +
                            IERC20(peggedToken).balanceOf(stabilityPoolLeveraged),
                        1 ether,
                        anchorOutstanding
                    ),
                    fairSail,
                    IMultipleRewardAccumulator_v3(stabilityPoolLeveraged).maxLiquidationReward(),
                    Math.mulDiv(sailSupply, 0.25 ether, 1 ether),
                    sailSupply
                )
            );

            vm.revertToStateAndDelete(snapshot);
        }
        vm.closeFile(file);
    }
}
