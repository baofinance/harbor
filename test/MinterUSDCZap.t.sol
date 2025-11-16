// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MinterUSDCZapV2} from "src/minter/MinterUSDCZap_v2.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

import {TestMinterSetUp} from "test/Minter_base.t.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

contract MinterUSDCZapForkTest is TestMinterSetUp {
    MinterUSDCZapV2 zap;
    address user1;
    address receiver;

    // Mainnet addresses
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant FXUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;
    address constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;

    function setUpFork() internal override {
        vm.createSelectFork(vm.rpcUrl("mainnet"));

        feeReceiver = makeAddr("feeReceiver");
        owner = makeAddr("owner");

        priceOracle = address(new MockWrappedPriceOracle());
        vm.label(priceOracle, "priceOracle");

        setUp_leveragedToken();
        peggedToken = address(new MockERC20("BaoUSD", "BAOUSD", 18));
        vm.label(peggedToken, "pegged");
        peggedTokenBurnSig = "burnFrom(address,uint256)";

        wrappedCollateralToken = FXSAVE;
        collateralToken = USDC;

        setUp_reservePool();
    }

    function setUp() public override {
        super.setUp();

        // Bootstrap minter with initial collateral (needed for price calculations)
        setUp_collateral(1000 * 1e6, 1000 * 1e6); // 1000 USDC worth of fxSAVE

        zap = new MinterUSDCZapV2(minter);
        vm.label(address(zap), "MinterUSDCZapV2");

        user1 = makeAddr("user1");
        receiver = makeAddr("receiver");

        deal(USDC, user1, 10000 * 1e6);
    }

    // ============ USDC to Pegged Tests ============

    function test_ZapUsdcToPegged_Success() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        uint256 peggedBalBefore = IERC20(peggedToken).balanceOf(receiver);
        uint256 fxBalBefore = IERC20(FXSAVE).balanceOf(minter);

        uint256 peggedOut = zap.zapUsdcToPegged(usdcAmount, receiver, 0);

        vm.stopPrank();

        uint256 peggedBalAfter = IERC20(peggedToken).balanceOf(receiver);
        uint256 fxBalAfter = IERC20(FXSAVE).balanceOf(minter);

        console.log("=== USDC to Pegged Zap Success ===");
        console.log("USDC Deposited:", usdcAmount);
        console.log("Pegged Tokens Minted:", peggedOut);
        console.log("Pegged Balance:", peggedBalAfter - peggedBalBefore);
        console.log("fxSAVE in Minter:", fxBalAfter);
        console.log("fxSAVE Deposited:", fxBalAfter - fxBalBefore);
        console.log("Total Pegged Supply:", IERC20(peggedToken).totalSupply());
        console.log("Minter Pegged Balance:", IMinter(minter).peggedTokenBalance());
        console.log("Minter Collateral Balance:", IMinter(minter).collateralTokenBalance());
        console.log("User USDC Left:", IERC20(USDC).balanceOf(user1));
        console.log("==========================");

        assertGt(peggedOut, 0, "Should receive pegged tokens");
        assertEq(peggedBalAfter, peggedBalBefore + peggedOut, "Pegged balance mismatch");
        assertGt(fxBalAfter, fxBalBefore, "fxSAVE should be deposited");
        assertEq(IERC20(USDC).balanceOf(user1), 10000 * 1e6 - usdcAmount, "USDC not deducted");

        // Allowances should be cleared
        assertEq(IERC20(USDC).allowance(address(zap), zap.FXUSD_DIAMOND()), 0, "USDC allowance not cleared");
        assertEq(IERC20(FXSAVE).allowance(address(zap), minter), 0, "fxSAVE allowance not cleared");
    }

    function test_ZapUsdcToPegged_ZeroAmount() public {
        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), type(uint256).max);

        vm.expectRevert(MinterUSDCZapV2.ZeroAmount.selector);
        zap.zapUsdcToPegged(0, receiver, 0);

        vm.stopPrank();
    }

    function test_ZapUsdcToPegged_InvalidReceiver() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        vm.expectRevert(MinterUSDCZapV2.InvalidAddress.selector);
        zap.zapUsdcToPegged(usdcAmount, address(0), 0);

        vm.stopPrank();
    }

    function test_ZapUsdcToPegged_Event() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        vm.expectEmit(true, true, true, false);
        emit MinterUSDCZapV2.USDCZappedToPegged(user1, minter, receiver, usdcAmount, 0, 0);

        zap.zapUsdcToPegged(usdcAmount, receiver, 0);

        vm.stopPrank();
    }

    // ============ USDC to Leveraged Tests ============

    function test_ZapUsdcToLeveraged_Success() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        uint256 leveragedBalBefore = IERC20(leveragedToken).balanceOf(receiver);
        uint256 fxBalBefore = IERC20(FXSAVE).balanceOf(minter);

        uint256 leveragedOut = zap.zapUsdcToLeveraged(usdcAmount, receiver, 0);

        vm.stopPrank();

        uint256 leveragedBalAfter = IERC20(leveragedToken).balanceOf(receiver);
        uint256 fxBalAfter = IERC20(FXSAVE).balanceOf(minter);

        console.log("=== USDC to Leveraged Zap Success ===");
        console.log("USDC Deposited:", usdcAmount);
        console.log("Leveraged Tokens Minted:", leveragedOut);
        console.log("Leveraged Balance:", leveragedBalAfter - leveragedBalBefore);
        console.log("fxSAVE in Minter:", fxBalAfter);
        console.log("fxSAVE Deposited:", fxBalAfter - fxBalBefore);
        console.log("Total Leveraged Supply:", IERC20(leveragedToken).totalSupply());
        console.log("Minter Leveraged Balance:", IMinter(minter).leveragedTokenBalance());
        console.log("Minter Collateral Balance:", IMinter(minter).collateralTokenBalance());
        console.log("User USDC Left:", IERC20(USDC).balanceOf(user1));
        console.log("==========================");

        assertGt(leveragedOut, 0, "Should receive leveraged tokens");
        assertEq(leveragedBalAfter, leveragedBalBefore + leveragedOut, "Leveraged balance mismatch");
        assertGt(fxBalAfter, fxBalBefore, "fxSAVE should be deposited");
        assertEq(IERC20(USDC).balanceOf(user1), 10000 * 1e6 - usdcAmount, "USDC not deducted");

        // Allowances should be cleared
        assertEq(IERC20(USDC).allowance(address(zap), zap.FXUSD_DIAMOND()), 0, "USDC allowance not cleared");
        assertEq(IERC20(FXSAVE).allowance(address(zap), minter), 0, "fxSAVE allowance not cleared");
    }

    function test_ZapUsdcToLeveraged_ZeroAmount() public {
        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), type(uint256).max);

        vm.expectRevert(MinterUSDCZapV2.ZeroAmount.selector);
        zap.zapUsdcToLeveraged(0, receiver, 0);

        vm.stopPrank();
    }

    function test_ZapUsdcToLeveraged_InvalidReceiver() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        vm.expectRevert(MinterUSDCZapV2.InvalidAddress.selector);
        zap.zapUsdcToLeveraged(usdcAmount, address(0), 0);

        vm.stopPrank();
    }

    function test_ZapUsdcToLeveraged_Event() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        vm.expectEmit(true, true, true, false);
        emit MinterUSDCZapV2.USDCZappedToLeveraged(user1, minter, receiver, usdcAmount, 0, 0);

        zap.zapUsdcToLeveraged(usdcAmount, receiver, 0);

        vm.stopPrank();
    }

    // ============ fxUSD to Pegged Tests ============

    function test_ZapFxUsdToPegged_Success() public {
        // Fund user with fxUSD (using deal on fork)
        deal(FXUSD, user1, 10000 * 1e18); // fxUSD has 18 decimals
        uint256 fxUsdAmount = 1000 * 1e18;

        vm.startPrank(user1);
        IERC20(FXUSD).approve(address(zap), fxUsdAmount);

        uint256 peggedBalBefore = IERC20(peggedToken).balanceOf(receiver);
        uint256 fxBalBefore = IERC20(FXSAVE).balanceOf(minter);

        uint256 peggedOut = zap.zapFxUsdToPegged(fxUsdAmount, receiver, 0);

        vm.stopPrank();

        uint256 peggedBalAfter = IERC20(peggedToken).balanceOf(receiver);
        uint256 fxBalAfter = IERC20(FXSAVE).balanceOf(minter);

        console.log("=== fxUSD to Pegged Zap Success ===");
        console.log("fxUSD Deposited:", fxUsdAmount);
        console.log("Pegged Tokens Minted:", peggedOut);
        console.log("Pegged Balance:", peggedBalAfter - peggedBalBefore);
        console.log("fxSAVE in Minter:", fxBalAfter);
        console.log("fxSAVE Deposited:", fxBalAfter - fxBalBefore);
        console.log("Total Pegged Supply:", IERC20(peggedToken).totalSupply());
        console.log("Minter Pegged Balance:", IMinter(minter).peggedTokenBalance());
        console.log("Minter Collateral Balance:", IMinter(minter).collateralTokenBalance());
        console.log("User fxUSD Left:", IERC20(FXUSD).balanceOf(user1));
        console.log("==========================");

        assertGt(peggedOut, 0, "Should receive pegged tokens");
        assertEq(peggedBalAfter, peggedBalBefore + peggedOut, "Pegged balance mismatch");
        assertGt(fxBalAfter, fxBalBefore, "fxSAVE should be deposited");
        assertEq(IERC20(FXUSD).balanceOf(user1), 10000 * 1e18 - fxUsdAmount, "fxUSD not deducted");

        // Allowances should be cleared
        assertEq(IERC20(FXUSD).allowance(address(zap), zap.FXUSD_DIAMOND()), 0, "fxUSD allowance not cleared");
        assertEq(IERC20(FXSAVE).allowance(address(zap), minter), 0, "fxSAVE allowance not cleared");
    }

    function test_ZapFxUsdToPegged_ZeroAmount() public {
        deal(FXUSD, user1, 10000 * 1e18);

        vm.startPrank(user1);
        IERC20(FXUSD).approve(address(zap), type(uint256).max);

        vm.expectRevert(MinterUSDCZapV2.ZeroAmount.selector);
        zap.zapFxUsdToPegged(0, receiver, 0);

        vm.stopPrank();
    }

    function test_ZapFxUsdToPegged_InvalidReceiver() public {
        deal(FXUSD, user1, 10000 * 1e18);
        uint256 fxUsdAmount = 1000 * 1e18;

        vm.startPrank(user1);
        IERC20(FXUSD).approve(address(zap), fxUsdAmount);

        vm.expectRevert(MinterUSDCZapV2.InvalidAddress.selector);
        zap.zapFxUsdToPegged(fxUsdAmount, address(0), 0);

        vm.stopPrank();
    }

    function test_ZapFxUsdToPegged_Event() public {
        deal(FXUSD, user1, 10000 * 1e18);
        uint256 fxUsdAmount = 1000 * 1e18;

        vm.startPrank(user1);
        IERC20(FXUSD).approve(address(zap), fxUsdAmount);

        vm.expectEmit(true, true, true, false);
        emit MinterUSDCZapV2.FXUSDZappedToPegged(user1, minter, receiver, fxUsdAmount, 0, 0);

        zap.zapFxUsdToPegged(fxUsdAmount, receiver, 0);

        vm.stopPrank();
    }

    // ============ fxUSD to Leveraged Tests ============

    function test_ZapFxUsdToLeveraged_Success() public {
        // Fund user with fxUSD (using deal on fork)
        deal(FXUSD, user1, 10000 * 1e18); // fxUSD has 18 decimals
        uint256 fxUsdAmount = 1000 * 1e18;

        vm.startPrank(user1);
        IERC20(FXUSD).approve(address(zap), fxUsdAmount);

        uint256 leveragedBalBefore = IERC20(leveragedToken).balanceOf(receiver);
        uint256 fxBalBefore = IERC20(FXSAVE).balanceOf(minter);

        uint256 leveragedOut = zap.zapFxUsdToLeveraged(fxUsdAmount, receiver, 0);

        vm.stopPrank();

        uint256 leveragedBalAfter = IERC20(leveragedToken).balanceOf(receiver);
        uint256 fxBalAfter = IERC20(FXSAVE).balanceOf(minter);

        console.log("=== fxUSD to Leveraged Zap Success ===");
        console.log("fxUSD Deposited:", fxUsdAmount);
        console.log("Leveraged Tokens Minted:", leveragedOut);
        console.log("Leveraged Balance:", leveragedBalAfter - leveragedBalBefore);
        console.log("fxSAVE in Minter:", fxBalAfter);
        console.log("fxSAVE Deposited:", fxBalAfter - fxBalBefore);
        console.log("Total Leveraged Supply:", IERC20(leveragedToken).totalSupply());
        console.log("Minter Leveraged Balance:", IMinter(minter).leveragedTokenBalance());
        console.log("Minter Collateral Balance:", IMinter(minter).collateralTokenBalance());
        console.log("User fxUSD Left:", IERC20(FXUSD).balanceOf(user1));
        console.log("==========================");

        assertGt(leveragedOut, 0, "Should receive leveraged tokens");
        assertEq(leveragedBalAfter, leveragedBalBefore + leveragedOut, "Leveraged balance mismatch");
        assertGt(fxBalAfter, fxBalBefore, "fxSAVE should be deposited");
        assertEq(IERC20(FXUSD).balanceOf(user1), 10000 * 1e18 - fxUsdAmount, "fxUSD not deducted");

        // Allowances should be cleared
        assertEq(IERC20(FXUSD).allowance(address(zap), zap.FXUSD_DIAMOND()), 0, "fxUSD allowance not cleared");
        assertEq(IERC20(FXSAVE).allowance(address(zap), minter), 0, "fxSAVE allowance not cleared");
    }

    function test_ZapFxUsdToLeveraged_ZeroAmount() public {
        deal(FXUSD, user1, 10000 * 1e18);

        vm.startPrank(user1);
        IERC20(FXUSD).approve(address(zap), type(uint256).max);

        vm.expectRevert(MinterUSDCZapV2.ZeroAmount.selector);
        zap.zapFxUsdToLeveraged(0, receiver, 0);

        vm.stopPrank();
    }

    function test_ZapFxUsdToLeveraged_InvalidReceiver() public {
        deal(FXUSD, user1, 10000 * 1e18);
        uint256 fxUsdAmount = 1000 * 1e18;

        vm.startPrank(user1);
        IERC20(FXUSD).approve(address(zap), fxUsdAmount);

        vm.expectRevert(MinterUSDCZapV2.InvalidAddress.selector);
        zap.zapFxUsdToLeveraged(fxUsdAmount, address(0), 0);

        vm.stopPrank();
    }

    function test_ZapFxUsdToLeveraged_Event() public {
        deal(FXUSD, user1, 10000 * 1e18);
        uint256 fxUsdAmount = 1000 * 1e18;

        vm.startPrank(user1);
        IERC20(FXUSD).approve(address(zap), fxUsdAmount);

        vm.expectEmit(true, true, true, false);
        emit MinterUSDCZapV2.FXUSDZappedToLeveraged(user1, minter, receiver, fxUsdAmount, 0, 0);

        zap.zapFxUsdToLeveraged(fxUsdAmount, receiver, 0);

        vm.stopPrank();
    }
}

