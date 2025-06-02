// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//import { Test } from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";

import "test/Useful.sol";
import {TestMinterSetUp} from "test/Minter_base.t.sol";

contract TestMinterMint is TestMinterSetUp {
    using SafeERC20 for IERC20;

    address system;
    address sender;
    address receiver;

    function setUpConfig() internal override {
        setUp_config_basicWithDisallow();
    }

    function setUp() public virtual override {
        super.setUp();
        system = vm.createWallet("system").addr;
        sender = vm.createWallet("sender").addr;
        receiver = vm.createWallet("receiver").addr;
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
            130,
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
        uint256 leveragedFor2 = IMinter(minter).leveragedTokensForCollateral(2 ether);
        uint256 leveragedFor1a = IMinter(minter).leveragedTokensForCollateral(1 ether);

        uint256 leveragedPrice = IMinter(minter).leveragedTokenPrice();
        vm.prank(zeroFee);
        uint256 actualMinted1a = IMinter(minter).freeMintLeveragedToken(1 ether, receiver);
        assertEq(leveragedPrice, IMinter(minter).leveragedTokenPrice(), "leveraged price doesn't change");

        assertEq(actualMinted1a, leveragedFor1a, "actual minted is as predicted");

        uint256 leveragedFor1b = IMinter(minter).leveragedTokensForCollateral(1 ether);
        assertEq(leveragedFor1a + leveragedFor1b, leveragedFor2, "1 + 1 = 2");
    }

    function _mintLeveraged(uint256 collateral) private {
        int256 incentiveRatio;
        uint256 fee;
        uint256 leveragedExpected;
        (incentiveRatio, fee, , , leveragedExpected, , ) = IMinter(minter).mintLeveragedTokenDryRun(collateral);

        // check that the fees match the reported value, both emit and that transferred
        uint256 feeReceiverCollateralBalanceBefore = IERC20(Deployed.wstETH).balanceOf(feeReceiver);
        uint256 leveragedCalculated = IMinter(minter).leveragedTokensForCollateral(collateral - fee);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintLeveragedToken(sender, sender, collateral, leveragedCalculated);
        // console2.log("expected leveraged minted=%s", leveragedCalculated);
        vm.prank(sender);
        uint256 leveragedMinted = IMinter(minter).mintLeveragedToken(collateral, sender, 0);
        // 1 ----------------------------------------------------------------------------
        assertEq(leveragedMinted, leveragedExpected, "mint vs dry run matches");
        assertEq(IERC20(Deployed.wstETH).balanceOf(feeReceiver), feeReceiverCollateralBalanceBefore + fee);
    }

    function test_mintLeveraged1Band() public {
        setUp_config(
            130,
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
            130,
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
            130,
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
            130,
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
