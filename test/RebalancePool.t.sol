// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Ownable } from "@solady/auth/Ownable.sol";

import { IMinter } from "src/minter/IMinter.sol";
import { RebalancePool_v1 } from "src/minter/RebalancePool_v1.sol";
import { LeveragedToken_v1 } from "src/minter/LeveragedToken_v1.sol";
import { IRebalancePool } from "src/minter/IRebalancePool.sol";

import { Token } from "@bao/Token.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";

import { Deployed } from "@bao/Deployed.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";
import { IBaoUSD } from "test/IBaoUSD.sol";
import "test/clog.sol";
import { TestMinterFeeSetUp } from "test/Minter_fees.t.sol";

contract TestRebalancePoolSetUp is TestMinterFeeSetUp {
    address rebalancePool;
    address user1;
    address user2;

    function setUp() public virtual override(TestMinterFeeSetUp) {
        super.setUp();

        rebalancePool = UnsafeUpgrades.deployUUPSProxy(
            address(new RebalancePool_v1()), // "RebalancePool_v1.sol",
            abi.encodeCall(RebalancePool_v1.initialize, (owner, minter, collateralToken))
        );

        user1 = vm.createWallet("user1").addr;
        vm.prank(user1);
        IERC20(Deployed.BaoUSD).approve(rebalancePool, type(uint256).max);

        user2 = vm.createWallet("user2").addr;
        vm.prank(user2);
        IERC20(Deployed.BaoUSD).approve(rebalancePool, type(uint256).max);
    }

    function test_init(address rp, address liquidateTo) internal view {
        assertEq(RebalancePool_v1(rp).owner(), owner);
        assertEq(IRebalancePool(rp).assetToken(), peggedToken);
        assertEq(IRebalancePool(rp).liquidationToken(), liquidateTo);
        assertEq(IRebalancePool(rp).minter(), minter);
        assertEq(IRebalancePool(rp).totalAssetSupply(), 0);
        assertEq(IRebalancePool(rp).liquidatableCollateralRatio(), IMinter(minter).rebalanceCollateralRatio());
    }
}

contract TestRebalancePoolInit is TestRebalancePoolSetUp {
    using SafeERC20 for IERC20;

    function test_init() public view {
        test_init(rebalancePool, collateralToken);
    }
}

contract TestRebalancePoolInitEvents is TestRebalancePoolSetUp {
    address rpCollateral;
    address rpLeveraged;

    function setUp() public override {
        TestMinterFeeSetUp.setUp(); // no rebalance pool proxy set up
        rpCollateral = address(new RebalancePool_v1());
        rpLeveraged = address(new RebalancePool_v1());
    }

    function test_initEventsImplementation() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        address(new RebalancePool_v1());
    }

    function test_initEvents(address rp, address liquidateTo) internal {
        vm.expectEmit();
        emit IERC1967.Upgraded(address(rp));
        vm.expectEmit();
        emit Ownable.OwnershipTransferred(address(0), owner);
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call

        address rpProxy = UnsafeUpgrades.deployUUPSProxy(
            rp, // "RebalancePool_v1.sol",
            abi.encodeCall(RebalancePool_v1.initialize, (owner, minter, liquidateTo))
        );

        test_init(rpProxy, liquidateTo);
    }

    function test_initEventsCollateral() public {
        test_initEvents(rpCollateral, collateralToken);
    }

    function test_initEventsLeveraged() public {
        test_initEvents(rpLeveraged, leveragedToken);
    }

    function test_initEventsBad() public {
        address rp = address(new RebalancePool_v1());
        vm.expectRevert(abi.encodeWithSelector(IRebalancePool.InvalidLiquidationToken.selector, peggedToken));
        UnsafeUpgrades.deployUUPSProxy(
            rp, // "RebalancePool_v1.sol",
            abi.encodeCall(RebalancePool_v1.initialize, (owner, minter, peggedToken))
        );
    }
}

contract TestRebalancePoolDepositWithdraw is TestRebalancePoolSetUp {
    function setUp() public virtual override(TestRebalancePoolSetUp) {
        super.setUp();
    }

    function _depositWithdraw(address receiver) private {
        uint256 price = MockPriceOracle(priceOracle).latestAnswer();
        // more than holding
        setUp_collateral(20 ether, 0 ether);
        deal(peggedToken, user1, 10 * price);
        assertEq(IERC20(peggedToken).balanceOf(user1), 10 * price, "user1 has");
        vm.expectRevert("SafeMath: subtraction underflow"); // should be amount exceeds balance, but hey-ho
        vm.prank(user1);
        IRebalancePool(rebalancePool).deposit(20 * price, receiver, 0);
        // --------------------------------------------------------

        // $2 deposit
        assertEq(IERC20(peggedToken).balanceOf(user1), 10 * price);
        assertEq(IERC20(peggedToken).balanceOf(rebalancePool), 0);
        vm.prank(user1);
        uint256 deposited = IRebalancePool(rebalancePool).deposit(2 * price, receiver, 0);
        // 1 deposit --------------------------------------------------------------------
        assertEq(deposited, 2 * price, "returned value");
        assertEq(IERC20(peggedToken).balanceOf(rebalancePool), 2 * price);
        assertEq(IRebalancePool(rebalancePool).assetBalanceOf(receiver), 2 * price);
        assertEq(IERC20(peggedToken).balanceOf(user1), 8 * price);

        // $3 withdrawal
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IRebalancePool.WithdrawAmountExceedsBalance.selector, 3 * price, 2 * price)
        );
        IRebalancePool(rebalancePool).withdraw(3 * price, receiver);
        // 1 withdraw ---------------------------------------------
        assertEq(IRebalancePool(rebalancePool).assetBalanceOf(receiver), 2 * price);

        // $5 second deposit
        vm.prank(user1);
        deposited = IRebalancePool(rebalancePool).deposit(5 * price, receiver, 0);
        // 2 deposit ------------------------------------------------------------
        assertEq(deposited, 5 * price, "returned value 5");
        assertEq(IERC20(peggedToken).balanceOf(rebalancePool), 7 * price);
        assertEq(IRebalancePool(rebalancePool).assetBalanceOf(receiver), 7 * price);

        // withdraw some
        vm.prank(user1);
        uint256 withdrawn = IRebalancePool(rebalancePool).withdraw(4 * price, receiver);
        // 2 withdraw -----------------------------------------------------------------
        assertEq(withdrawn, 4 * price, "withdraw 4");
        assertEq(IRebalancePool(rebalancePool).assetBalanceOf(receiver), 3 * price);

        // withdraw rest
        vm.prank(user1);
        withdrawn = IRebalancePool(rebalancePool).withdraw(type(uint256).max, receiver);
        // 3 withdraw -----------------------------------------------------------------
        assertEq(withdrawn, 3 * price, "withdraw 3 (-1)");
        assertEq(IRebalancePool(rebalancePool).assetBalanceOf(receiver), 0);

        // deposit -1
        vm.prank(user1);
        deposited = IRebalancePool(rebalancePool).deposit(type(uint256).max, receiver, 0);
        // 3 deposit --------------------------------------------------------------------
        assertEq(deposited, 10 * price, "returned value 10");
        assertEq(IRebalancePool(rebalancePool).assetBalanceOf(receiver), 10 * price);
        assertEq(IERC20(peggedToken).balanceOf(user1), 0);

        // deposit for more than the minter has minted, deposits up to the minter's balance
        // mint from another source, not minter
        setUp_collateral(1 ether, 0 ether); // add more minter
        assertEq(IMinter(minter).peggedTokenBalance(), 21 * price, "minted by minter");
        assertEq(IERC20(peggedToken).balanceOf(rebalancePool), 10 * price);
        deal(address(peggedToken), user1, 20 * price);
        vm.prank(user1);
        deposited = IRebalancePool(rebalancePool).deposit(20 * price, receiver, 0);
        // 4 deposit -------------------------------------------------------------
        assertEq(deposited, 11 * price, "returned value 11, not 20");

        // minter has none left, so zero deposit
        vm.expectRevert(abi.encodeWithSelector(IRebalancePool.DepositZeroAmount.selector));
        vm.prank(user1);
        deposited = IRebalancePool(rebalancePool).deposit(9 * price, receiver, 0);
        // 5 deposit -------------------------------------------------------------

        // check min deposit amount
        setUp_collateral(1 ether, 0 ether); // add more minter
        deal(address(peggedToken), user1, 3 * price);
        vm.expectRevert(
            abi.encodeWithSelector(IRebalancePool.DepositAmountLessThanMinimum.selector, 1 * price, 2 * price)
        );
        vm.prank(user1);
        IRebalancePool(rebalancePool).deposit(3 * price, receiver, 2 * price);
        // 6 deposit --------------------------------------------------------
    }

    function test_depositWithdraw1() public {
        _depositWithdraw(user1);
    }

    function test_depositWithdraw2() private {
        _depositWithdraw(user2);
    }

    // TODO: check stake owners
}
