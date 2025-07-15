// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";

import {MockERC20} from "test/mock/MockERC20.sol";
import {TestStabilityPool2SetUp} from "test/TestStabilityPool2SetUp.sol";

/// @title TestStabilityPoolLossSetUp
/// @notice Base setup for all stability pool loss tests
contract TestStabilityPoolBaseSetUp is TestStabilityPool2SetUp {
    // Additional users for loss tests
    address user3;
    address user4;
    address rebalancer;
    address rewarder;

    // Mock tokens for reward testing
    address[] rewardTokens;

    // Test both stability pools
    address[] stabilityPools;

    // Constants
    uint256 constant INITIAL_DEPOSIT = 100 ether;
    uint256 constant INITIAL_REWARD_AMOUNT = 1000 ether;
    uint256 REBALANCER_ROLE;
    uint256 REWARDER_ROLE;

    function setUp() public virtual override {
        super.setUp();

        // Set up additional users
        user3 = makeAddr("user3");
        user4 = makeAddr("user4");
        rebalancer = makeAddr("rebalancer");
        rewarder = makeAddr("rewarder");

        // Set up reward tokens
        rewardTokens = new address[](2);
        rewardTokens[0] = address(new MockERC20("Reward Token 1", "RWD1", 18));
        vm.label(rewardTokens[0], MockERC20(rewardTokens[0]).symbol());
        rewardTokens[1] = address(new MockERC20("Reward Token 2", "RWD2", 18));
        vm.label(rewardTokens[1], MockERC20(rewardTokens[1]).symbol());

        stabilityPools = new address[](2);
        stabilityPools[0] = stabilityPoolCollateral;
        stabilityPools[1] = stabilityPoolLeveraged;

        // Mint test tokens to users
        deal(peggedToken, user3, 3000 ether);
        deal(peggedToken, user4, 4000 ether);

        // Approve tokens for additional users
        vm.startPrank(user3);
        IERC20(peggedToken).approve(address(stabilityPoolCollateral), type(uint256).max);
        IERC20(peggedToken).approve(address(stabilityPoolLeveraged), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user4);
        IERC20(peggedToken).approve(address(stabilityPoolCollateral), type(uint256).max);
        IERC20(peggedToken).approve(address(stabilityPoolLeveraged), type(uint256).max);
        vm.stopPrank();

        // Set up reward tokens

        // Grant rebalancer role for both stability pools
        REBALANCER_ROLE = IStabilityPool(stabilityPoolCollateral).REBALANCER_ROLE();
        REWARDER_ROLE = IStabilityPool(stabilityPoolCollateral).REWARDER_ROLE();
        vm.startPrank(owner);
        for (uint i = 0; i < rewardTokens.length; i++) {
            MockERC20(rewardTokens[i]).mint(address(this), INITIAL_REWARD_AMOUNT * 10);
            IBaoRoles(address(stabilityPools[i])).grantRoles(rebalancer, REBALANCER_ROLE);
            IBaoRoles(address(stabilityPools[i])).grantRoles(rewarder, REWARDER_ROLE);
            IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(
                address(rewardTokens[i]),
                stabilityPools[i]
            );
        }
        vm.stopPrank();
    }
}
