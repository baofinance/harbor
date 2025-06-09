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

contract TestMinterHarvestSetUp is TestMinterSetUp {
    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public virtual override {
        super.setUp();
    }
}

contract TestMinterHarvest is TestMinterHarvestSetUp {
    address harvester;
    address harvestReceiver;

    function setUp() public virtual override(TestMinterHarvestSetUp) {
        super.setUp();
        harvestReceiver = vm.createWallet("harvestReceiver").addr;
        harvester = vm.createWallet("harvester").addr;
        uint256 harvesterRole = IMinter(minter).HARVESTER_ROLE();
        vm.prank(owner);
        IBaoRoles(minter).grantRoles(harvester, harvesterRole);
        deal(address(Deployed.wstETH), harvester, 100 ether);
        vm.prank(harvester);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);
    }

    function test_harvestInit() public {
        assertEq(IMinter(minter).harvestable(), 0, "hasvestable is zero at the start");
        setUp_collateral(50 ether, 50 ether); // 100 collateral

        address collateralToken = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            IERC20(collateralToken).balanceOf(minter),
            "collaterals match"
        );
        assertEq(IMinter(minter).harvestable(), 0, "hasvestable is zero with new collateral");
    }

    function test_harvestPriceChange(uint256 startPrice, uint256 startRate) public {
        startPrice = bound(startPrice, 0, 10000 ether);
        startRate = bound(startRate, 0, 5 ether);

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(startPrice, startRate);
        setUp_collateral(50 ether, 50 ether); // 100 collateral
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        // price changes
        for (uint256 p = 0; p < price * 2; p += 100 ether) {
            MockWrappedPriceOracle(priceOracle).setLatestAnswer(p, rate);

            assertEq(
                IMinter(minter).harvestable(),
                0,
                string.concat(
                    "harvestable is the same as with price=",
                    Strings.toString(p),
                    ", rate=",
                    Strings.toString(rate)
                )
            );
        }
    }

    function test_harvestRateChange(uint256 startPrice, uint256 startRate) public {
        startPrice = bound(startPrice, 0, 10000 ether);
        startRate = bound(startRate, 0, 5 ether); // 1.102235739966061915
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(startPrice, startRate);
        {
            (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
            assertEq(price, startPrice, "price is set correctly");
            assertEq(rate, startRate, "rate is set correctly");
        }

        setUp_collateral(50 ether, 50 ether); // 100 collateral
        uint256 collateral = IMinter(minter).collateralTokenBalance();
        uint256 wrappedCollateral = IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(minter);
        assertEq(
            collateral,
            (wrappedCollateral * startRate) / 1e18,
            "collateral and wrapped collateral match after setUp_collateral"
        );

        // Then rate change
        for (uint256 r = 0; r < startRate * 2; r += 1e16) {
            MockWrappedPriceOracle(priceOracle).setLatestAnswer(startPrice, r);
            uint256 expectedHarvestable = 0;
            if (r > startRate) {
                uint256 heldValue = wrappedCollateral;
                uint256 accountingValue = (collateral * 1e18) / r;
                expectedHarvestable = heldValue - accountingValue;
            }
            assertEq(
                IMinter(minter).harvestable(), // 0.699482885940368019
                expectedHarvestable, // 0
                string.concat(
                    "harvestable is correct with price=", // 1845.157210154513240346
                    Strings.toString(startPrice),
                    ", rate=", // 1.110000000000000000
                    Strings.toString(r)
                )
            );
        }
    }

    function test_harvestVariableRateChange(uint256 startPrice, uint256 startRate) public {
        startPrice = bound(startPrice, 0, 10000 ether);
        startRate = bound(startRate, 0, 5 ether); // 1.102235739966061915

        setUp_collateral(50 ether, 50 ether); // 100 collateral
        uint256 collateral = IMinter(minter).collateralTokenBalance();
        address wrappedCollateralToken = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();

        uint256 lastRate = startRate;
        for (uint256 r = 0; r < startRate * 2; r += 1e16) {
            MockWrappedPriceOracle(priceOracle).setLatestAnswer(startPrice, r);
            uint256 wrappedCollateral = IERC20(wrappedCollateralToken).balanceOf(minter);

            uint256 expectedHarvestable = 0;
            if (r > 0) {
                uint256 accountingValue = (collateral * 1e18) / r;
                if (wrappedCollateral > accountingValue) {
                    expectedHarvestable = wrappedCollateral - accountingValue;
                }
            }
            assertEq(
                IMinter(minter).harvestable(),
                expectedHarvestable,
                string.concat(
                    "harvestable is correct with price=",
                    Strings.toString(startPrice),
                    ", rate=",
                    Strings.toString(r)
                )
            );

            if (expectedHarvestable > 0) {
                // Harvest
                uint256 beforeHarvestReceiver = IERC20(wrappedCollateralToken).balanceOf(harvestReceiver);
                uint256 beforeMinter = IERC20(wrappedCollateralToken).balanceOf(minter);
                vm.prank(harvester);
                ITokenHolder(minter).sweep(wrappedCollateralToken, expectedHarvestable, harvestReceiver);
                assertEq(
                    IERC20(wrappedCollateralToken).balanceOf(harvestReceiver),
                    beforeHarvestReceiver + expectedHarvestable,
                    "harvested amount matches"
                );
                assertEq(
                    IERC20(wrappedCollateralToken).balanceOf(minter),
                    beforeMinter - expectedHarvestable,
                    "minter balance matches"
                );
            }
            lastRate = r;
        }
    }
}
