// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {Stem_v1} from "@bao/Stem_v1.sol";

import {Steam_v1} from "src/reward/steam/Steam_v1.sol";
import {IERC20STEAM} from "src/interfaces/IERC20STEAM.sol";

contract Steam_v1Test is Test {
    address steam;
    address steamImpl;
    address stem;
    address owner;

    function setUp() public {
        owner = makeAddr("owner");
        steamImpl = address(new Steam_v1(1, 2));
        stem = address(new Stem_v1(owner, 0)); // stem is immediately owned by owner
        steam = UnsafeUpgrades.deployUUPSProxy(stem, "");
    }

    function test_upgradeStemmedToSteam() public {
        // Upgrade stem to steam, calling initializer
        /////////////////////////////////////////////
        vm.startPrank(owner);
        UnsafeUpgrades.upgradeProxy(
            steam,
            steamImpl,
            abi.encodeWithSelector(Steam_v1.initialize.selector, owner, 100, "Steam", "STEAM")
        );
        vm.stopPrank();

        // Check the upgrade worked
        assertEq(IBaoOwnable(steam).owner(), owner);
        assertEq(IERC20STEAM(steam).name(), "Steam");
        assertEq(IERC20STEAM(steam).symbol(), "STEAM");
        assertEq(IERC20STEAM(steam).decimals(), 18);
        assertEq(IERC20STEAM(steam).totalSupply(), 100);
        assertEq(IERC20STEAM(steam).INITIAL_RATE(), 1);
        assertEq(IERC20STEAM(steam).RATE_REDUCTION_COEFFICIENT(), 2);

        // now replace with Stem again
        //////////////////////////////
        vm.startPrank(owner);
        // Upgrade stem to steam, calling initializer
        UnsafeUpgrades.upgradeProxy(steam, stem, "");
        vm.stopPrank();

        // Check the stemming worked
        assertEq(IBaoOwnable(steam).owner(), owner);
        vm.expectRevert(
            abi.encodeWithSelector(Stem_v1.Stemmed.selector, "Contract is stemmed and all functions are disabled")
        );
        IERC20STEAM(steam).name();
        vm.expectRevert(
            abi.encodeWithSelector(Stem_v1.Stemmed.selector, "Contract is stemmed and all functions are disabled")
        );
        IERC20STEAM(steam).INITIAL_RATE();
    }
}
