// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

//import { Test } from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Deployed} from "@bao/Deployed.sol";
import {ITokenHolder} from "@bao/interfaces/ITokenHolder.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";

import "test/Useful.sol";
import {TestMinterSetUp} from "test/Minter_base.t.sol";

contract MinterSlashTest is TestMinterSetUp {
    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function test_slash_() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        setUp_collateral(100 ether, 40 ether); // CR = 140%

        assertEq(IMinter(minter).collateralRatio(), 1.4 ether, "start CR");
        assertEq(IMinter(minter).leverageRatio(), 3499999999999999991, "start leverage ratio");
        assertEq(IMinter(minter).harvestable(), 0, "start harvestable");

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 101) / 100); // 1% increase

        assertEq(IMinter(minter).collateralRatio(), 1.4 ether, "after rate bump CR");
        assertEq(IMinter(minter).leverageRatio(), 3499999999999999991, "after rate bump leverage ratio");
        assertEq(IMinter(minter).harvestable(), 1386138613861386139, "after rate bump harvestable");

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 9) / 10); // 10% reduction, and below 1

        assertEq(IMinter(minter).collateralRatio(), 1.4 ether, "after rate drop change CR");
        assertEq(IMinter(minter).leverageRatio(), 3499999999999999991, "after rate drop leverage ratio");
        assertEq(IMinter(minter).harvestable(), 0, "after rate drop harvestable");

        vm.prank(owner);
        IMinter(minter).reset();

        assertEq(IMinter(minter).collateralRatio(), 1.26 ether, "after reset CR"); // 10% down
        assertEq(IMinter(minter).leverageRatio(), 4846153846153846135, "after reset leverage ratio"); // leverage goes up
        assertEq(IMinter(minter).harvestable(), 0, "after reset harvestable");
    }

    function test_authority() public {
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IMinter(minter).reset();

        vm.prank(owner);
        IMinter(minter).reset();
    }
}
