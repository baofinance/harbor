// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Token} from "@bao/Token.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import "@harbor-test/Useful.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// How the protocol responds to the collateral it holds losing value, and how collateral given to it
/// as backing restores that.
contract MinterSlashTest is TestMinterSetUp {
    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    /// A rate rise is yield: it becomes harvestable, and moves neither the backing nor any price.
    /// A rate fall past that surplus is a loss: it is recognised immediately, without anyone acting.
    function test_slash_isRecognisedWithoutIntervention() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        setUp_collateral(100 ether, 40 ether); // CR = 140%

        assertEq(IMinter(minter).collateralRatio(), 1.4 ether, "start CR");
        assertEq(IMinter(minter).leverageRatio(), 3.5 ether, "start leverage ratio");
        assertEq(IMinter(minter).harvestable(), 0, "start harvestable");

        // 1% of yield: the surplus grows, the backing does not
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 101) / 100);

        assertEq(IMinter(minter).collateralRatio(), 1.4 ether, "yield does not move the ratio");
        assertEq(IMinter(minter).leverageRatio(), 3.5 ether, "yield does not move leverage");
        assertEq(IMinter(minter).harvestable(), 1386138613861386139, "yield is harvestable");

        // a 10% fall, far past the 1% surplus: a real loss
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 9) / 10);

        assertEq(IMinter(minter).collateralRatio(), 1.26 ether, "the loss is recognised at once");
        assertEq(IMinter(minter).leverageRatio(), 4846153846153846153, "leverage rises as cover falls");
        assertEq(IMinter(minter).harvestable(), 0, "a shortfall is not a surplus");
    }

    /// Collateral given as backing raises the ratio, and is credited at exactly what it is worth.
    function test_donateWrappedCollateral_restoresTheRatio() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(100 ether, 40 ether);

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 9) / 10);
        assertEq(IMinter(minter).collateralRatio(), 1.26 ether, "loss recognised");

        // the shortfall is 14 collateral tokens; at the reduced rate that is 14/0.9 wrapped
        uint256 makeGood = (14 ether * 1 ether) / ((rate * 9) / 10);

        address donor = makeAddr("donor");
        deal(wrappedCollateralToken, donor, makeGood);
        vm.startPrank(donor);
        IERC20(wrappedCollateralToken).approve(minter, makeGood);
        IMinter_v3(minter).donateWrappedCollateral(makeGood);
        vm.stopPrank();

        assertApproxEqAbs(IMinter(minter).collateralRatio(), 1.4 ether, 1e12, "the ratio is made whole");
        // The donation is converted to collateral once when credited and the whole holding is
        // converted once when harvestable is measured, so the two floors can differ by a single wei.
        // The direction is fixed: crediting rounds down, so any residue is yield, never phantom
        // backing. One wei is the exact bound - two would mean a second rounding step had crept in.
        assertLe(IMinter(minter).harvestable(), 1, "a donation is backing, not yield");
    }

    /// Wrapped collateral simply transferred in is yield for the stability pools, and moves neither
    /// the backing nor any price. The two routes are distinct and must stay so.
    function test_plainTransfer_becomesYieldNotBacking() public {
        setUp_collateral(100 ether, 40 ether);
        uint256 ratioBefore = IMinter(minter).collateralRatio();
        uint256 sailPriceBefore = IMinter(minter).leveragedTokenPrice();

        deal(wrappedCollateralToken, address(this), 10 ether);
        IERC20(wrappedCollateralToken).transfer(minter, 10 ether);

        assertEq(IMinter(minter).collateralRatio(), ratioBefore, "a transfer is not backing");
        assertEq(IMinter(minter).leveragedTokenPrice(), sailPriceBefore, "and moves no price");
        assertEq(IMinter(minter).harvestable(), 10 ether, "it is yield for the pools");
    }

    /// A donation may only ever add what it supplies. The surplus already held belongs to the
    /// stability pools, and no caller may absorb it into backing.
    function test_donateWrappedCollateral_cannotAbsorbTheExistingSurplus() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(100 ether, 40 ether);

        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 105) / 100);
        uint256 surplus = IMinter(minter).harvestable();
        assertGt(surplus, 0, "a surplus must exist for this to test anything");

        address donor = makeAddr("donor");
        deal(wrappedCollateralToken, donor, 1 ether);
        vm.startPrank(donor);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        IMinter_v3(minter).donateWrappedCollateral(1 ether);
        vm.stopPrank();

        assertApproxEqAbs(
            IMinter(minter).harvestable(),
            surplus,
            1,
            "the pools' surplus survives a donation untouched"
        );
    }

    function test_donateWrappedCollateral_isPermissionless() public {
        setUp_collateral(100 ether, 40 ether);

        address anyone = makeAddr("anyone");
        deal(wrappedCollateralToken, anyone, 1 ether);
        vm.startPrank(anyone);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        IMinter_v3(minter).donateWrappedCollateral(1 ether);
        vm.stopPrank();
    }

    function test_donateWrappedCollateral_refusesZero() public {
        setUp_collateral(100 ether, 40 ether);

        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, wrappedCollateralToken));
        IMinter_v3(minter).donateWrappedCollateral(0);
    }
}
