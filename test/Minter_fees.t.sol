// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import {LibString} from "@solady/utils/LibString.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

contract TestMinterFeeSetUp is TestMinterSetUp {
    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }
}

contract TestMinterFeeNoDisallow is TestMinterSetUp {
    function setUpConfig() internal virtual override {
        setUp_config_likelyNoDisallow();
    }

    function setUp() public virtual override {
        super.setUp();
        deal(address(Deployed.wstETH), address(this), 1 ether);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);
    }

    /// A retail pegged mint into the empty market reverts: it reads a ratio of exactly one, under the min CR, though
    /// the incentive config would allow it. Minted by the zero-fee route instead, the pegged redeems back in full.
    function test_minRedeemPegged() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        assertEq(IMinter(minter).peggedTokenBalance(), 0, "no pegged");

        bytes memory belowMinimum = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            1 ether,
            IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()
        );
        vm.expectRevert(belowMinimum);
        IMinter(minter).mintPeggedToken(1 ether, address(this), 0);

        (uint256 minted, ) = setUp_collateral(1 ether, 0, address(this));
        assertEq(minted, Math.mulDiv(1 ether, price, 1 ether), "some pegged minted, at the peg");
        assertEq(IMinter(minter).peggedTokenBalance(), minted, "some pegged");

        IERC20(peggedToken).approve(minter, type(uint256).max);
        IMinter(minter).redeemPeggedToken(minted, address(this), 0);
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "some pegged gone");
    }

    /// A leveraged supply first minted by the zero-fee route into the empty market - a token for each unit of value at
    /// the price - redeems in full, leaving none.
    function test_minRedeemLeveraged() public {
        // the high price, the one the leveraged mint reads
        (, uint256 price, , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertEq(IMinter(minter).leveragedTokenBalance(), 0, "no leveraged");

        setUp_collateral(0, 1 ether, address(this));
        assertGt(IMinter(minter).collateralRatio(), 1 ether, "CR > 1");
        uint256 minted = IERC20(leveragedToken).totalSupply();
        assertEq(minted, (1 ether * price) / 1e18, "some leveraged");

        IERC20(leveragedToken).approve(minter, type(uint256).max);
        IMinter(minter).redeemLeveragedToken(minted, address(this), 0);
        assertEq(IMinter(minter).leveragedTokenBalance(), 0, "some leveraged gone");
    }
}

contract TestMinterFees is TestMinterFeeSetUp {
    address user;

    function setUp() public virtual override {
        super.setUp();
        user = makeAddr("user");
        deal(address(Deployed.wstETH), user, 100 ether);
        vm.startPrank(user);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);
        vm.stopPrank();
    }

    /// The pegged mint's fee follows the collateral ratio: at 1.5 it is the normal band's; a mint that crosses into
    /// danger is priced between the two bands, the more so the further it goes, and pays exactly that ratio of its
    /// collateral; in danger the fee is danger's, and a mint that runs on into the disallowed band is priced at
    /// danger's ratio, to within the rounding of the figures the ratio is reported from.
    function test_mintPeggedFeeCalcs() public {
        _assertEqIncentiveConfig(
            config.mintPeggedIncentiveConfig,
            ic(ua(130, 140), ia(disallow, 100, 50)),
            "mint pegged incentive config"
        );

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
        int256 expectedFees$ = (incentiveRatio * int256(collateral));
        uint256 feeReceiverCollateralBalanceBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        vm.startPrank(user);
        vm.expectEmit(minter);
        emit IMinter.MintPeggedToken(user, user, collateral, peggedMinted);
        uint256 minted = IMinter(minter).mintPeggedToken(collateral, user, 0);
        vm.stopPrank();
        assertEq(minted, peggedMinted, "pegged minted");
        assertEq(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver),
            uint256(int256(feeReceiverCollateralBalanceBefore) + expectedFees$ / 1 ether)
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
        incentiveRatio = IMinter(minter).mintPeggedTokenIncentiveRatio();
        assertEq(
            incentiveRatio,
            penultimate(config.mintPeggedIncentiveConfig.incentiveRatios),
            "expected to be in danger"
        );
        // CR -> disallow but fee ratio is still danger: every wei the mint uses is priced in the danger band
        uint256 used;
        (incentiveRatio, , used, , , ) = IMinter(minter).mintPeggedTokenDryRun(3 ether);
        // The ratio reported is the fee over the collateral used - the fee rounded down, the collateral up and the
        // quotient down - so it never exceeds the band's ratio, and falls short of it by under (ratio + 1 ether) / used
        // for the two roundings of its parts plus a wei for the quotient's.
        int256 dangerRatio = penultimate(config.mintPeggedIncentiveConfig.incentiveRatios);
        assertLe(incentiveRatio, dangerRatio, "expected to still be in danger, never above its ratio");
        assertGe(
            incentiveRatio,
            dangerRatio - int256(Math.ceilDiv(uint256(dangerRatio) + 1 ether, used)),
            "expected to still be in danger, short of its ratio only by the rounding"
        );
    }

    /// @dev Mints `iTotalMint` ether a whole ether at a time, checking each mint's fee against its dry run and their
    ///      total against the dry run of the whole amount at once - both exactly. A dry run prices the mint its call
    ///      makes, on the same state. And at this suite's whole price and wrapped-to-underlying rate of one, a slice
    ///      inside one band pays a whole-wei fee and mints a whole number of pegged, each slice moving the next bound's
    ///      split by exactly the collateral it used: the slice that straddles a bound is cut where the one-shot walk
    ///      cuts it, so only its fee is rounded, and the one-shot mint's is rounded at the same point.
    function _checkMintPeggedIntegral(uint iTotalMint, uint step) private returns (uint256 totalFee) {
        (, totalFee, , , , ) = IMinter(minter).mintPeggedTokenDryRun(iTotalMint * 1 ether);
        uint256 start = IERC20(Deployed.wstETH).balanceOf(feeReceiver);

        for (uint i = 0; i < iTotalMint; i++) {
            uint256 beforeMint = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
            (, uint256 fee, , , , ) = IMinter(minter).mintPeggedTokenDryRun(1 ether);
            vm.startPrank(user);
            // A 1-ether mint fully inside the disallow band produces zero pegged and reverts MintZeroAmount - the
            // ONLY expected revert here (minPeggedOut is 0, so no slippage revert), and its dry run reports no fee
            // there, so the integral assertion below still holds. Any OTHER revert is unexpected and must surface,
            // not be swallowed as if the fee integral held.
            try IMinter(minter).mintPeggedToken(1 ether, user, 0) returns (uint256) {} catch (bytes memory reason) {
                if (bytes4(reason) != IMinter.MintZeroAmount.selector) {
                    assembly {
                        revert(add(reason, 0x20), mload(reason))
                    }
                }
            }
            vm.stopPrank();
            assertEq(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver) - beforeMint,
                uint256(fee),
                string.concat(LibString.toString(i), "th iteration in step ", LibString.toString(step))
            );
        }
        assertEq(IERC20(Deployed.wstETH).balanceOf(feeReceiver) - start, uint256(totalFee), LibString.toString(step));
    }

    /// A pegged mint's fee is the integral of the band rates over the collateral it adds: minted a whole ether at a
    /// time through every band to the edge of the disallowed one, and on into it, where nothing is taken, each slice
    /// pays its dry run's fee and each step the fee of the step minted at once, exactly; and the steps' fees add up to
    /// those of the whole run minted at once, to within the rounding derived below. Each step's collateral ratio is
    /// asserted, so the steps go where they are meant to.
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

        // check fees - each step's collateral, less its fee, joins the record and the pegged it buys the supply, so
        // from 28 over 18:
        uint[5] memory mintStep = [
            // 1) within the top band: mint(4), CR about 1.455
            uint(4),
            // 2) across the 1.40 boundary: mint(4), CR about 1.385
            uint(4),
            // 3) within the band below 1.40: mint(4), CR about 1.334
            uint(4),
            // 4) to the disallowed band's edge: mint(5), of which the mint takes about 3.45, CR = 1.30 exactly
            uint(5),
            // 5) inside the disallowed band: mint(4), every slice reverting MintZeroAmount, CR still 1.30
            uint(4)
        ];

        uint256[] memory maxCollaterals = new uint256[](mintStep.length);
        uint256[] memory totalFees = new uint256[](mintStep.length);
        uint256 collateralInSum = 0;
        for (uint i = 0; i < mintStep.length; i++) {
            uint step = i + 1;
            collateralInSum += (mintStep[i] * 1 ether);
            (, totalFees[i], maxCollaterals[i], , , ) = IMinter(minter).mintPeggedTokenDryRun(collateralInSum);
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
        BeforeActionBalance memory before = _readBeforeActionBalance();
        for (uint i = 0; i < mintStep.length; i++) {
            uint step = i + 1;
            totalFee += _checkMintPeggedIntegral(mintStep[i], step);
            // The steps' fees against the cumulative mint's, dry-run from the start: through step 3 they agree
            // exactly, as the slices within a step do. Step 2's straddling slice rounds its fee down and its pegged
            // down, leaving the record under a wei of collateral above and of pegged below the exact path; that moves
            // the disallow bound's split, crossed in step 4, by a few wei of collateral and its fee by under a wei. And
            // each step's fee is rounded down where the cumulative fee is rounded once - under a wei short for each
            // step whose fee is fractional, steps 2 and 4. So from step 4 they differ by at most two.
            assertApproxEqAbs(
                totalFee,
                totalFees[i],
                step < 4 ? 0 : 2,
                string.concat(LibString.toString(step), ", running sum")
            );
            assertEq(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver),
                totalFee,
                string.concat("step ", LibString.toString(step))
            );
            // The supply is what the user received, not the kept collateral at the price: the slice that meets the
            // disallowed band takes its collateral rounded up and mints its pegged rounded down.
            _assertStepCollateralRatio(
                step,
                before.backing + (before.userCollateral - IERC20(Deployed.wstETH).balanceOf(user)) - totalFee,
                before.peggedSupply + (IERC20(peggedToken).balanceOf(user) - before.userPegged)
            );
        }
    }

    /// The leveraged mint's fee follows the collateral ratio: in danger it is danger's; a mint that crosses into normal
    /// is priced between the two bands, the more so the further it goes, pays exactly that ratio of its collateral and
    /// mints, and emits, what its dry run forecasts; once in normal the fee is normal's.
    function test_mintLeveragedFeeCalcs() public {
        // ic(ua(100, 110, 120, 145), ia(-50, -50, 0, 20, 70)), // mint leveraged
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
        uint256 feeReceiverCollateralBalanceBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        vm.startPrank(user);
        vm.expectEmit(minter);
        emit IMinter.MintLeveragedToken(user, user, collateral, leveragedExpected);
        uint256 leveragedMinted = IMinter(minter).mintLeveragedToken(collateral, user, 0);
        vm.stopPrank();
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
    ) private returns (uint256 fee, uint256 subsidy, uint256 collateralUsed, uint256 leveragedMinted) {
        (, fee, subsidy, collateralUsed, leveragedMinted, , ) = IMinter(minter).mintLeveragedTokenDryRun(
            iTotalMint * 1 ether
        );
        BeforeActionBalance memory beforeAll = _readBeforeActionBalance();
        Total memory all;
        for (uint i = 0; i < iTotalMint; i++) {
            BeforeActionBalance memory before = _readBeforeActionBalance();
            Total memory one;
            (, one.fee, one.subsidy, one.collateralUsed, one.leveragedMinted, , ) = IMinter(minter)
                .mintLeveragedTokenDryRun(1 ether);
            all.fee += one.fee;
            all.subsidy += one.subsidy;
            all.collateralUsed += one.collateralUsed;
            all.leveragedMinted += one.leveragedMinted;
            vm.startPrank(user);
            IMinter(minter).mintLeveragedToken(1 ether, user, 0);
            vm.stopPrank();
            // ---------------------------------------------------
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver) - before.feeReceiver,
                one.fee,
                0,
                string.concat("fee calc in ", LibString.toString(i), "th iteration in step ", LibString.toString(step))
            );
            assertApproxEqAbs(
                IERC20(leveragedToken).balanceOf(user) - before.userLeveraged,
                one.leveragedMinted,
                0,
                string.concat(
                    "leveraged minted calc in ",
                    LibString.toString(i),
                    "th iteration in step ",
                    LibString.toString(step)
                )
            );
            assertApproxEqAbs(
                before.userCollateral - IERC20(Deployed.wstETH).balanceOf(user),
                one.collateralUsed,
                0,
                string.concat(
                    "collateral used calc in ",
                    LibString.toString(i),
                    "th iteration in step ",
                    LibString.toString(step)
                )
            );
            assertEq(
                before.reservePool - IERC20(Deployed.wstETH).balanceOf(reservePool),
                one.subsidy,
                "one: reserve pool has given up some collateral"
            );
        }
        assertApproxEqAbs(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver) - beforeAll.feeReceiver,
            fee,
            0,
            string.concat("fee calc in step ", LibString.toString(step))
        );
        assertApproxEqAbs(
            beforeAll.userCollateral - IERC20(Deployed.wstETH).balanceOf(user),
            collateralUsed,
            0,
            string.concat("collateral used calc in step", LibString.toString(step))
        );
        // Minting the whole amount in one call mints exactly what the sequential 1-ether mints do. A mint's tokens are
        // the collateral it credits, valued at the price, over the leveraged price; here each leveraged token is worth
        // exactly a pegged unit and the collateral price is a whole number of them, so every mint's tokens are a whole
        // number with nothing rounded away, and they leave the leveraged price exactly where it was for the next. The
        // collateral credited is the same either way: the fees, the subsidies and the collateral used are each checked
        // to the wei above and below.
        assertEq(all.leveragedMinted, leveragedMinted, "leveragedMinted: all = sigma one");
        assertEq(
            IERC20(leveragedToken).balanceOf(user) - beforeAll.userLeveraged,
            leveragedMinted,
            string.concat("leveraged minted calc in step ", LibString.toString(step))
        );
        assertEq(
            beforeAll.reservePool - IERC20(Deployed.wstETH).balanceOf(reservePool),
            subsidy,
            "all: reserve pool has given up some collateral"
        );
    }

    /// @dev Mints leveraged up through every band in seven steps, a whole ether at a time, checking each slice and each
    ///      step against its dry run, and each step's collateral ratio exactly, so the steps go where they are meant
    ///      to.
    function _checkMintLeveragedFeesIntegralList() public {
        // ic(ua(100, 110, 120, 145), ia(-50, -50, 0, 20, 70)), // mint leveraged
        // critical CRs (upper bounds) = 110% (bonus, -50), 120% (free, 0), 145% (danger, 20), -> (70)
        setUp_collateral(150 ether, 10 ether); // CR = 160/150 = 106.6%, bonus
        assertGt(
            second(config.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds),
            IMinter(minter).collateralRatio(),
            "test must start with CR bonus"
        );
        assertEq(IERC20(Deployed.wstETH).balanceOf(feeReceiver), 0, "no fees so far");

        // check fees - each step's collateral joins the record, less its fee and plus its subsidy, so from 160 over
        // 150, the fees and subsidies moving each ratio by under a thousandth:
        uint[7] memory mintStep = [
            // 1) within the subsidy band: mint(4), CR = 164/150 = 1.093
            uint(4),
            // 2) across the 1.10 boundary: mint(4), CR = 168/150 = 1.12
            uint(4),
            // 3) within the free band: mint(10), CR = 178/150 = 1.187
            uint(10),
            // 4) across the 1.20 boundary: mint(20), CR = 198/150 = 1.32
            uint(20),
            // 5) within the danger band: mint(10), CR = 208/150 = 1.387
            uint(10),
            // 6) still within the danger band: mint(5), CR = 213/150 = 1.42
            uint(5),
            // 7) across the 1.45 boundary: mint(5), CR = 218/150 = 1.453
            uint(5)
        ];

        Total[] memory totals = new Total[](mintStep.length);
        uint256 collateralInSum = 0;
        for (uint i = 0; i < mintStep.length; i++) {
            collateralInSum += (mintStep[i] * 1 ether);
            (, totals[i].fee, totals[i].subsidy, totals[i].collateralUsed, totals[i].leveragedMinted, , ) = IMinter(
                minter
            ).mintLeveragedTokenDryRun(collateralInSum);
        }

        deal(address(Deployed.wstETH), user, IMinter(minter).collateralTokenBalance());
        vm.startPrank(user);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);
        vm.stopPrank();

        BeforeActionBalance memory before = _readBeforeActionBalance();

        Total memory total;
        for (uint i = 0; i < mintStep.length; i++) {
            (
                uint256 fee,
                uint256 subsidy,
                uint256 collateralUsed,
                uint256 leveragedMinted
            ) = _checkMintLeveragedIntegral(mintStep[i], i + 1);
            total.collateralUsed += collateralUsed;
            total.leveragedMinted += leveragedMinted;
            total.fee += fee;
            total.subsidy += subsidy;
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver),
                total.fee,
                0,
                string.concat("step ", LibString.toString(i + 1), ", actual fee")
            );
            // Cumulative actual minted against the sum of the per-step one-call dry runs: each step is exact, so
            // their sum is.
            assertEq(
                IERC20(leveragedToken).balanceOf(user) - before.userLeveraged,
                total.leveragedMinted,
                string.concat("step ", LibString.toString(i + 1), ", actual minted")
            );
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(user),
                before.userCollateral - total.collateralUsed,
                0,
                string.concat("step ", LibString.toString(i + 1), ", actual used")
            );
            assertApproxEqAbs(
                before.reservePool - IERC20(Deployed.wstETH).balanceOf(reservePool),
                total.subsidy,
                0,
                string.concat("step ", LibString.toString(i + 1), ", actual reserve used")
            );
            _assertStepCollateralRatio(
                i + 1,
                before.backing + total.collateralUsed - total.fee + total.subsidy,
                before.peggedSupply
            );
        }
    }

    /// A leveraged mint's fee is the integral of the band rates over the collateral it adds, with no reserve to fund a
    /// subsidy: minted through every band a whole ether at a time, each slice and each step pays the fee, takes the
    /// collateral and mints the tokens its dry run forecasts.
    function test_mintLeveragedFeesAreIntegralOnlyFee() public {
        _checkMintLeveragedFeesIntegralList();
    }

    /// A leveraged mint's fees and subsidies are integrals of the band rates over the collateral it adds, with a
    /// reserve that funds every subsidy: each slice and each step pays and receives what its dry run forecasts.
    function test_mintLeveragedFeesAreIntegralWithReserve() public {
        // add to reserve pool
        deal(Deployed.wstETH, reservePool, 100 ether);
        _checkMintLeveragedFeesIntegralList();
    }

    /// The same integral with a reserve too small for every subsidy: the steps exhaust it, each slice and each step
    /// receiving what its dry run forecasts from what is left.
    /// forge-config: default.fuzz.runs = 50
    function test_mintLeveragedFeesAreIntegralWithPartialReserve(uint256 reserve) public {
        reserve = bound(reserve, 0, 24e15 - 1);
        // add to reserve pool
        deal(Deployed.wstETH, reservePool, reserve);
        _checkMintLeveragedFeesIntegralList();
        assertEq(IERC20(Deployed.wstETH).balanceOf(reservePool), 0, "reserve empty");
    }

    /// The pegged redemption's fee follows the collateral ratio: in danger it is danger's; a redemption that crosses
    /// into normal is priced between the two bands, the more so the further it goes, and pays exactly that ratio of
    /// the collateral it returns, as its event reports; once in normal the fee is normal's.
    function test_redeemPeggedFeeCalcs() public {
        _assertEqIncentiveConfig(
            config.redeemPeggedIncentiveConfig,
            ic(ua(100, 105, 115, 150), ia(-75, -75, -25, 60, 80)),
            "redeem pegged incentive config"
        );
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(3 ether, 1 ether, owner()); // CR = 4/3 = 1.33
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
        assertGe(IERC20(peggedToken).balanceOf(owner()), pegged);
        vm.startPrank(owner()); // the owner has all the tokens
        IERC20(peggedToken).approve(minter, type(uint256).max);

        vm.expectEmit(minter);
        emit IMinter.RedeemPeggedToken(owner(), user, pegged, collateral - expectedFees, 0); // 1
        IMinter(minter).redeemPeggedToken(pegged, user, 0); // 2
        vm.stopPrank();
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

    // to reduce stack space
    struct BeforeActionBalance {
        uint256 feeReceiver;
        uint256 userCollateral;
        uint256 userPegged;
        uint256 userLeveraged;
        uint256 reservePool;
        // the minter's record of its backing, and of the pegged it has issued
        uint256 backing;
        uint256 peggedSupply;
    }

    function _readBeforeActionBalance() private view returns (BeforeActionBalance memory before) {
        before.feeReceiver = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        before.userCollateral = IERC20(Deployed.wstETH).balanceOf(user);
        before.userPegged = IERC20(peggedToken).balanceOf(user);
        before.userLeveraged = IERC20(leveragedToken).balanceOf(user);
        before.reservePool = IERC20(Deployed.wstETH).balanceOf(reservePool);
        before.backing = IMinter(minter).collateralTokenBalance();
        before.peggedSupply = IMinter(minter).peggedTokenBalance();
    }

    /// @dev Asserts that a step of an integral test leaves exactly the collateral ratio it is meant to reach: the
    ///      record `backing` over the pegged supply `peggedSupply`, at the oracle's price - it quotes only one, so that
    ///      is also the mid price the ratio reads.
    function _assertStepCollateralRatio(uint256 step, uint256 backing, uint256 peggedSupply) private view {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        assertEq(
            IMinter(minter).collateralRatio(),
            Math.mulDiv(backing, price, peggedSupply),
            string.concat("step ", LibString.toString(step), " reaches the collateral ratio it is meant to")
        );
    }

    struct Total {
        uint256 peggedRedeemed;
        uint256 collateralReturned;
        uint256 leveragedMinted;
        uint256 collateralUsed;
        uint256 fee;
        uint256 subsidy;
    }

    function _checkRedeemPeggedIntegral(
        uint iTotalRedeem,
        uint step
    ) private returns (uint256 fee, uint256 subsidy, uint256 peggedRedeemed, uint256 collateralReturned) {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        (, fee, subsidy, peggedRedeemed, collateralReturned, , ) = IMinter(minter).redeemPeggedTokenDryRun(
            iTotalRedeem * price
        );
        BeforeActionBalance memory beforeAll = _readBeforeActionBalance();
        for (uint i = 0; i < iTotalRedeem; i++) {
            BeforeActionBalance memory before = _readBeforeActionBalance();
            Total memory one;
            (, one.fee, one.subsidy, one.peggedRedeemed, one.collateralReturned, , ) = IMinter(minter)
                .redeemPeggedTokenDryRun(price);
            vm.startPrank(user);
            IMinter(minter).redeemPeggedToken(price, user, 0);
            vm.stopPrank();
            // ---------------------------------------------------
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver) - before.feeReceiver,
                one.fee,
                0,
                string.concat("fee calc in ", LibString.toString(i), "th iteration in step ", LibString.toString(step))
            );
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(user) - before.userCollateral,
                one.collateralReturned,
                0,
                string.concat(
                    "collateral returned calc in ",
                    LibString.toString(i),
                    "th iteration in step ",
                    LibString.toString(step)
                )
            );
            assertApproxEqAbs(
                before.userPegged - IERC20(peggedToken).balanceOf(user),
                one.peggedRedeemed,
                0,
                string.concat(
                    "pegged redeemed calc in ",
                    LibString.toString(i),
                    "th iteration in step ",
                    LibString.toString(step)
                )
            );
            assertEq(
                before.reservePool - IERC20(Deployed.wstETH).balanceOf(reservePool),
                one.subsidy,
                string.concat(
                    "redeemPegged one: reserve pool has given up some collateral in ",
                    LibString.toString(i),
                    "th iteration in step ",
                    LibString.toString(step)
                )
            );
        }
        assertApproxEqAbs(
            IERC20(Deployed.wstETH).balanceOf(feeReceiver) - beforeAll.feeReceiver,
            fee,
            0,
            string.concat("fee calc in step ", LibString.toString(step))
        );
        assertApproxEqAbs(
            IERC20(Deployed.wstETH).balanceOf(user) - beforeAll.userCollateral,
            collateralReturned,
            0,
            string.concat("collateral returned calc in step ", LibString.toString(step))
        );
        assertApproxEqAbs(
            beforeAll.userPegged - IERC20(peggedToken).balanceOf(user),
            peggedRedeemed,
            0,
            string.concat("pegged redeemed calc in step ", LibString.toString(step))
        );
        assertEq(
            beforeAll.reservePool - IERC20(Deployed.wstETH).balanceOf(reservePool),
            subsidy,
            "redeemPegged all: reserve pool has given up some collateral"
        );
    }

    /// @dev Redeems pegged up through every band in seven steps, a collateral's worth at a time, checking each slice
    ///      and each step against its dry run, and each step's collateral ratio exactly, so the steps go where they
    ///      are meant to.
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

        // check fees - each step takes exactly its pegged's worth out of the record, whatever its fee and subsidy - the
        // fee comes out of that worth, the subsidy from the reserve - so from 104 over 100:
        uint[7] memory redeemStep = [
            // 1) within the first band: redeem(10), CR = 94/90 = 1.044
            uint(10),
            // 2) across the 1.05 boundary: redeem(30), CR = 64/60 = 1.067
            uint(30),
            // 3) within the second band: redeem(20), CR = 44/40 = 1.10
            uint(20),
            // 4) across the 1.15 boundary: redeem(20), CR = 24/20 = 1.20
            uint(20),
            // 5) within the third band: redeem(10), CR = 14/10 = 1.40
            uint(10),
            // 6) across the 1.50 boundary: redeem(3), CR = 11/7 = 1.571
            uint(3),
            // 7) within the top band: redeem(3), CR = 8/4 = 2.0
            uint(3)
        ];

        Total[] memory totals = new Total[](redeemStep.length);
        uint256 collateralInSum = 0;
        for (uint i = 0; i < redeemStep.length; i++) {
            collateralInSum += (redeemStep[i] * 1 ether);
            (, totals[i].fee, totals[i].subsidy, totals[i].peggedRedeemed, totals[i].collateralReturned, , ) = IMinter(
                minter
            ).redeemPeggedTokenDryRun((collateralInSum * price) / 1 ether);
        }

        deal(address(peggedToken), user, IMinter(minter).peggedTokenBalance());
        vm.startPrank(user);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        vm.stopPrank();

        BeforeActionBalance memory before = _readBeforeActionBalance();

        Total memory total;
        collateralInSum = 0;
        for (uint i = 0; i < redeemStep.length; i++) {
            (
                uint256 fee,
                uint256 subsidy,
                uint256 peggedRedeemed,
                uint256 collateralReturned
            ) = _checkRedeemPeggedIntegral(redeemStep[i], i + 1);
            total.peggedRedeemed += peggedRedeemed;
            total.collateralReturned += collateralReturned;
            total.fee += fee;
            total.subsidy += subsidy;
            assertApproxEqAbs(
                total.fee,
                totals[i].fee,
                0,
                string.concat("step ", LibString.toString(i + 1), ", calculated fee")
            );
            assertApproxEqAbs(
                total.subsidy,
                totals[i].subsidy,
                0,
                string.concat("step ", LibString.toString(i + 1), ", calculated subsidy")
            );
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver),
                total.fee,
                0,
                string.concat("step ", LibString.toString(i + 1), ", actual fee")
            );
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(user) - before.userCollateral,
                total.collateralReturned,
                0,
                string.concat("step ", LibString.toString(i + 1), ", actual returned")
            );
            assertApproxEqAbs(
                IERC20(peggedToken).balanceOf(user),
                before.userPegged - total.peggedRedeemed,
                0,
                string.concat("step ", LibString.toString(i + 1), ", actual redemption")
            );
            assertApproxEqAbs(
                before.reservePool - IERC20(Deployed.wstETH).balanceOf(reservePool),
                total.subsidy,
                0,
                string.concat("step ", LibString.toString(i + 1), ", actual reserve used")
            );
            collateralInSum += redeemStep[i] * 1 ether;
            _assertStepCollateralRatio(
                i + 1,
                before.backing - collateralInSum,
                before.peggedSupply - total.peggedRedeemed
            );
        }
    }

    /// A pegged redemption's fee is the integral of the band rates over the collateral it returns, with no reserve to
    /// fund a subsidy: redeemed through every band a collateral's worth at a time, each slice and each step pays,
    /// returns and burns what its dry run forecasts, and the steps add up to the cumulative dry runs, exactly.
    function test_redeemPeggedFeesAreIntegralsOnlyFee() public {
        _checkRedeemPeggedFeesIntegralList();
    }

    /// A pegged redemption's fees and subsidies are integrals of the band rates over the collateral it returns, with a
    /// reserve that funds every subsidy: each slice and each step pays and receives what its dry run forecasts, and the
    /// steps add up to the cumulative dry runs, exactly.
    function test_redeemPeggedFeesAreIntegralsWithReserve() public {
        // add to reserve pool
        deal(Deployed.wstETH, reservePool, 100 ether);
        _checkRedeemPeggedFeesIntegralList();
    }

    /// The same integral with a reserve too small for every subsidy: the steps exhaust it, each slice and each step
    /// receiving what its dry run forecasts from what is left.
    /// forge-config: default.fuzz.runs = 50
    function test_redeemPeggedFeesAreIntegralsWithPartialReserve(uint256 reserve) public {
        reserve = bound(reserve, 0, 283e15 - 1);
        // add to reserve pool
        deal(Deployed.wstETH, reservePool, reserve);
        _checkRedeemPeggedFeesIntegralList();
        assertEq(IERC20(Deployed.wstETH).balanceOf(reservePool), 0, "reserve empty");
    }

    /// From a collateral ratio of 1.4, three redemptions of a collateral's worth each, crossing into the normal band,
    /// pay in fees exactly what one redemption of all three would.
    function test_redeemPeggedFeesAreIntegralsBoundary() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(10 ether, 4 ether); // CR = 14/10 = 140%

        deal(address(peggedToken), user, IMinter(minter).peggedTokenBalance());
        vm.startPrank(user);
        IERC20(peggedToken).approve(minter, type(uint256).max);

        uint lots = 3;
        (, uint256 totalFeeExpected, uint256 totalSubsidyExpected, , , , ) = IMinter(minter).redeemPeggedTokenDryRun(
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
            uint256(totalSubsidyExpected),
            0,
            "test total subsidy"
        );
        vm.stopPrank();
    }

    /// @dev Redeems `iTotalRedeem` collateral's worth of leveraged a collateral's worth at a time, checking each
    ///      redemption's fee against its dry run - which prices the redemption its call makes, on the same state - and
    ///      their total against the dry run of the whole amount at once, both exactly.
    function _checkRedeemLeveragedIntegral(uint iTotalRedeem, uint step) private returns (uint256 fee) {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        (, fee, , , , ) = IMinter(minter).redeemLeveragedTokenDryRun(iTotalRedeem * price);
        uint256 start = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        for (uint i = 0; i < iTotalRedeem; i++) {
            uint256 beforeRedeem = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
            (, uint256 oneFee, , , , ) = IMinter(minter).redeemLeveragedTokenDryRun(price);
            vm.startPrank(user);
            IMinter(minter).redeemLeveragedToken(price, user, 0);
            vm.stopPrank();
            assertEq(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver) - beforeRedeem,
                oneFee,
                string.concat(LibString.toString(i), "th iteration in step ", LibString.toString(step))
            );
        }
        assertEq(IERC20(Deployed.wstETH).balanceOf(feeReceiver) - start, fee, LibString.toString(step));
    }

    /// A leveraged redemption's fee is the integral of the band rates over the collateral it takes out: redeemed down
    /// through both of its fee bands to the edge of the disallowed one, a collateral's worth at a time, each slice pays
    /// its dry run's fee, each step the fee of the step redeemed at once, and the steps add up to the cumulative dry
    /// runs, exactly. Each step's collateral ratio is asserted, so the steps go where they are meant to.
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

        // check fees - each step takes its whole claim out of the record, the fee with it, so from 60 over 40:
        uint[5] memory redeemStep = [
            // 1) within the top band: redeem(4), CR = 56/40 = 1.40
            uint(4),
            // 2) across the 1.35 boundary: redeem(4), CR = 52/40 = 1.30
            uint(4),
            // 3) within the lower band: redeem(4), CR = 48/40 = 1.20
            uint(4),
            // 4) within the lower band: redeem(5), CR = 43/40 = 1.075
            uint(5),
            // 5) down to the disallowed band's edge: redeem(1), CR = 42/40 = 1.05
            uint(1)
        ];

        uint256[] memory totalFees = new uint256[](redeemStep.length);
        uint256 collateralInSum = 0;
        for (uint i = 0; i < redeemStep.length; i++) {
            collateralInSum += (redeemStep[i] * 1 ether);
            (, totalFees[i], , , , ) = IMinter(minter).redeemLeveragedTokenDryRun((collateralInSum * price) / 1 ether);
        }

        deal(leveragedToken, user, IMinter(minter).leveragedTokenBalance());
        vm.startPrank(user);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        vm.stopPrank();

        // A collateral's worth of leveraged, at a leveraged price of exactly one pegged, claims exactly one collateral,
        // so the record falls by exactly what each step redeems and every step's ratio is exact.
        uint256 backing = IMinter(minter).collateralTokenBalance();
        uint256 peggedSupply = IMinter(minter).peggedTokenBalance();
        uint256 fee = 0;
        collateralInSum = 0;
        for (uint i = 0; i < redeemStep.length; i++) {
            uint step = i + 1;
            fee += _checkRedeemLeveragedIntegral(redeemStep[i], step);
            assertEq(fee, totalFees[i], string.concat(LibString.toString(step), ", running sum"));
            assertApproxEqAbs(
                IERC20(Deployed.wstETH).balanceOf(feeReceiver),
                totalFees[i],
                0,
                string.concat("step ", LibString.toString(step))
            );
            collateralInSum += redeemStep[i] * 1 ether;
            _assertStepCollateralRatio(step, backing - collateralInSum, peggedSupply);
        }
    }
}

contract TestMinterNoneMinted is TestMinterFeeSetUp {
    function setUp() public virtual override {
        super.setUp();
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
    }
    function setUpConfig() internal virtual override {
        setUp_config_feeIsCR();
    }

    /// A market that has minted nothing has nothing to redeem, and reads a ratio of exactly one, under the min CR, so
    /// retail mints of either token revert though the incentive config allows them. The zero-fee mints open it: the
    /// pegged half at the peg, then the leveraged half, judged on the market it leaves, holding the whole residual
    /// after its deposit.
    function test_all() public {
        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        IMinter(minter).redeemLeveragedToken(1000 ether, address(this), 0);

        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, peggedToken));
        IMinter(minter).redeemPeggedToken(1000 ether, address(this), 0);

        assertEq(IMinter(minter).collateralRatio(), 1 ether, "an empty market reads exactly one");
        bytes memory belowMinimum = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            1 ether,
            IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()
        );
        vm.expectRevert(belowMinimum);
        IMinter(minter).mintPeggedToken(1 ether, address(this), 0);
        vm.expectRevert(belowMinimum);
        IMinter(minter).mintLeveragedToken(1 ether, address(this), 0);

        // the pegged mint reads the low price, the leveraged mint the high
        (uint256 minPrice, uint256 maxPrice, , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        deal(wrappedCollateralToken, zeroFee, 2 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 2 ether);
        uint256 minted = IMinter(minter).freeMintPeggedToken(1 ether, zeroFee);
        assertEq(minted, Math.mulDiv(1 ether, minPrice, 1 ether), "the pegged half, at the peg");
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "the pegged half leaves the market exactly at the peg");
        uint256 leveragedMinted = IMinter(minter).freeMintLeveragedToken(1 ether, zeroFee);
        vm.stopPrank();

        assertEq(
            leveragedMinted,
            Math.mulDiv(IMinter(minter).collateralTokenBalance(), maxPrice, 1 ether) -
                IMinter(minter).peggedTokenBalance(),
            "the leveraged half holds the whole residual after its deposit"
        );
        assertEq(IMinter(minter).collateralRatio(), 2 ether, "and leaves the market at two");
    }
}

contract TestMinterDepeg is TestMinterFeeSetUp {
    function setUp() public virtual override {
        super.setUp();
        setUp_collateral(10 ether, 10 ether);
        deal(address(wrappedCollateralToken), address(this), 100 ether);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        deal(address(peggedToken), address(this), 5000 ether);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        deal(address(leveragedToken), address(this), 5000 ether);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
    }

    /// Below the leverage floor a leveraged mint is refused by name, deep below the peg and at it alike, and with no
    /// residual left a leveraged redemption has nothing to return.
    function test_leveraged() public {
        uint256 floor = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();
        // go depegged: below the floor the mint is refused by name, before anything is priced
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(500 ether);
        uint256 ratio = IMinter(minter).collateralRatio();
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, floor));
        IMinter(minter).mintLeveragedToken(1 ether, address(this), 0);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, wrappedCollateralToken));
        IMinter(minter).redeemLeveragedToken(1000 ether, address(this), 0);

        // actually re-pegged but on the border where there be zero divides - and still below the floor
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1000 ether);
        ratio = IMinter(minter).collateralRatio();
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, floor));
        IMinter(minter).mintLeveragedToken(1 ether, address(this), 0);

        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, wrappedCollateralToken));
        IMinter(minter).redeemLeveragedToken(1000 ether, address(this), 0);
    }
}

contract TestMinterLargeMintAndRedeem is TestMinterFeeSetUp {
    uint256 price;

    function setUpConfig() internal virtual override {
        setUp_config_flat();
    }

    function setUp() public virtual override {
        super.setUp();
        (price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        deal(address(wrappedCollateralToken), address(this), 1_000_000_000_000 ether);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
    }

    /// Across pegged and leveraged supplies and deposits from a billionth of a token to a trillion tokens, a pegged
    /// mint and a leveraged mint each either redeem back or, where the min CR does not allow them, revert by name.
    function test_mintPeggedLargeDeposit() public {
        uint256 amount = 1_000_000_000_000 ether;
        uint256 snap = vm.snapshotState();

        for (uint256 p = 1e9; p < amount; p += amount / 10) {
            for (uint256 l = 1e9; l < amount; l += amount / 10) {
                for (uint256 d = 1e9; d < amount; d += amount / 10) {
                    setUp_collateral(p, l);
                    uint256 snap2 = vm.snapshotState();
                    uint256 minted;
                    // A pegged deposit dwarfing the leveraged one leaves the ratio at or under the min CR, where a
                    // pegged mint reverts by name; above it the mint is served - cut at the min CR if it is large -
                    // and redeems back.
                    uint256 ratio = IMinter(minter).collateralRatio();
                    if (ratio > IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()) {
                        minted = IMinter(minter).mintPeggedToken(d, address(this), 0);
                        IMinter(minter).redeemPeggedToken(minted, address(this), 0);
                    } else {
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                IMinter_v3.BelowMinimumCollateralRatio.selector,
                                ratio,
                                IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()
                            )
                        );
                        IMinter(minter).mintPeggedToken(d, address(this), 0);
                    }
                    vm.revertToState(snap2);

                    // A leveraged deposit dwarfed by the pegged one leaves the ratio at the peg, below the
                    // floor at which leverage is sold: refused by name, and nothing to redeem back.
                    if (IMinter_v3(minter).leveragedMintable()) {
                        minted = IMinter(minter).mintLeveragedToken(d, address(this), 0);
                        IMinter(minter).redeemLeveragedToken(minted, address(this), 0);
                    } else {
                        vm.expectRevert(
                            abi.encodeWithSelector(
                                IMinter_v3.BelowMinimumCollateralRatio.selector,
                                IMinter(minter).collateralRatio(),
                                IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()
                            )
                        );
                        IMinter(minter).mintLeveragedToken(d, address(this), 0);
                    }

                    vm.revertToState(snap);
                }
            }
        }
    }
}
