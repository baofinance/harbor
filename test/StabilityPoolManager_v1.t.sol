// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {TokenHolder, ITokenHolder} from "@bao/TokenHolder.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {StabilityPoolManager_v1} from "src/minter/StabilityPoolManager_v1.sol";

import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {TestStabilityPool2SetUp} from "test/Rebalance.t.sol";

import "test/Useful.sol";

contract TestStabilityPoolManagerSetUp is TestStabilityPool2SetUp {
    address stabilityPoolManager;
    address treasury;
    address bountyReceiver;
    address user;

    function setUp() public virtual override(TestStabilityPool2SetUp) {
        super.setUp();

        treasury = vm.createWallet("treasury").addr;
        bountyReceiver = vm.createWallet("bountyReceiver").addr;
        user = vm.createWallet("user").addr;
        // deal(peggedToken, user, 10000 ether);
        // vm.prank(user);
        // IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        // vm.prank(user);
        // IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);

        stabilityPoolManager = UnsafeUpgrades.deployUUPSProxy(
            address(new StabilityPoolManager_v1(minter, treasury, stabilityPoolCollateral, stabilityPoolLeveraged)),
            abi.encodeCall(StabilityPoolManager_v1.initialize, owner)
        );
        IBaoOwnable(stabilityPoolManager).transferOwnership(owner);

        uint256 rebalancerRole = IStabilityPool(stabilityPoolCollateral).REBALANCER_ROLE();
        uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
        uint256 harvesterRole = IMinter(minter).HARVESTER_ROLE();

        // Grant roles
        vm.startPrank(owner);
        IBaoRoles(stabilityPoolCollateral).grantRoles(stabilityPoolManager, rebalancerRole);
        IBaoRoles(stabilityPoolLeveraged).grantRoles(stabilityPoolManager, rebalancerRole);
        IBaoRoles(minter).grantRoles(stabilityPoolManager, zeroFeeRole);
        IBaoRoles(minter).grantRoles(stabilityPoolManager, harvesterRole);
        vm.stopPrank();
    }
}

contract TestStabilityPoolManagerInit is TestStabilityPoolManagerSetUp {
    address stabilityPoolManagerImpl;

    function setUp_impl() internal virtual {
        stabilityPoolManagerImpl = address(
            new StabilityPoolManager_v1(minter, treasury, stabilityPoolCollateral, stabilityPoolLeveraged)
        );
    }

    function setUp_proxy() internal virtual {
        stabilityPoolManager = UnsafeUpgrades.deployUUPSProxy(
            stabilityPoolManagerImpl,
            abi.encodeCall(StabilityPoolManager_v1.initialize, (owner))
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

        address[] memory pools = IStabilityPoolManager(stabilityPoolManager).stabilityPools();
        assertEq(pools.length, 2, "Should have 2 stability pools");
        assertTrue(
            IStabilityPoolManager(stabilityPoolManager).hasStabilityPool(stabilityPoolCollateral),
            "Should have pool1"
        );
        assertTrue(
            IStabilityPoolManager(stabilityPoolManager).hasStabilityPool(stabilityPoolLeveraged),
            "Should have pool2"
        );

        assertEq(
            IStabilityPoolManager(stabilityPoolManager).rebalanceBountyRatio(),
            0 ether,
            "Wrong rebalance bounty ratio"
        );
        assertEq(
            IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio(),
            0 ether,
            "Wrong harvest bounty ratio"
        );

        // we haven't transferred ownership yet
        assertEq(IBaoOwnable(stabilityPoolManager).owner(), address(this), "Wrong owner");

        // Check rebalanceCollateralRatio is initialized correctly
        assertEq(IStabilityPoolManager(stabilityPoolManager).rebalanceThreshold(), 0, "Wrong rebalance ratio");
    }
}

contract TestStabilityPoolManagerBasic is TestStabilityPoolManagerSetUp {
    function test_viewFunctions() public view {
        // Test basic view functions
        address[] memory pools = IStabilityPoolManager(stabilityPoolManager).stabilityPools();
        assertEq(pools.length, 2, "Should have 2 pools");
        assertEq(pools[0], stabilityPoolCollateral, "First pool mismatch");
        assertEq(pools[1], stabilityPoolLeveraged, "Second pool mismatch");

        assertTrue(
            IStabilityPoolManager(stabilityPoolManager).hasStabilityPool(stabilityPoolCollateral),
            "Should have pool1"
        );
        assertTrue(
            IStabilityPoolManager(stabilityPoolManager).hasStabilityPool(stabilityPoolLeveraged),
            "Should have pool2"
        );
        assertFalse(
            IStabilityPoolManager(stabilityPoolManager).hasStabilityPool(address(0)),
            "Should not have zero address pool"
        );

        assertEq(
            IStabilityPoolManager(stabilityPoolManager).rebalanceBountyRatio(),
            0 ether,
            "Wrong rebalance bounty ratio"
        );
        assertEq(
            IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio(),
            0 ether,
            "Wrong harvest bounty ratio"
        );
    }

    function test_setBounty() public {
        // Test setting bounty
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        StabilityPoolManager_v1(stabilityPoolManager).setRebalanceBountyRatio(0.02 ether);
        vm.prank(owner);
        StabilityPoolManager_v1(stabilityPoolManager).setRebalanceBountyRatio(0.02 ether);
        assertEq(
            IStabilityPoolManager(stabilityPoolManager).rebalanceBountyRatio(),
            0.02 ether,
            "Wrong rebalance bounty ratio"
        );

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        StabilityPoolManager_v1(stabilityPoolManager).setHarvestBountyRatio(0.01 ether);
        vm.prank(owner);
        StabilityPoolManager_v1(stabilityPoolManager).setHarvestBountyRatio(0.01 ether);
        assertEq(
            IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio(),
            0.01 ether,
            "Wrong harvest bounty ratio"
        );
    }

    function test_setRebalanceCollateralRatio() public {
        // Test setting rebalance collateral ratio
        uint256 newRatio = 140 ether / 100; // 140%

        vm.prank(owner);
        StabilityPoolManager_v1(stabilityPoolManager).setRebalanceThreshold(newRatio);

        assertEq(
            IStabilityPoolManager(stabilityPoolManager).rebalanceThreshold(),
            newRatio,
            "Wrong rebalance ratio after update"
        );

        // Test unauthorized access
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        StabilityPoolManager_v1(stabilityPoolManager).setRebalanceThreshold(135 ether / 100);
    }

    function test_rebalanceable() public {
        setUp_collateral(1 ether, 1 ether); // CR = 200%
        uint256 currentCR = IMinter(minter).collateralRatio();

        // Test rebalanceable condition using manager's rebalanceCollateralRatio
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).setRebalanceThreshold(currentCR + 1);
        assertTrue(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "Should be rebalanceable");

        // When CR >= manager's rebalance threshold, should not be rebalanceable
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).setRebalanceThreshold(currentCR);
        assertFalse(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "Should not be rebalanceable");

        // Update rebalance ratio and test again
        vm.prank(owner);
        StabilityPoolManager_v1(stabilityPoolManager).setRebalanceThreshold(currentCR + 2);
        assertTrue(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "Should be rebalanceable again");
    }

    function test_harvestable() public {
        // Test harvestable amount
        assertEq(IStabilityPoolManager(stabilityPoolManager).harvestable(), 0, "Should be 0 harvestable");
        setUp_collateral(1 ether, 1 ether);
        assertEq(IStabilityPoolManager(stabilityPoolManager).harvestable(), 0, "Should still be 0 harvestable");
        assertEq(
            IStabilityPoolManager(stabilityPoolManager).harvestable(),
            IMinter(minter).harvestable(),
            "Should be = harvestable"
        );

        (uint256 startPrice, uint256 startRate, , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(startPrice, startRate * 1.1 ether);
        assertGt(IStabilityPoolManager(stabilityPoolManager).harvestable(), 0, "Should be some harvestable");
    }
}

struct Balances {
    uint256 totalPegged;
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
        balances.minterPegged = IMinter(minter).peggedTokenBalance();

        balances.bountyReceiverCollateral = IERC20(wrappedCollateralToken).balanceOf(bountyReceiver);
        balances.minterCollateral = IERC20(wrappedCollateralToken).balanceOf(minter);
        balances.poolCollateralCollateral = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        balances.poolLeveragedCollateral = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged);

        balances.bountyReceiverLeveraged = IERC20(leveragedToken).balanceOf(bountyReceiver);
        balances.poolLeveragedLeveraged = IERC20(leveragedToken).balanceOf(stabilityPoolLeveraged);
    }

    function test_rebalanceTransfers(uint256 threshold, uint256 bountyRatio) public {
        threshold = bound(threshold, 1.2 ether + 1, 2 ether); // Ensure threshold is between 100% and 200%
        bountyRatio = bound(bountyRatio, 0, 0.9 ether); // Ensure bounty ratio is between 0% and 100%

        vm.startPrank(owner);
        IStabilityPoolManager(stabilityPoolManager).setRebalanceThreshold(threshold);
        IStabilityPoolManager(stabilityPoolManager).setRebalanceBountyRatio(bountyRatio);
        vm.stopPrank();
        // Check rebalanceable
        assertTrue(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "Should be rebalanceable");

        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // Setup conditions for successful rebalance using the manager's ratio
        setUp_collateral(100 ether, 20 ether, user); // CR = 120 / 100 = 120%

        // Fund the stability pools
        vm.startPrank(user);

        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);

        uint256 userPegged = IERC20(peggedToken).balanceOf(user);
        assertEq(userPegged, 100 * price, "User should have 100 pegged tokens");

        IStabilityPool(stabilityPoolCollateral).deposit(userPegged / 3, user, 0);
        IStabilityPool(stabilityPoolLeveraged).deposit(userPegged - (userPegged / 2), user, 0);
        vm.stopPrank();

        // Execute rebalance as liquidator
        Balances memory before = _readBalances();
        assertEq(IERC20(leveragedToken).balanceOf(stabilityPoolCollateral), 0, "pool1 has no leveraged");

        IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);
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
        // bounty receiver
        // assertGt(
        //     after_.bountyReceiverCollateral,
        //     before.bountyReceiverCollateral,
        //     "Bounty receiver should have collateral after rebalance"
        // );
        // assertGt(
        //     after_.bountyReceiverLeveraged,
        //     before.bountyReceiverLeveraged,
        //     "Bounty receiver should have leveraged after rebalance"
        // );

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
        console2.log("poolLeveragedLeveraged gain=", after_.poolLeveragedLeveraged - before.poolLeveragedLeveraged);
        assertEq(
            ((after_.poolLeveragedLeveraged -
                before.poolLeveragedLeveraged +
                after_.bountyReceiverLeveraged -
                before.bountyReceiverLeveraged) * IStabilityPoolManager(stabilityPoolManager).rebalanceBountyRatio()) /
                1 ether,
            (after_.bountyReceiverLeveraged - before.bountyReceiverLeveraged),
            "Leveraged correctly split"
        );

        assertEq(
            ((after_.poolCollateralCollateral -
                before.poolCollateralCollateral +
                after_.bountyReceiverCollateral -
                before.bountyReceiverCollateral) * IStabilityPoolManager(stabilityPoolManager).rebalanceBountyRatio()) /
                1 ether,
            (after_.bountyReceiverCollateral - before.bountyReceiverCollateral),
            "Collateral correctly split"
        );
    }

    function test_rebalanceFailures() public {
        // Test when CR is too high compared to manager's ratio
        uint256 currentCR = IMinter(minter).collateralRatio();
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPoolManager(stabilityPoolManager).setRebalanceThreshold(currentCR);

        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).setRebalanceThreshold(currentCR);
        assertFalse(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "Should not be rebalanceable");
    }
}

/*
contract TestStabilityPoolManagerHarvest is TestStabilityPoolManagerSetUp {
    function test_harvest() public {
        // Setup harvestable amount
        MockMinter(minter).setHarvestable(5 ether);

        // Make sure pools have some tokens to calculate proportion
        deal(bountyToken, stabilityPoolCollateral, 3 ether);
        deal(bountyToken, stabilityPoolLeveraged, 2 ether);

        // Record initial balances
        uint256 harvesterBefore = IERC20(bountyToken).balanceOf(harvester);
        uint256 pool1Before = IERC20(bountyToken).balanceOf(stabilityPoolCollateral);
        uint256 pool2Before = IERC20(bountyToken).balanceOf(stabilityPoolLeveraged);

        // Execute harvest
        vm.prank(harvester);
        uint256 harvested = IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);

        // Calculate expected bounty (5% of 5 ether)
        uint256 expectedBounty = (5 ether * 5) / 100;

        // Verify results
        assertEq(harvested, 5 ether, "Incorrect harvest amount");
        assertEq(IERC20(bountyToken).balanceOf(harvester) - harvesterBefore, expectedBounty, "Incorrect bounty amount");

        // Check distribution to pools (proportional to balance)
        uint256 pool1Increase = IERC20(bountyToken).balanceOf(stabilityPoolCollateral) - pool1Before;
        uint256 pool2Increase = IERC20(bountyToken).balanceOf(stabilityPoolLeveraged) - pool2Before;

        assertApproxEqRel(
            pool1Increase,
            ((5 ether - expectedBounty) * 3) / 5,
            0.01 ether,
            "Pool 1 should receive 3/5 of remaining harvest"
        );

        assertApproxEqRel(
            pool2Increase,
            ((5 ether - expectedBounty) * 2) / 5,
            0.01 ether,
            "Pool 2 should receive 2/5 of remaining harvest"
        );
    }

    function test_harvestFailures() public {
        // Test when nothing to harvest
        MockMinter(minter).setHarvestable(0);

        vm.prank(harvester);
        vm.expectRevert(IStabilityPoolManager.NoHarvestable.selector);
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);

        // Test with unauthorized caller
        MockMinter(minter).setHarvestable(5 ether);

        vm.expectRevert();
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);

        // Test with minimum bounty too high
        vm.prank(harvester);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.InsufficientBounty.selector,
                bountyToken,
                0.25 ether, // 5% of 5 ether
                1 ether
            )
        );
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 1 ether);
    }

    function test_harvest_noStabilityPools() public {
        // Setup a manager with no stability pools
        address[] memory emptyPools = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager.NoStabilityPools.selector));
        // Deploy a new manager with no pools
        new StabilityPoolManager_v1(minter, treasury, emptyPools);
    }
}

contract TestStabilityPoolManagerIntegration is TestStabilityPoolManagerSetUp {
    function test_fullCycle() public {
        // This test simulates a full cycle of operations:
        // 1. Set up the system with pools having deposits
        // 2. Perform a rebalance
        // 3. Generate harvestable value
        // 4. Perform a harvest

        // Setup
        MockMinter(minter).setCollateralRatio(120 ether / 100); // 120%

        // Fund the stability pools
        deal(bountyToken, user, 10 ether);
        vm.startPrank(user);
        IERC20(bountyToken).approve(stabilityPoolCollateral, 5 ether);
        IERC20(bountyToken).approve(stabilityPoolLeveraged, 5 ether);
        MockStabilityPool(stabilityPoolCollateral).deposit(5 ether, user, 0);
        MockStabilityPool(stabilityPoolLeveraged).deposit(5 ether, user, 0);
        vm.stopPrank();

        // Record initial balances
        uint256 liquidatorBefore = IERC20(bountyToken).balanceOf(liquidator);
        uint256 harvesterBefore = IERC20(bountyToken).balanceOf(harvester);

        // Step 1: Perform rebalance
        vm.prank(liquidator);
        uint256 liquidated = IStabilityPoolManager(stabilityPoolManager).rebalance(liquidator, 1 ether);

        assertGt(liquidated, 0, "Should have liquidated some tokens");
        assertEq(
            IERC20(bountyToken).balanceOf(liquidator) - liquidatorBefore,
            0.1 ether,
            "Bounty amount incorrect for liquidator"
        );

        // Step 2: Generate harvestable value
        MockMinter(minter).setHarvestable(3 ether);

        // Step 3: Perform harvest
        vm.prank(harvester);
        uint256 harvested = IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);

        assertEq(harvested, 3 ether, "Incorrect harvest amount");
        assertEq(
            IERC20(bountyToken).balanceOf(harvester) - harvesterBefore,
            0.15 ether, // 5% of 3 ether
            "Incorrect bounty amount for harvester"
        );

        // Verify system state after full cycle
        uint256 pool1Balance = IERC20(bountyToken).balanceOf(stabilityPoolCollateral);
        uint256 pool2Balance = IERC20(bountyToken).balanceOf(stabilityPoolLeveraged);

        assertGt(pool1Balance, 5 ether, "Pool 1 should have more than initial balance");
        assertGt(pool2Balance, 5 ether, "Pool 2 should have more than initial balance");
    }

    function test_multiplePools() public {
        // Test that distributes to multiple pools when harvesting
        MockMinter(minter).setHarvestable(10 ether);

        // Fund the stability pools with different balances
        deal(bountyToken, stabilityPoolCollateral, 7 ether);
        deal(bountyToken, stabilityPoolLeveraged, 3 ether);

        // Harvest
        vm.prank(harvester);
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);

        // Check rewards distribution is proportional to pool balances
        uint256 totalHarvestDistributed = (10 ether * 95) / 100; // after 5% bounty

        // We can't directly check the pool balances because the pool mock may not accurately
        // track balances like a real contract would. Instead, check that the pools got called
        // with accumulateReward and got approximately the right amounts.
        uint256 expectedPool1 = (totalHarvestDistributed * 7) / 10;
        uint256 expectedPool2 = (totalHarvestDistributed * 3) / 10;
    }
}
*/
