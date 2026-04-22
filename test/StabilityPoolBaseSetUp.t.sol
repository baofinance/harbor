// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {TestStabilityPool2SetUp} from "@harbor-test/TestStabilityPool2SetUp.sol";

/// @title TestStabilityPoolLossSetUp
/// @notice Base setup for all stability pool loss tests
contract TestStabilityPoolBaseSetUp is TestStabilityPool2SetUp {
    // Mock tokens for reward testing
    address[] rewardTokens;

    // Test both stability pools
    address[] stabilityPools;

    // Constants
    uint256 constant INITIAL_DEPOSIT = 100 ether;
    uint256 constant INITIAL_REWARD_AMOUNT = 1000 ether;

    function setUp() public virtual override {
        super.setUp();

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

        for (uint i = 0; i < rewardTokens.length; i++) {
            MockERC20(rewardTokens[i]).mint(rewardDepositor, INITIAL_REWARD_AMOUNT * 10);
            for (uint s = 0; s < stabilityPools.length; s++) {
                vm.prank(rewardManager);
                IMultipleRewardDistributor(stabilityPools[s]).registerRewardToken(rewardTokens[i]);
                vm.prank(rewardDepositor);
                IERC20(rewardTokens[i]).approve(stabilityPools[s], type(uint256).max);
            }
        }
    }
}
