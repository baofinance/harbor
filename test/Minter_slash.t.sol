// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

//import { Test } from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {Deployed} from "@bao/Deployed.sol";
import {ITokenHolder} from "@bao/interfaces/ITokenHolder.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
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
        uint256 beforeCR = IMinter(minter).collateralRatio();
        uint256 beforeLeverage = IMinter(minter).leverageRatio();
        uint256 beforeHarvestable = IMinter(minter).harvestable();

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 10) / 9); // 10% reduction, and below 1

        uint256 afterCR = IMinter(minter).collateralRatio();
        uint256 afterLeverage = IMinter(minter).leverageRatio();
        uint256 afterHarvestable = IMinter(minter).harvestable();

        assertEq(afterCR, beforeCR);
        assertEq(afterLeverage, beforeLeverage);
        assertEq(afterHarvestable, beforeHarvestable);
    }
}
