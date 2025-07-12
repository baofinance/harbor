// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

//import { Test } from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";

import "test/Useful.sol";
import {TestMinterSetUp} from "test/Minter_base.t.sol";

// TODO: check what happens when safe price is invalid

contract TestMinterFeeSetUp is TestMinterSetUp {
    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public virtual override {
        super.setUp();
    }
}

contract TestMinterFees is TestMinterFeeSetUp {
    address user;

    function setUp() public virtual override(TestMinterFeeSetUp) {
        super.setUp();
        user = vm.createWallet("user").addr;
        deal(address(Deployed.wstETH), user, 100 ether);
        vm.prank(user);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);
    }

    function test_mintPeggedFeeCalcs() public {
        _assertEqIncentiveConfig(
            config.mintPeggedIncentiveConfig,
            ic(ua(130, 140), ia(disallow, 100, 50)),
            "mint pegged incentive config"
        );

        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
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
        (incentiveRatio, fee, collateralUsed, peggedMinted, , ) = IMinter(minter).mintPeggedTokenDryRun(collateral);
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
        uint256 feeReceiverCollateralBalanceBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        vm.expectEmit(minter);
        // emit IMinter.MintPeggedToken(user, user, collateral, peggedMinted);
        emit IMinter.MintPeggedToken(
            user,
            user,
            collateral,
            uint256((int256(price) * (int256(collateral) - expectedFees))) / 1 ether
        );
        vm.prank(user);
        uint256 minted = IMinter(minter).mintPeggedToken(collateral, user, 0);
        assertEq(minted, peggedMinted, "pegged minted");
        // assertEq(IERC20(Deployed.wstETH).balanceOf(feeReceiver), feeReceiverCollateralBalanceBefore + fee);
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver),
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

    function _checkMintPeggedIntegral(uint iTotalMint, uint step, uint tolerance) private returns (uint256 totalFee) {
        (, totalFee, , , , ) = IMinter(minter).mintPeggedTokenDryRun(iTotalMint * 1 ether);
        uint256 start = IERC20(Deployed.wstETH).balanceOf(feeReceiver);

        // TODO: we should check the reserve pool too
        for (uint i = 0; i < iTotalMint; i++) {
            uint256 beforeMint = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
            (, uint256 fee, , , , ) = IMinter(minter).mintPeggedTokenDryRun(1 ether);
            vm.prank(user);
            try IMinter(minter).mintPeggedToken(1 ether, user, 0) returns (uint256) {} catch {}
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver) - beforeMint,
                uint256(fee),
                2,
                string.concat(Useful.toString(i), "th iteration in step ", Useful.toString(step))
            );
        }
        assertApproxEqAbs(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver) - start,
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
        assertEq(IERC20(Deployed.wstETH).balanceOf(feeReceiver), 0, "no fees so far");

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
        uint256 collateralInSum = 0;
        for (uint i = 0; i < mintStep.length; i++) {
            uint step = i + 1;
            // clog("step(setup)", step);
            collateralInSum += (mintStep[i] * 1 ether);
            // clog("collateralInSum", collateralInSum);
            (, totalFees[i], maxCollaterals[i], , , ) = IMinter(minter).mintPeggedTokenDryRun(collateralInSum);
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

        uint256 totalFee = 0;
        for (uint i = 0; i < mintStep.length; i++) {
            uint step = i + 1;
            // clog("step(run)", step);
            totalFee += _checkMintPeggedIntegral(mintStep[i], step, step * 2);
            assertApproxEqAbs(totalFee, totalFees[i], step / 4, string.concat(Useful.toString(step), ", running sum"));
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver),
                totalFee,
                0,
                string.concat("step ", Useful.toString(step))
            );
        }
    }

    function test_mintLeveragedFeeCalcs() public {
        // ic(ua(100, 110, 120, 145), ia(-50, -50, 0, 20, 70)), // mint leveraged
        // TODO: start in critical 120, then go to danger 140, then normal
        // (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
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
        uint256 fee;
        uint256 leveragedExpected;
        (incentiveRatio, fee, , , leveragedExpected, , ) = IMinter(minter).mintLeveragedTokenDryRun(collateral);
        // console2.log("incentiveRatio=%s", incentiveRatio);
        // console2.log("fee=%s", fee);
        // console2.log("leveragedExpected=%s", leveragedExpected);
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
        (int256 incentiveRatioPlus, , , , , , ) = IMinter(minter).mintLeveragedTokenDryRun(collateral + 10 ** 16);
        assertGt(incentiveRatioPlus, incentiveRatio, "the more in normal the higher the fee");

        // check that the fees match the reported value, both emit and that transferred
        uint256 expectedFees = uint256(incentiveRatio * int256(collateral)) / 1 ether;
        // console2.log("expectedFees=%s", expectedFees);
        uint256 feeReceiverCollateralBalanceBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        uint256 leveragedCalculated = IMinter(minter).leveragedTokensForCollateral(collateral - expectedFees);
        vm.expectEmit(true, true, false, true, minter);
        // expected: emit MintLeveragedToken(sender: user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D], receiver: user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D],
        //                           collateralIn: 1000000000000000000 [1e18], leveragedOut: 1989507014028056114000 [1.989e21])
        // actual :  emit MintLeveragedToken(sender: user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D], receiver: user: [0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D],
        //                           collateralIn: 1000000000000000000 [1e18], leveragedOut: 1724020275845809267766 [1.724e21])
        emit IMinter.MintLeveragedToken(user, user, collateral, leveragedCalculated);
        // console2.log("expected leveraged minted=%s", leveragedCalculated);
        vm.prank(user);
        uint256 leveragedMinted = IMinter(minter).mintLeveragedToken(collateral, user, 0);
        // 1 ----------------------------------------------------------------------------
        assertEq(leveragedMinted, leveragedExpected, "mint vs dry run matches");
        assertEq(IERC20(Deployed.wstETH).balanceOf(feeReceiver), feeReceiverCollateralBalanceBefore + expectedFees);

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
    ) private returns (uint256 fee, uint256 discount, uint256 collateralUsed, uint256 leveragedMinted) {
        // console2.log("mintLeveragedTokenDryRun in step %s...", Useful.toString(step));
        (, fee, discount, collateralUsed, leveragedMinted, , ) = IMinter(minter).mintLeveragedTokenDryRun(
            iTotalMint * 1 ether
        );
        BeforeActionBalance memory beforeAll = _readBeforeActionBalance();
        Total memory all;
        for (uint i = 0; i < iTotalMint; i++) {
            BeforeActionBalance memory before = _readBeforeActionBalance();
            Total memory one;
            (, one.fee, one.discount, one.collateralUsed, one.leveragedMinted, , ) = IMinter(minter)
                .mintLeveragedTokenDryRun(1 ether);
            all.fee += one.fee;
            all.discount += one.discount;
            all.collateralUsed += one.collateralUsed;
            all.leveragedMinted += one.leveragedMinted;
            vm.prank(user);
            IMinter(minter).mintLeveragedToken(1 ether, user, 0);
            // ---------------------------------------------------
            // TODO: the below should handle reserve pool usage
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver) - before.feeReceiver,
                one.fee,
                0,
                string.concat("fee calc in ", Useful.toString(i), "th iteration in step ", Useful.toString(step))
            );
            assertApproxEqAbs(
                IERC20(leveragedToken).balanceOf(user) - before.userLeveraged,
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
                before.userCollateral - IERC20(Deployed.wstETH).balanceOf(user),
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
                before.reservePool - IERC20(Deployed.wstETH).balanceOf(reservePool),
                one.discount,
                "one: reserve pool has given up some collateral"
            );
        }
        assertApproxEqAbs(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver) - beforeAll.feeReceiver,
            fee,
            0,
            string.concat("fee calc in step ", Useful.toString(step))
        );
        assertApproxEqAbs(
            beforeAll.userCollateral - IERC20(Deployed.wstETH).balanceOf(user),
            collateralUsed,
            0,
            string.concat("collateral used calc in step", Useful.toString(step))
        );
        assertEq(all.leveragedMinted, leveragedMinted, "leveragedMinted: all = sigma one");
        assertApproxEqAbs(
            IERC20(leveragedToken).balanceOf(user) - beforeAll.userLeveraged,
            leveragedMinted,
            0,
            string.concat("leveraged minted calc in step ", Useful.toString(step))
        );
        assertEq(
            beforeAll.reservePool - IERC20(Deployed.wstETH).balanceOf(reservePool),
            discount,
            "all: reserve pool has given up some collateral"
        );
    }

    function _checkMintLeveragedFeesIntegralList() public {
        // ic(ua(100, 110, 120, 145), ia(-50, -50, 0, 20, 70)), // mint leveraged
        // critical CRs (upper bounds) = 110% (bonus, -50), 120% (free, 0), 140% (danger, 20), -> (70)
        setUp_collateral(150 ether, 10 ether); // CR = 160/150 = 106.6%, bonus
        assertGt(
            second(config.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds),
            IMinter(minter).collateralRatio(),
            "test must start with CR bonus"
        );
        assertEq(IERC20(Deployed.wstETH).balanceOf(feeReceiver), 0, "no fees so far");

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
            // console2.log("*** setup step %s", i + 1);
            collateralInSum += (mintStep[i] * 1 ether);
            // clog("collateralInSum", collateralInSum);
            (, totals[i].fee, totals[i].discount, totals[i].collateralUsed, totals[i].leveragedMinted, , ) = IMinter(
                minter
            ).mintLeveragedTokenDryRun(collateralInSum);
        }

        // TODO: also check for minter balances reducing
        deal(address(Deployed.wstETH), user, IMinter(minter).collateralTokenBalance());
        vm.prank(user);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);

        BeforeActionBalance memory before = _readBeforeActionBalance();

        Total memory total;
        for (uint i = 0; i < mintStep.length; i++) {
            // console2.log("*** run step %s", i + 1);
            (
                uint256 fee,
                uint256 discount,
                uint256 collateralUsed,
                uint256 leveragedMinted
            ) = _checkMintLeveragedIntegral(mintStep[i], i + 1);
            // console2.log("fee=%s", fee);
            total.collateralUsed += collateralUsed;
            total.leveragedMinted += leveragedMinted;
            total.fee += fee;
            total.discount += discount;
            // console2.log("total.fee=%s", total.fee);
            // console2.log("totals[%s].fee=%s", i, totals[i].fee);

            // fees and reserve collateral usage is netted and so we can't check this
            // assertApproxEqAbs(
            //     total.fee,
            //     totals[i].fee,
            //     0,
            //     string.concat("step ", Useful.toString(i + 1), ", calculated fee")
            // );
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver),
                total.fee,
                0,
                string.concat("step ", Useful.toString(i + 1), ", actual fee")
            );
            assertApproxEqAbs(
                IERC20(leveragedToken).balanceOf(user) - before.userLeveraged,
                total.leveragedMinted,
                0,
                string.concat("step ", Useful.toString(i + 1), ", actual minted")
            );
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(user),
                before.userCollateral - total.collateralUsed,
                0,
                string.concat("step ", Useful.toString(i + 1), ", actual used")
            );
            assertApproxEqAbs(
                before.reservePool - IERC20(Deployed.wstETH).balanceOf(reservePool),
                total.discount,
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
        deal(Deployed.wstETH, reservePool, 100 ether);
        _checkMintLeveragedFeesIntegralList();
    }

    /// forge-config: default.fuzz.runs = 50
    function test_mintLeveragedFeesAreIntegralWithPartialReserve(uint256 reserve) public {
        vm.assume(reserve < 24e15);
        // add to reserve pool
        deal(Deployed.wstETH, reservePool, reserve);
        _checkMintLeveragedFeesIntegralList();
        assertEq(IERC20(Deployed.wstETH).balanceOf(reservePool), 0, "reserve empty");
    }

    function _redeemPeggedFeeCalc(uint256 collateral) private returns (int256 redeemPeggedFeeRatio) {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        redeemPeggedFeeRatio = IMinter(minter).redeemPeggedTokenIncentiveRatio();
        assertEq(redeemPeggedFeeRatio, penultimate(config.redeemPeggedIncentiveConfig.incentiveRatios));

        uint256 pegged = (collateral * price) / 1 ether;
        uint256 expectedFees = (uint256(redeemPeggedFeeRatio) * collateral) / 1 ether;
        uint256 feeReceiverCollateralBalanceBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        assertGe(IERC20(peggedToken).balanceOf(owner), pegged);
        vm.prank(owner);
        IERC20(peggedToken).approve(minter, type(uint256).max);

        vm.expectEmit(true, true, true, true, minter);
        emit IMinter.RedeemPeggedToken(owner, user, pegged, collateral - expectedFees, 0);
        vm.prank(owner); // the owner has all the tokens
        IMinter(minter).redeemPeggedToken(pegged, user, 0);
        assertEq(IERC20(Deployed.wstETH).balanceOf(feeReceiver), feeReceiverCollateralBalanceBefore + expectedFees);
    }

    function test_redeemPeggedFeeCalcs() public {
        _assertEqIncentiveConfig(
            config.redeemPeggedIncentiveConfig,
            ic(ua(100, 105, 115, 150), ia(-75, -75, -25, 60, 80)),
            "redeem pegged incentive config"
        );
        // TODO: go depegged
        // TODO: start in critical 115, then go to danger 150, then normal
        // TODO: add bonus band in. Also in mintLeveraged
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(3 ether, 1 ether, owner); // CR = 4/3 = 1.33
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
        (redeemPeggedFeeRatio, , , , , , ) = IMinter(minter).redeemPeggedTokenDryRun(pegged);
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

        (int256 redeemPeggedFeeRatio2, , , , , , ) = IMinter(minter).redeemPeggedTokenDryRun(pegged + 10 ** 16);
        assertGt(redeemPeggedFeeRatio2, redeemPeggedFeeRatio, "the more in normal the higher the fee");

        // check that the fees match the reported value, both emit and that transferred
        uint256 expectedFees = (uint256(redeemPeggedFeeRatio) * collateral) / 1 ether;
        uint256 feeReceiverCollateralBalanceBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        assertGe(IERC20(peggedToken).balanceOf(owner), pegged);
        vm.prank(owner);
        IERC20(peggedToken).approve(minter, type(uint256).max);

        vm.expectEmit(minter);
        emit IMinter.RedeemPeggedToken(owner, user, pegged, collateral - expectedFees, 0); // 1
        vm.prank(owner); // the owner has all the tokens
        IMinter(minter).redeemPeggedToken(pegged, user, 0); // 2
        assertEq(IERC20(Deployed.wstETH).balanceOf(feeReceiver), feeReceiverCollateralBalanceBefore + expectedFees);

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
        before.feeReceiver = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        before.userCollateral = IERC20(Deployed.wstETH).balanceOf(user);
        before.userPegged = IERC20(peggedToken).balanceOf(user);
        before.userLeveraged = IERC20(leveragedToken).balanceOf(user);
        before.reservePool = IERC20(Deployed.wstETH).balanceOf(reservePool);
    }

    struct Total {
        uint256 peggedRedeemed;
        uint256 collateralReturned;
        uint256 leveragedMinted;
        uint256 collateralUsed;
        uint256 fee;
        uint256 discount;
    }

    function _checkRedeemPeggedIntegral(
        uint iTotalRedeem,
        uint step
    ) private returns (uint256 fee, uint256 discount, uint256 peggedRedeemed, uint256 collateralReturned) {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        (, fee, discount, peggedRedeemed, collateralReturned, , ) = IMinter(minter).redeemPeggedTokenDryRun(
            iTotalRedeem * price
        );
        BeforeActionBalance memory beforeAll = _readBeforeActionBalance();
        for (uint i = 0; i < iTotalRedeem; i++) {
            BeforeActionBalance memory before = _readBeforeActionBalance();
            Total memory one;
            (, one.fee, one.discount, one.peggedRedeemed, one.collateralReturned, , ) = IMinter(minter)
                .redeemPeggedTokenDryRun(price);
            vm.prank(user);
            IMinter(minter).redeemPeggedToken(price, user, 0);
            // ---------------------------------------------------
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver) - before.feeReceiver,
                one.fee,
                0,
                string.concat("fee calc in ", Useful.toString(i), "th iteration in step ", Useful.toString(step))
            );
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(user) - before.userCollateral,
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
                before.userPegged - IERC20(peggedToken).balanceOf(user),
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
                before.reservePool - IERC20(Deployed.wstETH).balanceOf(reservePool),
                one.discount,
                string.concat(
                    "redeemPegged one: reserve pool has given up some collateral in ",
                    Useful.toString(i),
                    "th iteration in step ",
                    Useful.toString(step)
                )
            );
        }
        assertApproxEqAbs(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver) - beforeAll.feeReceiver,
            fee,
            0,
            string.concat("fee calc in step ", Useful.toString(step))
        );
        assertApproxEqAbs(
            IERC20(Deployed.wstETH).balanceOf(user) - beforeAll.userCollateral,
            collateralReturned,
            0,
            string.concat("collateral returned calc in step ", Useful.toString(step))
        );
        assertApproxEqAbs(
            beforeAll.userPegged - IERC20(peggedToken).balanceOf(user),
            peggedRedeemed,
            0,
            string.concat("pegged redeemed calc in step ", Useful.toString(step))
        );
        assertEq(
            beforeAll.reservePool - IERC20(Deployed.wstETH).balanceOf(reservePool),
            discount,
            "redeemPegged all: reserve pool has given up some collateral"
        );
    }

    function _checkRedeemPeggedFeesIntegralList() private {
        // ic(ua(100, 105, 115, 150), ia(-75, -75, -25, 60, 80)), // redeem pegged
        // critical CRs = 105% (big bonus 75), 115% (small bonus 25), 150% (danger, 60), -> 80
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(100 ether, 4 ether); // CR = 104/100 = 104%, bonus
        assertGt(
            second(config.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds),
            IMinter(minter).collateralRatio(),
            "test must start with CR bonus"
        );
        assertEq(IERC20(Deployed.wstETH).balanceOf(feeReceiver), 0, "no fees so far");

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
            (, totals[i].fee, totals[i].discount, totals[i].peggedRedeemed, totals[i].collateralReturned, , ) = IMinter(
                minter
            ).redeemPeggedTokenDryRun((collateralInSum * price) / 1 ether);
        }

        // TODO: also check for minter balances reducing
        deal(address(peggedToken), user, IMinter(minter).peggedTokenBalance());
        vm.prank(user);
        IERC20(peggedToken).approve(minter, type(uint256).max);

        BeforeActionBalance memory before = _readBeforeActionBalance();

        Total memory total;
        for (uint i = 0; i < redeemStep.length; i++) {
            // clog("step(run)", i + 1);
            (
                uint256 fee,
                uint256 discount,
                uint256 peggedRedeemed,
                uint256 collateralReturned
            ) = _checkRedeemPeggedIntegral(redeemStep[i], i + 1);
            total.peggedRedeemed += peggedRedeemed;
            total.collateralReturned += collateralReturned;
            total.fee += fee;
            total.discount += discount;
            assertApproxEqAbs(
                total.fee,
                totals[i].fee,
                0,
                string.concat("step ", Useful.toString(i + 1), ", calculated fee")
            );
            assertApproxEqAbs(
                total.discount,
                totals[i].discount,
                0,
                string.concat("step ", Useful.toString(i + 1), ", calculated discount")
            );
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver),
                total.fee,
                0,
                string.concat("step ", Useful.toString(i + 1), ", actual fee")
            );
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(user) - before.userCollateral,
                total.collateralReturned,
                0,
                string.concat("step ", Useful.toString(i + 1), ", actual returned")
            );
            assertApproxEqAbs(
                IERC20(peggedToken).balanceOf(user),
                before.userPegged - total.peggedRedeemed,
                0,
                string.concat("step ", Useful.toString(i + 1), ", actual redemption")
            );
            assertApproxEqAbs(
                before.reservePool - IERC20(Deployed.wstETH).balanceOf(reservePool),
                total.discount,
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
        deal(Deployed.wstETH, reservePool, 100 ether);
        _checkRedeemPeggedFeesIntegralList();
    }

    /// forge-config: default.fuzz.runs = 50
    function test_redeemPeggedFeesAreIntegralsWithPartialReserve(uint256 reserve) public {
        vm.assume(reserve < 283e15);
        // add to reserve pool
        deal(Deployed.wstETH, reservePool, reserve);
        _checkRedeemPeggedFeesIntegralList();
        assertEq(IERC20(Deployed.wstETH).balanceOf(reservePool), 0, "reserve empty");
    }

    function test_redeemPeggedFeesAreIntegralsBoundary() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(10 ether, 4 ether); // CR = 14/10 = 140%

        deal(address(peggedToken), user, IMinter(minter).peggedTokenBalance());
        vm.startPrank(user);
        IERC20(peggedToken).approve(minter, type(uint256).max);

        uint lots = 3;
        (, uint256 totalFeeExpected, uint256 totalDiscountExpected, , , , ) = IMinter(minter).redeemPeggedTokenDryRun(
            lots * price
        );

        for (uint i = 0; i < lots; i++) {
            IMinter(minter).redeemPeggedToken(price, user, 0);
        }
        assertApproxEqAbs(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver),
            uint256(totalFeeExpected),
            0,
            "test total fee"
        );
        assertApproxEqAbs(
            IERC20(Deployed.wstETH).balanceOf(reservePool),
            uint256(totalDiscountExpected),
            0,
            "test total discount"
        );
        vm.stopPrank();
    }

    function _checkRedeemLeveragedIntegral(uint iTotalRedeem, uint step, uint tolerance) private returns (uint256 fee) {
        // bool log = true; // step == 6;
        // console2.log("_checkRedeemLeveragedIntegral(%s, %s)", iTotalRedeem, step);
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        // console2.log("------------------------------------------");
        (, fee, , , , ) = IMinter(minter).redeemLeveragedTokenDryRun(iTotalRedeem * price);
        // if (log) clog("  incentiveRatio", incentiveRatio);
        // if (log) clog("  expected fees", fee);
        uint256 start = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        // if (log) console2.log("  starting fees=%s", start);
        for (uint i = 0; i < iTotalRedeem; i++) {
            // console2.log("    step %s redeem %s of %s", step, i + 1, iTotalRedeem);
            uint256 beforeRedeem = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
            (, uint256 oneFee, , , , ) = IMinter(minter).redeemLeveragedTokenDryRun(price);
            // console2.log("oneFee=%s", oneFee);
            vm.prank(user);
            IMinter(minter).redeemLeveragedToken(price, user, 0);
            // if (log) clog("    fees this redeem", IERC20(Deployed.wstETH).balanceOf(feeReceiver) - beforeRedeem);
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver) - beforeRedeem,
                oneFee,
                2,
                string.concat(Useful.toString(i), "th iteration in step ", Useful.toString(step))
            );
            // if (log) clog("    extra fees received so far", IERC20(Deployed.wstETH).balanceOf(feeReceiver) - start);
        }
        // if (log) clog(" actual fees  ", IERC20(Deployed.wstETH).balanceOf(feeReceiver) - start);
        // clog(" all (pre-calc'd) ", fee);
        assertApproxEqAbs(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver) - start,
            fee,
            tolerance,
            Useful.toString(step)
        );
        // console2.log("_checkRedeemLeveragedIntegral() -> %s", fee);
    }

    function test_redeemLeveragedFeesAreIntegrals() public {
        // ic(ua(105, 135), ia(disallow, 150, 120)) // redeem leveraged
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(40 ether, 20 ether); // CR = 60/40 = 150%, normal
        assertLt(
            ultimate(config.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds),
            IMinter(minter).collateralRatio(),
            "test must start with CR nromal ml"
        );
        assertEq(IERC20(Deployed.wstETH).balanceOf(feeReceiver), 0, "no fees so far");

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
        uint256 collateralInSum = 0;
        for (uint i = 0; i < redeemStep.length; i++) {
            // clog("step(setup)", i + 1);
            collateralInSum += (redeemStep[i] * 1 ether);
            // clog("collateralInSum", collateralInSum);
            (, totalFees[i], , , , ) = IMinter(minter).redeemLeveragedTokenDryRun((collateralInSum * price) / 1 ether);
        }

        deal(leveragedToken, user, IMinter(minter).leveragedTokenBalance());
        vm.prank(user);
        IERC20(leveragedToken).approve(minter, type(uint256).max);

        uint256 fee = 0;
        for (uint i = 0; i < redeemStep.length; i++) {
            uint step = i + 1;
            // clog("step(run)", step);
            fee += _checkRedeemLeveragedIntegral(redeemStep[i], step, 0);
            assertApproxEqAbs(fee, totalFees[i], 0, string.concat(Useful.toString(step), ", running sum"));
            // TODO: should this check against the reserve pool balance?
            assertEq(fee, totalFees[i]);
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver),
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
        deal(address(wrappedCollateralToken), address(this), 100 ether);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        deal(address(peggedToken), address(this), 5000 ether);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        deal(address(leveragedToken), address(this), 5000 ether);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
    }

    function test_leveraged() public {
        // go depegged
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(500 ether);
        // vm.expectRevert(IMinter.ActionPaused.selector);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, leveragedToken));
        IMinter(minter).mintLeveragedToken(1 ether, address(this), 0);

        vm.expectRevert(IMinter.ActionPaused.selector);
        IMinter(minter).redeemLeveragedToken(1000 ether, address(this), 0);

        // actually re-pegged but on the border where there be zero divides
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1000 ether);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, leveragedToken));
        IMinter(minter).mintLeveragedToken(1 ether, address(this), 0);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, wrappedCollateralToken));
        IMinter(minter).redeemLeveragedToken(1000 ether, address(this), 0);
    }
}
