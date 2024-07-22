// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

//import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

import { IMinter, IMinterTreasury } from "src/minter/IMinter.sol";
import { deployed } from "test/deployed.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";

import "test/Useful.sol";
import { TestMinter } from "test/Minter_base.t.sol";

// TODO: need to test discounts

contract TestMinterFees is TestMinter {
    Vm.Wallet user;

    function setUpConfig() public override {
        setUpConfig(
            130,
            250,
            ic(ua(130, 140), ia(disallow, 100, 50)), // mint pegged
            ic(ua(110, 120, 145), ia(-50, 0, 20, 70)), // mint leveraged
            ic(ua(105, 115, 150), ia(-75, -25, 60, 80)), // redeem pegged
            ic(ua(105, 135), ia(disallow, 150, 120)) // redeem leveraged
        );
    }

    function setUp() public virtual override {
        super.setUp();
        user = vm.createWallet("user");
        setUp_permissions();

        deal(address(deployed.wstETH), user.addr, 100 ether);
        vm.prank(user.addr);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);
    }

    function test_mintPeggedFeeCalcs() public {
        // ic(ua(130, 140), ia(disallow, 100, 50)), // mint pegged
        (, uint256 price, , ) = priceOracle.getPrice();
        setUp_collateral(2 ether, 1 ether); // CR = 3/2 = 1.5
        assertLt(
            ultimate(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            IMinter(minter).collateralRatio(),
            "test must start with CR normal"
        );

        // fees at normal
        uint256 maxCollateral;
        int256 mintPeggedFees;
        (mintPeggedFees, maxCollateral) = IMinter(minter).mintPeggedTokenIncentiveRatio(0);
        assertEq(mintPeggedFees, ultimate(config.mintPeggedIncentiveConfig.incentiveRatios));

        // fees crossing into danger
        uint256 collateral = 1 ether; // CR -> 4/3 = 1.33 i.e. crossing into danger
        (mintPeggedFees, maxCollateral) = IMinter(minter).mintPeggedTokenIncentiveRatio(collateral);
        assertGt(
            mintPeggedFees,
            ultimate(config.mintPeggedIncentiveConfig.incentiveRatios),
            "fee is part normal, part danger, so > normal"
        );
        assertLt(
            mintPeggedFees,
            penultimate(config.mintPeggedIncentiveConfig.incentiveRatios),
            "fee is part normal, part danger, so < danger"
        );
        int256 mintPeggedFeesPlus;
        (mintPeggedFeesPlus, maxCollateral) = IMinter(minter).mintPeggedTokenIncentiveRatio(collateral + 10 ** 16);
        assertGt(mintPeggedFeesPlus, mintPeggedFees, "the more in danger the higher the fee");

        // check that the fees match the reported value, both emit and that transferred
        int256 expectedFees = (mintPeggedFees * int256(collateral)) / 1 ether;
        uint256 feeReceiverCollateralBalanceBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintPeggedToken(
            user.addr,
            user.addr,
            collateral,
            uint256((int256(price) * (int256(collateral) - expectedFees))) / 1 ether
        );
        vm.prank(user.addr);
        IMinter(minter).mintPeggedToken(collateral, user.addr, 0);
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            uint256(int256(feeReceiverCollateralBalanceBefore) + expectedFees)
        );

        // we are now in danger (CR=1.33), so check the fee here
        assertGt(
            ultimate(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            IMinter(minter).collateralRatio(),
            "test must be in CR danger < normal"
        );
        assertLt(
            initial(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds), // disallow
            IMinter(minter).collateralRatio(),
            "test must be in CR danger > disallow"
        );
        (mintPeggedFees, maxCollateral) = IMinter(minter).mintPeggedTokenIncentiveRatio(0);
        assertEq(
            mintPeggedFees,
            penultimate(config.mintPeggedIncentiveConfig.incentiveRatios),
            "expected to be in danger"
        );
        (mintPeggedFees, maxCollateral) = IMinter(minter).mintPeggedTokenIncentiveRatio(3 ether);
        assertApproxEqAbs(
            mintPeggedFees,
            penultimate(config.mintPeggedIncentiveConfig.incentiveRatios),
            5,
            "expected to still be in danger"
        ); // CR -> disallow but fee ratio is still danger
    }

    function _checkMintPeggedIntegral(uint iTotalMint, uint step, uint tolerance) private returns (int256 totalFee) {
        uint256 maxCollateral;
        int256 incentiveRatio;
        (incentiveRatio, maxCollateral) = IMinter(minter).mintPeggedTokenIncentiveRatio(iTotalMint * 1 ether);
        totalFee = (int256(maxCollateral) * incentiveRatio) / 1 ether;
        uint256 start = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);

        for (uint i = 0; i < iTotalMint; i++) {
            uint256 beforeMint = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
            int256 expected;
            (incentiveRatio, maxCollateral) = IMinter(minter).mintPeggedTokenIncentiveRatio(1 ether);
            expected = (int256(maxCollateral) * incentiveRatio) / 1 ether;
            vm.prank(user.addr);
            try IMinter(minter).mintPeggedToken(1 ether, user.addr, 0) returns (uint256) {} catch {}
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeMint,
                uint256(expected),
                2,
                string.concat(Useful.toString(i), "th iteration in step ", Useful.toString(step))
            );
        }
        assertApproxEqAbs(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start,
            uint256(totalFee),
            tolerance,
            Useful.toString(step)
        );
    }

    function test_mintPeggedFeesAreIntegrals() public {
        // ic(ua(130, 140), ia(disallow, 100, 50)), // mint pegged
        // critical CRs = 130% (disallow), 140% (danger)
        // TODO: check the above is the case
        setUp_collateral(18 ether, 10 ether); // CR = 28/18 = 155%
        assertLt(
            penultimate(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            IMinter(minter).collateralRatio(),
            "test must start with CR normal 2"
        );
        assertEq(IERC20(deployed.wstETH).balanceOf(feeReceiver.addr), 0, "no fees so far");

        // check fees:
        uint[5] memory mintStep = [
            // 1) completely in the first band: mint(4), CR = 32/22 = 145%
            uint(4),
            // 2) straddling the first boundary: mint(4), CR = 36/26 = 138%
            uint(4),
            // 3) remaining in the second band: mint(4), CR= 40/30 = 133%
            uint(4),
            // 4) straddling the second boundary: mint(5), CR = 45/35 = 128%
            uint(5),
            // 5) straddling all bands: mint(4), CR = 49/39 = 126%
            uint(4)
        ];

        uint256[] memory maxCollaterals = new uint256[](mintStep.length);
        int256[] memory totalFeeRatios = new int256[](mintStep.length);
        int256[] memory totalFees = new int256[](mintStep.length);
        uint256 collateralInSum = 0;
        for (uint i = 0; i < mintStep.length; i++) {
            uint step = i + 1;
            // clog("step(setup)", step);
            collateralInSum += (mintStep[i] * 1 ether);
            // clog("collateralInSum", collateralInSum);
            (totalFeeRatios[i], maxCollaterals[i]) = IMinter(minter).mintPeggedTokenIncentiveRatio(collateralInSum);
            // clog("totalFeeRatios[i]", totalFeeRatios[i]);
            // clog("maxCollaterals[i]", maxCollaterals[i]);
            // last two steps need special treatment as we're in the disallow band
            if (step == 4) {
                assertGt(maxCollaterals[i], collateralInSum - mintStep[i] * 1 ether, "(step 4) gt than previos value");
                assertLt(maxCollaterals[i], collateralInSum, "(step 4) less than this one");
            } else if (step == 5) {
                assertGt(
                    maxCollaterals[i],
                    collateralInSum - mintStep[i] * 1 ether - mintStep[i - 1] * 1 ether,
                    "(step 5) gt than previos value"
                );
                assertLt(maxCollaterals[i], collateralInSum - mintStep[i - 1] * 1 ether, "(step 5) less than this one");
            } else {
                assertEq(maxCollaterals[i], collateralInSum, "should be no disallowed collateral");
            }
            totalFees[i] = (int256(maxCollaterals[i]) * totalFeeRatios[i]) / 1 ether;
            // clog("totalFees[i]", totalFees[i]);
        }

        int256 totalFee = 0;
        for (uint i = 0; i < mintStep.length; i++) {
            uint step = i + 1;
            // clog("step(run)", step);
            totalFee += _checkMintPeggedIntegral(mintStep[i], step, step * 2);
            assertApproxEqAbs(totalFee, totalFees[i], step * 3, string.concat(Useful.toString(step), ", running sum"));
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
                uint256(totalFee),
                step * 2,
                string.concat("step ", Useful.toString(step))
            );
        }
    }

    function test_mintLeveragedFeeCalcs() public {
        // TODO: start in critical 120, then go to danger 140, then normal
        (, uint256 price, , ) = priceOracle.getPrice();
        setUp_collateral(3 ether, 1 ether); // CR = 4/3 = 1.33
        assertGe(
            ultimate(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            IMinter(minter).collateralRatio(),
            "test must start with CR danger"
        );

        // fees at danger
        int256 mintLeveragedFees = IMinter(minter).mintLeveragedTokenIncentiveRatio(0);
        assertEq(mintLeveragedFees, penultimate(config.mintLeveragedIncentiveConfig.incentiveRatios));

        // fees crossing into normal
        uint256 collateral = 1 ether; // CR -> 5/3 = 1.66 i.e. crossing into normal
        mintLeveragedFees = IMinter(minter).mintLeveragedTokenIncentiveRatio(collateral);
        assertLt(
            mintLeveragedFees,
            ultimate(config.mintLeveragedIncentiveConfig.incentiveRatios),
            "fee is part normal, part danger, so < normal"
        );
        assertGt(
            mintLeveragedFees,
            penultimate(config.mintLeveragedIncentiveConfig.incentiveRatios),
            "fee is part normal, part danger, so > danger"
        );
        assertGt(
            IMinter(minter).mintLeveragedTokenIncentiveRatio(collateral + 10 ** 16),
            mintLeveragedFees,
            "the more in normal the higher the fee"
        );

        // check that the fees match the reported value, both emit and that transferred
        int256 expectedFees = (mintLeveragedFees * int256(collateral)) / 1 ether;
        uint256 feeReceiverCollateralBalanceBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintLeveragedToken(
            user.addr,
            user.addr,
            collateral,
            uint256((int256(price) * (int256(collateral) - expectedFees))) / 1 ether
        );
        vm.prank(user.addr);
        IMinter(minter).mintLeveragedToken(collateral, user.addr, 0);
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            uint256(int256(feeReceiverCollateralBalanceBefore) + expectedFees)
        );

        // we are now in normal (CR=1.66), so check the fee here
        assertLt(
            ultimate(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            IMinter(minter).collateralRatio(),
            "test must be in CR normal now"
        );
        mintLeveragedFees = IMinter(minter).mintLeveragedTokenIncentiveRatio(0);
        assertEq(
            mintLeveragedFees,
            ultimate(config.mintLeveragedIncentiveConfig.incentiveRatios),
            "expected to be in normal"
        );
    }

    // TODO: check the bonus if properly paid - do this with the reserve pool

    function _checkMintLeveragedIntegral(uint iTotalMint, uint step, uint tolerance) private returns (int256 totalFee) {
        // bool log = false;
        // console.log("_checkMintLeveragedIntegral(%s, %s)", iTotalMint, step);
        // console.log("------------------------------------------");
        uint256 collateral = iTotalMint * 1 ether;
        int256 incentiveRatio = IMinter(minter).mintLeveragedTokenIncentiveRatio(collateral);
        // if (log) clog("  incentiveRatio", incentiveRatio);
        totalFee = (int256(collateral) * incentiveRatio) / 1 ether;
        // if (log) clog("  expected fees", totalFee);
        uint256 start = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        // if (log) console.log("  starting fees=%s", start);

        for (uint i = 0; i < iTotalMint; i++) {
            // console.log("    step %s mint %s of %s", step, i + 1, iTotalMint);
            uint256 beforeMint = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
            // if (log) clog("    collateralRatio", IMinter(minter).collateralRatio());
            uint256 expected = uint256(IMinter(minter).mintLeveragedTokenIncentiveRatio(1 ether));
            // if (log) clog("    expected fees this mint", expected);
            vm.prank(user.addr);
            IMinter(minter).mintLeveragedToken(1 ether, user.addr, 0);
            // if (log)
            // clog("    actual   fees this mint", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeMint);
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeMint,
                expected,
                2,
                string.concat(Useful.toString(i), "th iteration in step ", Useful.toString(step))
            );
            // if (log)
            // clog("    extra fees received so far", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start);
        }
        // if (log) clog(" actual fees  ", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start);
        // clog(" all (pre-calc'd) ", totalFee);
        assertApproxEqAbs(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start,
            uint256(SignedMath.max(totalFee, 0)), // ignore bonuses here for now
            // TODO: do another loop like this for bonuses
            tolerance,
            Useful.toString(step)
        );
        // console.log("_checkMintLeveragedIntegral() -> %s", totalFee);
    }

    function test_mintLeveragedFeesAreIntegrals() public {
        // critical CRs (upper bounds) = 110% (bonus, -50), 120% (free, 0), 140% (danger, 20), -> (70)
        // TODO: check the above is the case
        setUp_collateral(150 ether, 10 ether); // CR = 160/150 = 107%, bonus
        assertGt(
            initial(config.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds),
            IMinter(minter).collateralRatio(),
            "test must start with CR bonus"
        );
        assertEq(IERC20(deployed.wstETH).balanceOf(feeReceiver.addr), 0, "no fees so far");

        // check fees:

        uint[7] memory mintStep = [
            // 1) completely in the first band: mint(4), CR = 164/150 = 109%
            uint(4),
            // 2) straddling the first boundary: mint(4), CR = 168/150 = 112%
            uint(4),
            // 3) remaining in the second band: mint(10), CR= 178/150 = 119%
            uint(10),
            // 4) straddling the second boundary: mint(20), CR = 198/150 = 132%
            uint(20),
            // 5) remaining in the third band: mint(10), CR= 208/150 = 139%
            uint(10),
            // 6) straddling the third boundary: mint(5), CR = 215/150 = 143%
            uint(5),
            // 6) straddling all bands: mint(5), CR = 228/150 = 145%
            uint(5)
        ];

        int256[] memory totalFeeRatios = new int256[](mintStep.length);
        int256[] memory totalFees = new int256[](mintStep.length);
        uint256 collateralInSum = 0;
        for (uint i = 0; i < mintStep.length; i++) {
            // uint step = i + 1;
            // clog("step", step);
            collateralInSum += (mintStep[i] * 1 ether);
            // clog("collateralInSum", collateralInSum);
            totalFeeRatios[i] = IMinter(minter).mintLeveragedTokenIncentiveRatio(collateralInSum);
            // clog("totalFeeRatios[i]", totalFeeRatios[i]);
            totalFees[i] = (int256(collateralInSum) * totalFeeRatios[i]) / 1 ether;
            // clog("totalFees[i]", totalFees[i]);
        }
        int256 totalFee = 0;
        // TODO: add tolerances to mint pegged
        for (uint i = 0; i < mintStep.length; i++) {
            uint step = i + 1;
            totalFee += _checkMintLeveragedIntegral(mintStep[i], step, step * 2);
            assertApproxEqAbs(totalFee, totalFees[i], i * 10, string.concat(Useful.toString(step), ", running sum"));
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
                uint256(SignedMath.max(0, totalFee)),
                step * 2,
                string.concat("step ", Useful.toString(step))
            );
        }
    }

    function _redeemPeggedFeeCalc(uint256 collateral) private returns (int256 redeemPeggedFeeRatio) {
        (, uint256 price, , ) = priceOracle.getPrice();
        (redeemPeggedFeeRatio, ) = IMinter(minter).redeemPeggedTokenIncentiveRatio(0);
        assertEq(redeemPeggedFeeRatio, penultimate(config.redeemPeggedIncentiveConfig.incentiveRatios));

        uint256 pegged = (collateral * price) / 1 ether;
        uint256 expectedFees = (uint256(redeemPeggedFeeRatio) * collateral) / 1 ether;
        uint256 feeReceiverCollateralBalanceBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        assertGe(IERC20(deployed.BaoUSD).balanceOf(owner.addr), pegged);
        vm.prank(owner.addr);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        vm.expectEmit(true, true, true, true, minter);
        emit IMinter.RedeemPeggedToken(owner.addr, user.addr, pegged, collateral - expectedFees);
        vm.prank(owner.addr); // the owner has all the tokens
        IMinter(minter).redeemPeggedToken(pegged, user.addr, 0);
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            feeReceiverCollateralBalanceBefore + expectedFees
        );
    }

    function test_redeemPeggedFeeCalcs() public {
        // fee config is ic(ua(105, 115, 150), ia(-75, -25, 60, 80)), // redeem pegged
        // TODO: start in critical 115, then go to danger 150, then normal
        // TODO: add bonus band in. Also in mintLeveraged
        (, uint256 price, , ) = priceOracle.getPrice();
        setUp_collateral(3 ether, 1 ether, owner.addr); // CR = 4/3 = 1.33
        assertLt(
            IMinter(minter).collateralRatio(),
            ultimate(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            "test must start with CR danger"
        );

        // fees at danger
        (int256 redeemPeggedFeeRatio, ) = IMinter(minter).redeemPeggedTokenIncentiveRatio(0);
        assertEq(redeemPeggedFeeRatio, penultimate(config.redeemPeggedIncentiveConfig.incentiveRatios));

        // fees crossing into normal
        uint256 collateral = 2 ether; // CR -> 2/1 = 2 i.e. crossing into normal
        uint256 pegged = (collateral * price) / 1 ether;
        (redeemPeggedFeeRatio, ) = IMinter(minter).redeemPeggedTokenIncentiveRatio(pegged);
        assertLt(
            redeemPeggedFeeRatio,
            ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios),
            "fee is part normal, part danger, so < normal"
        );
        assertGt(
            redeemPeggedFeeRatio,
            penultimate(config.redeemPeggedIncentiveConfig.incentiveRatios),
            "fee is part normal, part danger, so > danger"
        );
        (int256 redeemPeggedFeeRatio2, ) = IMinter(minter).redeemPeggedTokenIncentiveRatio(pegged + 10 ** 16);
        assertGt(redeemPeggedFeeRatio2, redeemPeggedFeeRatio, "the more in normal the higher the fee");

        // check that the fees match the reported value, both emit and that transferred
        uint256 expectedFees = (uint256(redeemPeggedFeeRatio) * collateral) / 1 ether;
        uint256 feeReceiverCollateralBalanceBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        assertGe(IERC20(deployed.BaoUSD).balanceOf(owner.addr), pegged);
        vm.prank(owner.addr);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        vm.expectEmit(minter);
        emit IMinter.RedeemPeggedToken(owner.addr, user.addr, pegged, collateral - expectedFees);
        vm.prank(owner.addr); // the owner has all the tokens
        IMinter(minter).redeemPeggedToken(pegged, user.addr, 0);
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            feeReceiverCollateralBalanceBefore + expectedFees
        );

        // we are now in normal (CR=1.5), so check the fee here
        assertLt(
            ultimate(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            IMinter(minter).collateralRatio(),
            "test must be in CR normal now"
        );
        (redeemPeggedFeeRatio, ) = IMinter(minter).redeemPeggedTokenIncentiveRatio(0);
        assertEq(
            redeemPeggedFeeRatio,
            ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios),
            "expected to be in normal"
        );
    }

    // TODO: check the bonus if properly paid - do this with the reserve pool?

    function _checkRedeemPeggedIntegral(
        uint iTotalRedeem,
        uint step,
        uint tolerance
    ) private returns (int256 totalFee) {
        // bool log = true; // step == 6;
        // console.log("_checkRedeemPeggedIntegral(%s, %s)", iTotalRedeem, step);
        (, uint256 price, , ) = priceOracle.getPrice();
        // console.log("------------------------------------------");
        (int256 incentiveRatio, uint256 collateral) = IMinter(minter).redeemPeggedTokenIncentiveRatio(
            iTotalRedeem * price
        );
        // if (log) clog("  incentiveRatio", incentiveRatio);
        totalFee = (int256(collateral) * incentiveRatio) / 1 ether;
        // if (log) clog("  expected fees", totalFee);
        uint256 start = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        // if (log) console.log("  starting fees=%s", start);
        for (uint i = 0; i < iTotalRedeem; i++) {
            // console.log("    step %s redeem %s of %s", step, i + 1, iTotalRedeem);
            uint256 beforeRedeem = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
            (incentiveRatio, collateral) = IMinter(minter).redeemPeggedTokenIncentiveRatio(price);
            uint256 expected = (uint256(incentiveRatio) * collateral) / 1 ether;
            vm.prank(user.addr);
            IMinter(minter).redeemPeggedToken(price, user.addr, 0);
            // if (log) clog("    fees this redeem", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeRedeem);
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeRedeem,
                expected,
                2,
                string.concat(Useful.toString(i), "th iteration in step ", Useful.toString(step))
            );
            // if (log)
            //     clog("    extra fees received so far", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start);
        }
        // if (log) clog(" actual fees  ", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start);
        // clog(" all (pre-calc'd) ", totalFee);
        assertApproxEqAbs(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start,
            uint256(SignedMath.max(totalFee, 0)), // ignore bonuses here for now
            // TODO: do another loop like this for bonuses
            tolerance,
            Useful.toString(step)
        );
        // console.log("_checkRedeemPeggedIntegral() -> %s", totalFee);
    }

    function test_redeemPeggedFeesAreIntegrals() public {
        // ic(ua(105, 115, 150), ia(-75, -25, 60, 80)), // redeem pegged
        // critical CRs = 105% (big bonus 75), 115% (small bonus 25), 150% (danger, 60), -> 80
        (, uint256 price, , ) = priceOracle.getPrice();
        setUp_collateral(100 ether, 4 ether); // CR = 104/100 = 104%, bonus
        assertGt(
            initial(config.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            IMinter(minter).collateralRatio(),
            "test must start with CR bonus"
        );
        assertEq(IERC20(deployed.wstETH).balanceOf(feeReceiver.addr), 0, "no fees so far");

        // TODO: do a check where they land on the boundaried exactly
        // check fees:
        uint[7] memory redeemStep = [
            // 1) completely in the first band: redeem(10), CR = 94/90 = 104.4%
            uint(10),
            // 2) straddling the first boundary: redeem(30), CR = 64/60 = 106.7%
            uint(30),
            // 3) remaining in the second band: redeem(20), CR= 44/40 = 110%
            uint(20),
            // 4) straddling the second boundary: redeem(20), CR = 24/20 = 120%
            uint(20),
            // 5) remaining in the third band: redeem(10), CR= 14/10 = 140%
            uint(10),
            // 6) straddling the third boundary: redeem(3), CR = 11/7 = 157%
            uint(3),
            // 7) straddling all bands: redeem(3), CR = 8/4 = 200%
            uint(3)
        ];

        int256[] memory totalFeeRatios = new int256[](redeemStep.length);
        int256[] memory totalFees = new int256[](redeemStep.length);
        uint256 collateralInSum = 0;
        for (uint i = 0; i < redeemStep.length; i++) {
            // TODO: check the CRs in comments above against the config
            // clog("step(setup)", i + 1);
            collateralInSum += (redeemStep[i] * 1 ether);
            // clog("collateralInSum", collateralInSum);
            (totalFeeRatios[i], ) = IMinter(minter).redeemPeggedTokenIncentiveRatio(
                (collateralInSum * price) / 1 ether
            );
            // clog("totalFeeRatios[i]", totalFeeRatios[i]);
            totalFees[i] = (int256(collateralInSum) * totalFeeRatios[i]) / 1 ether;
            // clog("totalFees[i]", totalFees[i]);
        }

        deal(address(deployed.BaoUSD), user.addr, IMinter(minter).peggedTokenBalance());
        vm.prank(user.addr);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        int256 totalFee = 0;
        for (uint i = 0; i < redeemStep.length; i++) {
            uint step = i + 1;
            // clog("step(run)", step);
            totalFee += _checkRedeemPeggedIntegral(redeemStep[i], step, step * 2);
            assertApproxEqAbs(
                totalFee,
                totalFees[i],
                step == 7 ? 94 : step * 9,
                string.concat(Useful.toString(step), ", running sum")
            );
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
                uint256(SignedMath.max(0, totalFee)),
                step * 2,
                string.concat("step ", Useful.toString(step))
            );
        }
    }

    function test_redeemPeggedFeesAreIntegralsBoundary() public {
        (, uint256 price, , ) = priceOracle.getPrice();
        setUp_collateral(10 ether, 4 ether); // CR = 14/10 = 140%

        deal(address(deployed.BaoUSD), user.addr, IMinter(minter).peggedTokenBalance());
        vm.startPrank(user.addr);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        uint lots = 3;
        // clog("collateralRatio", IMinter(minter).collateralRatio());
        (int256 totalFeeRatio, uint256 collateral) = IMinter(minter).redeemPeggedTokenIncentiveRatio(lots * price);
        uint256 totalFeeExpected = (uint256(totalFeeRatio) * collateral) / 1 ether;
        // clog("totalFeeExpected", totalFeeExpected);

        for (uint i = 0; i < lots; i++) {
            IMinter(minter).redeemPeggedToken(price, user.addr, 0);
            // clog("collateralRatio", IMinter(minter).collateralRatio());
        }
        assertApproxEqAbs(IERC20(deployed.wstETH).balanceOf(feeReceiver.addr), uint256(totalFeeExpected), 2);
        vm.stopPrank();
    }
}
