// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";

import {StabilityPoolManager_v2} from "@harbor/minter/StabilityPoolManager_v2.sol";

import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestStabilityPool2SetUp} from "@harbor-test/Rebalance.t.sol";

import "@harbor-test/Useful.sol";

contract TestStabilityPoolManagerSetUp is TestStabilityPool2SetUp {
    address stabilityPoolManager;
    address treasury;
    address bountyReceiver;
    address user;

    function setUp() public virtual override(TestStabilityPool2SetUp) {
        super.setUp();

        treasury = makeAddr("treasury");
        bountyReceiver = makeAddr("bountyReceiver");
        user = makeAddr("user");
        // deal(peggedToken, user, 10000 ether);
        // vm.prank(user);
        // IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        // vm.prank(user);
        // IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);

        stabilityPoolManager = UnsafeUpgrades.deployUUPSProxy(
            address(new StabilityPoolManager_v2(minter, stabilityPoolCollateral, stabilityPoolLeveraged)),
            abi.encodeCall(StabilityPoolManager_v2.initialize, (address(this), owner))
        );
        IBaoOwnable(stabilityPoolManager).transferOwnership(owner);
        // Mirror the production deploy, which points the fee (cut) receiver at the treasury; the initialize seed is
        // the owner, and it is never zero.
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateFeeReceiver(treasury);

        uint256 rebalancerRole = IStabilityPool(stabilityPoolCollateral).REBALANCER_ROLE();
        uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
        uint256 harvesterRole = IMinter(minter).HARVESTER_ROLE();
        uint256 rewardDepositorRole = IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_DEPOSITOR_ROLE();

        // Grant roles
        vm.startPrank(owner);
        IBaoRoles(stabilityPoolCollateral).grantRoles(stabilityPoolManager, rebalancerRole);
        IBaoRoles(stabilityPoolLeveraged).grantRoles(stabilityPoolManager, rebalancerRole);
        IBaoRoles(minter).grantRoles(stabilityPoolManager, zeroFeeRole);
        IBaoRoles(minter).grantRoles(stabilityPoolManager, harvesterRole);
        IBaoRoles(stabilityPoolCollateral).grantRoles(stabilityPoolManager, rewardDepositorRole);
        IBaoRoles(stabilityPoolLeveraged).grantRoles(stabilityPoolManager, rewardDepositorRole);
        vm.stopPrank();
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
            abi.encodeCall(StabilityPoolManager_v2.initialize, (address(this), owner))
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
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceBountyRatio(0.02 ether);
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceBountyRatio(0.02 ether);
        assertEq(
            IStabilityPoolManager(stabilityPoolManager).rebalanceBountyRatio(),
            0.02 ether,
            "Wrong rebalance bounty ratio"
        );

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestBountyRatio(0.01 ether);
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestBountyRatio(0.01 ether);
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
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(newRatio);

        assertEq(
            IStabilityPoolManager(stabilityPoolManager).rebalanceThreshold(),
            newRatio,
            "Wrong rebalance ratio after update"
        );

        // Test unauthorized access
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(135 ether / 100);
    }

    function test_rebalanceable() public {
        setUp_collateral(1 ether, 1 ether); // CR = 200%
        uint256 currentCR = IMinter(minter).collateralRatio();

        // Test rebalanceable condition using manager's rebalanceCollateralRatio
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(currentCR + 1);
        assertTrue(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "Should be rebalanceable");

        // When CR >= manager's rebalance threshold, should not be rebalanceable
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(currentCR);
        assertFalse(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "Should not be rebalanceable");

        // Update rebalance ratio and test again
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(currentCR + 2);
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

    function test_supportsInterfaceNegative() public view {
        bytes4 invalidInterfaceId = bytes4(keccak256("InvalidInterface()"));
        bool supported = IERC165(stabilityPoolManager).supportsInterface(invalidInterfaceId);
        assertFalse(supported, "Should not support invalid interface");
    }

    function test_invalidRebalanceThreshold() public {
        vm.startPrank(owner);
        uint256 invalidThreshold = 0.9 ether; // Less than 1 ether
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPoolManager.InvalidRebalanceThreshold.selector, invalidThreshold)
        );
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(invalidThreshold);
        vm.stopPrank();
    }

    function test_invalidRebalanceBountyRatio() public {
        vm.startPrank(owner);
        uint256 invalidRatio = 1.1 ether; // Greater than 1 ether
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPoolManager.InvalidRebalanceBountyRatio.selector, invalidRatio)
        );
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceBountyRatio(invalidRatio);
        vm.stopPrank();
    }

    function test_invalidHarvestBountyRatio() public {
        vm.startPrank(owner);
        uint256 invalidRatio = 1.1 ether; // Greater than 1 ether
        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager.InvalidHarvestBountyRatio.selector, invalidRatio));
        IStabilityPoolManager(stabilityPoolManager).updateHarvestBountyRatio(invalidRatio);
        vm.stopPrank();
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
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(threshold);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceBountyRatio(bountyRatio);
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
        // console2.log("poolLeveragedLeveraged gain=", after_.poolLeveragedLeveraged - before.poolLeveragedLeveraged);
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
        setUp_collateral(100 ether, 40 ether); // 1.4
        uint256 currentCR = IMinter(minter).collateralRatio();

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(currentCR);

        vm.startPrank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(currentCR);

        assertFalse(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "Should not be rebalanceable");

        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(currentCR + 1);
        assertTrue(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "Should be rebalanceable");

        // threshold must be strictly > 1 ether; 1 ether hits the `newRatio <= 1 ether` guard.
        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager.InvalidRebalanceThreshold.selector, 1 ether));
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(1 ether);

        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager.InvalidRebalanceThreshold.selector, 0.9 ether));
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(0.9 ether);

        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(1 ether + 1);
        assertEq(IStabilityPoolManager(stabilityPoolManager).rebalanceThreshold(), 1 ether + 1);

        vm.stopPrank();
    }

    // // Test rebalance with zero collateral needed
    // function test_rebalanceWithZeroCollateral_() public {
    //     // Setup for rebalance
    //     vm.prank(owner);
    //     IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(1.5 ether);

    //     // Make pools have some balances
    //     deal(peggedToken, stabilityPoolCollateral, 5 ether);
    //     deal(peggedToken, stabilityPoolLeveraged, 5 ether);

    //     // Mock minter to return zero for redeemPeggedForCollateralRatio
    //     // This simulates a case where only leveraged token is needed
    //     vm.mockCall(
    //         minter,
    //         abi.encodeWithSelector(IMinter.redeemPeggedForCollateralRatio.selector, 1.5 ether),
    //         abi.encode(0)
    //     );

    //     vm.mockCall(
    //         minter,
    //         abi.encodeWithSelector(IMinter.swapPeggedForLeveragedForCollateralRatio.selector, 1.5 ether),
    //         abi.encode(10 ether)
    //     );

    //     // Mock collateral ratio to be below threshold
    //     MockMinter(minter).setCollateralRatio(1.4 ether); // Mock necessary functions to allow rebalance to complete
    //     vm.mockCall(
    //         stabilityPoolLeveraged,
    //         abi.encodeWithSelector(ITokenHolder.sweep.selector, peggedToken, 10 ether, address(stabilityPoolManager)),
    //         abi.encode()
    //     );

    //     vm.mockCall(
    //         minter,
    //         abi.encodeWithSelector(
    //             IMinter.freeSwapPeggedForLeveraged.selector,
    //             10 ether,
    //             address(stabilityPoolManager)
    //         ),
    //         abi.encode(10 ether)
    //     );

    //     // Execute rebalance
    //     uint256 liquidated = IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);

    //     // Verify the full pool balance was used for leveraged
    //     assertEq(liquidated, 10 ether, "Should have used total pool balance for leveraged");
    // }

    //     // Test rebalance with zero leveraged needed
    //     function test_rebalanceWithZeroLeveraged_() public {
    //         // Setup for rebalance
    //         vm.prank(owner);
    //         IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(1.5 ether);

    //         // Make pools have some balances
    //         deal(peggedToken, stabilityPoolCollateral, 5 ether);
    //         deal(peggedToken, stabilityPoolLeveraged, 5 ether);

    //         // Mock minter to return zero for swapPeggedForLeveragedForCollateralRatio
    //         // This simulates a case where only collateral token is needed
    //         vm.mockCall(
    //             minter,
    //             abi.encodeWithSelector(IMinter.redeemPeggedForCollateralRatio.selector, 1.5 ether),
    //             abi.encode(10 ether)
    //         );

    //         vm.mockCall(
    //             minter,
    //             abi.encodeWithSelector(IMinter.swapPeggedForLeveragedForCollateralRatio.selector, 1.5 ether),
    //             abi.encode(0)
    //         );

    //         // Mock collateral ratio to be below threshold
    //         MockMinter(minter).setCollateralRatio(1.4 ether); // Mock necessary functions to allow rebalance to complete
    //         vm.mockCall(
    //             stabilityPoolCollateral,
    //             abi.encodeWithSelector(ITokenHolder.sweep.selector, peggedToken, 10 ether, address(stabilityPoolManager)),
    //             abi.encode()
    //         );

    //         vm.mockCall(
    //             minter,
    //             abi.encodeWithSelector(IMinter.freeRedeemPeggedToken.selector, 10 ether, address(stabilityPoolManager)),
    //             abi.encode(10 ether)
    //         );

    //         // Execute rebalance
    //         uint256 liquidated = IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);

    //         // Verify the full pool balance was used for collateral
    //         assertEq(liquidated, 10 ether, "Should have used total pool balance for collateral");
    //     }
}

contract MockStabilityPoolManagerUpgraded is StabilityPoolManager_v2 {
    bool public upgradeSuccessful;

    // Keep the same constructor signature
    constructor(
        address minter_,
        address stabilityPoolCollateral,
        address stabilityPoolLeveraged
    ) StabilityPoolManager_v2(minter_, stabilityPoolCollateral, stabilityPoolLeveraged) {}

    // Add a new function that would only be available in the upgraded version
    function newFunctionOnlyInUpgrade() external pure returns (bool) {
        return true;
    }

    // Override a function to demonstrate it was upgraded
    function isUpgraded() external pure returns (bool) {
        return true;
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
        vm.prank(owner);
        IBaoRoles(minter).grantRoles(harvester, harvesterRole);

        setUp_collateral(500 ether, 500 ether, address(this));
        (uint256 startPrice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(startPrice, 1010101010101010101);
        uint256 harvestableAmount = IMinter(minter).harvestable();
        assertApproxEqAbs(harvestableAmount, 10 ether, 10, "harvestable should be 10 ether");
    }

    function _claimable(address user) internal returns (uint256 claimable) {
        claimable = IERC20(wrappedCollateralToken).balanceOf(user);
        uint256 snap = vm.snapshotState();
        vm.prank(user);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim();
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
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(200 ether, user1, 0);

        skip(100 weeks);

        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).deposit(800 ether, user2, 0);

        assertEq(_claimable(user1), 0, "user1 claimable=0");
        assertEq(_claimable(user2), 0, "user2 claimable=0");

        uint256 snap = vm.snapshotState();

        //////////////////////////////////////////////////
        // SCENARIO 1 - simple harvest: distribution of harvest on basis of current balance
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);
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
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);

        skip(3.5 days); // claimable is 0 even after a week, but that week is worth

        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).requestWithdrawal();
        (uint64 _start, ) = IStabilityPool(stabilityPoolCollateral).getWithdrawalRequest(user2);
        vm.warp(_start + 1);
        vm.prank(user2);
        IStabilityPool(stabilityPoolCollateral).withdraw(400 ether, user2, 0);

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
        vm.prank(user3);
        IStabilityPool(stabilityPoolCollateral).deposit(1000 ether, user3, 0); // doubles the total shares
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0); // get the harvest going
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

    function test_harvest0_() public {
        // Make sure pools have some tokens to calculate proportion
        deal(peggedToken, stabilityPoolCollateral, 3 ether);
        deal(peggedToken, stabilityPoolLeveraged, 2 ether);

        // Record initial balances
        uint256 harvesterBefore = IERC20(wrappedCollateralToken).balanceOf(harvester);
        uint256 feeReceiverBefore = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);

        // Execute harvest
        vm.prank(harvester);
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);
        assertEq(IERC20(wrappedCollateralToken).balanceOf(harvester), harvesterBefore, "Incorrect bounty amount");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(feeReceiver), feeReceiverBefore, "Incorrect fee amount");
    }

    function test_harvestMinBounty_() public {
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPoolManager.InsufficientBounty.selector, wrappedCollateralToken, 0, 1)
        );
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 1);

        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestBountyRatio(0.10 ether);

        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.InsufficientBounty.selector,
                wrappedCollateralToken,
                1 ether - 1,
                1 ether
            )
        );
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 1 ether);

        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 1 ether - 1);
        assertEq(IMinter(minter).harvestable(), 0);

        assertEq(IERC20(wrappedCollateralToken).balanceOf(harvester), 1 ether - 1, "Incorrect bounty amount of 0.5");
    }

    function test_harvest_() public {
        // Make sure pools have some tokens to calculate proportion
        deal(peggedToken, stabilityPoolCollateral, 3 ether);
        deal(peggedToken, stabilityPoolLeveraged, 2 ether);

        // Record initial balances
        uint256 harvesterBefore = IERC20(wrappedCollateralToken).balanceOf(harvester);
        uint256 pool1Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        uint256 pool2Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged);

        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestBountyRatio(0.05 ether);

        // Execute harvest
        uint256 harvestableBefore = IMinter(minter).harvestable();
        vm.prank(harvester);
        uint256 harvested = IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);

        // Calculate expected bounty (5% of 10 ether)
        uint256 expectedBounty = (10 ether * 5) / 100;

        // Verify results: harvested == what left the minter; the split-gross-then-skim path floors <= 5 wei below the
        // harvestable (a holdings-split remainder <= 1 wei plus four ratio floors), which stays harvestable.
        assertApproxEqAbs(
            harvested,
            harvestableBefore,
            6,
            "harvest takes ~all the harvestable, less the flooring remainder"
        );
        assertApproxEqAbs(
            IERC20(wrappedCollateralToken).balanceOf(harvester) - harvesterBefore,
            expectedBounty,
            1,
            "Incorrect bounty amount 5%"
        );

        // Check distribution to pools (proportional to balance)
        uint256 pool1Increase = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - pool1Before;
        uint256 pool2Increase = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged) - pool2Before;

        assertApproxEqRel(
            pool1Increase,
            ((10 ether - expectedBounty) * 3) / 5,
            0.01 ether,
            "Pool 1 should receive 3/5 of remaining harvest"
        );

        assertApproxEqRel(
            pool2Increase,
            ((10 ether - expectedBounty) * 2) / 5,
            0.01 ether,
            "Pool 2 should receive 2/5 of remaining harvest"
        );
    }

    function test_harvestToTreasury() public {
        // stability pools are empty, no bount or fee
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);
        assertEq(IERC20(wrappedCollateralToken).balanceOf(harvester), 0, "Harvester should not receive bounty");
        assertApproxEqAbs(
            IERC20(wrappedCollateralToken).balanceOf(treasury),
            10 ether,
            10,
            "Treasury should receive bounty"
        );
        assertEq(IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral), 0 ether);
        assertEq(IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged), 0 ether);
    }

    function test_harvestToTreasury2() public {
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IStabilityPool(stabilityPoolCollateral).deposit(3 ether, address(this), 0);
        // one pool is empty, no bount or fee
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);
        assertApproxEqAbs(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral),
            10 ether,
            10,
            "all goes to one pool, not treasury"
        );
        assertEq(IERC20(wrappedCollateralToken).balanceOf(harvester), 0, "no bounty");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(treasury), 0, "Treasury should not receive bounty");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged), 0 ether, "none in this pool");
    }

    function test_harvestFailures() public {
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestBountyRatio(0.05 ether);

        // Test with minimum bounty too high
        vm.prank(harvester);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStabilityPoolManager.InsufficientBounty.selector,
                wrappedCollateralToken,
                0.5 ether - 1, // 5% of 10 ether
                1 ether
            )
        );
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 1 ether);

        // Test when nothing to harvest
        vm.startPrank(harvester);
        ITokenHolder(minter).sweep(wrappedCollateralToken, IMinter(minter).harvestable(), owner);
        vm.stopPrank();

        vm.expectRevert(IStabilityPoolManager.NoHarvestable.selector);
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);
    }

    function test_multiplePools() public {
        // Test that distributes to multiple pools when harvesting

        // Fund the stability pools with different balances
        deal(peggedToken, stabilityPoolCollateral, 7 ether);
        deal(peggedToken, stabilityPoolLeveraged, 3 ether);

        // Harvest
        vm.prank(harvester);
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);

        // Check rewards distribution is proportional to pool balances
        uint256 totalHarvestDistributed = 10 ether; // (10 ether * 95) / 100; // after 5% bounty

        uint256 expectedPool1 = (totalHarvestDistributed * 7) / 10;
        uint256 expectedPool2 = (totalHarvestDistributed * 3) / 10;

        assertApproxEqAbs(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral),
            expectedPool1,
            10,
            "Pool 1 should receive 70% of harvest"
        );
        assertApproxEqAbs(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged),
            expectedPool2,
            10,
            "Pool 2 should receive 30% of harvest"
        );
    }

    // Test case where bountyAmount is 0 due to zero harvestBountyRatio
    function test_harvestWithZeroBountyRatio_() public {
        // Ensure harvestBountyRatio is 0 (default)
        assertEq(
            IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio(),
            0,
            "Harvest bounty ratio should be 0"
        );

        // Set up pools with balances
        deal(peggedToken, stabilityPoolCollateral, 7 ether);
        deal(peggedToken, stabilityPoolLeveraged, 3 ether);

        // Record balances before harvest
        uint256 harvesterBefore = IERC20(wrappedCollateralToken).balanceOf(harvester);
        uint256 pool1Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        uint256 pool2Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged);

        // Execute harvest
        vm.prank(harvester);
        uint256 harvested = IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);

        // Verify harvester got no bounty (since ratio is 0)
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(harvester),
            harvesterBefore,
            "Harvester should not get bounty when ratio is 0"
        );

        // Check correct distribution to pools
        uint256 pool1Increase = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - pool1Before;
        uint256 pool2Increase = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged) - pool2Before;

        assertApproxEqAbs(harvested, 10 ether, 10, "Should have harvested 10 ether");
        assertApproxEqAbs(pool1Increase + pool2Increase, 10 ether, 10, "Full harvest amount should go to pools");

        // Verify proportional distribution (7:3 ratio)
        assertApproxEqRel(pool1Increase, 7 ether, 0.01 ether, "Pool 1 should receive 70% of harvest");

        assertApproxEqRel(pool2Increase, 3 ether, 0.01 ether, "Pool 2 should receive 30% of harvest");
    }

    // Test for the harvestCutRatio and feeReceiver functionality
    function test_harvestWithCutRatioAndFeeReceiver_() public {
        // Set up cut ratio and fee receiver
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestCutRatio(0.2 ether); // 20% cut

        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateFeeReceiver(feeReceiver);

        // Set up bounty ratio
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestBountyRatio(0.1 ether); // 10% bounty

        // Set up pools with balances
        deal(peggedToken, stabilityPoolCollateral, 7 ether);
        deal(peggedToken, stabilityPoolLeveraged, 3 ether);

        // Record initial balances
        uint256 harvesterBefore = IERC20(wrappedCollateralToken).balanceOf(harvester);
        uint256 feeReceiverBefore = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);
        uint256 pool1Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        uint256 pool2Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged);

        // Execute harvest
        uint256 harvestableBefore = IMinter(minter).harvestable();
        vm.prank(harvester);
        uint256 harvested = IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);

        // Calculate expected amounts
        uint256 expectedBounty = 1 ether; // 10% of 10 ether
        uint256 expectedCut = 2 ether; // 20% of 10 ether
        uint256 remainingForPools = 7 ether; // 10 - 1 - 2 = 7 ether

        // Verify harvested amount: it equals what left the minter, less the split-gross-then-skim flooring (<= 5 wei)
        assertApproxEqAbs(
            harvested,
            harvestableBefore,
            6,
            "harvest takes ~all the harvestable, less the flooring remainder"
        );
        assertApproxEqAbs(
            IERC20(wrappedCollateralToken).balanceOf(harvester) - harvesterBefore,
            expectedBounty,
            1,
            "Harvester should receive correct bounty"
        );

        // Check cut was correctly sent to fee receiver
        assertApproxEqAbs(
            IERC20(wrappedCollateralToken).balanceOf(feeReceiver) - feeReceiverBefore,
            expectedCut,
            2,
            "Fee receiver should receive correct cut"
        );

        // Check distribution to pools
        uint256 pool1Increase = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - pool1Before;
        uint256 pool2Increase = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged) - pool2Before;

        assertApproxEqRel(
            pool1Increase,
            (remainingForPools * 7) / 10,
            0.01 ether,
            "Pool 1 should receive 70% of remaining harvest"
        );

        assertApproxEqRel(
            pool2Increase,
            (remainingForPools * 3) / 10,
            0.01 ether,
            "Pool 2 should receive 30% of remaining harvest"
        );
    }

    // Test harvest with empty pools - should send to treasury
    function test_harvestWithEmptyPoolsToTreasury_() public {
        // Ensure pools are empty
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 0, "Pool 1 should be empty");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolLeveraged), 0, "Pool 2 should be empty");

        // Set up bounty ratio
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestBountyRatio(0.1 ether); // 10% bounty

        // Record initial balances
        uint256 harvesterBefore = IERC20(wrappedCollateralToken).balanceOf(harvester);
        uint256 treasuryBefore = IERC20(wrappedCollateralToken).balanceOf(treasury);

        // Execute harvest
        vm.prank(harvester);
        uint256 harvested = IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);

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
            IERC20(wrappedCollateralToken).balanceOf(treasury) - treasuryBefore,
            expectedToTreasury,
            10,
            "Treasury should receive remainder when pools are empty"
        );
    }

    // Harvest with a cut sends the cut to the fee receiver (the treasury, per setUp); the pools get the residual.
    function test_harvestWithCutToFeeReceiver_() public {
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestCutRatio(0.2 ether); // 20% cut

        // Set up pools with balances
        deal(peggedToken, stabilityPoolCollateral, 7 ether);
        deal(peggedToken, stabilityPoolLeveraged, 3 ether);

        // Record initial balances
        uint256 pool1Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        uint256 pool2Before = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged);

        // Execute harvest
        uint256 harvestableBefore = IMinter(minter).harvestable();
        vm.prank(harvester);
        uint256 harvested = IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);

        // The cut goes to the fee receiver (the treasury); the pools get the residual (harvestable - cut).
        uint256 pool1Increase = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - pool1Before;
        uint256 pool2Increase = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged) - pool2Before;

        // harvested == what left the minter, less the split-gross-then-skim flooring (<= 5 wei), which stays harvestable
        assertApproxEqAbs(
            harvested,
            harvestableBefore,
            6,
            "harvest takes ~all the harvestable, less the flooring remainder"
        );
        assertApproxEqAbs(
            pool1Increase + pool2Increase,
            8 ether, // residual after the 20% cut (no bounty)
            10,
            "the pools receive the residual after the cut"
        );
        assertApproxEqAbs(
            IERC20(wrappedCollateralToken).balanceOf(treasury),
            2 ether,
            10,
            "Treasury gets the fee receiver cut"
        );
    }

    // Test harvest with zero address as bounty receiver
    function test_harvestWithZeroBountyReceiver_() public {
        // Try to harvest with address(0) as bounty receiver
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        IStabilityPoolManager(stabilityPoolManager).harvest(address(0), 0);
    }

    // Test interface implementation
    function test_supportsInterface_() public view {
        // Test that the contract correctly implements its interfaces
        bool supportsStabilityPoolManager = IERC165(stabilityPoolManager).supportsInterface(
            type(IStabilityPoolManager).interfaceId
        );
        bool supportsTokenHolder = IERC165(stabilityPoolManager).supportsInterface(type(ITokenHolder).interfaceId);

        assertTrue(supportsStabilityPoolManager, "Should support IStabilityPoolManager interface");
        assertTrue(supportsTokenHolder, "Should support ITokenHolder interface");
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
        IStabilityPool(stabilityPoolCollateral).deposit(300 ether, address(this), 0);
        IStabilityPool(stabilityPoolLeveraged).deposit(200 ether, address(this), 0);
    }

    function test_updateHarvestCutRatio_() public {
        // Initially should be zero
        assertEq(
            IStabilityPoolManager(stabilityPoolManager).harvestCutRatio(),
            0,
            "Initial harvest cut ratio should be 0"
        );

        // Set cut ratio to 10%
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestCutRatio(0.1 ether);

        // Verify it was set correctly
        assertEq(
            IStabilityPoolManager(stabilityPoolManager).harvestCutRatio(),
            0.1 ether,
            "Harvest cut ratio should be 0.1 ether"
        );

        // Try to set it over 100% which should fail
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager.InvalidHarvestBountyRatio.selector, 1.1 ether));
        IStabilityPoolManager(stabilityPoolManager).updateHarvestCutRatio(1.1 ether);

        // Try with non-owner which should fail (BaoOwnableRoles onlyOwner reverts Unauthorized).
        vm.prank(address(0xBEEF));
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestCutRatio(0.2 ether);
    }

    function test_updateFeeReceiver_() public {
        // The fee receiver is never zero: setUp points it at the treasury (the initialize seed is the owner).
        assertEq(
            IStabilityPoolManager(stabilityPoolManager).feeReceiver(),
            treasury,
            "fee receiver starts at the setUp value (the treasury), never zero"
        );

        // Set fee receiver
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IStabilityPoolManager.UpdateFeeReceiver(treasury, feeReceiver);
        IStabilityPoolManager(stabilityPoolManager).updateFeeReceiver(feeReceiver);

        // Verify it was set correctly
        assertEq(
            IStabilityPoolManager(stabilityPoolManager).feeReceiver(),
            feeReceiver,
            "Fee receiver should be updated"
        );

        // Update to a new address and verify event is emitted with correct old address
        address newFeeReceiver = makeAddr("newFeeReceiver");
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IStabilityPoolManager.UpdateFeeReceiver(feeReceiver, newFeeReceiver);
        IStabilityPoolManager(stabilityPoolManager).updateFeeReceiver(newFeeReceiver);

        // Try with non-owner which should fail (BaoOwnableRoles onlyOwner reverts Unauthorized).
        vm.prank(address(0xBEEF));
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IStabilityPoolManager(stabilityPoolManager).updateFeeReceiver(address(0xDEAD));
    }

    function test_harvestWithCutAndFeeReceiver_(uint256 bounty, uint256 cut) public {
        // keep bounty + cut <= 99% so the residual to the pools stays well above the per-period dust floor and each pool
        // takes a real streamed share. The 100%-cut / no-residual corner (where the pools correctly receive nothing) is
        // covered by the envelope no-dust tests, not re-derived here.
        bounty = bound(bounty, 0, 0.99 ether);
        cut = bound(cut, 0, 0.99 ether - bounty);
        // Set cut first (bounty=0 so any cut ≤ 100% is valid), then bounty.
        // Fuzz bounds guarantee bounty + cut ≤ 100%, so the second update is always valid.
        vm.startPrank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateFeeReceiver(feeReceiver);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestCutRatio(cut);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestBountyRatio(bounty);
        vm.stopPrank();

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(
            startPrice,
            (startRate * 10) / 9 // Set a rate to ensure collateral is available
        );
        uint256 harvestableAmount = IMinter(minter).harvestable();
        assertApproxEqAbs(harvestableAmount, 100 ether, 100, "harvestable should be 100 ether");

        // The manager splits the new yield by holdings GROSS (flooring both), then skims: the bounty and cut are ratio
        // slices of the total gross distributed, and each pool gets net = its gross share * residualRatio. The split
        // remainder stays in the minter, not swept, so the emitted/returned amount is that sum, not the full harvestable.
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
        uint256 netCollateral = (grossCollateral * residualRatio) / 1 ether;
        uint256 netLeveraged = (grossLeveraged * residualRatio) / 1 ether;
        uint256 swept = bountyAmount + cutAmount + netCollateral + netLeveraged;

        address harvester = makeAddr("harvester");
        vm.expectEmit();
        emit IStabilityPoolManager.Harvested(swept);
        uint256 harvested = IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);
        assertEq(
            IERC20(peggedToken).balanceOf(stabilityPoolManager),
            0,
            "StabilityPoolManager should not receive tokens yet"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(feeReceiver),
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

        // the harvest returns exactly what it swept (bounty + cut + each pool's streamed net)
        assertEq(harvested, swept, "returns the amount actually harvested");
    }

    function test_harvestWithoutSufficientTokens_() public {
        // Set up fee receiver and harvest cut ratio
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateFeeReceiver(feeReceiver);

        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestCutRatio(0.1 ether); // 10% cut

        // Set up harvester role
        uint256 harvesterRole = IMinter(minter).HARVESTER_ROLE();
        address harvester = makeAddr("harvester");
        vm.prank(owner);
        IBaoRoles(minter).grantRoles(harvester, harvesterRole);

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
        vm.prank(harvester);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        IStabilityPoolManager(stabilityPoolManager).harvest(harvester, 0);
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
        vm.prank(address(0xBEEF));
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        UUPSUpgradeable(stabilityPoolManager).upgradeToAndCall(address(0), "");

        // Create the V2 implementation (already done in setUp)

        // Perform the upgrade as the owner
        vm.prank(owner);
        UUPSUpgradeable(stabilityPoolManager).upgradeToAndCall(address(newImplementation), "");

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
        vm.prank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestBountyRatio(0.1 ether);
        assertEq(
            IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio(),
            0.1 ether,
            "Storage should be preserved across upgrades"
        );
    }
}

contract Gist_1 is TestStabilityPoolManagerSetUp {
    // GIST-1 audit issue (modified only to have it compile here and generate the same error/log output)
    function test_rebalanceDepeg() public {
        uint256 threshold = 1.3 ether;
        uint256 bountyRatio = 0.2 ether;

        vm.startPrank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(threshold);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceBountyRatio(bountyRatio);
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
        assertEq(IERC20(leveragedToken).balanceOf(stabilityPoolCollateral), 0, "pool1 has no leveraged");

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1555 ether); // makes the collateral ratio = 0.93
        (price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // console.log("price: %s", price);
        // console.log("CR: %s", IMinter(minter).collateralRatio());
        // console.log("Pegged balance before rebalance: %s", IMinter(minter).peggedTokenBalance());

        IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);

        // console.log("Pegged balance AFTER: %s", IMinter(minter).peggedTokenBalance());
        // console.log("CR AFTER: %s", IMinter(minter).collateralRatio());

        // we hit the rebalance collateral ratio exactly
        assertEq(IMinter(minter).collateralRatio(), threshold, "collateral ratio is reset after rebalance");
    }

    function test_rebalanceDepeg_exagerated() public {
        uint256 threshold = 1.3 ether;
        uint256 bountyRatio = 0.2 ether;

        vm.startPrank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(threshold);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceBountyRatio(bountyRatio);
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
        assertEq(IERC20(leveragedToken).balanceOf(stabilityPoolCollateral), 0, "pool1 has no leveraged");

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1000 ether); // makes the collateral ratio = 120 / 100 / 2 = 60%
        (price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // console.log("price: %s", price);
        // console.log("CR: %s", IMinter(minter).collateralRatio());
        // console.log("Pegged balance before rebalance: %s", IMinter(minter).peggedTokenBalance());

        IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);

        // console.log("Pegged balance AFTER: %s", IMinter(minter).peggedTokenBalance());
        // console.log("CR AFTER: %s", IMinter(minter).collateralRatio());

        // we hit the rebalance collateral ratio exactly
        assertEq(IMinter(minter).collateralRatio(), threshold, "collateral ratio is reset after rebalance");
    }
}

contract Gist_2 is TestStabilityPoolManagerSetUp {
    function test_insufficientStabilityPoolBalance() public {
        uint256 threshold = 1.4 ether; // Ensure threshold is between 100% and 200%
        uint256 bountyRatio = 0.2 ether; // Ensure bounty ratio is between 0% and 100%

        vm.startPrank(owner);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(threshold);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceBountyRatio(bountyRatio);
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

        IStabilityPool(stabilityPoolCollateral).deposit(userPegged / 4, user, 0);
        IStabilityPool(stabilityPoolLeveraged).deposit(userPegged - (userPegged / 2), user, 0);
        vm.stopPrank();

        // console.log(
        //     "stabilityPoolCollateral pegged balance: %e",
        //     IERC20(peggedToken).balanceOf(stabilityPoolCollateral)
        // );
        // console.log("stabilityPoolLeveraged pegged balance: %e", IERC20(peggedToken).balanceOf(stabilityPoolLeveraged));
        // console.log();

        // Execute rebalance as liquidator
        assertEq(IERC20(leveragedToken).balanceOf(stabilityPoolCollateral), 0, "pool1 has no leveraged");

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1800 ether);
        IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);
        // Adding one more rebalance call would drive the CR to the expected.
        //                                          ---------
        // we hit the rebalance collateral ratio exactly
        assertEq(IMinter(minter).collateralRatio(), threshold, "collateral ratio is reset after rebalance");
    }
}
