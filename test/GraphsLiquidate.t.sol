// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";

import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {TestCollateralRatioRangeSetUp} from "@harbor-test/CollateralRatio.t.sol";
import {TestMinterMarketConfig_rebalanceThreshold130} from "@harbor-test/config/TestMinterMarketConfig_rebalanceThreshold130.sol";
import {MarketDeployRun} from "@harbor-test/harness/MarketDeployRun.sol";
import {MockStabilityPoolMarketDeployRun} from "@harbor-test/harness/MockStabilityPoolMarketDeployRun.sol";
import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";

/// @dev The market cut at a rebalance threshold of 1.30: the manager comes from the deploy, configured and granted its
///      roles by it, and the graphs below rebalance through it.
abstract contract TestGraphsLiquidateSetUp is GraphTestBase, TestCollateralRatioRangeSetUp {
    address stabilityPoolManager;
    address bountyReceiver;

    function newDeployRun() internal virtual override returns (MarketDeployRun) {
        return
            new MockStabilityPoolMarketDeployRun(
                owner(),
                treasury(),
                HarborDeployRun.Cut.Market,
                new TestMinterMarketConfig_rebalanceThreshold130()
            );
    }

    function setUp() public virtual override {
        super.setUp();
        stabilityPoolManager = deployRun.stabilityPoolManagerAddress(marketConfig);
        bountyReceiver = makeAddr("bountyReceiver");
    }
}

contract TestGraphsLiquidatePartial is TestGraphsLiquidateSetUp {
    string liquidateFile;

    function setUp() public override {
        super.setUp();

        liquidateFile = openFile(
            "liquidate_partial",
            sa(
                "before CR",
                "CR after liquidate to collateral",
                "CR after liquidate to leveraged",
                "CR after liquidate to both",
                "pegged before",
                "pegged after liquidate to collateral",
                "pegged after liquidate to leveraged",
                "pegged after liquidate to both",
                "before leveraged price",
                "price after liquidate to collateral",
                "price after liquidate to leveraged",
                "price after liquidate to both"
            )
        );
    }

    function setDown() internal override {
        vm.closeFile(liquidateFile);
    }

    struct PartialMeasures {
        uint256 beforeCR;
        uint256 beforePegged;
        uint256 beforePrice;
        uint256 afterCR_collateral;
        uint256 afterCR_leveraged;
        uint256 afterCR_both;
        uint256 afterPegged_collateral;
        uint256 afterPegged_leveraged;
        uint256 afterPegged_both;
        uint256 afterPrice_collateral;
        uint256 afterPrice_leveraged;
        uint256 afterPrice_both;
    }

    /// @dev Three scenarios from one state: the market's manager rebalancing out of the collateral pool alone, the
    ///      leveraged pool alone, and both. Each scenario fills its own pool(s) under the snapshot - the manager takes
    ///      from whichever pools hold pegged - and the snapshot puts the next one back where the first began.
    function doOneCollateralRatio(uint256 collateralRatio) internal override {
        PartialMeasures memory m;
        m.beforePegged = IMinter(minter).peggedTokenBalance();
        m.beforeCR = IMinter(minter).collateralRatio();
        m.beforePrice = IMinter(minter).leveragedTokenPrice();

        uint256 snap = vm.snapshotState();
        IStabilityPool(stabilityPoolCollateral).deposit(4 * startPrice, address(this), 0);
        (m.afterCR_collateral, m.afterPrice_collateral, m.afterPegged_collateral) = _rebalanceAndRead(m);
        vm.revertToState(snap);

        IStabilityPool(stabilityPoolLeveraged).deposit(4 * startPrice, address(this), 0);
        (m.afterCR_leveraged, m.afterPrice_leveraged, m.afterPegged_leveraged) = _rebalanceAndRead(m);
        vm.revertToState(snap);

        IStabilityPool(stabilityPoolCollateral).deposit(4 * startPrice, address(this), 0);
        IStabilityPool(stabilityPoolLeveraged).deposit(4 * startPrice, address(this), 0);
        (m.afterCR_both, m.afterPrice_both, m.afterPegged_both) = _rebalanceAndRead(m);
        vm.revertToState(snap);

        writeLine(
            liquidateFile,
            ua(
                collateralRatio,
                m.afterCR_collateral,
                m.afterCR_leveraged,
                m.afterCR_both,
                m.beforePegged,
                m.afterPegged_collateral,
                m.afterPegged_leveraged,
                m.afterPegged_both,
                m.beforePrice,
                m.afterPrice_collateral,
                m.afterPrice_leveraged,
                m.afterPrice_both
            )
        );
    }

    /// @dev Rebalance if the market asks for one, then read the collateral ratio, the leveraged price and the pegged
    ///      supply; where no rebalance runs, the ratio and the price are the ones before it.
    function _rebalanceAndRead(
        PartialMeasures memory m
    ) private returns (uint256 collateralRatioAfter, uint256 leveragedPriceAfter, uint256 peggedAfter) {
        if (IStabilityPoolManager(stabilityPoolManager).rebalanceable()) {
            IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);
            collateralRatioAfter = IMinter(minter).collateralRatio();
            leveragedPriceAfter = IMinter(minter).leveragedTokenPrice();
        } else {
            collateralRatioAfter = m.beforeCR;
            leveragedPriceAfter = m.beforePrice;
        }
        peggedAfter = IMinter(minter).peggedTokenBalance();
    }
}

contract TestGraphsLiquidate is TestGraphsLiquidateSetUp {
    string liquidateFile;
    string toFile;
    uint256 collateralPoolShare;
    uint256 leveragedPoolShare;
    address user;

    /// @param collateralPoolShare_ Share of the minter's pegged deposited into the collateral pool, as a 1e18 fraction.
    /// @param leveragedPoolShare_ Share deposited into the leveraged pool, as a 1e18 fraction.
    constructor(uint256 collateralPoolShare_, uint256 leveragedPoolShare_) {
        collateralPoolShare = collateralPoolShare_;
        leveragedPoolShare = leveragedPoolShare_;
    }

    function setUp() public virtual override {
        super.setUp();
        uint256 minterPegged = IMinter(minter).peggedTokenBalance();

        uint256 peggedForCollateralPool = (collateralPoolShare * minterPegged) / 1 ether;
        uint256 peggedForLeveragedPool = (leveragedPoolShare * minterPegged) / 1 ether;
        if (peggedForCollateralPool > 0) {
            IStabilityPool(stabilityPoolCollateral).deposit(peggedForCollateralPool, address(this), 0);
        }
        if (peggedForLeveragedPool > 0) {
            IStabilityPool(stabilityPoolLeveraged).deposit(peggedForLeveragedPool, address(this), 0);
        }
        user = address(this);

        liquidateFile = openFile(
            "liquidate",
            sa(
                "current CR",
                "before CR",
                "after CR",
                "before minter pegged",
                "after minter pegged",
                "before SPCollateral pegged",
                "after SPCollateral pegged",
                "before SPLeveraged pegged",
                "after SPLeveraged pegged",
                "before leveraged price",
                "after leveraged price"
            )
        );

        toFile = openFile(
            "liquidate_to",
            sa(
                "current CR",
                "after user collateral",
                "after SPCollateral collateral",
                "after user leveraged",
                "after SPLeveraged leveraged",
                "",
                "after minter collateral",
                "after user SPCollateral balance",
                "after user SPLeveraged balance",
                "after leveraged price"
            )
        );
    }

    function setDown() internal override {
        vm.closeFile(liquidateFile);
        vm.closeFile(toFile);
    }

    struct Measures {
        uint256 collateralRatio;
        uint256 minterPegged;
        uint256 minterCollateral;
        uint256 stabilityPoolCollateralPegged;
        uint256 stabilityPoolLeveragedPegged;
        uint256 stabilityPoolCollateralCollateral;
        uint256 stabilityPoolLeveragedLeveraged;
        uint256 userCollateral;
        uint256 userLeveraged;
        uint256 userBalanceCollateralPool;
        uint256 userBalanceLeveragedPool;
        uint256 leveragedTokenPrice;
    }

    function _readMeasures() internal view returns (Measures memory m) {
        m.collateralRatio = IMinter(minter).collateralRatio();
        m.minterPegged = IMinter(minter).peggedTokenBalance();
        m.minterCollateral = IERC20(wrappedCollateralToken).balanceOf(minter);
        m.stabilityPoolCollateralPegged = IERC20(peggedToken).balanceOf(stabilityPoolCollateral);
        m.stabilityPoolLeveragedPegged = IERC20(peggedToken).balanceOf(stabilityPoolLeveraged);
        m.stabilityPoolCollateralCollateral = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        m.stabilityPoolLeveragedLeveraged = IERC20(leveragedToken).balanceOf(stabilityPoolLeveraged);
        m.userCollateral = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            user,
            aa(wrappedCollateralToken)
        )[0];
        m.userLeveraged = IMultipleRewardAccumulator(stabilityPoolLeveraged).claimable(user, aa(leveragedToken))[0];
        m.userBalanceCollateralPool = IERC20(stabilityPoolCollateral).balanceOf(user);
        m.userBalanceLeveragedPool = IERC20(stabilityPoolLeveraged).balanceOf(user);
        m.leveragedTokenPrice = IMinter(minter).leveragedTokenPrice();
    }

    function doOneCollateralRatio(uint256 collateralRatio) internal override {
        Measures memory pre = _readMeasures();

        uint256 snap = vm.snapshotState();

        if (IStabilityPoolManager(stabilityPoolManager).rebalanceable()) {
            IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);
        }

        Measures memory post = _readMeasures();

        vm.revertToState(snap);

        writeLine(
            liquidateFile,
            ua(
                collateralRatio,
                pre.collateralRatio,
                post.collateralRatio,
                pre.minterPegged,
                post.minterPegged,
                pre.stabilityPoolCollateralPegged,
                post.stabilityPoolCollateralPegged,
                pre.stabilityPoolLeveragedPegged,
                post.stabilityPoolLeveragedPegged,
                pre.leveragedTokenPrice,
                post.leveragedTokenPrice
            )
        );
        writeLine(
            toFile,
            ua(
                collateralRatio,
                post.userCollateral,
                post.stabilityPoolCollateralCollateral,
                post.userLeveraged,
                post.stabilityPoolLeveragedLeveraged,
                0,
                post.minterCollateral,
                post.userBalanceCollateralPool,
                post.userBalanceLeveragedPool,
                post.leveragedTokenPrice
            )
        );
    }
}

contract TestGraphsLiquidateAllCollateral is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(1 ether, 0) {}
    function context() internal pure override returns (string memory) {
        return "_all_collateral";
    }
}

contract TestGraphsLiquidateAllLeveraged is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(0, 1 ether) {}

    /// @dev Left overridable: this is the variant that converts the most pegged into leveraged, so it is the
    ///      one a candidate conversion rule is compared against.
    function context() internal pure virtual override returns (string memory) {
        return "_all_leveraged";
    }
}

contract TestGraphsLiquidateAllBoth is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(1 ether / 2, 1 ether - 1 ether / 2) {}
    function context() internal pure override returns (string memory) {
        return "_all_both";
    }
}

//////////////////////

contract TestGraphsLiquidatePartialCollateral is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(1 ether / 2, 0) {}
    function context() internal pure override returns (string memory) {
        return "_partial_collateral";
    }
}

contract TestGraphsLiquidatePartialLeveraged is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(0, 1 ether / 2) {}
    function context() internal pure override returns (string memory) {
        return "_partial_leveraged";
    }
}

contract TestGraphsLiquidatePartialBoth33 is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(0.4 ether, 0.4 ether) {}
    function context() internal pure override returns (string memory) {
        return "_partial_both44";
    }
}

contract TestGraphsLiquidatePartialBoth15 is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(0.2 ether, 0.6 ether) {}
    function context() internal pure override returns (string memory) {
        return "_partial_both26";
    }
}

contract TestGraphsLiquidatePartialBoth51 is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(0.6 ether, 0.2 ether) {}
    function context() internal pure override returns (string memory) {
        return "_partial_both62";
    }
}

//////////////////////

contract TestGraphsLiquidateParameters is GraphTestBase, TestCollateralRatioRangeSetUp {
    string file;

    function setUp() public override {
        super.setUp();

        file = openFile(
            "liquidate_parameters",
            sa(
                "current CR",
                "pegged for collateral for 1.01",
                "pegged for leveraged for 1.01",
                "pegged for collateral for 1.25",
                "pegged for leveraged for 1.25",
                "pegged for collateral for 1.5",
                "pegged for leveraged for 1.5"
            )
        );
    }

    function setDown() internal override {
        vm.closeFile(file);
    }

    function doOneCollateralRatio(uint256 collateralRatio) internal override {
        // the unconstrained intercepts (no headroom caps, no holdings split) - the removed 1-arg's behaviour
        (uint256 peggedForCollateral101, uint256 peggedForLeveraged101) = IMinter_v3(minter)
            .redeemPeggedForCollateralRatio(1.01 ether, type(uint256).max, type(uint256).max, 0, 0);
        (uint256 peggedForCollateral125, uint256 peggedForLeveraged125) = IMinter_v3(minter)
            .redeemPeggedForCollateralRatio(1.25 ether, type(uint256).max, type(uint256).max, 0, 0);
        (uint256 peggedForCollateral150, uint256 peggedForLeveraged150) = IMinter_v3(minter)
            .redeemPeggedForCollateralRatio(1.50 ether, type(uint256).max, type(uint256).max, 0, 0);
        writeLine(
            file,
            ua(
                collateralRatio,
                peggedForCollateral101,
                peggedForLeveraged101,
                peggedForCollateral125,
                peggedForLeveraged125,
                peggedForCollateral150,
                peggedForLeveraged150
            )
        );
    }
}
