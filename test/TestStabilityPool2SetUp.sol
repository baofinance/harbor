// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TestStabilityPoolRebalanceSetUp} from "test/StabilityPoolRebalance.t.sol";

contract TestStabilityPool2SetUp is TestStabilityPoolRebalanceSetUp {
    address stabilityPoolLeveraged;

    function setUp() public virtual override {
        super.setUp();

        stabilityPoolLeveraged = _setupStabilityPool(leveragedToken);
        vm.prank(user1);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);

        vm.prank(user2);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
    }
}
