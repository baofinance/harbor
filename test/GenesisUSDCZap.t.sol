// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {GenesisUSDCZap_v1} from "src/minter/GenesisUSDCZap_v1.sol";
import {Genesis_v1} from "src/minter/Genesis_v1.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";

import {TestMinterSetUp} from "test/Minter_base.t.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

contract GenesisUSDCZapTest is TestMinterSetUp {
    GenesisUSDCZap_v1 zap;
    address genesis;
    address genesisImpl;
    address user1;
    address receiver;

    // Constants from GenesisUSDCZap_v1
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant FXSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;

    function setUpFork() internal override {
        // Use latest block to ensure fxSAVE contract exists
        vm.createSelectFork(vm.rpcUrl("mainnet"));

        feeReceiver = makeAddr("feeReceiver");
        owner = makeAddr("owner");

        priceOracle = address(new MockWrappedPriceOracle());
        vm.label(priceOracle, "priceOracle");

        setUp_leveragedToken();
        peggedToken = address(new MockERC20("BaoUSD", "BAOUSD", 18));
        vm.label(peggedToken, "pegged");
        peggedTokenBurnSig = "burnFrom(address,uint256)";
        
        // Use fxSAVE instead of wstETH
        wrappedCollateralToken = FXSAVE;
        collateralToken = USDC; // fxSAVE uses USDC as underlying

        setUp_reservePool();
    }

    function setUp() public override {
        super.setUp();

        // Set up Genesis contract with fxSAVE as collateral
        setUp_genesisImplementation();
        setUp_genesisProxy();

        // Set up zap contract (uses real USDC and fxSAVE from mainnet fork)
        zap = new GenesisUSDCZap_v1(genesis);
        vm.label(address(zap), "GenesisUSDCZap");

        user1 = makeAddr("user1");
        receiver = makeAddr("receiver");

        // Give user USDC
        deal(USDC, user1, 10000 * 1e6); // 10,000 USDC
    }

    function setUp_genesisImplementation() internal {
        genesisImpl = address(new Genesis_v1(minter));
    }

    function setUp_genesisProxy() internal {
        genesis = UnsafeUpgrades.deployUUPSProxy(
            genesisImpl,
            abi.encodeCall(Genesis_v1.initialize, owner)
        );
        vm.label(genesis, "Genesis");
    }

    function test_ZapUSDCtoGenesis_Success() public {
        uint256 usdcAmount = 1000 * 1e6; // 1,000 USDC

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        uint256 genesisBalanceBefore = IGenesis(genesis).balanceOf(receiver);
        uint256 fxSAVEBalanceBefore = IERC20(FXSAVE).balanceOf(genesis);

        uint256 collateralAmount = zap.zapUSDCtoGenesis(usdcAmount, receiver);

        vm.stopPrank();

        // Console log the deposit values
        uint256 genesisBalanceAfter = IGenesis(genesis).balanceOf(receiver);
        uint256 fxSAVEBalanceAfter = IERC20(FXSAVE).balanceOf(genesis);
        
        console.log("=== USDC Zap to Genesis Deposit (Fork) ===");
        console.log("User Address (user1):", user1);
        console.log("Receiver Address:", receiver);
        console.log("USDC Amount Deposited:", usdcAmount);
        console.log("fxSAVE Amount Received:", collateralAmount);
        console.log("");
        console.log("--- Receiver's Contribution to Genesis ---");
        console.log("Receiver Genesis Balance Before:", genesisBalanceBefore);
        console.log("Receiver Genesis Balance After:", genesisBalanceAfter);
        console.log("Receiver Genesis Balance Increase:", genesisBalanceAfter - genesisBalanceBefore);
        console.log("");
        console.log("--- Genesis Contract State ---");
        console.log("fxSAVE in Genesis Before:", fxSAVEBalanceBefore);
        console.log("fxSAVE in Genesis After:", fxSAVEBalanceAfter);
        console.log("fxSAVE in Genesis Increase:", fxSAVEBalanceAfter - fxSAVEBalanceBefore);
        console.log("");
        console.log("--- User Balances ---");
        console.log("User USDC Balance Remaining:", IERC20(USDC).balanceOf(user1));
        console.log("USDC in fxSAVE Vault:", IERC20(USDC).balanceOf(FXSAVE));
        console.log("===========================================");

        // Check balances
        assertEq(genesisBalanceAfter, genesisBalanceBefore + collateralAmount, "Genesis balance should increase");
        assertEq(fxSAVEBalanceAfter, fxSAVEBalanceBefore + collateralAmount, "Genesis should receive fxSAVE");
        assertEq(IERC20(USDC).balanceOf(user1), 10000 * 1e6 - usdcAmount, "User USDC should decrease");
    }

    function test_ZapUSDCtoGenesis_ZeroAmount() public {
        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), type(uint256).max);

        vm.expectRevert(GenesisUSDCZap_v1.ZeroAmount.selector);
        zap.zapUSDCtoGenesis(0, receiver);

        vm.stopPrank();
    }

    function test_ZapUSDCtoGenesis_InvalidReceiver() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        vm.expectRevert(GenesisUSDCZap_v1.InvalidAddress.selector);
        zap.zapUSDCtoGenesis(usdcAmount, address(0));

        vm.stopPrank();
    }

    function test_ZapUSDCtoGenesis_Event() public {
        uint256 usdcAmount = 1000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), usdcAmount);

        // Check only the indexed parameters (user, genesis, receiver)
        // fxSAVEAmount and collateralAmount are non-indexed and will have actual values
        vm.expectEmit(true, true, true, false);
        emit GenesisUSDCZap_v1.USDCZappedToGenesis(user1, genesis, receiver, usdcAmount, 0, 0);

        zap.zapUSDCtoGenesis(usdcAmount, receiver);

        vm.stopPrank();
    }

    function test_ZapUSDCtoGenesis_MultipleDeposits() public {
        uint256 usdcAmount1 = 1000 * 1e6;
        uint256 usdcAmount2 = 2000 * 1e6;

        vm.startPrank(user1);
        IERC20(USDC).approve(address(zap), type(uint256).max);

        uint256 collateralAmount1 = zap.zapUSDCtoGenesis(usdcAmount1, receiver);
        uint256 collateralAmount2 = zap.zapUSDCtoGenesis(usdcAmount2, receiver);

        vm.stopPrank();

        uint256 totalCollateral = collateralAmount1 + collateralAmount2;
        assertEq(IGenesis(genesis).balanceOf(receiver), totalCollateral, "Total Genesis balance should match");
        assertEq(IERC20(FXSAVE).balanceOf(genesis), totalCollateral, "Total fxSAVE in Genesis should match");
    }
}

