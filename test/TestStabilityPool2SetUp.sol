// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {StabilityPool_v1} from "src/minter/StabilityPool_v1.sol";

import {TestStabilityPoolSetUp} from "test/StabilityPool.t.sol";

contract TestStabilityPool2SetUp is TestStabilityPoolSetUp {
    address stabilityPoolLeveraged;

    function setUp() public virtual override(TestStabilityPoolSetUp) {
        super.setUp();

        (stabilityPoolLeveraged, , ) = _setupStabilityPool(leveragedToken);

        vm.prank(user1);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        vm.prank(user2);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);

        vm.prank(owner);
        IBaoRoles(minter).grantRoles(stabilityPoolCollateral, zeroFeeRole);
        vm.prank(stabilityPoolCollateral);
        IERC20(peggedToken).approve(minter, type(uint256).max);

        vm.prank(owner);
        IBaoRoles(minter).grantRoles(stabilityPoolLeveraged, zeroFeeRole);
        vm.prank(stabilityPoolLeveraged);
        IERC20(peggedToken).approve(minter, type(uint256).max);
    }
}
