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

contract TestMinterFees is TestMinter {
    Vm.Wallet user;

    function setUp() public virtual override {
        super.setUp();
        user = vm.createWallet("user");
        setUp_permissions();

        deal(address(deployed.wstETH), user.addr, 100 ether);
        vm.prank(user.addr);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);
    }

    //---------------------------------------------------------------------------------------------
    // Fees
    //---------------------------------------------------------------------------------------------

    function getIncentives()
        private
        view
        returns (
            int256 mintPeggedIncentive,
            int256 redeemPeggedIncentive,
            int256 mintLeveragedIncentive,
            int256 redeemLeveragedIncentive
        )
    {
        (mintPeggedIncentive, ) = IMinter(minter).mintPeggedTokenIncentiveRatio(0);
        redeemPeggedIncentive = IMinter(minter).redeemPeggedTokenIncentiveRatio(0);
        mintLeveragedIncentive = IMinter(minter).mintLeveragedTokenIncentiveRatio(0);
        (redeemLeveragedIncentive, ) = IMinter(minter).redeemLeveragedTokenIncentiveRatio(0);
    }

    function test_fees() public {
        // TODO: check that the fee is adjusted for begin-state (mintLeveraged) and end-state (mintPegged)
        setUp_collateral(1 ether, 0);
        assertEq(IMinter(minter).collateralRatio(), 1 ether);
        (, uint256 startPrice, , ) = IPriceOracle(priceOracle).getPrice();

        /*
        // test fees at the extremities, around rebalance and danger
        // CR is proportional to price
        console.log(
            "startPrice (%s) * config.rebalanceCollateralRatioUpperBound (%s)",
            startPrice,
            config.rebalanceCollateralRatioUpperBound
        );
        uint256 priceForCollateral = (startPrice * config.rebalanceCollateralRatioUpperBound) / 1 ether;
        for (uint256 price = priceForCollateral - 100000; price < priceForCollateral + 100000; price += 100) {
            MockPriceOracle(priceOracle).setPrice(price);
            uint256 cr = IMinter(minter).collateralRatio();
            // TODO: check the results against the expected behavior:
            // always rising/falling or staying the same and last value is geater/less than the first, etc.
            // inflection point is around the config collateral ratio
            //console.log("%s - %s - %s", price, config.rebalanceCollateralRatioUpperBound, cr);
            (
                uint256 mintPeggedFees,
                uint256 redeemPeggedFees,
                uint256 mintLeveragedFees,
                uint256 redeemLeveragedFees
            ) = IncentiveRatio(();
        }
        // TODO: merge the two checks into one.
        priceForCollateral = (startPrice * config.dangerCollateralRatioUpperBound) / 1 ether;
        for (uint256 price = priceForCollateral - 100000; price < priceForCollateral + 100000; price += 100) {
            MockPriceOracle(priceOracle).setPrice(price);
            uint256 cr = IMinter(minter).collateralRatio();
            (
                uint256 mintPeggedFees,
                uint256 redeemPeggedFees,
                uint256 mintLeveragedFees,
                uint256 redeemLeveragedFees
            ) = IncentiveRatio(();
        }
        */

        // write a gnuplot data file for fees
        string memory file = "./results/fees.csv";
        if (vm.exists(file)) vm.removeFile(file);
        vm.writeLine(
            file,
            "Price, Collateral Ratio, Mint Pegged Fees, Redeem Pegged Fees, Mint Leveraged Fees, Redeem Leveraged Fees"
        );

        //for (uint256 price = (startPrice * 9) / 10; price < (startPrice * 15) / 10; price += 10 ether)

        for (uint256 cr = 9 ether / 10; cr <= 16 ether / 10; cr += 1 ether / 1000) {
            // for (uint256 cr = 11 ether / 10; cr <= 15 ether / 10; cr += 5 ether / 100) {
            uint256 price = (startPrice * cr) / 1 ether;
            MockPriceOracle(priceOracle).setPrice(price);
            assertEq(cr, IMinter(minter).collateralRatio(), "crs must match");
            (
                int256 mintPeggedFees,
                int256 redeemPeggedFees,
                int256 mintLeveragedFees,
                int256 redeemLeveragedFees
            ) = getIncentives();
            vm.writeLine(
                file,
                string.concat(
                    Useful.toStringScaled(price, 18),
                    ",",
                    Useful.toStringScaled(cr, 18),
                    ",",
                    Useful.toStringScaled(mintPeggedFees, 18),
                    ",",
                    Useful.toStringScaled(redeemPeggedFees, 18),
                    ",",
                    Useful.toStringScaled(mintLeveragedFees, 18),
                    ",",
                    Useful.toStringScaled(redeemLeveragedFees, 18)
                )
            );
        }
        vm.closeFile(file);
    }

    function test_mintPeggedFeeCalcs() public {
        (, uint256 price, , ) = priceOracle.getPrice();
        setUp_collateral(2 ether, 1 ether); // CR = 3/2 = 1.5
        assertLt(dangerCollateralRatioUpperBound, IMinter(minter).collateralRatio(), "test must start with CR normal");

        // fees at normal
        uint256 maxCollateral;
        int256 mintPeggedFees;
        (mintPeggedFees, maxCollateral) = IMinter(minter).mintPeggedTokenIncentiveRatio(0);
        assertEq(mintPeggedFees, mintPeggedNormalIncentiveRatio);

        // fees crossing into danger
        uint256 collateral = 1 ether; // CR -> 4/3 = 1.33 i.e. crossing into danger
        (mintPeggedFees, maxCollateral) = IMinter(minter).mintPeggedTokenIncentiveRatio(collateral);
        assertGt(mintPeggedFees, mintPeggedNormalIncentiveRatio, "fee is part normal, part danger, so > normal");
        assertLt(mintPeggedFees, mintPeggedDangerIncentiveRatio, "fee is part normal, part danger, so < danger");
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
            dangerCollateralRatioUpperBound,
            IMinter(minter).collateralRatio(),
            "test must be in CR danger < normal"
        );
        assertLt(
            config.disallowMintPeggedCollateralRatioUpperBound,
            IMinter(minter).collateralRatio(),
            "test must be in CR danger > disallow"
        );
        (mintPeggedFees, maxCollateral) = IMinter(minter).mintPeggedTokenIncentiveRatio(0);
        assertEq(mintPeggedFees, mintPeggedDangerIncentiveRatio, "expected to be in danger");
        (mintPeggedFees, maxCollateral) = IMinter(minter).mintPeggedTokenIncentiveRatio(3 ether);
        assertApproxEqAbs(mintPeggedFees, mintPeggedDangerIncentiveRatio, 5, "expected to still be in danger"); // CR -> disallow but fee ratio is still danger
    }

    function _checkMintPeggedIntegral(uint iTotalMint, uint step, uint tolerance) private returns (int256 totalFee) {
        bool log = step == 2;
        console.log("_checkMintPeggedIntegral(%s, %s)", iTotalMint, step);
        // console.log("------------------------------------------");
        uint256 maxCollateral;
        int256 incentiveRatio;
        (incentiveRatio, maxCollateral) = IMinter(minter).mintPeggedTokenIncentiveRatio(iTotalMint * 1 ether);
        if (log) clog("  incentiveRatio", incentiveRatio);
        totalFee = (int256(maxCollateral) * incentiveRatio) / 1 ether;
        if (log) clog("  expected fees", totalFee);
        uint256 start = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        if (log) clog("starting fees", start);
        for (uint i = 0; i < iTotalMint; i++) {
            console.log("    step %s mint %s of %s", step, i + 1, iTotalMint);
            uint256 beforeMint = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
            // uint256 expected = 1 ether * uint256(IMinter(minter).mintPeggedTokenIncentiveRatio(1 ether));
            vm.prank(user.addr);
            try IMinter(minter).mintPeggedToken(1 ether, user.addr, 0) returns (uint256) {} catch {
                console.log("    mint reverted");
            }
            if (log) clog("    fees this mint", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeMint);
            // assertApproxEqAbs(
            //     IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeMint,
            //     expected,
            //     2,
            //     string.concat(Useful.toString(i), "th iteration in step ", Useful.toString(step))
            // );
            // if (log)
            //     clog("    extra fees received so far", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start);
        }
        if (log) clog(" actual fees  ", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start);
        // clog(" all (pre-calc'd) ", totalFee);
        assertApproxEqAbs(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start,
            uint256(totalFee),
            tolerance,
            Useful.toString(step)
        );
        console.log("_checkMintPeggedIntegral() -> %s", totalFee);
    }

    function test_mintPeggedFeesAreIntegrals() private {
        // critical CRs = 131% (disallow), 140% (danger)
        // TODO: check the above is the case
        setUp_collateral(18 ether, 10 ether); // CR = 28/18 = 155%
        assertLt(
            dangerCollateralRatioUpperBound,
            IMinter(minter).collateralRatio(),
            "test must start with CR normal 2"
        );
        assertEq(IERC20(deployed.wstETH).balanceOf(feeReceiver.addr), 0, "no fees so far");

        // check fees:
        uint[5] memory mintStep = [
            // 1) completely in the first band: mint(4), CR = 32/22 = 145%
            uint(4),
            // 2) straddling the first boundary: mint(4), CR = 36/26 = 138%
            uint(3),
            // 3) remaining in the second band: mint(4), CR= 40/30 = 133%
            uint(3),
            // 4) straddling the second boundary: mint(4), CR = 44/34 = 128%
            uint(5),
            // 5) straddling all bands: mint(4), CR = 48/38 = 126%
            uint(5)
        ];

        uint256[] memory maxCollaterals = new uint256[](mintStep.length);
        int256[] memory totalFeeRatios = new int256[](mintStep.length);
        int256[] memory totalFees = new int256[](mintStep.length);
        uint256 collateralInSum = 0;
        for (uint i = 0; i < mintStep.length; i++) {
            uint step = i + 1;
            clog("step(setup)", step);
            collateralInSum += (mintStep[i] * 1 ether);
            clog("collateralInSum", collateralInSum);
            (totalFeeRatios[i], maxCollaterals[i]) = IMinter(minter).mintPeggedTokenIncentiveRatio(collateralInSum);
            clog("totalFeeRatios[i]", totalFeeRatios[i]);
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
                assertLt(maxCollaterals[i], collateralInSum - mintStep[i - 1] * 1 ether, "(step 4) less than this one");
            } else {
                assertEq(maxCollaterals[i], collateralInSum, "should be no disallowed collateral");
            }
            totalFees[i] = (int256(maxCollaterals[i]) * totalFeeRatios[i]) / 1 ether;
            clog("totalFees[i]", totalFees[i]);
        }

        int256 totalFee = 0;
        for (uint i = 0; i < mintStep.length; i++) {
            uint step = i + 1;
            clog("step(run)", step);
            totalFee += _checkMintPeggedIntegral(mintStep[i], step, step * 2);
            assertApproxEqAbs(totalFee, totalFees[i], step * 2, string.concat(Useful.toString(step), ", running sum"));
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
        assertGe(dangerCollateralRatioUpperBound, IMinter(minter).collateralRatio(), "test must start with CR danger");

        // fees at danger
        int256 mintLeveragedFees = IMinter(minter).mintLeveragedTokenIncentiveRatio(0);
        assertEq(mintLeveragedFees, mintLeveragedDangerIncentiveRatio);

        // fees crossing into normal
        uint256 collateral = 1 ether; // CR -> 5/3 = 1.66 i.e. crossing into normal
        mintLeveragedFees = IMinter(minter).mintLeveragedTokenIncentiveRatio(collateral);
        assertLt(mintLeveragedFees, mintLeveragedNormalIncentiveRatio, "fee is part normal, part danger, so < normal");
        assertGt(mintLeveragedFees, mintLeveragedDangerIncentiveRatio, "fee is part normal, part danger, so > danger");
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
        assertLt(dangerCollateralRatioUpperBound, IMinter(minter).collateralRatio(), "test must be in CR normal now");
        mintLeveragedFees = IMinter(minter).mintLeveragedTokenIncentiveRatio(0);
        assertEq(mintLeveragedFees, mintLeveragedNormalIncentiveRatio, "expected to be in normal");
    }

    // TODO: check the bonus if properly paid - do this with the reserve pool

    function _checkMintLeveragedIntegral(uint iTotalMint, uint step, uint tolerance) private returns (int256 totalFee) {
        bool log = step == 4;
        console.log("_checkMintLeveragedIntegral(%s, %s)", iTotalMint, step);
        // console.log("------------------------------------------");
        uint256 collateral = iTotalMint * 1 ether;
        int256 incentiveRatio = IMinter(minter).mintLeveragedTokenIncentiveRatio(collateral);
        if (log) clog("  incentiveRatio", incentiveRatio);
        totalFee = (int256(collateral) * incentiveRatio) / 1 ether;
        if (log) clog("  expected fees", totalFee);
        uint256 start = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        if (log) console.log("  starting fees=%s", start);
        for (uint i = 0; i < iTotalMint; i++) {
            console.log("    step %s mint %s of %s", step, i + 1, iTotalMint);
            uint256 beforeMint = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
            // uint256 expected = 1 ether * uint256(IMinter(minter).mintLeveragedTokenIncentiveRatio(1 ether));
            vm.prank(user.addr);
            IMinter(minter).mintLeveragedToken(1 ether, user.addr, 0);
            if (log) clog("    fees this mint", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeMint);
            // assertApproxEqAbs(
            //     IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeMint,
            //     expected,
            //     2,
            //     string.concat(Useful.toString(i), "th iteration in step ", Useful.toString(step))
            // );
            // if (log)
            //     clog("    extra fees received so far", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start);
        }
        if (log) clog(" actual fees  ", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start);
        // clog(" all (pre-calc'd) ", totalFee);
        assertApproxEqAbs(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start,
            uint256(SignedMath.max(totalFee, 0)), // ignore bonuses here for now
            // TODO: do another loop like this for bonuses
            tolerance,
            Useful.toString(step)
        );
        console.log("_checkMintLeveragedIntegral() -> %s", totalFee);
    }

    function test_mintLeveragedFeesAreIntegrals() private {
        // critical CRs = 110% (bonus), 120% (free), 140% (danger)
        // TODO: check the above is the case
        setUp_collateral(150 ether, 10 ether); // CR = 160/150 = 107%, bonus
        assertGt(bonusCollateralRatioUpperBound, IMinter(minter).collateralRatio(), "test must start with CR bonus");
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
            uint step = i + 1;
            clog("step", step);
            collateralInSum += (mintStep[i] * 1 ether);
            clog("collateralInSum", collateralInSum);
            totalFeeRatios[i] = IMinter(minter).mintLeveragedTokenIncentiveRatio(collateralInSum);
            clog("totalFeeRatios[i]", totalFeeRatios[i]);
            totalFees[i] = (int256(collateralInSum) * totalFeeRatios[i]) / 1 ether;
            clog("totalFees[i]", totalFees[i]);
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

    function test_redeemPeggedFeeCalcs() public {
        // TODO: start in critical 120, then go to danger 140, then normal
        // TODO: add bonus band in. Also in mintLeveraged
        (, uint256 price, , ) = priceOracle.getPrice();
        setUp_collateral(3 ether, 1 ether, owner.addr); // CR = 4/3 = 1.33
        assertLt(IMinter(minter).collateralRatio(), dangerCollateralRatioUpperBound, "test must start with CR danger");

        // fees at danger
        int256 redeemPeggedFees = IMinter(minter).redeemPeggedTokenIncentiveRatio(0);
        assertEq(redeemPeggedFees, redeemPeggedDangerIncentiveRatio);

        // fees crossing into normal
        uint256 collateral = 1 ether; // CR -> 2/1 = 1.5 i.e. crossing into normal
        uint256 pegged = (collateral * price) / 1 ether;
        redeemPeggedFees = IMinter(minter).redeemPeggedTokenIncentiveRatio(pegged);
        assertLt(redeemPeggedFees, redeemPeggedNormalIncentiveRatio, "fee is part normal, part danger, so < normal");
        assertGt(redeemPeggedFees, redeemPeggedDangerIncentiveRatio, "fee is part normal, part danger, so > danger");
        assertGt(
            IMinter(minter).redeemPeggedTokenIncentiveRatio(pegged + 10 ** 16),
            redeemPeggedFees,
            "the more in normal the higher the fee"
        );

        // check that the fees match the reported value, both emit and that transferred
        uint256 expectedFees = (uint256(redeemPeggedFees) * collateral) / 1 ether;
        uint256 feeReceiverCollateralBalanceBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        assertGe(IERC20(deployed.BaoUSD).balanceOf(owner.addr), pegged);
        vm.prank(owner.addr);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.RedeemPeggedToken(owner.addr, user.addr, pegged, collateral - expectedFees);
        vm.prank(owner.addr); // the owner has all the tokens
        IMinter(minter).redeemPeggedToken(pegged, user.addr, 0);
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            feeReceiverCollateralBalanceBefore + expectedFees
        );

        // we are now in normal (CR=1.5), so check the fee here
        assertLt(dangerCollateralRatioUpperBound, IMinter(minter).collateralRatio(), "test must be in CR normal now");
        redeemPeggedFees = IMinter(minter).redeemPeggedTokenIncentiveRatio(0);
        assertEq(redeemPeggedFees, redeemPeggedNormalIncentiveRatio, "expected to be in normal");
    }

    // TODO: check the bonus if properly paid - do this with the reserve pool?

    function _checkRedeemPeggedIntegral(
        uint iTotalRedeem,
        uint step,
        uint tolerance
    ) private returns (int256 totalFee) {
        bool log = true; //step == 4;
        console.log("_checkRedeemPeggedIntegral(%s, %s)", iTotalRedeem, step);
        (, uint256 price, , ) = priceOracle.getPrice();
        // console.log("------------------------------------------");
        uint256 pegged = iTotalRedeem * price;
        uint256 collateral = iTotalRedeem * 1 ether;
        int256 incentiveRatio = IMinter(minter).redeemPeggedTokenIncentiveRatio(pegged);
        if (log) clog("  incentiveRatio", incentiveRatio);
        totalFee = (int256(collateral) * incentiveRatio) / 1 ether;
        if (log) clog("  expected fees", totalFee);
        uint256 start = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        if (log) console.log("  starting fees=%s", start);
        for (uint i = 0; i < iTotalRedeem; i++) {
            console.log("    step %s redeem %s of %s", step, i + 1, iTotalRedeem);
            uint256 beforeRedeem = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
            // uint256 expected = 1 ether * uint256(IMinter(minter).redeemPeggedTokenIncentiveRatio(price));
            vm.prank(user.addr);
            IMinter(minter).redeemPeggedToken(price, user.addr, 0);
            if (log) clog("    fees this redeem", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeRedeem);
            // assertApproxEqAbs(
            //     IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeRedeem,
            //     expected,
            //     2,
            //     string.concat(Useful.toString(i), "th iteration in step ", Useful.toString(step))
            // );
            // if (log)
            //     clog("    extra fees received so far", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start);
            //assertFalse(true, "breakpoint");
        }
        if (log) clog(" actual fees  ", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start);
        // clog(" all (pre-calc'd) ", totalFee);
        assertApproxEqAbs(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - start,
            uint256(SignedMath.max(totalFee, 0)), // ignore bonuses here for now
            // TODO: do another loop like this for bonuses
            tolerance,
            Useful.toString(step)
        );
        console.log("_checkRedeemPeggedIntegral() -> %s", totalFee);
    }

    function test_redeemPeggedFeesAreIntegrals() private {
        (, uint256 price, , ) = priceOracle.getPrice();
        // critical CRs = 110% (bonus), 120% (free), 140% (danger)
        // TODO: check the above is the case
        setUp_collateral(60 ether, 4 ether); // CR = 64/60 = 107%, bonus
        assertGt(bonusCollateralRatioUpperBound, IMinter(minter).collateralRatio(), "test must start with CR bonus");
        assertEq(IERC20(deployed.wstETH).balanceOf(feeReceiver.addr), 0, "no fees so far");

        // check fees:
        uint[7] memory redeemStep = [
            // 1) completely in the first band: redeem(12), CR = 52/         = 108%
            uint(12),
            // 2) straddling the first boundary: redeem(12), CR = 40/36 = 111%
            uint(12),
            // 3) remaining in the second band: redeem(12), CR= 28/24 = 117%
            uint(12),
            // 4) straddling the second boundary: redeem(8), CR = 20/16 = 125%
            uint(8),
            // 5) remaining in the third band: redeem(4), CR= 16/12 = 133%
            uint(4),
            // 6) straddling the third boundary: redeem(3), CR = 13/9 = 1.36% -> 140 -> 144%
            uint(3),
            // 7) straddling all bands: redeem(3), CR = 10/6 = 166%
            uint(3)
        ];

        int256[] memory totalFeeRatios = new int256[](redeemStep.length);
        int256[] memory totalFees = new int256[](redeemStep.length);
        uint256 collateralInSum = 0;
        for (uint i = 0; i < redeemStep.length; i++) {
            clog("step(setup)", i + 1);
            collateralInSum += (redeemStep[i] * 1 ether);
            clog("collateralInSum", collateralInSum);
            totalFeeRatios[i] = IMinter(minter).redeemPeggedTokenIncentiveRatio((collateralInSum * price) / 1 ether);
            clog("totalFeeRatios[i]", totalFeeRatios[i]);
            totalFees[i] = (int256(collateralInSum) * totalFeeRatios[i]) / 1 ether;
            clog("totalFees[i]", totalFees[i]);
        }

        deal(address(deployed.BaoUSD), user.addr, IMinter(minter).peggedTokenBalance());
        vm.prank(user.addr);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        int256 totalFee = 0;
        for (uint i = 0; i < redeemStep.length; i++) {
            uint step = i + 1;
            clog("step(run)", step);
            totalFee += _checkRedeemPeggedIntegral(redeemStep[i], step, step * 2);
            assertApproxEqAbs(totalFee, totalFees[i], step * 9, string.concat(Useful.toString(step), ", running sum"));
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
                uint256(SignedMath.max(0, totalFee)),
                step * 2,
                string.concat("step ", Useful.toString(step))
            );
        }
    }

    function test_redeemPeggedFeesAreIntegralsQuick() private {
        (, uint256 price, , ) = priceOracle.getPrice();
        // critical CRs = 140% (danger)
        // TODO: check the above is the case
        setUp_collateral(12 ether, 4 ether); // CR = 16/12 = 133%
        assertGt(dangerCollateralRatioUpperBound, IMinter(minter).collateralRatio(), "test must start with CR bonus");
        assertEq(IERC20(deployed.wstETH).balanceOf(feeReceiver.addr), 0, "no fees so far");

        // check fees:
        uint[1] memory redeemStep = [
            // 1) straddling the third boundary: redeem(3), CR = 13/9 = 1.36% -> 140 -> 144%
            uint(3)
        ];

        int256[] memory totalFeeRatios = new int256[](redeemStep.length);
        int256[] memory totalFees = new int256[](redeemStep.length);
        uint256 collateralInSum = 0;
        for (uint i = 0; i < redeemStep.length; i++) {
            clog("step(setup)", i + 1);
            collateralInSum += (redeemStep[i] * 1 ether);
            clog("collateralInSum", collateralInSum);
            totalFeeRatios[i] = IMinter(minter).redeemPeggedTokenIncentiveRatio((collateralInSum * price) / 1 ether);
            clog("totalFeeRatios[i]", totalFeeRatios[i]);
            totalFees[i] = (int256(collateralInSum) * totalFeeRatios[i]) / 1 ether;
            clog("totalFees[i]", totalFees[i]);
        }

        deal(address(deployed.BaoUSD), user.addr, IMinter(minter).peggedTokenBalance());
        vm.prank(user.addr);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        int256 totalFee = 0;
        for (uint i = 0; i < redeemStep.length; i++) {
            uint step = i + 1;
            clog("step(run)", step);
            totalFee += _checkRedeemPeggedIntegral(redeemStep[i], step, step * 2);
            assertApproxEqAbs(totalFee, totalFees[i], step * 9, string.concat(Useful.toString(step), ", running sum"));
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
                uint256(SignedMath.max(0, totalFee)),
                step * 2,
                string.concat("step ", Useful.toString(step))
            );
        }
    }

    function test_redeemPeggedFeesAreIntegralsQuick2_a() private {
        (, uint256 price, , ) = priceOracle.getPrice();
        // critical CRs = 140% (danger)
        // TODO: check the above is the case
        setUp_collateral(12 ether, 4 ether); // CR = 16/12 = 133%

        deal(address(deployed.BaoUSD), user.addr, IMinter(minter).peggedTokenBalance());
        vm.prank(user.addr);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        clog("collateralRatio", IMinter(minter).collateralRatio());
        uint256 totalFee = 0;
        for (uint i = 0; i < 3; i++) {
            uint256 feesBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
            vm.prank(user.addr);
            IMinter(minter).redeemPeggedToken(price, user.addr, 0);
            uint256 fee = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - feesBefore;
            clog("collateralRatio", IMinter(minter).collateralRatio());
            clog("fee", fee);
            totalFee += fee;
        }
        clog("totalFee", totalFee);
        assertTrue(false);
    }

    function test_redeemPeggedFeesAreIntegralsQuick2_b() private {
        (, uint256 price, , ) = priceOracle.getPrice();
        // critical CRs = 140% (danger)
        // TODO: check the above is the case
        setUp_collateral(12 ether, 4 ether); // CR = 16/12 = 133%

        deal(address(deployed.BaoUSD), user.addr, IMinter(minter).peggedTokenBalance());
        vm.prank(user.addr);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        clog("collateralRatio", IMinter(minter).collateralRatio());
        uint256 totalFee = 0;
        vm.prank(user.addr);
        IMinter(minter).redeemPeggedToken(3 * price, user.addr, 0);
        uint256 fee = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        clog("collateralRatio", IMinter(minter).collateralRatio());
        clog("fee", fee);
        totalFee += fee;
        clog("totalFee", totalFee);
        assertTrue(false);
    }
}
