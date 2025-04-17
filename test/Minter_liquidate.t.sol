// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//import { Test } from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMinter} from "@interfaces/IMinter.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IPriceOracle} from "@interfaces/IPriceOracle.sol";
import {MockPriceOracle} from "test/MockPriceOracle.sol";

import "test/Useful.sol";
import {TestMinterFeeSetUp} from "test/Minter_fees.t.sol";

contract TestMinterLiquidate is TestMinterFeeSetUp {
    using SafeERC20 for IERC20;
    uint256 price;

    function setUp() public override(TestMinterFeeSetUp) {
        super.setUp();
        price = MockPriceOracle(priceOracle).latestAnswer();
        vm.prank(owner);
        IERC20(peggedToken).approve(minter, type(uint256).max);
    }

    // no leveraged tokens
    function test_liquidateRedeem0() public {
        setUp_collateral(10 ether, 0 ether); // cr=10/10 = 100%
        assertEq(IERC20(peggedToken).balanceOf(owner), price * 10, "owner should have pegged");
        assertEq(IMinter(minter).collateralRatio(), 1 ether);

        uint256 peggedTokens = IMinter(minter).redeemPeggedForCollateralRatio(11 ether / 10);
        assertEq(peggedTokens, IMinter(minter).peggedTokenBalance(), "should be all tokens");
        vm.prank(owner);
        IMinter(minter).freeRedeemPeggedToken(peggedTokens, owner);
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "should have liquidated all");
    }

    function _liquidateRedeemToCR(uint256 targetCR) private {
        uint256 startCR = IMinter(minter).collateralRatio();
        uint256 peggedTokens = IMinter(minter).redeemPeggedForCollateralRatio(targetCR);
        if (peggedTokens > 0) {
            vm.prank(owner);
            IMinter(minter).freeRedeemPeggedToken(peggedTokens, owner);
            if (targetCR < startCR) {
                assertEq(IMinter(minter).collateralRatio(), startCR, "should not have changed CR");
            } else {
                assertEq(IMinter(minter).collateralRatio(), targetCR, "should have reached target collateral ratio");
            }
        }
    }

    function test_liquidateRedeemSame100() public {
        setUp_collateral(10 ether, 0 ether); // cr=10/10 = 100%
        assertEq(IMinter(minter).collateralRatio(), 1 ether); // CR= 110%
        _liquidateRedeemToCR(1 ether); // 100%
    }

    function test_liquidateRedeemSame110() public {
        setUp_collateral(10 ether, 1 ether); // cr=11/10 = 110%
        _liquidateRedeemToCR(11 ether / 10); // 110%
    }

    function test_liquidateRedeem1() public {
        setUp_collateral(10 ether, 1 ether); // cr=11/10 = 110%
        _liquidateRedeemToCR(12 ether / 10); // 120%
    }

    function _liquidateSwapToCR(uint256 targetCR) private {
        // uint256 startCR = IMinter(minter).collateralRatio();
        uint256 pegged = IMinter(minter).swapPeggedForLeveragedForCollateralRatio(targetCR);
        if (pegged > 0) {
            uint256 startPegged = IERC20(peggedToken).balanceOf(owner);
            vm.prank(owner);
            uint256 actualPegged = IMinter(minter).freeSwapPeggedForLeveraged(pegged, owner);
            assertEq(actualPegged, pegged, "swapped requested");
            assertEq(startPegged - IERC20(peggedToken).balanceOf(owner), pegged, "gave up correct pegged");

            // if (targetCR < startCR) {
            // assertEq(IMinter(minter).collateralRatio(), startCR, "should not have changed CR");
            // } else {
            assertEq(IMinter(minter).collateralRatio(), targetCR, "should have reached target collateral ratio");
            // }
        }
    }

    function test_liquidateSwap0() public {
        setUp_collateral(10 ether, 0 ether); // cr=10/10 = 100%
        _liquidateSwapToCR(12 ether / 10); // 120%
    }

    function test_liquidateSwapSame100() public {
        setUp_collateral(10 ether, 0 ether); // cr=10/10 = 100%
        assertEq(IMinter(minter).collateralRatio(), 1 ether); // CR= 100%
        _liquidateSwapToCR(1 ether); // 100%
    }

    function test_liquidateSwapSame110() public {
        setUp_collateral(10 ether, 1 ether); // cr=11/10 = 110%
        _liquidateSwapToCR(11 ether / 10); // 110%
    }

    function test_liquidateSwap1() public {
        setUp_collateral(10 ether, 1 ether); // cr=11/10 = 110%
        _liquidateSwapToCR(12 ether / 10); // 120%
    }
}
