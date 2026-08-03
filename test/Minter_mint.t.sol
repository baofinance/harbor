// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

import "@harbor-test/Useful.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

contract TestMinterMint is TestMinterSetUp {
    using SafeERC20 for IERC20;

    address system;
    address sender;
    address receiver;

    function setUpConfig() internal virtual override {
        setUp_config_basicWithDisallow();
    }

    function setUp() public virtual override {
        super.setUp();
        system = makeAddr("system");
        sender = makeAddr("sender");
        receiver = makeAddr("receiver");
    }
}

contract TestMinterMintMechanics is TestMinterMint {
    function setUp() public virtual override {
        super.setUp();

        deal(wrappedCollateralToken, sender, 10 ether);
        vm.prank(sender);
        IERC20(wrappedCollateralToken).approve(minter, 10 ether);

        // (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(3 ether, 1 ether); // CR = 4/3 = 1.33

        int256 incentiveRatio = IMinter(minter).mintLeveragedTokenIncentiveRatio();
        assertEq(incentiveRatio, 70e14, "incentive ratio wrong");
    }

    function test_freeLeveragedMechanics() public {
        // single band, no disallow (just depegged)
        setUp_config(
            ic(ua(100), ia(100, 50)),
            ic(ua(100), ia(40, 80)),
            ic(ua(100), ia(35, 70)),
            ic(ua(100), ia(240, 120))
        );
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        deal(wrappedCollateralToken, zeroFee, 10 ether);
        vm.prank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 10 ether);

        // how much can I get for 2 eth
        (, uint256 fee2, , , uint256 leveragedFor2, uint256 price, ) = IMinter(minter).mintLeveragedTokenDryRun(
            2 ether
        );
        leveragedFor2 += (fee2 * price) / 1 ether;
        (, uint256 fee1a, , , uint256 leveragedFor1a, , ) = IMinter(minter).mintLeveragedTokenDryRun(1 ether);
        leveragedFor1a += (fee1a * price) / 1 ether;
        // uint256 leveragedFor2 = IMinter(minter).leveragedTokensForCollateral(2 ether);
        // uint256 leveragedFor1a = IMinter(minter).leveragedTokensForCollateral(1 ether);

        uint256 leveragedPrice = IMinter(minter).leveragedTokenPrice();
        vm.prank(zeroFee);
        uint256 actualMinted1a = IMinter(minter).freeMintLeveragedToken(1 ether, receiver);
        assertEq(leveragedPrice, IMinter(minter).leveragedTokenPrice(), "leveraged price doesn't change");

        assertEq(actualMinted1a, leveragedFor1a, "actual minted is as predicted");

        // uint256 leveragedFor1b = IMinter(minter).leveragedTokensForCollateral(1 ether);
        (, uint256 fee1b, , , uint256 leveragedFor1b, , ) = IMinter(minter).mintLeveragedTokenDryRun(1 ether);
        leveragedFor1b += (fee1b * price) / 1 ether;
        assertEq(leveragedFor1a + leveragedFor1b, leveragedFor2, "1 + 1 = 2");
    }

    function _mintLeveraged(uint256 collateral) private {
        int256 incentiveRatio;
        uint256 fee;
        uint256 leveragedExpected;
        (incentiveRatio, fee, , , leveragedExpected, , ) = IMinter(minter).mintLeveragedTokenDryRun(collateral);

        // check that the fees match the reported value, both emit and that transferred
        uint256 feeReceiverCollateralBalanceBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        // uint256 leveragedCalculated = IMinter(minter).leveragedTokensForCollateral(collateral - fee);
        vm.expectEmit(true, true, true, false, minter);
        emit IMinter.MintLeveragedToken(sender, sender, collateral, 0);
        // console2.log("expected leveraged minted=%s", leveragedCalculated);
        vm.prank(sender);
        uint256 leveragedMinted = IMinter(minter).mintLeveragedToken(collateral, sender, 0);
        // 1 ----------------------------------------------------------------------------
        assertEq(leveragedMinted, leveragedExpected, "mint vs dry run matches");
        assertEq(IERC20(Deployed.wstETH).balanceOf(feeReceiver), feeReceiverCollateralBalanceBefore + fee);
    }

    function test_mintLeveraged1Band() public {
        setUp_config(
            ic(ua(100), ia(100, 50)),
            ic(ua(100), ia(40, 80)),
            ic(ua(100), ia(35, 70)),
            ic(ua(100), ia(240, 120))
        );
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        _mintLeveraged(1 ether);
        // assertTrue(false);
    }

    function test_mintLeveraged1Band2Mints() public {
        setUp_config(
            ic(ua(100), ia(100, 50)),
            ic(ua(100), ia(40, 80)),
            ic(ua(100), ia(35, 70)),
            ic(ua(100), ia(240, 120))
        );
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // this should do the same as the 2BandSameLevel (the number below was taken from its logs)
        uint256 collateralIfWeHadABoundary140 = 201409869083585095;
        // expect emit MintLeveragedToken(sender: sender: [0xCD1722F3947DEf4Cf144679Da39c4c32BDC35681], receiver: sender: [0xCD1722F3947DEf4Cf144679Da39c4c32BDC35681], collateralIn: 201409869083585095 [2.014e17], leveragedOut: 400000000000000002000 [4e20])
        // actual emit MintLeveragedToken(sender: sender: [0xCD1722F3947DEf4Cf144679Da39c4c32BDC35681], receiver: sender: [0xCD1722F3947DEf4Cf144679Da39c4c32BDC35681], collateralIn: 201409869083585095 [2.014e17], leveragedOut: 400000000000000000000 [4e20])
        _mintLeveraged(collateralIfWeHadABoundary140);
        _mintLeveraged(1 ether - collateralIfWeHadABoundary140);
        // assertTrue(false);
    }

    function test_mintLeveraged2Band() public {
        // collateral ratio already at 4/3 = 1.33
        setUp_config(
            ic(ua(100), ia(100, 50)),
            ic(ua(100), ia(40, 80)),
            ic(ua(100, 140), ia(35, 70, 100)), // <--
            ic(ua(100), ia(240, 120))
        );
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // mint 1 ether, we get CR = 5/3 = 1.66, so crosses the 140 boundary
        // expect emit MintLeveragedToken(sender: sender: [0xCD1722F3947DEf4Cf144679Da39c4c32BDC35681], receiver: sender: [0xCD1722F3947DEf4Cf144679Da39c4c32BDC35681], collateralIn: 1000000000000000000 [1e18], leveragedOut: 1981208459214501512000 [1.981e21])
        // actual emit MintLeveragedToken(sender: sender: [0xCD1722F3947DEf4Cf144679Da39c4c32BDC35681], receiver: sender: [0xCD1722F3947DEf4Cf144679Da39c4c32BDC35681], collateralIn: 1000000000000000000 [1e18], leveragedOut: 1755321536469572726717 [1.755e21])
        _mintLeveraged(1 ether);
    }

    function test_mintLeveraged2BandSameLevel() public {
        // collateral ratio already at 4/3 = 1.33
        setUp_config(
            ic(ua(100), ia(100, 50)),
            ic(ua(100), ia(40, 80)),
            ic(ua(100, 140), ia(35, 70, 70)), // <--
            ic(ua(100), ia(240, 120))
        );
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // mint 1 ether, we get CR = 5/3 = 1.66, so crosses the 140 boundary
        // expect emit MintLeveragedToken(sender: sender: [0xCD1722F3947DEf4Cf144679Da39c4c32BDC35681], receiver: sender: [0xCD1722F3947DEf4Cf144679Da39c4c32BDC35681], collateralIn: 1000000000000000000 [1e18], leveragedOut: 1986000000000000002000 [1.986e21])
        // actual emit MintLeveragedToken(sender: sender: [0xCD1722F3947DEf4Cf144679Da39c4c32BDC35681], receiver: sender: [0xCD1722F3947DEf4Cf144679Da39c4c32BDC35681], collateralIn: 1000000000000000000 [1e18], leveragedOut: 1759428571428571432433 [1.759e21])
        _mintLeveraged(1 ether);
    }
}

contract TestMinterOverflow is TestMinterMint {
    uint256 amount = 1e31; // 100T
    uint256 collateralFor100T;

    function setUpConfig() internal virtual override {
        setUp_config(ic(ua(100), ia(0, 0)), ic(ua(100), ia(0, 0)), ic(ua(100), ia(0, 0)), ic(ua(100), ia(0, 0)));
    }

    function setUp() public virtual override {
        super.setUp();
        // simple no disallow, etc. fee structure
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        collateralFor100T = (amount * 1 ether) / price; // 100T pegged
        setUp_collateral(collateralFor100T, collateralFor100T); // CR=2

        deal(address(Deployed.wstETH), address(this), amount * 10);
        IERC20(Deployed.wstETH).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
    }

    function test_mintPeggedOverflow() public {
        uint256 minted1 = IMinter(minter).mintPeggedToken(1 ether, address(this), 0);
        uint256 minted100T = IMinter(minter).mintPeggedToken(collateralFor100T, address(this), 0);

        uint256 returned100T = IMinter(minter).redeemPeggedToken(minted100T, address(this), 0);
        assertEq(returned100T, collateralFor100T, "returned 100T");
        uint256 returned1 = IMinter(minter).redeemPeggedToken(minted1, address(this), 0);
        assertEq(returned1, 1 ether, "returned 1");
    }

    function test_mintLeveragedOverflow() public {
        uint256 minted1 = IMinter(minter).mintLeveragedToken(1 ether, address(this), 0);
        uint256 minted100T = IMinter(minter).mintLeveragedToken(collateralFor100T, address(this), 0);

        uint256 returned100T = IMinter(minter).redeemLeveragedToken(minted100T, address(this), 0);
        assertEq(returned100T, collateralFor100T, "returned 100T");
        uint256 returned1 = IMinter(minter).redeemLeveragedToken(minted1, address(this), 0);
        assertEq(returned1, 1 ether, "returned 1");
    }
}

/// @notice A mint must never take collateral and hand back nothing.
/// @dev The minter floors the pegged tokens it mints, so a mint small enough to buy less than one whole
///      pegged token yields zero — while the collateral and the fee for it are still consumed. At a
///      collateral price of 1e-9 pegged per token that is any mint under about a billion wei, which is
///      what these tests use. Redeeming pegged, minting leveraged and redeeming leveraged all already
///      refuse this with ReturnZeroAmount; minting pegged is held to the same rule.
contract TestMinterMintZeroOutput is TestMinterMint {
    uint256 constant COLLATERAL_PRICE = 1e9; // 1e-9 pegged tokens per collateral token
    uint256 constant DUST = 1e9; // buys 0.995 pegged after the 0.5% fee, so floors to zero

    function setUpConfig() internal virtual override {
        // flat 0.5% on every action: no bands to cross and no disallow, so the only thing that can
        // stop this mint is the zero-output rule under test
        setUp_config(
            ic(ua(100), ia(50, 50)),
            ic(ua(100), ia(50, 50)),
            ic(ua(100), ia(50, 50)),
            ic(ua(100), ia(50, 50))
        );
    }

    function setUp() public virtual override {
        super.setUp();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(COLLATERAL_PRICE, 1 ether);
        setUp_collateral(100 ether, 100 ether); // collateral ratio 2, far above the peg
        deal(wrappedCollateralToken, sender, 10 ether);
        vm.startPrank(sender);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        vm.stopPrank();
    }

    function test_mintPegged_revertsWhenOutputRoundsToZero() public {
        (, , uint256 collateralUsed, uint256 peggedOut, , ) = IMinter(minter).mintPeggedTokenDryRun(DUST);
        assertGt(collateralUsed, 0, "precondition: this mint would consume collateral");
        assertEq(peggedOut, 0, "precondition: this mint would yield no pegged tokens");

        uint256 senderWrapped = IERC20(wrappedCollateralToken).balanceOf(sender);
        uint256 minterWrapped = IERC20(wrappedCollateralToken).balanceOf(minter);
        uint256 feeWrapped = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, peggedToken));
        IMinter(minter).mintPeggedToken(DUST, sender, 0);
        vm.stopPrank();

        assertEq(IERC20(wrappedCollateralToken).balanceOf(sender), senderWrapped, "sender keeps their collateral");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(minter), minterWrapped, "minter takes nothing");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(feeReceiver), feeWrapped, "no fee is charged");
    }

    /// @dev The guard rejects only what rounds away: the smallest mint that does buy a whole pegged
    ///      token still succeeds.
    function test_mintPegged_succeedsAtExactlyOnePeggedToken() public {
        uint256 wrapped = DUST + DUST / 100; // 1.005 pegged before flooring
        (, , , uint256 peggedOut, , ) = IMinter(minter).mintPeggedTokenDryRun(wrapped);
        assertEq(peggedOut, 1, "precondition: this mint buys exactly one pegged token");

        vm.startPrank(sender);
        uint256 minted = IMinter(minter).mintPeggedToken(wrapped, sender, 0);
        vm.stopPrank();

        assertEq(minted, 1, "one whole pegged token is minted");
        assertEq(IERC20(peggedToken).balanceOf(sender), 1, "and delivered to the caller");
    }

    /// @dev The capped variant reports "cannot do this" by returning zero rather than reverting, which
    ///      is what its callers rely on. Nothing is consumed either way.
    function test_mintPegged_cappedReturnsZeroWhenOutputRoundsToZero() public {
        uint256 senderWrapped = IERC20(wrappedCollateralToken).balanceOf(sender);
        uint256 minterWrapped = IERC20(wrappedCollateralToken).balanceOf(minter);

        vm.startPrank(sender);
        // a 100% fee cap cannot bind, so only the zero-output rule can stop this
        (uint256 peggedOut, uint256 collateralUsed) = IMinter_v3(minter).mintPeggedToken(DUST, sender, 0, 1 ether);
        vm.stopPrank();

        assertEq(peggedOut, 0, "no pegged tokens minted");
        assertEq(collateralUsed, 0, "and no collateral reported as used");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(sender), senderWrapped, "sender keeps their collateral");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(minter), minterWrapped, "minter takes nothing");
    }
}

/// @notice The input-side and output-side zero cases stay distinguishable.
/// @dev MintZeroAmount means the config forbids minting at this collateral ratio, so nothing can be
///      taken at all; ReturnZeroAmount means collateral could be taken but would buy no whole token.
///      Reporting both as one error would lose which of the two actually happened.
contract TestMinterMintZeroOutputDisallowed is TestMinterMint {
    function setUp() public virtual override {
        super.setUp();
        // basicWithDisallow forbids minting pegged below a collateral ratio of 1.31
        setUp_collateral(100 ether, 20 ether); // collateral ratio 1.2
        deal(wrappedCollateralToken, sender, 10 ether);
        vm.startPrank(sender);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        vm.stopPrank();
    }

    function test_mintPegged_revertsMintZeroAmountWhenDisallowed() public {
        assertLt(IMinter(minter).collateralRatio(), 1.31 ether, "precondition: minting pegged is disallowed here");

        vm.startPrank(sender);
        vm.expectRevert(abi.encodeWithSelector(IMinter.MintZeroAmount.selector, peggedToken));
        IMinter(minter).mintPeggedToken(1 ether, sender, 0);
        vm.stopPrank();
    }
}
