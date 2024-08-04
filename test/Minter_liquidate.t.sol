// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

//import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMinter } from "src/minter/IMinter.sol";
import { deployed } from "test/deployed.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";

import "test/Useful.sol";
import { TestMinterFeeSetup } from "test/Minter_fees.t.sol";

contract TestMinterLiquidate is TestMinterFeeSetup {
    using SafeERC20 for IERC20;
    uint256 price;

    function setUp() public override(TestMinterFeeSetup) {
        super.setUp();
        (, price, , ) = priceOracle.getPrice();
        vm.prank(owner.addr);
        IERC20(peggedToken).approve(minter, type(uint256).max);
    }

    // no leveraged tokens
    function test_liquidateRedeem0() public {
        setUp_collateral(10 ether, 0 ether); // cr=10/10 = 100%
        assertEq(IERC20(peggedToken).balanceOf(owner.addr), price * 10, "owner should have pegged");
        assertEq(IMinter(minter).collateralRatio(), 1 ether);

        uint256 peggedTokens = IMinter(minter).redeemPeggedForCollateralRatio(11 ether / 10);
        assertEq(peggedTokens, IMinter(minter).peggedTokenBalance(), "should be all tokens");
        vm.prank(owner.addr);
        IMinter(minter).freeRedeemPeggedToken(peggedTokens, owner.addr);
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "should have liquidated all");
    }

    function _liquidateRedeemToCR(uint256 targetCR) private {
        uint256 startCR = IMinter(minter).collateralRatio();
        uint256 peggedTokens = IMinter(minter).redeemPeggedForCollateralRatio(targetCR);
        if (peggedTokens > 0) {
            vm.prank(owner.addr);
            IMinter(minter).freeRedeemPeggedToken(peggedTokens, owner.addr);
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
}
