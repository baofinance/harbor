// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console} from "forge-std/console.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UnsafeUpgrades} from "../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";

import {GenesisETHZapV2} from "src/minter/GenesisETHZap_v2.sol";
import {Genesis_v1} from "src/minter/Genesis_v1.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";

import {TestMinterSetUp} from "test/Minter_base.t.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

contract GenesisETHZapForkTest is TestMinterSetUp {
    GenesisETHZapV2 zap;
    address genesis;
    address genesisImpl;
    address user1;
    address receiver;

    // Mainnet Lido addresses
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

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

        wrappedCollateralToken = WSTETH;
        collateralToken = STETH;

        setUp_reservePool();
    }

    function setUp() public override {
        super.setUp();

        genesisImpl = address(new Genesis_v1(minter));
        genesis = UnsafeUpgrades.deployUUPSProxy(genesisImpl, abi.encodeCall(Genesis_v1.initialize, owner));
        vm.label(genesis, "Genesis");

        zap = new GenesisETHZapV2(genesis, address(0));
        vm.label(address(zap), "GenesisETHZapV2");

        user1 = makeAddr("user1");
        receiver = makeAddr("receiver");

        vm.deal(user1, 100 ether);
    }

    function test_ZapEthToGenesis_Success() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        uint256 genesisBalBefore = IGenesis(genesis).balanceOf(receiver);
        uint256 wstEthBalBefore = IERC20(WSTETH).balanceOf(genesis);

        uint256 collateralAmount = zap.zapEthToGenesis{value: ethAmount}(receiver);

        vm.stopPrank();

        uint256 genesisBalAfter = IGenesis(genesis).balanceOf(receiver);
        uint256 wstEthBalAfter = IERC20(WSTETH).balanceOf(genesis);

        console.log("=== ETH Zap v2 Success ===");
        console.log("ETH Deposited:", ethAmount);
        console.log("wstETH Received:", collateralAmount);
        console.log("Genesis Shares Minted:", genesisBalAfter - genesisBalBefore);
        console.log("wstETH in Genesis:", wstEthBalAfter);
        console.log("User ETH Left:", user1.balance);
        console.log("==========================");

        assertGt(collateralAmount, 0, "Should receive wstETH");
        assertEq(genesisBalAfter, genesisBalBefore + collateralAmount, "Shares mismatch");
        assertEq(wstEthBalAfter, wstEthBalBefore + collateralAmount, "wstETH not deposited");
        assertEq(user1.balance, 100 ether - ethAmount, "User ETH not deducted");

        // Allowances should be cleared
        assertEq(IERC20(STETH).allowance(address(zap), WSTETH), 0, "stETH allowance not cleared");
        assertEq(IERC20(WSTETH).allowance(address(zap), genesis), 0, "wstETH allowance not cleared");
    }

    function test_ZapEthToGenesis_ZeroAmount() public {
        vm.startPrank(user1);

        vm.expectRevert(GenesisETHZapV2.ZeroAmount.selector);
        zap.zapEthToGenesis{value: 0}(receiver);

        vm.stopPrank();
    }

    function test_ZapEthToGenesis_InvalidReceiver() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        vm.expectRevert(GenesisETHZapV2.InvalidAddress.selector);
        zap.zapEthToGenesis{value: ethAmount}(address(0));

        vm.stopPrank();
    }

    function test_ZapEthToGenesis_Event() public {
        uint256 ethAmount = 1 ether;

        vm.startPrank(user1);

        vm.expectEmit(true, true, true, false);
        emit GenesisETHZapV2.ETHZappedToGenesis(user1, genesis, receiver, ethAmount, 0, 0);

        zap.zapEthToGenesis{value: ethAmount}(receiver);

        vm.stopPrank();
    }

    function test_ZapEthToGenesis_MultipleDeposits() public {
        uint256 eth1 = 1 ether;
        uint256 eth2 = 2 ether;

        vm.startPrank(user1);

        uint256 col1 = zap.zapEthToGenesis{value: eth1}(receiver);
        uint256 col2 = zap.zapEthToGenesis{value: eth2}(receiver);

        vm.stopPrank();

        uint256 total = col1 + col2;
        assertEq(IGenesis(genesis).balanceOf(receiver), total, "Total shares wrong");
        assertEq(IERC20(WSTETH).balanceOf(genesis), total, "Total wstETH wrong");
    }
}
