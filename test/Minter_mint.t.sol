// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

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
        vm.startPrank(sender);
        IERC20(wrappedCollateralToken).approve(minter, 10 ether);
        vm.stopPrank();

        setUp_collateral(3 ether, 1 ether); // CR = 4/3 = 1.33

        int256 incentiveRatio = IMinter(minter).mintLeveragedTokenIncentiveRatio();
        assertEq(incentiveRatio, config.mintLeveragedIncentiveConfig.incentiveRatios[1], "the band above the peg");
    }

    function test_freeLeveragedMechanics() public {
        // single band, no disallow (just depegged)
        setUp_config(
            ic(ua(100), ia(100, 50)),
            ic(ua(100), ia(40, 80)),
            ic(ua(100), ia(35, 70)),
            ic(ua(100), ia(240, 120))
        );
        vm.startPrank(owner());
        IMinter(minter).updateConfig(config);
        vm.stopPrank();

        deal(wrappedCollateralToken, zeroFee, 10 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 10 ether);
        vm.stopPrank();

        // how much can I get for 2 eth
        (, uint256 fee2, , , uint256 leveragedFor2, uint256 price, ) = IMinter(minter).mintLeveragedTokenDryRun(
            2 ether
        );
        leveragedFor2 += (fee2 * price) / 1 ether;
        (, uint256 fee1a, , , uint256 leveragedFor1a, , ) = IMinter(minter).mintLeveragedTokenDryRun(1 ether);
        leveragedFor1a += (fee1a * price) / 1 ether;

        uint256 leveragedPrice = IMinter(minter).leveragedTokenPrice();
        vm.startPrank(zeroFee);
        uint256 actualMinted1a = IMinter(minter).freeMintLeveragedToken(1 ether, receiver);
        vm.stopPrank();
        assertEq(leveragedPrice, IMinter(minter).leveragedTokenPrice(), "leveraged price doesn't change");

        assertEq(actualMinted1a, leveragedFor1a, "actual minted is as predicted");

        (, uint256 fee1b, , , uint256 leveragedFor1b, , ) = IMinter(minter).mintLeveragedTokenDryRun(1 ether);
        leveragedFor1b += (fee1b * price) / 1 ether;
        assertEq(leveragedFor1a + leveragedFor1b, leveragedFor2, "1 + 1 = 2");
    }

    function _mintLeveraged(uint256 collateral) private {
        int256 incentiveRatio;
        uint256 fee;
        uint256 leveragedExpected;
        (incentiveRatio, fee, , , leveragedExpected, , ) = IMinter(minter).mintLeveragedTokenDryRun(collateral);

        // check that the mint matches its dry run, in what it returns, what it emits and the fee it transfers
        uint256 feeReceiverCollateralBalanceBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintLeveragedToken(sender, sender, collateral, leveragedExpected);
        vm.startPrank(sender);
        uint256 leveragedMinted = IMinter(minter).mintLeveragedToken(collateral, sender, 0);
        vm.stopPrank();
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
        vm.startPrank(owner());
        IMinter(minter).updateConfig(config);
        vm.stopPrank();

        _mintLeveraged(1 ether);
    }

    function test_mintLeveraged1Band2Mints() public {
        setUp_config(
            ic(ua(100), ia(100, 50)),
            ic(ua(100), ia(40, 80)),
            ic(ua(100), ia(35, 70)),
            ic(ua(100), ia(240, 120))
        );
        vm.startPrank(owner());
        IMinter(minter).updateConfig(config);
        vm.stopPrank();

        // split where 2BandSameLevel puts a bound: the collateral that, net of the band's fee, takes the ratio from
        // 4/3 to 1.40 - from the ratio's definition, (C + x (1 - f)) p / P = 1.40
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        uint256 collateralIfWeHadABoundary140 = Math.mulDiv(
            1.4 ether * IMinter(minter).peggedTokenBalance() * 1 ether -
                IMinter(minter).collateralTokenBalance() * 1 ether * price,
            1 ether,
            price * (1 ether - uint256(config.mintLeveragedIncentiveConfig.incentiveRatios[1])) * rate
        );
        _mintLeveraged(collateralIfWeHadABoundary140);
        _mintLeveraged(1 ether - collateralIfWeHadABoundary140);
    }

    function test_mintLeveraged2Band() public {
        // collateral ratio already at 4/3 = 1.33
        setUp_config(
            ic(ua(100), ia(100, 50)),
            ic(ua(100), ia(40, 80)),
            ic(ua(100, 140), ia(35, 70, 100)), // <--
            ic(ua(100), ia(240, 120))
        );
        vm.startPrank(owner());
        IMinter(minter).updateConfig(config);
        vm.stopPrank();

        // mint 1 ether, we get CR = 5/3 = 1.66, so crosses the 140 boundary
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
        vm.startPrank(owner());
        IMinter(minter).updateConfig(config);
        vm.stopPrank();

        // mint 1 ether, we get CR = 5/3 = 1.66, so crosses the 140 boundary
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
/// @dev The minter floors the pegged tokens it mints, so the band walk prices a mint small enough to buy
///      less than one whole pegged token at zero - while still charging it the collateral and the fee. At
///      a collateral price of 1e-9 pegged per token that is any mint under about a billion wei, which is
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
        (, , , uint256 peggedOut, , ) = IMinter(minter).mintPeggedTokenDryRun(DUST);
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

    /// @dev A dry run says what its call does. This offer buys no whole pegged token, so the plain mint refuses
    ///      it and the capped one consumes nothing: both dry runs report nothing used, no fee, nothing minted,
    ///      and the ratio of the band the market is in.
    function test_mintPeggedDryRun_forAnOfferTooSmallForOneToken_reportsNothingUsed() public view {
        int256 bandRatio = config.mintPeggedIncentiveConfig.incentiveRatios[1]; // the market is above the peg
        (int256 ratio, uint256 fee, uint256 used, uint256 minted, , ) = IMinter(minter).mintPeggedTokenDryRun(DUST);
        assertEq(used, 0, "nothing used");
        assertEq(fee, 0, "no fee");
        assertEq(minted, 0, "nothing minted");
        assertEq(ratio, bandRatio, "the band's ratio");

        // a 100% fee cap cannot bind, so only the zero-output rule decides this
        (ratio, fee, used, minted, , ) = IMinter_v3(minter).mintPeggedTokenDryRun(DUST, 1 ether);
        assertEq(used, 0, "capped: nothing used");
        assertEq(fee, 0, "capped: no fee");
        assertEq(minted, 0, "capped: nothing minted");
        assertEq(ratio, bandRatio, "capped: the band's ratio");
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
