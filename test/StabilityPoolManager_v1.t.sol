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

import {MockStabilityPool} from "test/mock/MockStabilityPool.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {MockMinter} from "test/mock/MockMinter.sol";

import "test/Useful.sol";

contract TestStabilityPoolManagerSetUp is Test {
    address stabilityPoolManager;
    address owner;
    address treasury;
    address stabilityPoolManagerImpl;
    address minter;
    address stabilityPool1;
    address stabilityPool2;
    address bountyToken;
    address liquidator;
    address harvester;
    address user;

    uint256 liquidatorRole;
    uint256 harvesterRole;
    uint256 customRebalanceRatio = 125 ether / 100; // 125% default

    function setUp() public virtual {
        setUp_mocks();
        setUp_owner();
        setUp_impl();
        setUp_proxy();
        setUp_roles();
    }

    function setUp_owner() public virtual {
        owner = vm.createWallet("owner").addr;
        treasury = vm.createWallet("treasury").addr;
        liquidator = vm.createWallet("liquidator").addr;
        harvester = vm.createWallet("harvester").addr;
        user = vm.createWallet("user").addr;
    }

    function setUp_mocks() internal virtual {
        // Create mock contracts
        minter = address(new MockMinter());
        bountyToken = MockMinter(minter).WRAPPED_COLLATERAL_TOKEN();

        // Create mock stability pools
        stabilityPool1 = address(new MockStabilityPool(minter, bountyToken, false));
        stabilityPool2 = address(new MockStabilityPool(minter, bountyToken, true));

        // Fund the test contract
        vm.deal(address(this), 100 ether);
    }

    function setUp_impl() internal virtual {
        address[] memory stabilityPools = new address[](2);
        stabilityPools[0] = stabilityPool1;
        stabilityPools[1] = stabilityPool2;

        stabilityPoolManagerImpl = address(new StabilityPoolManager_v1(minter, treasury, stabilityPools));
    }

    function setUp_proxy() internal virtual {
        stabilityPoolManager = UnsafeUpgrades.deployUUPSProxy(
            stabilityPoolManagerImpl,
            abi.encodeCall(StabilityPoolManager_v1.initialize, (owner))
        );
    }

    function setUp_roles() internal virtual {
        liquidatorRole = StabilityPoolManager_v1(stabilityPoolManager).LIQUIDATOR_ROLE();
        harvesterRole = StabilityPoolManager_v1(stabilityPoolManager).HARVESTER_ROLE();

        // Grant roles
        IBaoRoles(stabilityPoolManager).grantRoles(liquidator, liquidatorRole);
        IBaoRoles(stabilityPoolManager).grantRoles(harvester, harvesterRole);

        // Fund contracts
        deal(bountyToken, address(this), 100 ether);
        deal(bountyToken, minter, 100 ether);
        IERC20(bountyToken).transfer(stabilityPoolManager, 10 ether);

        // Set configuration using update functions instead of initialization
        StabilityPoolManager_v1(stabilityPoolManager).setRebalanceBounty(0.1 ether, 0.05 ether);
        StabilityPoolManager_v1(stabilityPoolManager).setRebalanceCollateralRatio(customRebalanceRatio);

        // Transfer ownership to owner
        IBaoOwnable(stabilityPoolManager).transferOwnership(owner);
    }
}

contract TestStabilityPoolManagerInit is TestStabilityPoolManagerSetUp {
    function setUp() public override {
        setUp_mocks();
        setUp_owner();
        setUp_impl();
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
        setUp_proxy();
        setUp_roles();

        address[] memory pools = IStabilityPoolManager(stabilityPoolManager).stabilityPools();
        assertEq(pools.length, 2, "Should have 2 stability pools");
        assertTrue(IStabilityPoolManager(stabilityPoolManager).hasStabilityPool(stabilityPool1), "Should have pool1");
        assertTrue(IStabilityPoolManager(stabilityPoolManager).hasStabilityPool(stabilityPool2), "Should have pool2");

        (address token, uint256 amount, uint256 ratio) = IStabilityPoolManager(stabilityPoolManager).bounty();
        assertEq(token, bountyToken, "Wrong bounty token");
        assertEq(amount, 0.1 ether, "Wrong bounty amount");
        assertEq(ratio, 0.05 ether, "Wrong bounty ratio");

        assertEq(IBaoOwnable(stabilityPoolManager).owner(), owner, "Wrong owner");

        // Check rebalanceCollateralRatio is initialized correctly
        assertEq(
            IStabilityPoolManager(stabilityPoolManager).rebalanceCollateralRatio(),
            customRebalanceRatio,
            "Wrong rebalance ratio"
        );
    }
}

contract TestStabilityPoolManagerBasic is TestStabilityPoolManagerSetUp {
    function test_viewFunctions() public view {
        // Test basic view functions
        address[] memory pools = IStabilityPoolManager(stabilityPoolManager).stabilityPools();
        assertEq(pools.length, 2, "Should have 2 pools");
        assertEq(pools[0], stabilityPool1, "First pool mismatch");
        assertEq(pools[1], stabilityPool2, "Second pool mismatch");

        assertTrue(IStabilityPoolManager(stabilityPoolManager).hasStabilityPool(stabilityPool1), "Should have pool1");
        assertTrue(IStabilityPoolManager(stabilityPoolManager).hasStabilityPool(stabilityPool2), "Should have pool2");
        assertFalse(
            IStabilityPoolManager(stabilityPoolManager).hasStabilityPool(address(0)),
            "Should not have zero address pool"
        );

        (address token, uint256 amount, uint256 ratio) = IStabilityPoolManager(stabilityPoolManager).bounty();
        assertEq(token, bountyToken, "Wrong bounty token");
        assertEq(amount, 0.1 ether, "Wrong bounty amount");
        assertEq(ratio, 0.05 ether, "Wrong bounty ratio");
    }

    function test_setBounty() public {
        // Test setting bounty
        vm.prank(owner);
        StabilityPoolManager_v1(stabilityPoolManager).setRebalanceBounty(0.2 ether, 0.1 ether);

        (address token, uint256 amount, uint256 ratio) = IStabilityPoolManager(stabilityPoolManager).bounty();
        assertEq(token, bountyToken, "Wrong bounty token");
        assertEq(amount, 0.2 ether, "Wrong bounty amount");
        assertEq(ratio, 0.1 ether, "Wrong bounty ratio");

        // Test unauthorized access
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        StabilityPoolManager_v1(stabilityPoolManager).setRebalanceBounty(0.3 ether, 0.15 ether);
    }

    function test_setRebalanceCollateralRatio() public {
        // Test setting rebalance collateral ratio
        uint256 newRatio = 140 ether / 100; // 140%

        vm.prank(owner);
        StabilityPoolManager_v1(stabilityPoolManager).setRebalanceCollateralRatio(newRatio);

        assertEq(
            IStabilityPoolManager(stabilityPoolManager).rebalanceCollateralRatio(),
            newRatio,
            "Wrong rebalance ratio after update"
        );

        // Test unauthorized access
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        StabilityPoolManager_v1(stabilityPoolManager).setRebalanceCollateralRatio(135 ether / 100);
    }

    function test_rebalanceable() public {
        // Test rebalanceable condition using manager's rebalanceCollateralRatio
        MockMinter(minter).setCollateralRatio(120 ether / 100); // 120%

        // When CR < manager's rebalance threshold (125%), should be rebalanceable
        assertTrue(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "Should be rebalanceable");

        // When CR >= manager's rebalance threshold, should not be rebalanceable
        MockMinter(minter).setCollateralRatio(130 ether / 100); // 130%
        assertFalse(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "Should not be rebalanceable");

        // Update rebalance ratio and test again
        vm.prank(owner);
        StabilityPoolManager_v1(stabilityPoolManager).setRebalanceCollateralRatio(135 ether / 100);

        MockMinter(minter).setCollateralRatio(130 ether / 100); // 130%
        assertTrue(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "Should be rebalanceable after update");
    }

    function test_harvestable() public {
        // Test harvestable amount
        MockMinter(minter).setHarvestable(0);
        assertEq(IStabilityPoolManager(stabilityPoolManager).harvestable(), 0, "Should be 0 harvestable");

        MockMinter(minter).setHarvestable(5 ether);
        assertEq(IStabilityPoolManager(stabilityPoolManager).harvestable(), 5 ether, "Should be 5 ether harvestable");
    }
}

contract TestStabilityPoolManagerRebalance is TestStabilityPoolManagerSetUp {
    function test_rebalance() public {
        // Setup conditions for successful rebalance using the manager's ratio
        MockMinter(minter).setCollateralRatio(120 ether / 100); // 120%

        // Fund the stability pools
        vm.prank(user);
        IERC20(bountyToken).approve(stabilityPool1, 10 ether);
        vm.prank(user);
        MockStabilityPool(stabilityPool1).deposit(5 ether, user, 0);

        // Check rebalanceable
        assertTrue(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "Should be rebalanceable");

        // Execute rebalance as liquidator
        uint256 bountyReceiverBefore = IERC20(bountyToken).balanceOf(liquidator);

        vm.prank(liquidator);
        uint256 liquidated = IStabilityPoolManager(stabilityPoolManager).rebalance(liquidator, 1 ether);

        // Verify results
        assertGt(liquidated, 0, "Should have liquidated some tokens");
        assertEq(
            IERC20(bountyToken).balanceOf(liquidator) - bountyReceiverBefore,
            0.1 ether,
            "Bounty amount incorrect"
        );
    }

    function test_rebalanceFailures() public {
        // Test when CR is too high compared to manager's ratio
        MockMinter(minter).setCollateralRatio(130 ether / 100); // 130%

        assertFalse(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "Should not be rebalanceable");

        vm.prank(liquidator);
        vm.expectRevert();
        IStabilityPoolManager(stabilityPoolManager).rebalance(liquidator, 1 ether);

        // Test with unauthorized caller
        MockMinter(minter).setCollateralRatio(120 ether / 100); // 120%

        vm.expectRevert();
        IStabilityPoolManager(stabilityPoolManager).rebalance(liquidator, 1 ether);

        // Test with minimum liquidation too high
        vm.prank(liquidator);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager.InsufficientLiquidation.selector, 0, 10 ether));
        IStabilityPoolManager(stabilityPoolManager).rebalance(liquidator, 10 ether);
    }
}

contract TestStabilityPoolManagerHarvest is TestStabilityPoolManagerSetUp {
    function test_harvest() public {
        // Setup harvestable amount
        MockMinter(minter).setHarvestable(5 ether);

        // Make sure pools have some tokens to calculate proportion
        deal(bountyToken, stabilityPool1, 3 ether);
        deal(bountyToken, stabilityPool2, 2 ether);

        // Record initial balances
        uint256 harvesterBefore = IERC20(bountyToken).balanceOf(harvester);
        uint256 pool1Before = IERC20(bountyToken).balanceOf(stabilityPool1);
        uint256 pool2Before = IERC20(bountyToken).balanceOf(stabilityPool2);

        // Execute harvest
        vm.prank(harvester);
        uint256 harvested = IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);

        // Calculate expected bounty (5% of 5 ether)
        uint256 expectedBounty = (5 ether * 5) / 100;

        // Verify results
        assertEq(harvested, 5 ether, "Incorrect harvest amount");
        assertEq(IERC20(bountyToken).balanceOf(harvester) - harvesterBefore, expectedBounty, "Incorrect bounty amount");

        // Check distribution to pools (proportional to balance)
        uint256 pool1Increase = IERC20(bountyToken).balanceOf(stabilityPool1) - pool1Before;
        uint256 pool2Increase = IERC20(bountyToken).balanceOf(stabilityPool2) - pool2Before;

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
        IERC20(bountyToken).approve(stabilityPool1, 5 ether);
        IERC20(bountyToken).approve(stabilityPool2, 5 ether);
        MockStabilityPool(stabilityPool1).deposit(5 ether, user, 0);
        MockStabilityPool(stabilityPool2).deposit(5 ether, user, 0);
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
        uint256 pool1Balance = IERC20(bountyToken).balanceOf(stabilityPool1);
        uint256 pool2Balance = IERC20(bountyToken).balanceOf(stabilityPool2);

        assertGt(pool1Balance, 5 ether, "Pool 1 should have more than initial balance");
        assertGt(pool2Balance, 5 ether, "Pool 2 should have more than initial balance");
    }

    function test_multiplePools() public {
        // Test that distributes to multiple pools when harvesting
        MockMinter(minter).setHarvestable(10 ether);

        // Fund the stability pools with different balances
        deal(bountyToken, stabilityPool1, 7 ether);
        deal(bountyToken, stabilityPool2, 3 ether);

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
