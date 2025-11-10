// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UnsafeUpgrades} from "../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";

import {GenesisUSDCZapV2} from "src/minter/GenesisUSDCZap_v2.sol";
import {Genesis_v1} from "src/minter/Genesis_v1.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";

import {TestMinterSetUp} from "test/Minter_base.t.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

contract GenesisUSDCZapForkTest is TestMinterSetUp {
    GenesisUSDCZapV2 zap;
    address genesis;
    address genesisImpl;
    address user1;
    address receiver;

    // Mainnet addresses
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
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

        genesisImpl = address(new Genesis_v1(minter));
        genesis = UnsafeUpgrades.deployUUPSProxy(genesisImpl, abi.encodeCall(Genesis_v1.initialize, owner));
        vm.label(genesis, "Genesis");

        zap = new GenesisUSDCZapV2(genesis);
        vm.label(address(zap), "GenesisUSDCZapV2");

        user1 = makeAddr("user1");
        receiver = makeAddr("receiver");

        deal(USDC, user1, 10000 * 1e6);
    }

    function test_ZapUsdcToGenesis_Success() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        uint256 genBalBefore = IGenesis(genesis).balanceOf(receiver);
        uint256 fxBalBefore = IERC20(FXSAVE).balanceOf(genesis);

        uint256 collateralAmount = zap.zapUsdcToGenesis(usdcAmount, receiver);

        vm.stopPrank();

        uint256 genBalAfter = IGenesis(genesis).balanceOf(receiver);
        uint256 fxBalAfter = IERC20(FXSAVE).balanceOf(genesis);

        console.log("=== USDC Zap v2 Success ===");
        console.log("USDC Deposited:", usdcAmount);
        console.log("fxSAVE Received:", collateralAmount);
        console.log("Genesis Shares Minted:", genBalAfter - genBalBefore);
        console.log("fxSAVE in Genesis:", fxBalAfter);
        console.log("User USDC Left:", IERC20(USDC).balanceOf(user1));
        console.log("==========================");

        assertGt(collateralAmount, 0, "Should receive fxSAVE");
        assertEq(genBalAfter, genBalBefore + collateralAmount, "Shares mismatch");
        assertEq(fxBalAfter, fxBalBefore + collateralAmount, "fxSAVE not deposited");
        assertEq(IERC20(USDC).balanceOf(user1), 10000 * 1e6 - usdcAmount, "USDC not deducted");

        // Allowances should be cleared
        assertEq(IERC20(USDC).allowance(address(zap), zap.FXUSD_DIAMOND()), 0, "USDC allowance not cleared");
        assertEq(IERC20(FXSAVE).allowance(address(zap), genesis), 0, "fxSAVE allowance not cleared");
    }

    function test_ZapUsdcToGenesis_ZeroAmount() public {
        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), type(uint256).max);

        vm.expectRevert(GenesisUSDCZapV2.ZeroAmount.selector);
        zap.zapUsdcToGenesis(0, receiver);

        vm.stopPrank();
    }

    function test_ZapUsdcToGenesis_InvalidReceiver() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        vm.expectRevert(GenesisUSDCZapV2.InvalidAddress.selector);
        zap.zapUsdcToGenesis(usdcAmount, address(0));

        vm.stopPrank();
    }

    function test_ZapUsdcToGenesis_Event() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        vm.expectEmit(true, true, true, false);
        emit GenesisUSDCZapV2.USDCZappedToGenesis(user1, genesis, receiver, usdcAmount, 0, 0);

        zap.zapUsdcToGenesis(usdcAmount, receiver);

        vm.stopPrank();
    }

    function test_ZapUsdcToGenesis_MultipleDeposits() public {
        uint256 amt1 = 1000 * 1e6;
        uint256 amt2 = 2000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), type(uint256).max);

        uint256 col1 = zap.zapUsdcToGenesis(amt1, receiver);
        uint256 col2 = zap.zapUsdcToGenesis(amt2, receiver);

        vm.stopPrank();

        uint256 total = col1 + col2;
        assertEq(IGenesis(genesis).balanceOf(receiver), total, "Total shares wrong");
        assertEq(IERC20(FXSAVE).balanceOf(genesis), total, "Total fxSAVE wrong");
    }
}
