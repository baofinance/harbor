// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

//import { Test } from "forge-std/Test.sol";

import "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import "@harbor-test/Useful.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

contract MinterSlashTest is TestMinterSetUp {
    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function test_slash_() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        setUp_collateral(100 ether, 40 ether); // CR = 140%

        assertEq(IMinter(minter).collateralRatio(), 1.4 ether, "start CR");
        assertEq(IMinter(minter).leverageRatio(), 3.5 ether, "start leverage ratio");
        assertEq(IMinter(minter).harvestable(), 0, "start harvestable");

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 101) / 100); // 1% increase

        assertEq(IMinter(minter).collateralRatio(), 1.4 ether, "after rate bump CR");
        assertEq(IMinter(minter).leverageRatio(), 3.5 ether, "after rate bump leverage ratio");
        assertEq(IMinter(minter).harvestable(), 1386138613861386139, "after rate bump harvestable");

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 9) / 10); // 10% reduction, and below 1

        assertEq(IMinter(minter).collateralRatio(), 1.4 ether, "after rate drop change CR");
        assertEq(IMinter(minter).leverageRatio(), 3.5 ether, "after rate drop leverage ratio");
        assertEq(IMinter(minter).harvestable(), 0, "after rate drop harvestable");

        vm.prank(owner);
        IMinter(minter).reset();

        assertEq(IMinter(minter).collateralRatio(), 1.26 ether, "after reset CR"); // 10% down
        assertEq(IMinter(minter).leverageRatio(), 4846153846153846153, "after reset leverage ratio"); // leverage goes up
        assertEq(IMinter(minter).harvestable(), 0, "after reset harvestable");
    }

    function test_authority() public {
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IMinter(minter).reset();

        vm.prank(owner);
        IMinter(minter).reset();
    }
}
