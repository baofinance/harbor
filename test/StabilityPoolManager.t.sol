// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IMultipleRewardDistributor_v3} from "@harbor/interfaces/IMultipleRewardDistributor_v3.sol";
import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {IYieldVaultManager} from "@harbor/interfaces/IYieldVaultManager.sol";

import {StabilityPoolManager_v2} from "@harbor/minter/StabilityPoolManager_v2.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestStabilityPool2SetUp} from "@harbor-test/TestStabilityPool2SetUp.sol";
import {MockStabilityPoolManagerUpgraded} from "@harbor-test/mocks/MockStabilityPoolManagerUpgraded.sol";
import {MockYieldVault} from "@harbor-test/mocks/MockYieldVault.sol";
import {TestMinterMarketConfig} from "@harbor-test/config/TestMinterMarketConfig.sol";
import {TestMinterMarketConfig_rebalanceThreshold130} from "@harbor-test/config/TestMinterMarketConfig_rebalanceThreshold130.sol";
import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {MarketDeployRun} from "@harbor-test/harness/MarketDeployRun.sol";
import {MockStabilityPoolMarketDeployRun} from "@harbor-test/harness/MockStabilityPoolMarketDeployRun.sol";

contract TestStabilityPoolManagerSetUp is TestStabilityPool2SetUp {
    address stabilityPoolManager;
    address bountyReceiver;
    address user;

    /// @dev The market cut: the manager that coordinates the two pools as well. Every role it needs is
    ///      already granted: each pool grants REBALANCER and REWARD_DEPOSITOR to the manager's predicted address
    ///      as part of being deployed, and the minter grants HARVESTER and ZERO_FEE the same way. Its fee
    ///      receiver is `treasury()`, set by `deployStabilityPoolManager` - a test wanting it elsewhere moves it
    ///      itself.
    function newDeployRun() internal virtual override returns (MarketDeployRun) {
        return
            new MockStabilityPoolMarketDeployRun(
                owner(),
                treasury(),
                HarborDeployRun.Cut.Market,
                new TestMinterMarketConfig()
            );
    }

    function setUp() public virtual override(TestStabilityPool2SetUp) {
        super.setUp();

        stabilityPoolManager = deployRun.stabilityPoolManagerAddress(marketConfig);
        vm.label(stabilityPoolManager, "stabilityPoolManager");

        bountyReceiver = makeAddr("bountyReceiver");
        user = makeAddr("user");
    }

    /// Write the harvest ratio pair straight into the manager's storage - the way a proxy configured before the two
    /// were validated as a pair carries one summing above 100%, which no setter will produce.
    function _storeHarvestRatios(uint256 harvestBountyRatio_, uint256 harvestCutRatio_) public {
        bytes32 storageBase = keccak256(abi.encode(uint256(keccak256("bao.storage.StabilityPoolManager")) - 1)) &
            ~bytes32(uint256(0xff));
        // the pair sits at fields 2 and 3 of StabilityPoolManagerStorage
        vm.store(stabilityPoolManager, bytes32(uint256(storageBase) + 2), bytes32(harvestBountyRatio_));
        vm.store(stabilityPoolManager, bytes32(uint256(storageBase) + 3), bytes32(harvestCutRatio_));
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio(),
            harvestBountyRatio_,
            "stored bounty ratio"
        );
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).harvestCutRatio(),
            harvestCutRatio_,
            "stored cut ratio"
        );
    }
}

/// @dev The market cut on the unit-test market with its rebalance threshold at 1.30, for the suites whose rebalance
///      scenarios are placed around it - the threshold reaches the manager by the deploy's own path.
abstract contract TestStabilityPoolManagerSetUp_rebalanceThreshold130 is TestStabilityPoolManagerSetUp {
    function newDeployRun() internal virtual override returns (MarketDeployRun) {
        return
            new MockStabilityPoolMarketDeployRun(
                owner(),
                treasury(),
                HarborDeployRun.Cut.Market,
                new TestMinterMarketConfig_rebalanceThreshold130()
            );
    }
}

contract TestStabilityPoolManagerInit is TestStabilityPoolManagerSetUp {
    address stabilityPoolManagerImpl;

    function setUp_impl() internal virtual {
        stabilityPoolManagerImpl = address(
            new StabilityPoolManager_v2(minter, stabilityPoolCollateral, stabilityPoolLeveraged)
        );
    }

    function setUp_proxy() internal virtual {
        stabilityPoolManager = UnsafeUpgrades.deployUUPSProxy(
            stabilityPoolManagerImpl,
            abi.encodeCall(StabilityPoolManager_v2.initialize, (address(this), owner()))
        );
    }

    function test_initEvents() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        setUp_impl();

        vm.expectEmit();
        emit IERC1967.Upgraded(stabilityPoolManagerImpl);
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call
        setUp_proxy();
    }

    function test_initialization() public {
        setUp_impl();
        setUp_proxy();

        address[] memory pools = IStabilityPoolManager_v2(stabilityPoolManager).stabilityPools();
        assertEq(pools.length, 2, "Should have 2 stability pools");
        assertTrue(
            IStabilityPoolManager_v2(stabilityPoolManager).hasStabilityPool(stabilityPoolCollateral),
            "Should have pool1"
        );
        assertTrue(
            IStabilityPoolManager_v2(stabilityPoolManager).hasStabilityPool(stabilityPoolLeveraged),
            "Should have pool2"
        );

        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceBountyRatio(),
            0 ether,
            "Wrong rebalance bounty ratio"
        );
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio(),
            0 ether,
            "Wrong harvest bounty ratio"
        );

        // we haven't transferred ownership yet
        assertEq(IBaoOwnable(stabilityPoolManager).owner(), address(this), "Wrong owner");

        // Check rebalanceCollateralRatio is initialized correctly
        assertEq(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceThreshold(), 0, "Wrong rebalance ratio");
    }
}

contract TestStabilityPoolManagerBasic is TestStabilityPoolManagerSetUp {
    function test_viewFunctions() public view {
        // Test basic view functions
        address[] memory pools = IStabilityPoolManager_v2(stabilityPoolManager).stabilityPools();
        assertEq(pools.length, 2, "Should have 2 pools");
        assertEq(pools[0], stabilityPoolCollateral, "First pool mismatch");
        assertEq(pools[1], stabilityPoolLeveraged, "Second pool mismatch");

        assertTrue(
            IStabilityPoolManager_v2(stabilityPoolManager).hasStabilityPool(stabilityPoolCollateral),
            "Should have pool1"
        );
        assertTrue(
            IStabilityPoolManager_v2(stabilityPoolManager).hasStabilityPool(stabilityPoolLeveraged),
            "Should have pool2"
        );
        assertFalse(
            IStabilityPoolManager_v2(stabilityPoolManager).hasStabilityPool(address(0)),
            "Should not have zero address pool"
        );

        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceBountyRatio(),
            0 ether,
            "Wrong rebalance bounty ratio"
        );
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio(),
            0 ether,
            "Wrong harvest bounty ratio"
        );
    }

    function test_setBounty() public {
        // Test setting bounty
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceBountyRatio(0.02 ether);
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceBountyRatio(0.02 ether);
        vm.stopPrank();
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceBountyRatio(),
            0.02 ether,
            "Wrong rebalance bounty ratio"
        );

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.01 ether, 0);
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.01 ether, 0);
        vm.stopPrank();
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio(),
            0.01 ether,
            "Wrong harvest bounty ratio"
        );
    }

    function test_setRebalanceCollateralRatio() public {
        // Test setting rebalance collateral ratio
        uint256 newRatio = 140 ether / 100; // 140%

        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(newRatio);
        vm.stopPrank();

        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceThreshold(),
            newRatio,
            "Wrong rebalance ratio after update"
        );

        // Test unauthorized access
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(135 ether / 100);
    }

    function test_rebalanceable() public {
        setUp_collateral(1 ether, 1 ether); // CR = 200%
        uint256 currentCR = IMinter(minter).collateralRatio();

        // Test rebalanceable condition using manager's rebalanceCollateralRatio
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(currentCR + 1);
        vm.stopPrank();
        assertTrue(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "Should be rebalanceable");

        // When CR >= manager's rebalance threshold, should not be rebalanceable
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(currentCR);
        vm.stopPrank();
        assertFalse(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "Should not be rebalanceable");

        // Update rebalance ratio and test again
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(currentCR + 2);
        vm.stopPrank();
        assertTrue(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "Should be rebalanceable again");
    }

    function test_harvestable() public {
        // Test harvestable amount
        assertEq(IStabilityPoolManager_v2(stabilityPoolManager).harvestable(), 0, "Should be 0 harvestable");
        setUp_collateral(1 ether, 1 ether);
        assertEq(IStabilityPoolManager_v2(stabilityPoolManager).harvestable(), 0, "Should still be 0 harvestable");
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).harvestable(),
            IMinter(minter).harvestable(),
            "Should be = harvestable"
        );

        (uint256 startPrice, uint256 startRate, , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(startPrice, startRate * 1.1 ether);
        assertGt(IStabilityPoolManager_v2(stabilityPoolManager).harvestable(), 0, "Should be some harvestable");
    }

    function test_supportsInterfaceNegative() public view {
        bytes4 invalidInterfaceId = bytes4(keccak256("InvalidInterface()"));
        bool supported = IERC165(stabilityPoolManager).supportsInterface(invalidInterfaceId);
        assertFalse(supported, "Should not support invalid interface");
    }

    function test_invalidRebalanceThreshold() public {
        vm.startPrank(owner());
        uint256 invalidThreshold = 0.9 ether; // Less than 1 ether
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPoolManager_v2.InvalidRebalanceThreshold.selector, invalidThreshold)
        );
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(invalidThreshold);
        vm.stopPrank();
    }

    function test_invalidRebalanceBountyRatio() public {
        vm.startPrank(owner());
        uint256 invalidRatio = 1.1 ether; // Greater than 1 ether
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPoolManager_v2.InvalidRebalanceBountyRatio.selector, invalidRatio)
        );
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceBountyRatio(invalidRatio);
        vm.stopPrank();
    }

    // The bounty and the cut are set together, as the pair they are validated as; a pair summing to exactly 100% is
    // valid and leaves the pools nothing, all of the harvest gross being fees.
    function test_updateHarvestRatios() public {
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.05 ether, 0.9 ether);
        vm.stopPrank();
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio(),
            0.05 ether,
            "bounty ratio of pair"
        );
        assertEq(IStabilityPoolManager_v2(stabilityPoolManager).harvestCutRatio(), 0.9 ether, "cut ratio of pair");

        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.01 ether, 0.99 ether);
        vm.stopPrank();
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio(),
            0.01 ether,
            "bounty ratio of 100%"
        );
        assertEq(IStabilityPoolManager_v2(stabilityPoolManager).harvestCutRatio(), 0.99 ether, "cut ratio of 100%");
    }

    // Only the owner sets the pair, and only a pair that harvest can split: each ratio within 100% (which also keeps
    // the sum from wrapping) and the two summing within it.
    function test_updateHarvestRatiosInvalid() public {
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.01 ether, 0.99 ether);

        vm.startPrank(owner());
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPoolManager_v2.InvalidHarvestRatioSum.selector, 0.02 ether, 0.99 ether)
        );
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.02 ether, 0.99 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPoolManager_v2.InvalidHarvestBountyRatio.selector, type(uint256).max)
        );
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(type(uint256).max, 1);

        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager_v2.InvalidHarvestBountyRatio.selector, 1.1 ether));
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0, 1.1 ether);
        vm.stopPrank();

        assertEq(IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio(), 0, "bounty ratio unchanged");
        assertEq(IStabilityPoolManager_v2(stabilityPoolManager).harvestCutRatio(), 0, "cut ratio unchanged");
    }

    // Writing the pair whole means a valid pair is reached in one call from ANY stored pair, including one summing
    // above 100% - what a proxy configured before the two were validated together carries.
    function test_updateHarvestRatiosFromPairAboveOneHundredPercent() public {
        _storeHarvestRatios(0.01 ether, 1 ether);

        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.01 ether, 0.99 ether);
        vm.stopPrank();
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio(),
            0.01 ether,
            "migrated bounty ratio"
        );
        assertEq(IStabilityPoolManager_v2(stabilityPoolManager).harvestCutRatio(), 0.99 ether, "migrated cut ratio");
    }
}

struct Balances {
    uint256 totalPegged;
    uint256 totalLeveraged;
    uint256 minterPegged;
    uint256 minterCollateral;
    uint256 bountyReceiverCollateral;
    uint256 poolCollateralCollateral;
    uint256 poolLeveragedCollateral;
    uint256 bountyReceiverLeveraged;
    uint256 poolLeveragedLeveraged;
}

contract TestStabilityPoolManagerRebalance is TestStabilityPoolManagerSetUp {
    function _readBalances() internal view returns (Balances memory balances) {
        balances.totalPegged = IERC20(peggedToken).totalSupply();
        balances.totalLeveraged = IERC20(leveragedToken).totalSupply();
        balances.minterPegged = IMinter(minter).peggedTokenBalance();

        balances.bountyReceiverCollateral = IERC20(wrappedCollateralToken).balanceOf(bountyReceiver);
        balances.minterCollateral = IERC20(wrappedCollateralToken).balanceOf(minter);
        balances.poolCollateralCollateral = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        balances.poolLeveragedCollateral = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged);

        balances.bountyReceiverLeveraged = IERC20(leveragedToken).balanceOf(bountyReceiver);
        balances.poolLeveragedLeveraged = IERC20(leveragedToken).balanceOf(stabilityPoolLeveraged);
    }

    /// @notice When a pool's reward-integral capacity (maxLiquidationReward) is below what a full liquidation would
    /// distribute, the rebalance clamps that leg's pegged so the redeemed proceeds notified to the pool stay within the
    /// capacity - they can never overflow the reward integral. The capacity is mocked small here to make the clamp bind
    /// (in production it dwarfs any real liquidation, so the clamp is a safety bound that drains a huge loss over calls).
    function test_rebalanceClampsLiquidationToRewardCapacity() public {
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(1.5 ether);
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceBountyRatio(0.02 ether);
        vm.stopPrank();

        setUp_collateral(100 ether, 20 ether, user); // CR = 120%, below the 150% threshold -> rebalanceable
        vm.startPrank(user);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        uint256 userPegged = IERC20(peggedToken).balanceOf(user);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(userPegged / 3, user, 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(userPegged - (userPegged / 2), user, 0);
        vm.stopPrank();

        // force the collateral pool's reward-integral capacity far below the full-liquidation proceeds, so the clamp binds
        uint256 smallReward = 1e12;
        vm.mockCall(
            stabilityPoolCollateral,
            abi.encodeWithSelector(IMultipleRewardAccumulator.maxLiquidationReward.selector),
            abi.encode(smallReward)
        );

        uint256 poolBefore = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        uint256 bountyBefore = IERC20(wrappedCollateralToken).balanceOf(bountyReceiver);

        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);

        // the collateral liquidation's proceeds (the reward to the pool + the bounty carved from it) are the redeemed
        // `returned`, which the clamp held within the capacity - so nothing the reward integral can't absorb is notified
        uint256 rewardToPool = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - poolBefore;
        uint256 bounty = IERC20(wrappedCollateralToken).balanceOf(bountyReceiver) - bountyBefore;
        assertLe(rewardToPool + bounty, smallReward, "collateral liquidation proceeds clamped to the reward capacity");
        assertGt(rewardToPool, 0, "a partial liquidation still happened (the clamp reduces, not cancels)");
    }

    function test_rebalanceTransfers(uint256 threshold, uint256 bountyRatio) public {
        threshold = bound(threshold, 1.2 ether + 1, 2 ether); // Ensure threshold is between 100% and 200%
        bountyRatio = bound(bountyRatio, 0, 0.9 ether); // Ensure bounty ratio is between 0% and 100%

        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(threshold);
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceBountyRatio(bountyRatio);
        vm.stopPrank();

        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // Setup conditions for successful rebalance using the manager's ratio
        setUp_collateral(100 ether, 20 ether, user); // CR = 120 / 100 = 120%
        assertTrue(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "Should be rebalanceable");

        // Fund the stability pools
        vm.startPrank(user);

        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);

        uint256 userPegged = IERC20(peggedToken).balanceOf(user);
        assertEq(userPegged, 100 * price, "User should have 100 pegged tokens");

        IStabilityPool_v3(stabilityPoolCollateral).deposit(userPegged / 3, user, 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(userPegged - (userPegged / 2), user, 0);
        vm.stopPrank();

        // Execute rebalance as liquidator
        Balances memory before = _readBalances();
        assertEq(IERC20(leveragedToken).balanceOf(stabilityPoolCollateral), 0, "pool1 has no leveraged");

        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
        //                                          ---------
        Balances memory after_ = _readBalances();
        // we hit the rebalance collateral ratio exactly
        assertEq(IMinter(minter).collateralRatio(), threshold, "collateral ratio is reset after rebalance");
        assertEq(IERC20(leveragedToken).balanceOf(stabilityPoolCollateral), 0, "pool1 still has no leveraged");

        // qualitive assertions
        // minter
        assertLt(after_.totalPegged, before.totalPegged, "Should have liquidated some tokens");
        assertEq(
            before.totalPegged - after_.totalPegged,
            before.minterPegged - after_.minterPegged,
            "reduction in pegged is from minter"
        );

        // pools
        assertGt(
            after_.poolCollateralCollateral,
            before.poolCollateralCollateral,
            "collateral Pool should have more collateral after rebalance"
        );
        assertEq(
            after_.poolLeveragedCollateral,
            before.poolLeveragedCollateral,
            "leveraged Pool should have same collateral after rebalance"
        );
        assertGt(
            after_.poolLeveragedLeveraged,
            before.poolLeveragedLeveraged,
            "leveraged Pool should have more leveraged after rebalance"
        );
        // bounty receiver: its ratio of each leg's proceeds, floored, the proceeds read from the minter's side - the
        // collateral the minter paid out (the rebalance pays no fee) and the leveraged it minted - not from the receiver
        assertEq(
            after_.bountyReceiverCollateral - before.bountyReceiverCollateral,
            ((before.minterCollateral - after_.minterCollateral) * bountyRatio) / 1 ether,
            "Bounty receiver is paid its ratio of the collateral proceeds"
        );
        assertEq(
            after_.bountyReceiverLeveraged - before.bountyReceiverLeveraged,
            ((after_.totalLeveraged - before.totalLeveraged) * bountyRatio) / 1 ether,
            "Bounty receiver is paid its ratio of the leveraged proceeds"
        );

        // collateral cannot be created or destroyed
        assertEq(
            before.minterCollateral +
                before.bountyReceiverCollateral +
                before.poolCollateralCollateral +
                before.poolLeveragedCollateral,
            after_.minterCollateral +
                after_.bountyReceiverCollateral +
                after_.poolCollateralCollateral +
                after_.poolLeveragedCollateral,
            "Collateral balances"
        );
        // console2.log("poolLeveragedLeveraged gain=", after_.poolLeveragedLeveraged - before.poolLeveragedLeveraged);
        assertEq(
            ((after_.poolLeveragedLeveraged -
                before.poolLeveragedLeveraged +
                after_.bountyReceiverLeveraged -
                before.bountyReceiverLeveraged) *
                IStabilityPoolManager_v2(stabilityPoolManager).rebalanceBountyRatio()) / 1 ether,
            (after_.bountyReceiverLeveraged - before.bountyReceiverLeveraged),
            "Leveraged correctly split"
        );

        assertEq(
            ((after_.poolCollateralCollateral -
                before.poolCollateralCollateral +
                after_.bountyReceiverCollateral -
                before.bountyReceiverCollateral) *
                IStabilityPoolManager_v2(stabilityPoolManager).rebalanceBountyRatio()) / 1 ether,
            (after_.bountyReceiverCollateral - before.bountyReceiverCollateral),
            "Collateral correctly split"
        );
    }

    function test_rebalanceFailures() public {
        // Test when CR is too high compared to manager's ratio
        setUp_collateral(100 ether, 40 ether); // 1.4
        uint256 currentCR = IMinter(minter).collateralRatio();

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(currentCR);

        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(currentCR);

        assertFalse(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "Should not be rebalanceable");

        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(currentCR + 1);
        assertTrue(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "Should be rebalanceable");

        // threshold must be strictly > 1 ether; 1 ether hits the `newRatio <= 1 ether` guard.
        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager_v2.InvalidRebalanceThreshold.selector, 1 ether));
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(1 ether);

        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager_v2.InvalidRebalanceThreshold.selector, 0.9 ether));
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(0.9 ether);

        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(1 ether + 1);
        assertEq(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceThreshold(), 1 ether + 1);

        vm.stopPrank();
    }
}

contract TestStabilityPoolManagerHarvest is TestStabilityPoolManagerSetUp {
    address harvester;
    address liquidator;

    function setUp() public override {
        super.setUp();

        harvester = makeAddr("harvester");
        liquidator = makeAddr("liquidator");

        uint256 harvesterRole = IMinter(minter).HARVESTER_ROLE();
        vm.startPrank(owner());
        IBaoRoles(minter).grantRoles(harvester, harvesterRole);
        vm.stopPrank();

        setUp_collateral(500 ether, 500 ether, address(this));
        (uint256 startPrice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(startPrice, 1010101010101010101);
        uint256 harvestableAmount = IMinter(minter).harvestable();
        assertApproxEqAbs(harvestableAmount, 10 ether, 10, "harvestable should be 10 ether");
    }

    function _claimable(address user) internal returns (uint256 claimable) {
        claimable = IERC20(wrappedCollateralToken).balanceOf(user);
        uint256 snap = vm.snapshotState();
        vm.startPrank(user);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
        vm.stopPrank();
        claimable = IERC20(wrappedCollateralToken).balanceOf(user) - claimable;
        vm.revertToState(snap);

        assertApproxEqAbs(
            IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user, aa(wrappedCollateralToken))[0],
            claimable,
            1,
            string.concat(vm.getLabel(user), "claimable(), vs claim()")
        );
    }

    function _part(
        uint256 reward,
        uint256 balance,
        uint256 total,
        uint256 durationRatio
    ) internal pure returns (uint256) {
        return (balance * reward * durationRatio) / (total * 1 ether);
    }

    function test_harvestFrontRun_() public {
        // user1 & user2 do deposits
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(200 ether, user1, 0);
        vm.stopPrank();

        skip(100 weeks);

        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(800 ether, user2, 0);
        vm.stopPrank();

        assertEq(_claimable(user1), 0, "user1 claimable=0");
        assertEq(_claimable(user2), 0, "user2 claimable=0");

        uint256 snap = vm.snapshotState();

        //////////////////////////////////////////////////
        // SCENARIO 1 - simple harvest: distribution of harvest on basis of current balance
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        assertEq(_claimable(user1), 0, "user1 claimable=0");
        assertEq(_claimable(user2), 0, "user2 claimable=0");
        assertEq(_claimable(user3), 0, "user3 claimable=0");

        skip(1 weeks); // claimable is 0 even after a week, but that week is worth

        assertApproxEqAbs(_claimable(user1), _part(10e18, 200e18, 1000e18, 1e18), 1e16, "user1 claimable=2 eth");
        assertApproxEqAbs(_claimable(user2), _part(10e18, 800e18, 1000e18, 1e18), 1e6, "user2 claimable=0");
        assertApproxEqAbs(_claimable(user3), 0, 0, "user3 claimable=0");

        vm.revertToState(snap);

        //////////////////////////////////////////////////
        // SCENARIO 2 - user2 withdraws half way through: time-weighted reward distribution on current balance
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);

        skip(3.5 days); // claimable is 0 even after a week, but that week is worth

        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 _start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user2);
        vm.warp(_start + 1);
        vm.startPrank(user2);
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(400 ether, user2, 0);
        vm.stopPrank();

        skip(3.5 days);

        assertApproxEqAbs(
            _claimable(user1),
            _part(10e18, 200e18, 1000e18, 0.5e18) + _part(10e18, 200e18, 600e18, 0.5e18),
            1e16,
            "user1 claimable=2+ eth"
        );
        assertApproxEqAbs(
            _claimable(user2),
            _part(10e18, 800e18, 1000e18, 0.5e18) + _part(10e18, 400e18, 600e18, 0.5e18),
            1e16,
            "user2 claimable=6 ish eth"
        );
        assertApproxEqAbs(_claimable(user3), 0, 0, "user3 claimable=0");

        vm.revertToState(snap);

        //////////////////////////////////////////////////
        // SCENARIO 3 - user3 decides to front-run a harvest
        vm.startPrank(user3);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(1000 ether, user3, 0); // doubles the total shares
        vm.stopPrank();
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0); // get the harvest going
        // but wait...
        assertApproxEqAbs(_claimable(user1), 0, 0, "user1 claimable=0");
        assertApproxEqAbs(_claimable(user2), 0, 0, "user2 claimable=0");
        assertApproxEqAbs(_claimable(user3), 0, 0, "user3 claimable=0");
        // hang on...
        skip(1 weeks);
        assertApproxEqAbs(_claimable(user1), _part(10e18, 200e18, 2000e18, 1e18), 1e6, "user1 1 eth");
        assertApproxEqAbs(_claimable(user2), _part(10e18, 800e18, 2000e18, 1e18), 1e6, "user2 4 eth");
        assertApproxEqAbs(_claimable(user3), _part(10e18, 1000e18, 2000e18, 1e18), 1e6, "user3 5 eth");
    }

    /// With no bounty and no cut the bounty receiver and the fee receiver are paid nothing: the pools take it all.
    function test_harvest0_() public {
        // deposits in both pools, so the harvest goes to them
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(3 ether, address(this), 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(2 ether, address(this), 0);

        // Record initial balances
        uint256 harvesterBefore = IERC20(wrappedCollateralToken).balanceOf(harvester);
        uint256 feeReceiverBefore = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);

        // Execute harvest
        vm.startPrank(harvester);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();
        assertEq(IERC20(wrappedCollateralToken).balanceOf(harvester), harvesterBefore, "Incorrect bounty amount");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(feeReceiver), feeReceiverBefore, "Incorrect fee amount");
    }

    function test_harvestMinBounty_() public {
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPoolManager_v2.InsufficientBounty.selector, wrappedCollateralToken, 0, 1)
        );
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 1);

        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.10 ether, 0);
        vm.stopPrank();

        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager_v2.InsufficientBounty.selector,
                wrappedCollateralToken,
                1 ether - 1,
                1 ether
            )
        );
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 1 ether);

        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 1 ether - 1);
        // unbiased floors: no pool holds here, so the gross is split into the bounty floor and the fee receiver's
        // residual floor - two independent floors whose remainder (<= 1 wei) stays unharvested, handed to neither.
        assertLe(IMinter(minter).harvestable(), 1, "only the <= 1 wei bounty + fee-receiver flooring remainder stays");

        assertEq(IERC20(wrappedCollateralToken).balanceOf(harvester), 1 ether - 1, "Incorrect bounty amount of 0.5");
    }

    /// A 5% bounty: the yield is split between the pools by their deposits, 3 : 2; the bounty receiver takes its
    /// floored ratio of the gross, each pool its own floored residual share, and the harvest returns exactly those parts.
    function test_harvest_() public {
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(3 ether, address(this), 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(2 ether, address(this), 0);

        // Record initial balances
        uint256 harvesterBefore = IERC20(wrappedCollateralToken).balanceOf(harvester);
        uint256 pool1Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        uint256 pool2Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged);

        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.05 ether, 0);
        vm.stopPrank();

        // Execute harvest
        uint256 harvestableBefore = IMinter(minter).harvestable();
        vm.startPrank(harvester);
        uint256 harvested = IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        // each pool owes its floored share of the deposits; every party then takes its own floor of its own base
        uint256 owedCollateral = Math.mulDiv(harvestableBefore, 3 ether, 5 ether);
        uint256 owedLeveraged = Math.mulDiv(harvestableBefore, 2 ether, 5 ether);
        uint256 expectedBounty = Math.mulDiv(owedCollateral + owedLeveraged, 0.05 ether, 1 ether);
        uint256 expectedCollateral = Math.mulDiv(owedCollateral, 0.95 ether, 1 ether);
        uint256 expectedLeveraged = Math.mulDiv(owedLeveraged, 0.95 ether, 1 ether);

        assertEq(
            harvested,
            expectedBounty + expectedCollateral + expectedLeveraged,
            "the harvest returns exactly the parts it paid"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(harvester) - harvesterBefore,
            expectedBounty,
            "the bounty receiver takes its floored 5% of the gross"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - pool1Before,
            expectedCollateral,
            "the collateral pool takes its floored residual of its 3/5"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged) - pool2Before,
            expectedLeveraged,
            "the leveraged pool takes its floored residual of its 2/5"
        );
    }

    /// The bounty and cut receivers each receive EXACTLY their ratio slice of the gross harvested - pinned to the wei,
    /// not within a tolerance - and each party takes only its OWN floored share: the holding pool gets its floored net
    /// floor(gross * residualRatio), not a conserving complement, so the three independent floors (bounty, cut, net) sum
    /// to at most 2 wei below the gross and that remainder stays harvestable. A single holding pool makes the whole
    /// harvestable that pool's owed with no holdings-split floor, so `gross == harvestable` and the three floors are the
    /// only rounding in play.
    function test_harvestBountyCutExact_() public {
        // one pool holds all the pegged: the entire harvestable becomes its owed, uncapped, so gross == harvestable
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(3 ether, address(this), 0);

        uint256 bountyRatio = 0.05 ether;
        uint256 cutRatio = 0.03 ether;
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(bountyRatio, cutRatio);
        vm.stopPrank();

        uint256 gross = IMinter(minter).harvestable(); // == totalGross for a single holding pool
        uint256 expectedBounty = (gross * bountyRatio) / 1 ether;
        uint256 expectedCut = (gross * cutRatio) / 1 ether;
        uint256 expectedNet = (gross * (1 ether - bountyRatio - cutRatio)) / 1 ether; // the pool's OWN floored net

        uint256 bountyBefore = IERC20(wrappedCollateralToken).balanceOf(harvester);
        uint256 cutBefore = IERC20(wrappedCollateralToken).balanceOf(treasury()); // feeReceiver == treasury (setUp)
        uint256 poolBefore = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);

        vm.startPrank(harvester);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(harvester) - bountyBefore,
            expectedBounty,
            "bounty receiver gets exactly bountyRatio * gross"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(treasury()) - cutBefore,
            expectedCut,
            "cut receiver gets exactly cutRatio * gross"
        );
        // unbiased floors: the holding pool gets its OWN floored net floor(gross * residualRatio), not a conserving
        // complement, so the two fee floors plus the net sum to <= 2 wei below gross - that remainder stays harvestable.
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - poolBefore,
            expectedNet,
            "pool receives its own floored net"
        );
        assertLe(IMinter(minter).harvestable(), 2, "the flooring remainder stays unharvested");
        assertEq(
            expectedBounty + expectedCut + expectedNet + IMinter(minter).harvestable(),
            gross,
            "the floored parts plus the harvestable remainder account for the whole gross"
        );
    }

    function test_harvestToTreasury() public {
        // stability pools are empty, no bount or fee
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        assertEq(IERC20(wrappedCollateralToken).balanceOf(harvester), 0, "Harvester should not receive bounty");
        assertApproxEqAbs(
            IERC20(wrappedCollateralToken).balanceOf(treasury()),
            10 ether,
            10,
            "Treasury should receive bounty"
        );
        assertEq(IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral), 0 ether);
        assertEq(IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged), 0 ether);
    }

    function test_harvestToTreasury2() public {
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(3 ether, address(this), 0);
        // one pool is empty, no bount or fee
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        assertApproxEqAbs(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral),
            10 ether,
            10,
            "all goes to one pool, not treasury"
        );
        assertEq(IERC20(wrappedCollateralToken).balanceOf(harvester), 0, "no bounty");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(treasury()), 0, "Treasury should not receive bounty");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged), 0 ether, "none in this pool");
    }

    /// New yield is split between the pools by what each has had deposited, its supply: pegged sent straight to a pool
    /// is no deposit and moves no pool's share.
    function test_harvest_splitsNewYieldByDeposits_notByPeggedDonated() public {
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(3 ether, address(this), 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(2 ether, address(this), 0);
        IERC20(peggedToken).transfer(stabilityPoolLeveraged, 1 ether); // the pools now hold 3 and 3

        uint256 harvestableBefore = IMinter(minter).harvestable();
        uint256 collateralPoolBefore = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        uint256 leveragedPoolBefore = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged);

        vm.startPrank(harvester);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        // no bounty and no cut, so each pool's share is streamed to it whole
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - collateralPoolBefore,
            Math.mulDiv(harvestableBefore, 3 ether, 5 ether),
            "the collateral pool is paid its share of the deposits"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged) - leveragedPoolBefore,
            Math.mulDiv(harvestableBefore, 2 ether, 5 ether),
            "the leveraged pool is paid its share of the deposits, not of the pegged it holds"
        );
    }

    /// Pegged sent straight to pools nobody has deposited in makes no depositor, so the new yield goes to the
    /// treasury as it does when the pools hold nothing: its floored residual, the bounty its floored ratio.
    function test_harvest_peggedDonatedToPoolsWithNoDeposits_goesToTheTreasury() public {
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.1 ether, 0);
        vm.stopPrank();
        IERC20(peggedToken).transfer(stabilityPoolCollateral, 3 ether);

        uint256 harvestableBefore = IMinter(minter).harvestable();
        uint256 harvesterBefore = IERC20(wrappedCollateralToken).balanceOf(harvester);
        uint256 treasuryBefore = IERC20(wrappedCollateralToken).balanceOf(treasury());

        vm.startPrank(harvester);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(treasury()) - treasuryBefore,
            Math.mulDiv(harvestableBefore, 0.9 ether, 1 ether),
            "the treasury takes the residual"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(harvester) - harvesterBefore,
            Math.mulDiv(harvestableBefore, 0.1 ether, 1 ether),
            "the bounty receiver takes its ratio"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral),
            0,
            "the pool holding the pegged is paid nothing"
        );
    }

    /// With no pool holding, the whole harvest is the treasury's gross, and the treasury takes its OWN floored residual
    /// share floor(gross * residualRatio) - on its own base, like every other party - rather than the complement
    /// gross - bounty - cut. The bounty, the cut and the treasury's residual are three independent floors, so they sum
    /// below the gross and that remainder is left unharvested.
    function test_harvestTreasuryTakesFlooredShare_() public {
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.05 ether, 0.03 ether);
        vm.stopPrank();

        // an odd gross so the independent floors leave a >= 1 wei remainder (deterministic discrimination)
        deal(wrappedCollateralToken, minter, IERC20(wrappedCollateralToken).balanceOf(minter) + 777);
        uint256 gross = IMinter(minter).harvestable(); // no pool holds -> the whole gross is the treasury's
        uint256 residualRatio = 1 ether - 0.05 ether - 0.03 ether;
        uint256 flooredTreasury = (gross * 0.03 ether) / 1 ether + (gross * residualRatio) / 1 ether; // cut + floored net
        uint256 complementTreasury = gross - (gross * 0.05 ether) / 1 ether; // cut + (gross - bounty - cut) = gross - bounty
        // the fixture must distinguish the two, or the assertions below hold for either rule
        assertTrue(complementTreasury != flooredTreasury, "fixture produces a discriminating flooring remainder");

        uint256 treasuryBefore = IERC20(wrappedCollateralToken).balanceOf(treasury()); // feeReceiver == treasury (setUp)
        vm.startPrank(harvester);
        uint256 harvested = IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(treasury()) - treasuryBefore,
            flooredTreasury,
            "treasury takes floor(cut) + floor(residual), not the complement"
        );
        assertLt(harvested, gross, "the flooring remainder is left unharvested");
    }

    /// A harvestable too small for any pool's share to clear one reward period leaves every share deferred at a stream
    /// rate of zero, so no gross is distributed. harvest() then reverts rather than sweeping nothing and reporting a
    /// zero harvest; the revert also rolls back the owed attribution made earlier in the same call.
    function test_harvestNothingFairlyHarvestableReverts_() public {
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(3 ether, address(this), 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(2 ether, address(this), 0);

        // below one reward period: each pool's streamed net floors to zero (sub-period defer), so totalGross == 0
        uint256 tiny = IMultipleRewardDistributor_v3(stabilityPoolCollateral).REWARD_PERIOD_LENGTH() - 1;
        vm.mockCall(minter, abi.encodeWithSelector(IMinter.harvestable.selector), abi.encode(tiny));

        vm.startPrank(harvester);
        vm.expectRevert(IStabilityPoolManager_v2.NoHarvestable.selector);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();
    }

    /// An impaired collateral suspends harvesting entirely, and only an impairment does. The surplus is the excess of
    /// the holding over the RECORDED backing, so once the rate falls below the level the record was credited at the
    /// holding is under the record and there is no surplus by construction. The harvest must then REVERT rather than
    /// distribute a zero - and the revert must cost nothing, which is what the recovery leg establishes: the same
    /// surplus is still there to distribute afterwards, so nothing was consumed or stranded by the attempt.
    function test_harvest_revertsWhenBackingOverstated() public {
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(3 ether, address(this), 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(2 ether, address(this), 0);

        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 surplus = IMinter(minter).harvestable();
        assertGt(surplus, 0, "a surplus must exist for its disappearance to mean anything");

        // impair the collateral below the rate the record was credited at: the holding no longer covers the record
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, 0.9 ether);
        assertEq(IMinter(minter).harvestable(), 0, "a shortfall is not a surplus");

        vm.startPrank(harvester);
        vm.expectRevert(IStabilityPoolManager_v2.NoHarvestable.selector);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        // the collateral recovers: the surplus is untouched, so the revert took nothing with it
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
        assertEq(IMinter(minter).harvestable(), surplus, "the reverted harvest consumed no surplus");

        vm.startPrank(harvester);
        uint256 harvested = IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();
        assertGt(harvested, 0, "harvesting resumes once the holding covers the record again");
    }

    /// The minimum-bounty check precedes the nothing-fairly-harvestable short circuit: with no gross distributed the
    /// bounty is a floor-share of zero, so a keeper that demanded a bounty is told its bounty was insufficient - the
    /// more specific of the two failures.
    function test_harvestMinBountyPrecedesShortCircuit_() public {
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.05 ether, 0);
        vm.stopPrank();
        vm.mockCall(minter, abi.encodeWithSelector(IMinter.harvestable.selector), abi.encode(uint256(0)));

        uint256 minBounty = 1;
        vm.startPrank(harvester);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager_v2.InsufficientBounty.selector,
                wrappedCollateralToken,
                0,
                minBounty
            )
        );
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, minBounty);
        vm.stopPrank();
    }

    /// A write-down - the minter's excess shrinking below the total owed - scales EACH pool's owed by its OWN floored
    /// share, so neither pool is handed the rounding remainder and that remainder stays un-owed and unharvested. The
    /// leveraged pool receives exactly floor(itsOwed * shrunkExcess / totalOwed), below the complement that a conserving
    /// rule would hand it, and the harvest distributes only the two floored shares.
    function test_harvestWriteDownFloorsBothPools_() public {
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(3 ether, address(this), 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(2 ether, address(this), 0);

        // harvest #1: cap the stream small on both pools so most of each pool's share defers as owed
        uint256 cap = 0.1 ether;
        vm.mockCall(
            stabilityPoolCollateral,
            abi.encodeWithSelector(IMultipleRewardDistributor_v3.maxDepositReward.selector),
            abi.encode(cap)
        );
        vm.mockCall(
            stabilityPoolLeveraged,
            abi.encodeWithSelector(IMultipleRewardDistributor_v3.maxDepositReward.selector),
            abi.encode(cap)
        );
        // With no bounty or cut the residual ratio is 1, so each pool streams exactly the cap and the rest of its
        // share of the supplies is left as that pool's own owed. (Both shares exceed the cap here, so both defer.)
        uint256 supplyCollateral = IStabilityPool_v3(stabilityPoolCollateral).totalAssetSupply();
        uint256 supplyLeveraged = IStabilityPool_v3(stabilityPoolLeveraged).totalAssetSupply();
        uint256 totalSupply = supplyCollateral + supplyLeveraged;
        uint256 harvestableBefore = IMinter(minter).harvestable();
        uint256 owedCollateral = (harvestableBefore * supplyCollateral) / totalSupply - cap;
        uint256 owedLeveraged = (harvestableBefore * supplyLeveraged) / totalSupply - cap;

        vm.startPrank(harvester);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();
        vm.clearMockedCalls(); // restore the real (uncapped) maxDepositReward for harvest #2

        // the deferred owed still sits in the minter; shrink the excess below it to trigger the write-down
        uint256 owedBefore = owedCollateral + owedLeveraged;
        uint256 shrunk = owedBefore / 2 + 7;
        uint256 flooredCollateral = (owedCollateral * shrunk) / owedBefore;
        uint256 flooredLeveraged = (owedLeveraged * shrunk) / owedBefore;
        // both floors must lose a fraction, or the floored and conserving rules would agree and prove nothing
        assertLt(
            flooredCollateral + flooredLeveraged,
            shrunk,
            "fixture produces a discriminating write-down remainder"
        );
        vm.mockCall(minter, abi.encodeWithSelector(IMinter.harvestable.selector), abi.encode(shrunk));

        uint256 leveragedBefore = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged);
        vm.startPrank(harvester);
        uint256 harvested = IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        // a conserving rule would hand the leveraged pool `shrunk - flooredCollateral` instead - the remainder more
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged) - leveragedBefore,
            flooredLeveraged,
            "leveraged pool gets its own floored write-down share, not the remainder"
        );
        assertEq(
            harvested,
            flooredCollateral + flooredLeveraged,
            "the harvest distributes only the two floored shares"
        );
        assertLt(harvested, shrunk, "the write-down remainder is left unharvested");
    }

    /// The bounty is a floored share of the gross claimed, while the swept total trails that gross by the flooring
    /// remainder - so the bounty receiver is never paid less than its ratio of what actually left the minter, and never
    /// more than one wei above it. A one-sided bound rather than an equality, because no party is handed another's
    /// shortfall.
    function test_harvest_bountyNeverShortChangesReceiver() public {
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(3 ether, address(this), 0);
        uint256 bountyRatio = 0.05 ether;
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(bountyRatio, 0);
        vm.stopPrank();

        uint256 bountyBefore = IERC20(wrappedCollateralToken).balanceOf(harvester);
        vm.startPrank(harvester);
        uint256 swept = IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();
        uint256 bounty = IERC20(wrappedCollateralToken).balanceOf(harvester) - bountyBefore;

        uint256 flooredOfSwept = (swept * bountyRatio) / 1 ether;
        assertGe(bounty, flooredOfSwept, "bounty is never below the floored ratio of what was swept");
        assertLe(bounty, flooredOfSwept + 1, "bounty is over the floored-of-swept by at most 1 wei");
    }

    function test_harvestFailures() public {
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.05 ether, 0);
        vm.stopPrank();

        // Test with minimum bounty too high
        vm.startPrank(harvester);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager_v2.InsufficientBounty.selector,
                wrappedCollateralToken,
                0.5 ether - 1, // 5% of 10 ether
                1 ether
            )
        );
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 1 ether);
        vm.stopPrank();

        // Test when nothing to harvest
        vm.startPrank(harvester);
        ITokenHolder(minter).sweep(wrappedCollateralToken, IMinter(minter).harvestable(), owner());
        vm.stopPrank();

        vm.expectRevert(IStabilityPoolManager_v2.NoHarvestable.selector);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
    }

    /// With no bounty and no cut each pool is streamed exactly its floored share of the harvest, split by its deposits.
    function test_multiplePools() public {
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(7 ether, address(this), 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(3 ether, address(this), 0);
        uint256 harvestableBefore = IMinter(minter).harvestable();
        uint256 pool1Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        uint256 pool2Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged);

        // Harvest
        vm.startPrank(harvester);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - pool1Before,
            Math.mulDiv(harvestableBefore, 7 ether, 10 ether),
            "Pool 1 should receive 70% of harvest"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged) - pool2Before,
            Math.mulDiv(harvestableBefore, 3 ether, 10 ether),
            "Pool 2 should receive 30% of harvest"
        );
    }

    /// With a bounty ratio of zero the bounty receiver is paid nothing and the whole harvest goes to the pools, each
    /// its floored share by deposits; the harvest returns exactly the two shares.
    function test_harvestWithZeroBountyRatio_() public {
        // Ensure harvestBountyRatio is 0 (default)
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio(),
            0,
            "Harvest bounty ratio should be 0"
        );

        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(7 ether, address(this), 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(3 ether, address(this), 0);

        // Record balances before harvest
        uint256 harvestableBefore = IMinter(minter).harvestable();
        uint256 harvesterBefore = IERC20(wrappedCollateralToken).balanceOf(harvester);
        uint256 pool1Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        uint256 pool2Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged);

        // Execute harvest
        vm.startPrank(harvester);
        uint256 harvested = IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        // Verify harvester got no bounty (since ratio is 0)
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(harvester),
            harvesterBefore,
            "Harvester should not get bounty when ratio is 0"
        );

        uint256 expectedPool1 = Math.mulDiv(harvestableBefore, 7 ether, 10 ether);
        uint256 expectedPool2 = Math.mulDiv(harvestableBefore, 3 ether, 10 ether);
        assertEq(harvested, expectedPool1 + expectedPool2, "the harvest returns exactly the two pools' shares");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - pool1Before,
            expectedPool1,
            "Pool 1 should receive 70% of harvest"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged) - pool2Before,
            expectedPool2,
            "Pool 2 should receive 30% of harvest"
        );
    }

    /// A 10% bounty and a 20% cut to a fee receiver of the owner's choosing: the bounty receiver and the fee receiver
    /// each take their floored ratio of the gross, each pool its own floored residual share of the yield split by its
    /// deposits, and the harvest returns exactly those parts.
    function test_harvestWithCutRatioAndFeeReceiver_() public {
        // Set up the ratio pair - 10% bounty, 20% cut - and a fee receiver other than the one the deploy set
        address chosenFeeReceiver = makeAddr("chosenFeeReceiver");
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.1 ether, 0.2 ether);
        IStabilityPoolManager_v2(stabilityPoolManager).updateFeeReceiver(chosenFeeReceiver);
        vm.stopPrank();

        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(7 ether, address(this), 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(3 ether, address(this), 0);

        // Record initial balances (the chosen fee receiver, a fresh address, holds nothing)
        uint256 harvesterBefore = IERC20(wrappedCollateralToken).balanceOf(harvester);
        uint256 pool1Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        uint256 pool2Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged);

        // Execute harvest
        uint256 harvestableBefore = IMinter(minter).harvestable();
        vm.startPrank(harvester);
        uint256 harvested = IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        // each pool owes its floored share of the deposits; every party then takes its own floor of its own base
        uint256 owedCollateral = Math.mulDiv(harvestableBefore, 7 ether, 10 ether);
        uint256 owedLeveraged = Math.mulDiv(harvestableBefore, 3 ether, 10 ether);
        uint256 expectedBounty = Math.mulDiv(owedCollateral + owedLeveraged, 0.1 ether, 1 ether);
        uint256 expectedCut = Math.mulDiv(owedCollateral + owedLeveraged, 0.2 ether, 1 ether);
        uint256 expectedPool1 = Math.mulDiv(owedCollateral, 0.7 ether, 1 ether);
        uint256 expectedPool2 = Math.mulDiv(owedLeveraged, 0.7 ether, 1 ether);

        assertEq(
            harvested,
            expectedBounty + expectedCut + expectedPool1 + expectedPool2,
            "the harvest returns exactly the parts it paid"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(harvester) - harvesterBefore,
            expectedBounty,
            "Harvester should receive correct bounty"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(chosenFeeReceiver),
            expectedCut,
            "the fee receiver the owner chose receives the cut"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - pool1Before,
            expectedPool1,
            "Pool 1 should receive its residual of 70% of the harvest"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged) - pool2Before,
            expectedPool2,
            "Pool 2 should receive its residual of 30% of the harvest"
        );
    }

    // Test harvest with empty pools - should send to treasury
    function test_harvestWithEmptyPoolsToTreasury_() public {
        // Ensure neither pool has a deposit - what the harvest splits by
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).totalAssetSupply(), 0, "Pool 1 should be empty");
        assertEq(IStabilityPool_v3(stabilityPoolLeveraged).totalAssetSupply(), 0, "Pool 2 should be empty");

        // Set up bounty ratio
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.1 ether, 0); // 10% bounty
        vm.stopPrank();

        // Record initial balances
        uint256 harvesterBefore = IERC20(wrappedCollateralToken).balanceOf(harvester);
        uint256 treasuryBefore = IERC20(wrappedCollateralToken).balanceOf(treasury());

        // Execute harvest
        vm.startPrank(harvester);
        uint256 harvested = IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        // Calculate expected amounts
        uint256 expectedBounty = 1 ether; // 10% of 10 ether
        uint256 expectedToTreasury = 9 ether; // remainder goes to treasury

        // Verify harvested amount
        assertApproxEqAbs(harvested, 10 ether, 100, "Should return total harvested amount");

        // Check bounty was correctly sent to harvester
        assertApproxEqAbs(
            IERC20(wrappedCollateralToken).balanceOf(harvester) - harvesterBefore,
            expectedBounty,
            1,
            "Harvester should receive correct bounty"
        );

        // Check remainder went to treasury
        assertApproxEqAbs(
            IERC20(wrappedCollateralToken).balanceOf(treasury()) - treasuryBefore,
            expectedToTreasury,
            10,
            "Treasury should receive remainder when pools are empty"
        );
    }

    // A stored ratio pair summing above 100% describes a split that does not exist, so the market has no harvest
    // until the pair is repaired - which the pair setter does from any stored pair, whereupon harvest splits the
    // gross by it. The pools hold nothing here, so the whole gross is the treasury's, taken as the two fee floors.
    function test_harvestAfterRatioPairRepair_() public {
        _storeHarvestRatios(0.01 ether, 1 ether);

        vm.startPrank(harvester);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11)); // the residual has no representation
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.01 ether, 0.99 ether);
        vm.stopPrank();
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio(),
            0.01 ether,
            "repaired bounty ratio"
        );
        assertEq(IStabilityPoolManager_v2(stabilityPoolManager).harvestCutRatio(), 0.99 ether, "repaired cut ratio");

        uint256 harvestableBefore = IMinter(minter).harvestable();
        vm.startPrank(harvester);
        uint256 harvested = IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();
        assertEq(
            harvested,
            (harvestableBefore * 0.01 ether) / 1 ether + (harvestableBefore * 0.99 ether) / 1 ether,
            "harvest splits the gross by the repaired pair"
        );
    }

    /// Harvest with a cut sends the cut to the fee receiver (the treasury, per setUp): its floored ratio of the gross;
    /// each pool takes its own floored residual share of the yield split by its deposits, and the harvest returns
    /// exactly those parts.
    function test_harvestWithCutToFeeReceiver_() public {
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0, 0.2 ether); // 20% cut
        vm.stopPrank();

        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(7 ether, address(this), 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(3 ether, address(this), 0);

        // Record initial balances
        uint256 treasuryBefore = IERC20(wrappedCollateralToken).balanceOf(treasury());
        uint256 pool1Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        uint256 pool2Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged);

        // Execute harvest
        uint256 harvestableBefore = IMinter(minter).harvestable();
        vm.startPrank(harvester);
        uint256 harvested = IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        // each pool owes its floored share of the deposits; every party then takes its own floor of its own base
        uint256 owedCollateral = Math.mulDiv(harvestableBefore, 7 ether, 10 ether);
        uint256 owedLeveraged = Math.mulDiv(harvestableBefore, 3 ether, 10 ether);
        uint256 expectedCut = Math.mulDiv(owedCollateral + owedLeveraged, 0.2 ether, 1 ether);
        uint256 expectedPool1 = Math.mulDiv(owedCollateral, 0.8 ether, 1 ether);
        uint256 expectedPool2 = Math.mulDiv(owedLeveraged, 0.8 ether, 1 ether);

        assertEq(
            harvested,
            expectedCut + expectedPool1 + expectedPool2,
            "the harvest returns exactly the parts it paid"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - pool1Before,
            expectedPool1,
            "the collateral pool receives its residual after the cut"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged) - pool2Before,
            expectedPool2,
            "the leveraged pool receives its residual after the cut"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(treasury()) - treasuryBefore,
            expectedCut,
            "Treasury gets the fee receiver cut"
        );
    }

    // Test harvest with zero address as bounty receiver
    function test_harvestWithZeroBountyReceiver_() public {
        // Try to harvest with address(0) as bounty receiver
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(address(0), 0);
    }

    /// @dev One harvest, checked: served, or reverting as having nothing to harvest - the only revert allowed - and,
    ///      served, the minter's wrapped collateral falls by exactly what the harvest returns, which is at most the
    ///      `harvestable()` read just before it, and the minter's record is still covered after.
    function _harvestWithinHarvestable() private {
        uint256 harvestableBefore = IMinter(minter).harvestable();
        uint256 heldBefore = IERC20(wrappedCollateralToken).balanceOf(minter);
        try IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0) returns (uint256 harvested) {
            assertEq(
                heldBefore - IERC20(wrappedCollateralToken).balanceOf(minter),
                harvested,
                "the minter gives up exactly what the harvest returns"
            );
            assertLe(harvested, harvestableBefore, "never more than is harvestable");
            (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
            assertLe(recorded, held, "and the minter's record is still covered");
        } catch (bytes memory reason) {
            assertEq(
                reason,
                abi.encodeWithSelector(IStabilityPoolManager_v2.NoHarvestable.selector),
                "the only revert is that there is nothing to harvest"
            );
        }
    }

    /// The harvest never sweeps more than is harvestable - whatever each pool holds, whatever the bounty and cut, whether
    /// a pool's period capacity defers part of its share as owed, and whether the surplus then shrinks below what is
    /// owed, so that the owed is written down, or grows: each harvest served takes from the minter exactly what it
    /// returns, at most the `harvestable()` it found, and leaves the record covered.
    function testFuzz_harvest_neverSweepsMoreThanIsHarvestable(
        uint256 depositCollateral,
        uint256 depositLeveraged,
        uint256 bountyRatio,
        uint256 cutRatio,
        uint256 capacity,
        uint256 surplusBps
    ) public {
        // each pool holds nothing, or a deposit it accepts
        depositCollateral = bound(depositCollateral, 0, 400_000 ether);
        if (depositCollateral < IStabilityPool_v3(stabilityPoolCollateral).MIN_DEPOSIT()) {
            depositCollateral = 0;
        }
        depositLeveraged = bound(depositLeveraged, 0, 400_000 ether);
        if (depositLeveraged < IStabilityPool_v3(stabilityPoolLeveraged).MIN_DEPOSIT()) {
            depositLeveraged = 0;
        }
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        if (depositCollateral > 0) {
            IStabilityPool_v3(stabilityPoolCollateral).deposit(depositCollateral, address(this), 0);
        }
        if (depositLeveraged > 0) {
            IStabilityPool_v3(stabilityPoolLeveraged).deposit(depositLeveraged, address(this), 0);
        }
        // any pair the setter accepts, a full cut included
        bountyRatio = bound(bountyRatio, 0, 1 ether);
        cutRatio = bound(cutRatio, 0, 1 ether - bountyRatio);
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(bountyRatio, cutRatio);
        vm.stopPrank();
        uint256 firstHarvestable = IMinter(minter).harvestable();

        // the first harvest, each pool able to take only `capacity` this period, so the rest of its share stays owed
        capacity = bound(capacity, 0, 2 * firstHarvestable);
        vm.mockCall(
            stabilityPoolCollateral,
            abi.encodeWithSelector(IMultipleRewardDistributor_v3.maxDepositReward.selector),
            abi.encode(capacity)
        );
        vm.mockCall(
            stabilityPoolLeveraged,
            abi.encodeWithSelector(IMultipleRewardDistributor_v3.maxDepositReward.selector),
            abi.encode(capacity)
        );
        _harvestWithinHarvestable();
        vm.clearMockedCalls();

        // the second, after the rate leaves a surplus from none to twice the first's: below what is owed the owed is
        // written down, above it there is new yield
        uint256 surplus = Math.mulDiv(firstHarvestable, bound(surplusBps, 0, 20_000), 10_000);
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(
            price,
            Math.mulDiv(
                IMinter(minter).collateralTokenBalance(),
                1 ether,
                IERC20(wrappedCollateralToken).balanceOf(minter) - surplus
            )
        );
        _harvestWithinHarvestable();
    }

    /// With one pool holding and no bounty or cut, a harvest sweeps the whole of what is harvestable and nothing more:
    /// none is left harvestable and the record is still covered. This is the case in which a wei too many would show,
    /// where elsewhere the parties' floored shares leave a few wei behind.
    function test_harvest_ofEverythingHarvestable_sweepsExactlyThatAndLeavesTheRecordCovered() public {
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(3 ether, address(this), 0);
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0, 0);
        vm.stopPrank();
        uint256 harvestableBefore = IMinter(minter).harvestable();
        uint256 heldBefore = IERC20(wrappedCollateralToken).balanceOf(minter);

        uint256 harvested = IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);

        assertEq(harvested, harvestableBefore, "the whole of what is harvestable is swept");
        assertEq(
            heldBefore - IERC20(wrappedCollateralToken).balanceOf(minter),
            harvested,
            "and nothing more leaves the minter"
        );
        assertEq(IMinter(minter).harvestable(), 0, "none is left harvestable");
        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
        assertLe(recorded, held, "and the record is still covered");
    }

    // Test interface implementation
    // The manager reports the ABI it actually has: the v2 surface, which is the v1 one without the single-ratio
    // harvest setters. It must not claim the v1 interface, whose callers would find those two selectors missing.
    function test_supportsInterface_() public view {
        assertTrue(
            IERC165(stabilityPoolManager).supportsInterface(type(IStabilityPoolManager_v2).interfaceId),
            "Should support IStabilityPoolManager_v2 interface"
        );
        assertFalse(
            IERC165(stabilityPoolManager).supportsInterface(type(IStabilityPoolManager).interfaceId),
            "Should not claim the IStabilityPoolManager interface it no longer implements"
        );
        assertTrue(
            IERC165(stabilityPoolManager).supportsInterface(type(ITokenHolder).interfaceId),
            "Should support ITokenHolder interface"
        );
    }

    // Test interface implementation with non-supported interface
    function test_supportsInterfaceNegative_() public view {
        // Test that the contract correctly returns false for an unsupported interface
        bytes4 unsupportedInterfaceId = bytes4(keccak256("unsupported()"));
        bool supportsUnsupported = IERC165(stabilityPoolManager).supportsInterface(unsupportedInterfaceId);

        assertEq(supportsUnsupported, false, "Should not support random interface");
    }
}

contract TestStabilityPoolManagerCutAndFeeReceiver is TestStabilityPoolManagerSetUp {
    uint256 startPrice;
    uint256 startRate;

    function setUp() public override {
        super.setUp();

        // Get some harvestable amount in the minter
        assertEq(IMinter(minter).harvestable(), 0, "Initial harvestable should be 0");
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "Initial pegged token balance should be 0");
        assertEq(IMinter(minter).leveragedTokenBalance(), 0, "Initial leveraged token balance should be 0");

        setUp_collateral(500 ether, 500 ether, address(this));
        (startPrice, , startRate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // Set up token balances for stability pools
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(300 ether, address(this), 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(200 ether, address(this), 0);
    }

    function test_updateFeeReceiver_() public {
        // The fee receiver is never zero: setUp points it at the treasury (the initialize seed is the owner).
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).feeReceiver(),
            treasury(),
            "fee receiver starts at the setUp value (the treasury), never zero"
        );

        // Set a fee receiver other than the one the deploy set
        address firstFeeReceiver = makeAddr("firstFeeReceiver");
        vm.startPrank(owner());
        vm.expectEmit(true, true, false, false);
        emit IStabilityPoolManager_v2.UpdateFeeReceiver(treasury(), firstFeeReceiver);
        IStabilityPoolManager_v2(stabilityPoolManager).updateFeeReceiver(firstFeeReceiver);
        vm.stopPrank();

        // Verify it was set correctly
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).feeReceiver(),
            firstFeeReceiver,
            "Fee receiver should be updated"
        );

        // Update to a new address and verify event is emitted with correct old address
        address newFeeReceiver = makeAddr("newFeeReceiver");
        vm.startPrank(owner());
        vm.expectEmit(true, true, false, false);
        emit IStabilityPoolManager_v2.UpdateFeeReceiver(firstFeeReceiver, newFeeReceiver);
        IStabilityPoolManager_v2(stabilityPoolManager).updateFeeReceiver(newFeeReceiver);
        vm.stopPrank();

        // Try with non-owner which should fail (BaoOwnableRoles onlyOwner reverts Unauthorized).
        vm.startPrank(address(0xBEEF));
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPoolManager_v2(stabilityPoolManager).updateFeeReceiver(address(0xDEAD));
        vm.stopPrank();
    }

    function test_harvestWithCutAndFeeReceiver_(uint256 bounty, uint256 cut) public {
        // keep bounty + cut <= 99% so the residual to the pools stays well above the per-period dust floor and each pool
        // takes a real streamed share. The 100%-cut / no-residual corner (where the pools correctly receive nothing) is
        // covered by the envelope no-dust tests, not re-derived here.
        bounty = bound(bounty, 0, 0.99 ether);
        cut = bound(cut, 0, 0.99 ether - bounty);
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateFeeReceiver(makeAddr("chosenFeeReceiver"));
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(bounty, cut);
        vm.stopPrank();

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(
            startPrice,
            (startRate * 10) / 9 // Set a rate to ensure collateral is available
        );
        uint256 harvestableAmount = IMinter(minter).harvestable();
        assertApproxEqAbs(harvestableAmount, 100 ether, 100, "harvestable should be 100 ether");

        // The manager splits the new yield by holdings GROSS (flooring both), then skims each part on its own base: the
        // bounty and cut are the exact ratio floors of the total gross distributed, and EACH pool gets its own floored
        // net floor(grossShare * residualRatio) - no pool absorbs another party's rounding. Every flooring remainder (the
        // holdings split and each per-part floor) is left unharvested in the minter, not handed to a pool.
        uint256 residualRatio = 1 ether - bounty - cut;
        uint256 totalHolding = IERC20(peggedToken).balanceOf(stabilityPoolCollateral) +
            IERC20(peggedToken).balanceOf(stabilityPoolLeveraged);
        uint256 grossCollateral = (harvestableAmount * IERC20(peggedToken).balanceOf(stabilityPoolCollateral)) /
            totalHolding;
        uint256 grossLeveraged = (harvestableAmount * IERC20(peggedToken).balanceOf(stabilityPoolLeveraged)) /
            totalHolding;
        uint256 totalGross = grossCollateral + grossLeveraged;
        uint256 bountyAmount = (totalGross * bounty) / 1 ether;
        uint256 cutAmount = (totalGross * cut) / 1 ether;
        uint256 netCollateral = (grossCollateral * residualRatio) / 1 ether; // each pool's OWN floored net
        uint256 netLeveraged = (grossLeveraged * residualRatio) / 1 ether;
        uint256 expectedHarvested = bountyAmount + cutAmount + netCollateral + netLeveraged;

        address harvester = makeAddr("harvester");
        vm.expectEmit();
        emit IStabilityPoolManager_v2.Harvested(expectedHarvested);
        uint256 harvested = IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        assertEq(
            IERC20(peggedToken).balanceOf(stabilityPoolManager),
            0,
            "StabilityPoolManager should not receive tokens yet"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(makeAddr("chosenFeeReceiver")),
            cutAmount,
            "Fee receiver should receive the cut on the distributed gross"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(harvester),
            bountyAmount,
            "harvester should get the bounty on the distributed gross"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral),
            netCollateral,
            "collateral pool gets the net of its floored gross share"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged),
            netLeveraged,
            "leveraged pool gets the net of its floored gross share"
        );

        // unbiased floors: the harvest returns exactly the sum of every party's own floored share (the two fee floors
        // plus both pools' floored nets); the per-part flooring remainder is left unharvested, not absorbed into a pool.
        assertEq(harvested, expectedHarvested, "returns the sum of the floored shares actually distributed");
    }

    function test_harvestWithoutSufficientTokens_() public {
        // Set up the harvest cut ratio
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0, 0.1 ether); // 10% cut
        vm.stopPrank();

        // Set up harvester role
        uint256 harvesterRole = IMinter(minter).HARVESTER_ROLE();
        address harvester = makeAddr("harvester");
        vm.startPrank(owner());
        IBaoRoles(minter).grantRoles(harvester, harvesterRole);
        vm.stopPrank();

        // Mock some harvestable amount in the minter
        uint256 harvestableAmount = 100 ether;
        vm.mockCall(minter, abi.encodeWithSelector(IMinter.harvestable.selector), abi.encode(harvestableAmount));

        // Mock the token sweep to simulate harvesting - make it succeed
        vm.mockCall(
            minter,
            abi.encodeWithSelector(
                ITokenHolder.sweep.selector,
                wrappedCollateralToken,
                harvestableAmount,
                address(stabilityPoolManager)
            ),
            abi.encode()
        );

        // Set up token balances for stability pools
        vm.mockCall(
            address(peggedToken),
            abi.encodeWithSelector(IERC20.balanceOf.selector, stabilityPoolCollateral),
            abi.encode(7 ether)
        );
        vm.mockCall(
            address(peggedToken),
            abi.encodeWithSelector(IERC20.balanceOf.selector, stabilityPoolLeveraged),
            abi.encode(3 ether)
        );

        // DON'T give tokens to the stabilityPoolManager - this should cause the transfer to fail
        // We're testing what happens when there's not enough balance

        // Try to execute harvest - should revert with transfer failure
        vm.startPrank(harvester);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();
    }
}

contract TestStabilityPoolManagerUpgradeable is TestStabilityPoolManagerSetUp {
    address newImplementation;

    function setUp() public override {
        super.setUp();
        // Deploy the new implementation contract
        newImplementation = address(
            new MockStabilityPoolManagerUpgraded(minter, stabilityPoolCollateral, stabilityPoolLeveraged)
        );
    }

    function test_authorizeUpgrade_() public {
        // Only owner can upgrade
        vm.startPrank(address(0xBEEF));
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        UUPSUpgradeable(stabilityPoolManager).upgradeToAndCall(address(0), "");
        vm.stopPrank();

        // Create the V2 implementation (already done in setUp)

        // Perform the upgrade as the owner
        vm.startPrank(owner());
        UUPSUpgradeable(stabilityPoolManager).upgradeToAndCall(address(newImplementation), "");
        vm.stopPrank();

        // Verify the upgrade was successful by calling the new version function
        assertEq(
            MockStabilityPoolManagerUpgraded(stabilityPoolManager).isUpgraded(),
            true,
            "Upgrade should succeed and new function should return true"
        );

        // Check the new function is accessible
        assertEq(
            MockStabilityPoolManagerUpgraded(stabilityPoolManager).newFunctionOnlyInUpgrade(),
            true,
            "New function should be accessible after upgrade"
        );

        // Check the existing functionality still works
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).MINTER(),
            minter,
            "Immutable variables should remain after upgrade"
        );

        // Check that the storage values are preserved
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateHarvestRatios(0.1 ether, 0);
        vm.stopPrank();
        assertEq(
            IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio(),
            0.1 ether,
            "Storage should be preserved across upgrades"
        );
    }
}

/// @notice GIST-1 audit issue: a rebalance with the market below the peg (the audit's reproduction, modified only to
/// compile here). Below the peg each pegged redeemed for collateral takes its pro rata share of the backing with it,
/// so no amount redeemed moves the collateral ratio: there is nothing a rebalance can repair. It reverts by name
/// and the pools keep their pegged for when the price brings the market back above the peg.
contract Gist_1 is TestStabilityPoolManagerSetUp {
    function test_rebalanceDepeg() public {
        uint256 threshold = 1.3 ether;
        uint256 bountyRatio = 0.2 ether;

        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(threshold);
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceBountyRatio(bountyRatio);
        vm.stopPrank();

        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // Setup conditions for successful rebalance using the manager's ratio
        setUp_collateral(100 ether, 20 ether, user); // CR = 120 / 100 = 120%
        assertTrue(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "Should be rebalanceable");

        // Fund the stability pools
        vm.startPrank(user);

        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);

        uint256 userPegged = IERC20(peggedToken).balanceOf(user);
        assertEq(userPegged, 100 * price, "User should have 100 pegged tokens");

        IStabilityPool_v3(stabilityPoolCollateral).deposit(userPegged / 3, user, 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(userPegged - (userPegged / 2), user, 0);
        vm.stopPrank();

        // Execute rebalance as liquidator
        assertEq(IERC20(leveragedToken).balanceOf(stabilityPoolCollateral), 0, "pool1 has no leveraged");

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1555 ether); // makes the collateral ratio = 0.93
        uint256 depeggedRatio = IMinter(minter).collateralRatio();
        assertFalse(
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(),
            "below the peg no rebalance is offered"
        );

        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPoolManager_v2.CollateralRatioNotAbovePeg.selector, depeggedRatio)
        );
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
    }

    function test_rebalanceDepeg_exagerated() public {
        uint256 threshold = 1.3 ether;
        uint256 bountyRatio = 0.2 ether;

        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(threshold);
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceBountyRatio(bountyRatio);
        vm.stopPrank();

        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // Setup conditions for successful rebalance using the manager's ratio
        setUp_collateral(100 ether, 20 ether, user); // CR = 120 / 100 = 120%
        assertTrue(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "Should be rebalanceable");

        // Fund the stability pools
        vm.startPrank(user);

        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);

        uint256 userPegged = IERC20(peggedToken).balanceOf(user);
        assertEq(userPegged, 100 * price, "User should have 100 pegged tokens");

        IStabilityPool_v3(stabilityPoolCollateral).deposit(userPegged / 3, user, 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(userPegged - (userPegged / 2), user, 0);
        vm.stopPrank();

        // Execute rebalance as liquidator
        assertEq(IERC20(leveragedToken).balanceOf(stabilityPoolCollateral), 0, "pool1 has no leveraged");

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1000 ether); // makes the collateral ratio = 120 / 100 / 2 = 60%
        uint256 depeggedRatio = IMinter(minter).collateralRatio();
        assertFalse(
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(),
            "below the peg no rebalance is offered"
        );

        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPoolManager_v2.CollateralRatioNotAbovePeg.selector, depeggedRatio)
        );
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
    }
}

contract Gist_2 is TestStabilityPoolManagerSetUp {
    function test_insufficientStabilityPoolBalance() public {
        uint256 threshold = 1.4 ether; // Ensure threshold is between 100% and 200%
        uint256 bountyRatio = 0.2 ether; // Ensure bounty ratio is between 0% and 100%

        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(threshold);
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceBountyRatio(bountyRatio);
        vm.stopPrank();

        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // Setup conditions for successful rebalance using the manager's ratio
        setUp_collateral(100 ether, 20 ether, user); // CR = 120 / 100 = 120%
        assertTrue(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "Should be rebalanceable");

        // Fund the stability pools
        vm.startPrank(user);

        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);

        uint256 userPegged = IERC20(peggedToken).balanceOf(user);
        assertEq(userPegged, 100 * price, "User should have 100 pegged tokens");

        IStabilityPool_v3(stabilityPoolCollateral).deposit(userPegged / 4, user, 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(userPegged - (userPegged / 2), user, 0);
        vm.stopPrank();

        // Execute rebalance as liquidator
        assertEq(IERC20(leveragedToken).balanceOf(stabilityPoolCollateral), 0, "pool1 has no leveraged");

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1800 ether);
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
        // Adding one more rebalance call would drive the CR to the expected.
        //                                          ---------
        // we hit the rebalance collateral ratio exactly
        assertEq(IMinter(minter).collateralRatio(), threshold, "collateral ratio is reset after rebalance");
    }
}

/// @notice Tests the StabilityPoolManager's IYieldVaultManager surface: registering/unregistering yield vaults, the
/// enumeration views, the access + validation guards, and that every registered vault's compound() is triggered
/// (non-fatally) after a harvest.
contract TestStabilityPoolManagerYieldVaults is TestStabilityPoolManagerSetUp {
    address vaultA;
    address vaultB;
    address failingVault;
    address harvester;

    function setUp() public virtual override {
        super.setUp();
        harvester = makeAddr("harvester"); // harvest is permissionless; any caller works
        vaultA = address(new MockYieldVault(false));
        vaultB = address(new MockYieldVault(false));
        failingVault = address(new MockYieldVault(true));
    }

    // addYieldVault registers a vault - reflected in the count and the indexed getter - and emits YieldVaultAdded.
    function test_addYieldVault_registers() public {
        vm.expectEmit(true, false, false, false);
        emit IYieldVaultManager.YieldVaultAdded(vaultA);
        vm.startPrank(owner());
        IYieldVaultManager(stabilityPoolManager).addYieldVault(vaultA);
        vm.stopPrank();

        assertEq(IYieldVaultManager(stabilityPoolManager).yieldVaultCount(), 1, "one vault registered");
        assertEq(IYieldVaultManager(stabilityPoolManager).yieldVault(0), vaultA, "vault readable at index 0");
    }

    // The zero address is rejected.
    function test_addYieldVault_rejectsZero() public {
        vm.startPrank(owner());
        vm.expectRevert(abi.encodeWithSelector(IYieldVaultManager.InvalidYieldVault.selector, address(0)));
        IYieldVaultManager(stabilityPoolManager).addYieldVault(address(0));
        vm.stopPrank();
    }

    // A duplicate is rejected - the set never double-registers (and would never double-compound).
    function test_addYieldVault_rejectsDuplicate() public {
        vm.startPrank(owner());
        IYieldVaultManager(stabilityPoolManager).addYieldVault(vaultA);
        vm.expectRevert(abi.encodeWithSelector(IYieldVaultManager.InvalidYieldVault.selector, vaultA));
        IYieldVaultManager(stabilityPoolManager).addYieldVault(vaultA);
        vm.stopPrank();
        assertEq(IYieldVaultManager(stabilityPoolManager).yieldVaultCount(), 1, "still only one registered");
    }

    // Only the owner may add.
    function test_addYieldVault_onlyOwner() public {
        vm.startPrank(address(0xBEEF));
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IYieldVaultManager(stabilityPoolManager).addYieldVault(vaultA);
        vm.stopPrank();
    }

    // removeYieldVault unregisters a vault (swap-and-pop leaves the other) and emits YieldVaultRemoved.
    function test_removeYieldVault_unregisters() public {
        vm.startPrank(owner());
        IYieldVaultManager(stabilityPoolManager).addYieldVault(vaultA);
        IYieldVaultManager(stabilityPoolManager).addYieldVault(vaultB);
        vm.expectEmit(true, false, false, false);
        emit IYieldVaultManager.YieldVaultRemoved(vaultA);
        IYieldVaultManager(stabilityPoolManager).removeYieldVault(vaultA);
        vm.stopPrank();

        assertEq(IYieldVaultManager(stabilityPoolManager).yieldVaultCount(), 1, "one vault left");
        assertEq(IYieldVaultManager(stabilityPoolManager).yieldVault(0), vaultB, "the remaining vault is vaultB");
    }

    // Removing an unregistered vault reverts.
    function test_removeYieldVault_notFound() public {
        vm.startPrank(owner());
        vm.expectRevert(abi.encodeWithSelector(IYieldVaultManager.YieldVaultNotFound.selector, vaultA));
        IYieldVaultManager(stabilityPoolManager).removeYieldVault(vaultA);
        vm.stopPrank();
    }

    // Only the owner may remove.
    function test_removeYieldVault_onlyOwner() public {
        vm.startPrank(owner());
        IYieldVaultManager(stabilityPoolManager).addYieldVault(vaultA);
        vm.stopPrank();
        vm.startPrank(address(0xBEEF));
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IYieldVaultManager(stabilityPoolManager).removeYieldVault(vaultA);
        vm.stopPrank();
    }

    // 0 vaults: a harvest completes - the empty compound loop is a no-op, not a revert.
    function test_compoundOnHarvest_zeroVaults() public {
        _createHarvestable();
        vm.startPrank(harvester);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();
    }

    // 1 vault: the harvest compounds it.
    function test_compoundOnHarvest_oneVault() public {
        vm.startPrank(owner());
        IYieldVaultManager(stabilityPoolManager).addYieldVault(vaultA);
        vm.stopPrank();

        _createHarvestable();
        vm.startPrank(harvester);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        assertEq(MockYieldVault(vaultA).compoundCount(), 1, "the single vault was compounded");
    }

    // N vaults incl. a failing one: every vault is visited, the failure is caught (non-fatal), and the rest still run.
    function test_compoundOnHarvest_manyVaults_failureIsNonFatal() public {
        vm.startPrank(owner());
        IYieldVaultManager(stabilityPoolManager).addYieldVault(vaultA);
        IYieldVaultManager(stabilityPoolManager).addYieldVault(failingVault);
        IYieldVaultManager(stabilityPoolManager).addYieldVault(vaultB);
        vm.stopPrank();

        _createHarvestable();
        vm.startPrank(harvester);
        vm.expectEmit(true, false, false, false);
        emit IYieldVaultManager.CompoundFailed(failingVault, "");
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(harvester, 0);
        vm.stopPrank();

        assertEq(MockYieldVault(vaultA).compoundCount(), 1, "vaultA compounded despite the failing vault");
        assertEq(MockYieldVault(vaultB).compoundCount(), 1, "vaultB compounded despite the failing vault");
        assertEq(MockYieldVault(failingVault).compoundCount(), 0, "the failing vault counted no success");
    }

    /// @dev Give the minter excess wrapped collateral above its backing, so it has something to harvest - a harvest
    /// with zero harvestable reverts (NoHarvestable) before it reaches the vault-compound step.
    function _createHarvestable() internal {
        deal(wrappedCollateralToken, minter, IERC20(wrappedCollateralToken).balanceOf(minter) + 10 ether);
    }
}
