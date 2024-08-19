// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

import { IMinter } from "src/minter/IMinter.sol";
import { deployed } from "test/deployed.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";

import "test/Useful.sol";
import { TestMinter } from "test/Minter_base.t.sol";

// TODO: check what happens when safe price is invalid

contract TestMinterFeeSetUp is TestMinter {
    function setUpConfig() internal virtual override {
        setUpConfig_likely();
    }

    function setUp() public virtual override {
        super.setUp();
        setUp_permissions();
    }
}

contract TestMinterFees is TestMinterFeeSetUp {
    Vm.Wallet user;

    function setUp() public virtual override(TestMinterFeeSetUp) {
        super.setUp();
        user = vm.createWallet("user");
        deal(address(deployed.wstETH), user.addr, 100 ether);
        vm.prank(user.addr);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);
    }

    function test_mintPeggedFeeCalcs() public {
        _assertEqIncentiveConfig(
            config.mintPeggedIncentiveConfig,
            ic(ua(130, 140), ia(disallow, 100, 50)),
            "mint pegged incentive config"
        );

        uint256 price = priceOracle.latestAnswer();
        setUp_collateral(2 ether, 1 ether); // CR = 3/2 = 1.5
        assertEq(IMinter(minter).collateralRatio(), 15 ether / 10);
        assertLt(
            ultimate(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            IMinter(minter).collateralRatio(),
            "test must start with CR normal"
        );

        // fees at normal
        int256 incentiveRatio = IMinter(minter).mintPeggedTokenIncentiveRatio();
        assertEq(incentiveRatio, ultimate(config.mintPeggedIncentiveConfig.incentiveRatios));

        // fees crossing into danger
        uint256 collateral = 1 ether; // CR -> 4/3 = 1.33 i.e. crossing into danger
        uint256 collateralUsed;
        uint256 peggedMinted;
        uint256 fee;
        (incentiveRatio, collateralUsed, peggedMinted, fee, , ) = IMinter(minter).mintPeggedTokenDryRun(collateral);
        assertGt(
            incentiveRatio,
            ultimate(config.mintPeggedIncentiveConfig.incentiveRatios),
            "fee is part normal, part danger, so > normal"
        );
        assertLt(
            incentiveRatio,
            penultimate(config.mintPeggedIncentiveConfig.incentiveRatios),
            "fee is part normal, part danger, so < danger"
        );
        (int256 incentiveRatioPlus, , , , , ) = IMinter(minter).mintPeggedTokenDryRun(collateral + 10 ** 16);
        assertGt(incentiveRatioPlus, incentiveRatio, "the more in danger the higher the fee");

        // check that the fees match the reported value, both emit and that transferred
        int256 expectedFees = (incentiveRatio * int256(collateral)) / 1 ether;
        uint256 feeReceiverCollateralBalanceBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        vm.expectEmit(minter);
        // emit IMinter.MintPeggedToken(user.addr, user.addr, collateral, peggedMinted);
        emit IMinter.MintPeggedToken(
            user.addr,
            user.addr,
            collateral,
            uint256((int256(price) * (int256(collateral) - expectedFees))) / 1 ether
        );
        vm.prank(user.addr);
        uint256 minted = IMinter(minter).mintPeggedToken(collateral, user.addr, 0);
        assertEq(minted, peggedMinted, "pegged minted");
        // assertEq(IERC20(deployed.wstETH).balanceOf(feeReceiver.addr), feeReceiverCollateralBalanceBefore + fee);
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            uint256(int256(feeReceiverCollateralBalanceBefore) + expectedFees)
        );

        // we are now in danger (CR=1.33), so check the fee here
        // assertEq(IMinter(minter).collateralRatio(), uint256(4 ether) / 3);
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
        incentiveRatio = IMinter(minter).mintPeggedTokenIncentiveRatio();
        assertEq(
            incentiveRatio,
            penultimate(config.mintPeggedIncentiveConfig.incentiveRatios),
            "expected to be in danger"
        );
        (incentiveRatio, , , , , ) = IMinter(minter).mintPeggedTokenDryRun(3 ether);
        assertApproxEqAbs(
            incentiveRatio,
            penultimate(config.mintPeggedIncentiveConfig.incentiveRatios),
            5,
            "expected to still be in danger"
        ); // CR -> disallow but fee ratio is still danger
    }

    function _checkMintPeggedIntegral(uint iTotalMint, uint step, uint tolerance) private returns (int256 totalFee) {
        (, , , uint256 fee, uint256 discount, ) = IMinter(minter).mintPeggedTokenDryRun(iTotalMint * 1 ether);
        totalFee = int256(fee) - int256(discount);
        uint256 start = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);

        for (uint i = 0; i < iTotalMint; i++) {
            uint256 beforeMint = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
            (, , , fee, discount, ) = IMinter(minter).mintPeggedTokenDryRun(1 ether);
            // int256 expected = int256(fee) - int256(discount);
            vm.prank(user.addr);
            try IMinter(minter).mintPeggedToken(1 ether, user.addr, 0) returns (uint256) {} catch {}
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeMint,
                fee,
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
        uint256[] memory totalFees = new uint256[](mintStep.length);
        uint256[] memory totalDiscounts = new uint256[](mintStep.length);
        uint256 collateralInSum = 0;
        for (uint i = 0; i < mintStep.length; i++) {
            uint step = i + 1;
            // clog("step(setup)", step);
            collateralInSum += (mintStep[i] * 1 ether);
            // clog("collateralInSum", collateralInSum);
            (, maxCollaterals[i], , totalFees[i], totalDiscounts[i], ) = IMinter(minter).mintPeggedTokenDryRun(
                collateralInSum
            );
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
        }

        int256 totalFee = 0;
        for (uint i = 0; i < mintStep.length; i++) {
            uint step = i + 1;
            // clog("step(run)", step);
            totalFee += _checkMintPeggedIntegral(mintStep[i], step, step * 2);
            assertApproxEqAbs(
                totalFee,
                int256(totalFees[i]) - int256(totalDiscounts[i]),
                step / 4,
                string.concat(Useful.toString(step), ", running sum")
            );
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
                uint256(SignedMath.max(0, totalFee)),
                0,
                string.concat("step ", Useful.toString(step))
            );
        }
    }

    function test_mintLeveragedFeeCalcs() public {
        // ic(ua(110, 120, 145), ia(-50, 0, 20, 70)), // mint leveraged
        // TODO: start in critical 120, then go to danger 140, then normal
        uint256 price = priceOracle.latestAnswer();
        setUp_collateral(3 ether, 1 ether); // CR = 4/3 = 1.33
        assertGe(
            ultimate(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            IMinter(minter).collateralRatio(),
            "test must start with CR danger"
        );

        // fees at danger
        int256 incentiveRatio = IMinter(minter).mintLeveragedTokenIncentiveRatio();
        assertEq(incentiveRatio, penultimate(config.mintLeveragedIncentiveConfig.incentiveRatios));

        // fees crossing into normal
        uint256 collateral = 1 ether; // CR -> 5/3 = 1.66 i.e. crossing into normal
        (incentiveRatio, , , , , ) = IMinter(minter).mintLeveragedTokenDryRun(collateral);
        assertLt(
            incentiveRatio,
            ultimate(config.mintLeveragedIncentiveConfig.incentiveRatios),
            "fee is part normal, part danger, so < normal"
        );
        assertGt(
            incentiveRatio,
            penultimate(config.mintLeveragedIncentiveConfig.incentiveRatios),
            "fee is part normal, part danger, so > danger"
        );
        (int256 incentiveRatioPlus, , , , , ) = IMinter(minter).mintLeveragedTokenDryRun(collateral + 10 ** 16);
        assertGt(incentiveRatioPlus, incentiveRatio, "the more in normal the higher the fee");

        // check that the fees match the reported value, both emit and that transferred
        int256 expectedFees = (incentiveRatio * int256(collateral)) / 1 ether;
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
        // ---------------------------------------------------------
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
        incentiveRatio = IMinter(minter).mintLeveragedTokenIncentiveRatio();
        assertEq(
            incentiveRatio,
            ultimate(config.mintLeveragedIncentiveConfig.incentiveRatios),
            "expected to be in normal"
        );
    }

    function _checkMintLeveragedIntegral(
        uint iTotalMint,
        uint step
    ) private returns (uint256 collateralUsed, uint256 leveragedMinted, uint256 fee, uint256 reserveCollateralUsed) {
        uint256 collateral = iTotalMint * 1 ether;
        (, collateralUsed, leveragedMinted, fee, reserveCollateralUsed, ) = IMinter(minter).mintLeveragedTokenDryRun(
            collateral
        );
        BeforeActionBalance memory beforeAll = _readBeforeActionBalance();
        for (uint i = 0; i < iTotalMint; i++) {
            BeforeActionBalance memory before = _readBeforeActionBalance();
            Total memory one;
            (, one.collateralUsed, one.leveragedMinted, one.fee, one.reserveCollateralUsed, ) = IMinter(minter)
                .mintLeveragedTokenDryRun(1 ether);
            vm.prank(user.addr);
            IMinter(minter).mintLeveragedToken(1 ether, user.addr, 0);
            // ---------------------------------------------------
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - before.feeReceiver,
                one.fee,
                0,
                string.concat("fee calc in ", Useful.toString(i), "th iteration in step ", Useful.toString(step))
            );
            assertApproxEqAbs(
                IERC20(leveragedToken).balanceOf(user.addr) - before.userLeveraged,
                one.leveragedMinted,
                0,
                string.concat(
                    "leveraged minted calc in ",
                    Useful.toString(i),
                    "th iteration in step ",
                    Useful.toString(step)
                )
            );
            assertApproxEqAbs(
                before.userCollateral - IERC20(deployed.wstETH).balanceOf(user.addr),
                one.collateralUsed,
                0,
                string.concat(
                    "collateral used calc in ",
                    Useful.toString(i),
                    "th iteration in step ",
                    Useful.toString(step)
                )
            );
            assertEq(
                before.reservePool - IERC20(deployed.wstETH).balanceOf(reservePool),
                one.reserveCollateralUsed,
                "one: reserve pool has given up some collateral"
            );
        }
        assertApproxEqAbs(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeAll.feeReceiver,
            fee,
            0,
            string.concat("fee calc in step ", Useful.toString(step))
        );
        assertApproxEqAbs(
            beforeAll.userCollateral - IERC20(deployed.wstETH).balanceOf(user.addr),
            collateralUsed,
            0,
            string.concat("collateral used calc in step", Useful.toString(step))
        );
        assertApproxEqAbs(
            IERC20(leveragedToken).balanceOf(user.addr) - beforeAll.userLeveraged,
            leveragedMinted,
            0,
            string.concat("leveraged minted calc in step ", Useful.toString(step))
        );
        assertEq(
            beforeAll.reservePool - IERC20(deployed.wstETH).balanceOf(reservePool),
            reserveCollateralUsed,
            "all: reserve pool has given up some collateral"
        );
    }

    function _checkMintLeveragedFeesIntegralList() public {
        // ic(ua(110, 120, 145), ia(-50, 0, 20, 70)), // mint leveraged
        // critical CRs (upper bounds) = 110% (bonus, -50), 120% (free, 0), 140% (danger, 20), -> (70)
        setUp_collateral(150 ether, 10 ether); // CR = 160/150 = 106.6%, bonus
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
            // fee=0, extraCollateral=24875621890547263
            uint(4),
            // 3) remaining in the second band: mint(10), CR= 178/150 = 119%
            // fee=0, extraCollateral=24875621890547263
            uint(10),
            // 4) straddling the second boundary: mint(20), CR = 198/150 = 132%
            // fee=36000000000000000, extraCollateral=24875621890547263
            uint(20),
            // 5) remaining in the third band: mint(10), CR= 208/150 = 139%
            // fee=56000000000000000, extraCollateral=24875621890547263
            uint(10),
            // 6) straddling the third boundary: mint(5), CR = 215/150 = 143%
            // fee=66000000000000000, extraCollateral=24875621890547263
            uint(5),
            // 7) straddling all bands: mint(5), CR = 228/150 = 145%
            // fee=78124248496993987, extraCollateral=24875621890547263
            uint(5)
        ];

        Total[] memory totals = new Total[](mintStep.length);
        uint256 collateralInSum = 0;
        for (uint i = 0; i < mintStep.length; i++) {
            // console.log("*** setup step %s", i + 1);
            collateralInSum += (mintStep[i] * 1 ether);
            // clog("collateralInSum", collateralInSum);
            (
                ,
                totals[i].collateralUsed,
                totals[i].leveragedMinted,
                totals[i].fee,
                totals[i].reserveCollateralUsed,

            ) = IMinter(minter).mintLeveragedTokenDryRun(collateralInSum);
        }

        // TODO: also check for minter balances reducing
        deal(address(deployed.wstETH), user.addr, IMinter(minter).collateralTokenBalance());
        vm.prank(user.addr);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);

        BeforeActionBalance memory before = _readBeforeActionBalance();

        Total memory total;
        for (uint i = 0; i < mintStep.length; i++) {
            // console.log("*** run step %s", i + 1);
            (
                uint256 collateralUsed,
                uint256 leveragedMinted,
                uint256 fee,
                uint256 reserveCollateralUsed
            ) = _checkMintLeveragedIntegral(mintStep[i], i + 1);
            // console.log("fee=%s", fee);
            total.collateralUsed += collateralUsed;
            total.leveragedMinted += leveragedMinted;
            total.fee += fee;
            // console.log("total.fee=%s", total.fee);
            // console.log("totals[%s].fee=%s", i, totals[i].fee);
            total.reserveCollateralUsed += reserveCollateralUsed;

            // sometimes fees and reserve collateral is netted and so we can't check this
            // assertApproxEqAbs(
            //     total.fee,
            //     totals[i].fee,
            //     0,
            //     string.concat("step ", Useful.toString(i + 1), ", calculated fee")
            // );
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
                total.fee,
                0,
                string.concat("step ", Useful.toString(i + 1), ", actual fee")
            );
            assertApproxEqAbs(
                IERC20(leveragedToken).balanceOf(user.addr) - before.userLeveraged,
                total.leveragedMinted,
                0,
                string.concat("step ", Useful.toString(i + 1), ", actual minted")
            );
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(user.addr),
                before.userCollateral - total.collateralUsed,
                0,
                string.concat("step ", Useful.toString(i + 1), ", actual used")
            );
            assertApproxEqAbs(
                before.reservePool - IERC20(deployed.wstETH).balanceOf(reservePool),
                total.reserveCollateralUsed,
                0,
                string.concat("step ", Useful.toString(i + 1), ", actual reserve used")
            );
        }
    }

    function test_mintLeveragedFeesAreIntegralOnlyFee() public {
        _checkMintLeveragedFeesIntegralList();
    }
    function test_mintLeveragedFeesAreIntegralWithReserve() public {
        // add to reserve pool
        deal(deployed.wstETH, reservePool, 100 ether);
        _checkMintLeveragedFeesIntegralList();
    }

    function _redeemPeggedFeeCalc(uint256 collateral) private returns (int256 redeemPeggedFeeRatio) {
        uint256 price = priceOracle.latestAnswer();
        redeemPeggedFeeRatio = IMinter(minter).redeemPeggedTokenIncentiveRatio();
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
        _assertEqIncentiveConfig(
            config.redeemPeggedIncentiveConfig,
            ic(ua(105, 115, 150), ia(-75, -25, 60, 80)),
            "redeem pegged incentive config"
        );
        // TODO: start in critical 115, then go to danger 150, then normal
        // TODO: add bonus band in. Also in mintLeveraged
        uint256 price = priceOracle.latestAnswer();
        setUp_collateral(3 ether, 1 ether, owner.addr); // CR = 4/3 = 1.33
        assertLt(
            IMinter(minter).collateralRatio(),
            ultimate(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            "test must start with CR danger"
        );

        // fees at danger
        int256 redeemPeggedFeeRatio = IMinter(minter).redeemPeggedTokenIncentiveRatio();
        assertEq(redeemPeggedFeeRatio, penultimate(config.redeemPeggedIncentiveConfig.incentiveRatios));

        // fees crossing into normal
        uint256 collateral = 2 ether; // CR -> 2/1 = 2 i.e. crossing into normal
        uint256 pegged = (collateral * price) / 1 ether;
        (redeemPeggedFeeRatio, , , , , ) = IMinter(minter).redeemPeggedTokenDryRun(pegged);
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

        (int256 redeemPeggedFeeRatio2, , , , , ) = IMinter(minter).redeemPeggedTokenDryRun(pegged + 10 ** 16);
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
        redeemPeggedFeeRatio = IMinter(minter).redeemPeggedTokenIncentiveRatio();
        assertEq(
            redeemPeggedFeeRatio,
            ultimate(config.redeemPeggedIncentiveConfig.incentiveRatios),
            "expected to be in normal"
        );
    }

    // TODO: check the bonus if properly paid - do this with the reserve pool?

    // to reduce stack space
    struct BeforeActionBalance {
        uint256 feeReceiver;
        uint256 userCollateral;
        uint256 userPegged;
        uint256 userLeveraged;
        uint256 reservePool;
        // TODO: add minter here
    }

    function _readBeforeActionBalance() private view returns (BeforeActionBalance memory before) {
        before.feeReceiver = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        before.userCollateral = IERC20(deployed.wstETH).balanceOf(user.addr);
        before.userPegged = IERC20(deployed.BaoUSD).balanceOf(user.addr);
        before.userLeveraged = IERC20(leveragedToken).balanceOf(user.addr);
        before.reservePool = IERC20(deployed.wstETH).balanceOf(reservePool);
    }

    struct Total {
        uint256 peggedRedeemed;
        uint256 collateralReturned;
        uint256 leveragedMinted;
        uint256 collateralUsed;
        uint256 fee;
        uint256 reserveCollateralUsed;
    }

    function _checkRedeemPeggedIntegral(
        uint iTotalRedeem,
        uint step
    ) private returns (uint256 peggedRedeemed, uint256 collateralReturned, uint256 fee, uint256 reserveCollateralUsed) {
        uint256 price = priceOracle.latestAnswer();
        (, peggedRedeemed, collateralReturned, fee, reserveCollateralUsed, ) = IMinter(minter).redeemPeggedTokenDryRun(
            iTotalRedeem * price
        );
        BeforeActionBalance memory beforeAll = _readBeforeActionBalance();
        for (uint i = 0; i < iTotalRedeem; i++) {
            BeforeActionBalance memory before = _readBeforeActionBalance();
            Total memory one;
            (, one.peggedRedeemed, one.collateralReturned, one.fee, one.reserveCollateralUsed, ) = IMinter(minter)
                .redeemPeggedTokenDryRun(price);
            vm.prank(user.addr);
            IMinter(minter).redeemPeggedToken(price, user.addr, 0);
            // ---------------------------------------------------
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - before.feeReceiver,
                one.fee,
                0,
                string.concat("fee calc in ", Useful.toString(i), "th iteration in step ", Useful.toString(step))
            );
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(user.addr) - before.userCollateral,
                one.collateralReturned,
                0,
                string.concat(
                    "collateral returned calc in ",
                    Useful.toString(i),
                    "th iteration in step ",
                    Useful.toString(step)
                )
            );
            assertApproxEqAbs(
                before.userPegged - IERC20(deployed.BaoUSD).balanceOf(user.addr),
                one.peggedRedeemed,
                0,
                string.concat(
                    "pegged redeemed calc in ",
                    Useful.toString(i),
                    "th iteration in step ",
                    Useful.toString(step)
                )
            );
            assertEq(
                before.reservePool - IERC20(deployed.wstETH).balanceOf(reservePool),
                one.reserveCollateralUsed,
                string.concat(
                    "redeemPegged one: reserve pool has given up some collateral in ",
                    Useful.toString(i),
                    "th iteration in step ",
                    Useful.toString(step)
                )
            );
        }
        assertApproxEqAbs(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeAll.feeReceiver,
            fee,
            0,
            string.concat("fee calc in step ", Useful.toString(step))
        );
        assertApproxEqAbs(
            IERC20(deployed.wstETH).balanceOf(user.addr) - beforeAll.userCollateral,
            collateralReturned,
            0,
            string.concat("collateral returned calc in step", Useful.toString(step))
        );
        assertApproxEqAbs(
            beforeAll.userPegged - IERC20(deployed.BaoUSD).balanceOf(user.addr),
            peggedRedeemed,
            0,
            string.concat("pegged redeemed calc in step ", Useful.toString(step))
        );
        assertEq(
            beforeAll.reservePool - IERC20(deployed.wstETH).balanceOf(reservePool),
            reserveCollateralUsed,
            "redeemPegged all: reserve pool has given up some collateral"
        );
    }

    function _checkRedeemPeggedFeesIntegralList() private {
        // ic(ua(105, 115, 150), ia(-75, -25, 60, 80)), // redeem pegged
        // critical CRs = 105% (big bonus 75), 115% (small bonus 25), 150% (danger, 60), -> 80
        uint256 price = priceOracle.latestAnswer();
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

        Total[] memory totals = new Total[](redeemStep.length);
        uint256 collateralInSum = 0;
        for (uint i = 0; i < redeemStep.length; i++) {
            // TODO: check the CRs in comments above against the config
            collateralInSum += (redeemStep[i] * 1 ether);
            (
                ,
                totals[i].peggedRedeemed,
                totals[i].collateralReturned,
                totals[i].fee,
                totals[i].reserveCollateralUsed,

            ) = IMinter(minter).redeemPeggedTokenDryRun((collateralInSum * price) / 1 ether);
        }

        // TODO: also check for minter balances reducing
        deal(address(deployed.BaoUSD), user.addr, IMinter(minter).peggedTokenBalance());
        vm.prank(user.addr);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        BeforeActionBalance memory before = _readBeforeActionBalance();

        Total memory total;
        for (uint i = 0; i < redeemStep.length; i++) {
            // clog("step(run)", i + 1);
            (
                uint256 peggedRedeemed,
                uint256 collateralReturned,
                uint256 fee,
                uint256 reserveCollateralUsed
            ) = _checkRedeemPeggedIntegral(redeemStep[i], i + 1);
            total.peggedRedeemed += peggedRedeemed;
            total.collateralReturned += collateralReturned;
            total.fee += fee;
            total.reserveCollateralUsed += reserveCollateralUsed;
            assertApproxEqAbs(
                total.fee,
                totals[i].fee,
                0,
                string.concat("step ", Useful.toString(i + 1), ", calculated fee")
            );
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
                total.fee,
                0,
                string.concat("step ", Useful.toString(i + 1), ", actual fee")
            );
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(user.addr) - before.userCollateral,
                total.collateralReturned,
                0,
                string.concat("step ", Useful.toString(i + 1), ", actual returned")
            );
            assertApproxEqAbs(
                IERC20(deployed.BaoUSD).balanceOf(user.addr),
                before.userPegged - total.peggedRedeemed,
                0,
                string.concat("step ", Useful.toString(i + 1), ", actual redemption")
            );
            assertApproxEqAbs(
                before.reservePool - IERC20(deployed.wstETH).balanceOf(reservePool),
                total.reserveCollateralUsed,
                0,
                string.concat("step ", Useful.toString(i + 1), ", actual reserve used")
            );
        }
    }

    function test_redeemPeggedFeesAreIntegralsOnlyFee() public {
        _checkRedeemPeggedFeesIntegralList();
    }

    function test_redeemPeggedFeesAreIntegralsWithReserve() public {
        // add to reserve pool
        deal(deployed.wstETH, reservePool, 100 ether);
        _checkRedeemPeggedFeesIntegralList();
    }

    function test_redeemPeggedFeesAreIntegralsBoundary() public {
        uint256 price = priceOracle.latestAnswer();
        setUp_collateral(10 ether, 4 ether); // CR = 14/10 = 140%

        deal(address(deployed.BaoUSD), user.addr, IMinter(minter).peggedTokenBalance());
        vm.startPrank(user.addr);
        IERC20(deployed.BaoUSD).approve(minter, type(uint256).max);

        uint lots = 3;
        (, , , uint256 totalFeeExpected, , ) = IMinter(minter).redeemPeggedTokenDryRun(lots * price);

        for (uint i = 0; i < lots; i++) {
            IMinter(minter).redeemPeggedToken(price, user.addr, 0);
        }
        assertApproxEqAbs(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            uint256(totalFeeExpected),
            0,
            "test total fee"
        );
        vm.stopPrank();
    }

    function _checkRedeemLeveragedIntegral(
        uint iTotalRedeem,
        uint step,
        uint tolerance
    ) private returns (int256 totalFee) {
        // bool log = true; // step == 6;
        // console.log("_checkRedeemLeveragedIntegral(%s, %s)", iTotalRedeem, step);
        uint256 price = priceOracle.latestAnswer();
        // console.log("------------------------------------------");
        (, , , uint256 fee, uint256 discount, ) = IMinter(minter).redeemLeveragedTokenDryRun(iTotalRedeem * price);
        // if (log) clog("  incentiveRatio", incentiveRatio);
        totalFee = int256(fee) - int256(discount);
        // if (log) clog("  expected fees", totalFee);
        uint256 start = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        // if (log) console.log("  starting fees=%s", start);
        for (uint i = 0; i < iTotalRedeem; i++) {
            // console.log("    step %s redeem %s of %s", step, i + 1, iTotalRedeem);
            uint256 beforeRedeem = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
            (, , , fee, discount, ) = IMinter(minter).redeemLeveragedTokenDryRun(price);
            // console.log("fee=%s", fee);
            // console.log("discount=%s", discount);
            // int256 expected = int256(fee) - int256(discount);
            vm.prank(user.addr);
            IMinter(minter).redeemLeveragedToken(price, user.addr, 0);
            // if (log) clog("    fees this redeem", IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeRedeem);
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr) - beforeRedeem,
                fee,
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
        // console.log("_checkRedeemLeveragedIntegral() -> %s", totalFee);
    }

    function test_redeemLeveragedFeesAreIntegrals() public {
        // ic(ua(105, 135), ia(disallow, 150, 120)) // redeem leveraged
        uint256 price = priceOracle.latestAnswer();
        setUp_collateral(40 ether, 20 ether); // CR = 60/40 = 150%, normal
        assertLt(
            ultimate(config.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds),
            IMinter(minter).collateralRatio(),
            "test must start with CR nromal ml"
        );
        assertEq(IERC20(deployed.wstETH).balanceOf(feeReceiver.addr), 0, "no fees so far");

        // check fees:
        uint[5] memory redeemStep = [
            // 1) completely in the first band: redeem(4), CR = 56/40 = 140%
            uint(4),
            // 2) straddling the first boundary: redeem(4), CR = 52/40 = 130%
            uint(4),
            // 3) remaining in the second band: redeem(4), CR= 46/40 = 115%
            uint(4),
            // 4) straddling the second boundary: redeem(5), CR = 41/40 = 102.5%
            uint(5),
            // 5) entering depeg: redeem(1), CR = 40/40 = 100%
            uint(1)
        ];

        uint256[] memory totalFees = new uint256[](redeemStep.length);
        uint256[] memory totalDiscounts = new uint256[](redeemStep.length);
        uint256 collateralInSum = 0;
        for (uint i = 0; i < redeemStep.length; i++) {
            // clog("step(setup)", i + 1);
            collateralInSum += (redeemStep[i] * 1 ether);
            // clog("collateralInSum", collateralInSum);
            (, , , totalFees[i], totalDiscounts[i], ) = IMinter(minter).redeemLeveragedTokenDryRun(
                (collateralInSum * price) / 1 ether
            );
        }

        deal(leveragedToken, user.addr, IMinter(minter).leveragedTokenBalance());
        vm.prank(user.addr);
        IERC20(leveragedToken).approve(minter, type(uint256).max);

        int256 totalFee = 0;
        for (uint i = 0; i < redeemStep.length; i++) {
            uint step = i + 1;
            // clog("step(run)", step);
            totalFee += _checkRedeemLeveragedIntegral(redeemStep[i], step, 0);
            assertApproxEqAbs(
                totalFee,
                int256(totalFees[i]) - int256(totalDiscounts[i]),
                0,
                string.concat(Useful.toString(step), ", running sum")
            );
            assertEq(uint256(SignedMath.max(0, totalFee)), totalFees[i]);
            assertApproxEqAbs(
                IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
                totalFees[i],
                0,
                string.concat("step ", Useful.toString(step))
            );
        }
    }
}

contract TestMinterNoneMinted is TestMinterFeeSetUp {
    function setUp() public virtual override(TestMinterFeeSetUp) {
        super.setUp();
    }

    function test_all() public {
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        IMinter(minter).redeemLeveragedToken(1000 ether, address(this), 0);

        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, peggedToken));
        IMinter(minter).redeemPeggedToken(1000 ether, address(this), 0);

        vm.expectRevert(IMinter.ActionPaused.selector);
        IMinter(minter).mintPeggedToken(1 ether, address(this), 0);

        vm.expectRevert(IMinter.ActionPaused.selector);
        IMinter(minter).mintLeveragedToken(1 ether, address(this), 0);
    }
}

contract TestMinterDepeg is TestMinterFeeSetUp {
    function setUp() public virtual override(TestMinterFeeSetUp) {
        super.setUp();
        setUp_collateral(10 ether, 10 ether);
        deal(address(collateralToken), address(this), 100 ether);
        IERC20(collateralToken).approve(minter, type(uint256).max);
        deal(address(peggedToken), address(this), 5000 ether);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        deal(address(leveragedToken), address(this), 5000 ether);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
    }

    function test_leveraged() public {
        // go depegged
        priceOracle.setLatestAnswer(500 ether);
        vm.expectRevert(IMinter.ActionPaused.selector);
        IMinter(minter).mintLeveragedToken(1 ether, address(this), 0);

        vm.expectRevert(IMinter.ActionPaused.selector);
        IMinter(minter).redeemLeveragedToken(1000 ether, address(this), 0);

        // actually re-pegged but on the border where there be zero divides
        priceOracle.setLatestAnswer(1000 ether);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, leveragedToken));
        IMinter(minter).mintLeveragedToken(1 ether, address(this), 0);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, collateralToken));
        IMinter(minter).redeemLeveragedToken(1000 ether, address(this), 0);
    }
}
