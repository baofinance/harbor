// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {GenesisETHZap_v1} from "src/minter/GenesisETHZap_v1.sol";
import {Genesis_v1} from "src/minter/Genesis_v1.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";

import {TestMinterSetUp} from "test/Minter_base.t.sol";

contract GenesisETHZapTest is TestMinterSetUp {
    GenesisETHZap_v1 zap;
    address genesis;
    address genesisImpl;
    address user1;
    address receiver;

    function setUp() public override {
        super.setUp();

        // Set up Genesis contract with wstETH as collateral (from TestMinterSetUp)
        setUp_genesisImplementation();
        setUp_genesisProxy();

        // Set up zap contract (uses real STETH and WSTETH from mainnet fork)
        zap = new GenesisETHZap_v1(genesis);
        vm.label(address(zap), "GenesisETHZap");

        user1 = makeAddr("user1");
        receiver = makeAddr("receiver");

        // Give user ETH
        vm.deal(user1, 100 ether);
    }

    function setUp_genesisImplementation() internal {
        // We need to deploy a minter that uses wstETH as collateral
        // For now, we'll use the existing minter setup which should use wstETH
        genesisImpl = address(new Genesis_v1(minter));
    }

    function setUp_genesisProxy() internal {
        genesis = UnsafeUpgrades.deployUUPSProxy(
            genesisImpl,
            abi.encodeCall(Genesis_v1.initialize, owner)
        );
        vm.label(genesis, "Genesis");
    }

    function test_ZapETHtoGenesis_Success() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        uint256 genesisBalanceBefore = IGenesis(genesis).balanceOf(receiver);
        uint256 wstETHBalanceBefore = IERC20(wrappedCollateralToken).balanceOf(genesis);

        uint256 collateralAmount = zap.zapETHtoGenesis{value: ethAmount}(receiver);

        vm.stopPrank();

        // Console log the deposit values
        uint256 genesisBalanceAfter = IGenesis(genesis).balanceOf(receiver);
        uint256 wstETHBalanceAfter = IERC20(wrappedCollateralToken).balanceOf(genesis);
        
        console.log("=== ETH Zap to Genesis Deposit ===");
        console.log("User Address (user1):", user1);
        console.log("Receiver Address:", receiver);
        console.log("ETH Amount Deposited:", ethAmount);
        console.log("wstETH Amount Received:", collateralAmount);
        console.log("");
        console.log("--- Receiver's Contribution to Genesis ---");
        console.log("Receiver Genesis Balance Before:", genesisBalanceBefore);
        console.log("Receiver Genesis Balance After:", genesisBalanceAfter);
        console.log("Receiver Genesis Balance Increase:", genesisBalanceAfter - genesisBalanceBefore);
        console.log("");
        console.log("--- Genesis Contract State ---");
        console.log("wstETH in Genesis Before:", wstETHBalanceBefore);
        console.log("wstETH in Genesis After:", wstETHBalanceAfter);
        console.log("wstETH in Genesis Increase:", wstETHBalanceAfter - wstETHBalanceBefore);
        console.log("");
        console.log("--- User Balances ---");
        console.log("User ETH Balance Remaining:", user1.balance);
        console.log("================================");

        // Check balances
        assertEq(genesisBalanceAfter, genesisBalanceBefore + collateralAmount, "Genesis balance should increase");
        assertEq(wstETHBalanceAfter, wstETHBalanceBefore + collateralAmount, "Genesis should receive wstETH");
        assertEq(user1.balance, 100 ether - ethAmount, "User ETH should decrease");
    }

    function test_ZapETHtoGenesis_ZeroAmount() public {
        vm.startPrank(user1);

        vm.expectRevert(GenesisETHZap_v1.ZeroAmount.selector);
        zap.zapETHtoGenesis{value: 0}(receiver);

        vm.stopPrank();
    }

    function test_ZapETHtoGenesis_InvalidReceiver() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        vm.expectRevert(GenesisETHZap_v1.InvalidAddress.selector);
        zap.zapETHtoGenesis{value: ethAmount}(address(0));

        vm.stopPrank();
    }

    function test_ZapETHtoGenesis_Event() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        // Check only the indexed parameters (user, genesis, receiver)
        // wstETHAmount and collateralAmount are non-indexed and will have actual values
        vm.expectEmit(true, true, true, false);
        emit GenesisETHZap_v1.ETHZappedToGenesis(user1, genesis, receiver, ethAmount, 0, 0);

        zap.zapETHtoGenesis{value: ethAmount}(receiver);

        vm.stopPrank();
    }

    function test_ZapETHtoGenesis_MultipleDeposits() public {
        uint256 ethAmount1 = 1 ether;
        uint256 ethAmount2 = 2 ether;

        vm.startPrank(user1);

        uint256 collateralAmount1 = zap.zapETHtoGenesis{value: ethAmount1}(receiver);
        uint256 collateralAmount2 = zap.zapETHtoGenesis{value: ethAmount2}(receiver);

        vm.stopPrank();

        uint256 totalCollateral = collateralAmount1 + collateralAmount2;
        assertEq(IGenesis(genesis).balanceOf(receiver), totalCollateral, "Total Genesis balance should match");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(genesis), totalCollateral, "Total wstETH in Genesis should match");
    }
}

