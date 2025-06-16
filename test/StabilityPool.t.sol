// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {StabilityPool_v1} from "src/minter/StabilityPool_v1.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";

import {Token} from "@bao/Token.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";

import {Deployed} from "@bao/Deployed.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {IBaoUSD} from "test/IBaoUSD.sol";
import {TestMinterFeeSetUp} from "test/Minter_fees.t.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

import {console2} from "forge-std/console2.sol";

contract TestStabilityPoolSetUp is TestMinterFeeSetUp {
    address stabilityPoolCollateral;
    string nameCollateral;
    string symbolCollateral;

    address user1;
    address user2;

    function _setupStabilityPool(
        address liquidationToken
    ) internal returns (address stabilityPool, string memory name, string memory symbol) {
        string memory pegged = IERC20Metadata(peggedToken).symbol();
        string memory liquidation = IERC20Metadata(liquidationToken).symbol();
        string memory collateral = IERC20Metadata(collateralToken).symbol();
        symbol = string.concat("pool-", pegged, "-", collateral, "-", liquidation);
        name = string.concat("Zhenglong stability ", symbol);
        stabilityPool = UnsafeUpgrades.deployUUPSProxy(
            address(new StabilityPool_v1(minter, liquidationToken, 1 weeks)), // "StabilityPool_v1.sol",
            abi.encodeCall(StabilityPool_v1.initialize, (owner, name, symbol))
        );
        IBaoRoles(stabilityPool).grantRoles(owner, IStabilityPool(stabilityPool).REWARD_MANAGER_ROLE());
        vm.prank(owner);
        IMultipleRewardDistributor(stabilityPool).registerRewardToken(liquidationToken, stabilityPool);

        IBaoOwnable(stabilityPool).transferOwnership(owner);
    }

    function setUp() public virtual override(TestMinterFeeSetUp) {
        super.setUp();

        (stabilityPoolCollateral, nameCollateral, symbolCollateral) = _setupStabilityPool(wrappedCollateralToken);

        user1 = vm.createWallet("user1").addr;
        vm.prank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        user2 = vm.createWallet("user2").addr;
        vm.prank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
    }

    function test_initOnly(address sp, address liquidateTo, string memory name, string memory symbol) internal view {
        assertEq(StabilityPool_v1(sp).owner(), owner);
        assertEq(IStabilityPool(sp).ASSET_TOKEN(), peggedToken);
        assertEq(IStabilityPool(sp).LIQUIDATION_TOKEN(), liquidateTo);
        assertEq(IStabilityPool(sp).MINTER(), minter);
        assertEq(IERC20(sp).totalSupply(), 0);
        assertEq(IERC20Metadata(sp).name(), name);
        assertEq(IERC20Metadata(sp).symbol(), symbol);
        assertEq(IERC20Metadata(sp).decimals(), 18);
    }
}

contract TestStabilityPoolInit is TestStabilityPoolSetUp {
    using SafeERC20 for IERC20;

    function test_initOnly() public view {
        test_initOnly(stabilityPoolCollateral, wrappedCollateralToken, nameCollateral, symbolCollateral);
    }
}

contract TestStabilityPoolInitEvents is TestStabilityPoolSetUp {
    function test_initEventsImplementation() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        address(new StabilityPool_v1(minter, wrappedCollateralToken, 1 weeks));
    }

    function test_initEvents(address liquidateTo) internal {
        address sp = address(new StabilityPool_v1(minter, liquidateTo, 1 weeks));
        vm.expectEmit();
        emit IERC1967.Upgraded(address(sp));
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call

        address spProxy = UnsafeUpgrades.deployUUPSProxy(
            sp, // "StabilityPool_v1.sol",
            abi.encodeCall(StabilityPool_v1.initialize, (owner, "name", "symbol"))
        );
        IBaoOwnable(spProxy).transferOwnership(owner);

        test_initOnly(spProxy, liquidateTo, "name", "symbol");
    }

    function test_initEventsCollateral() public {
        test_initEvents(wrappedCollateralToken);
    }

    function test_initEventsLeveraged() public {
        test_initEvents(leveragedToken);
    }

    function test_initEventsBad() public {
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidLiquidationToken.selector, peggedToken));
        new StabilityPool_v1(minter, peggedToken, 1 weeks);

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.InvalidPeriodLength.selector, 1 days - 1));
        new StabilityPool_v1(minter, peggedToken, 1 days - 1);
    }
}

contract TestStabilityPoolDepositWithdraw is TestStabilityPoolSetUp {
    function test_access() public {
        uint256 rebalancerRole = IStabilityPool(stabilityPoolCollateral).REBALANCER_ROLE();
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoRoles(stabilityPoolCollateral).grantRoles(address(this), rebalancerRole);

        vm.prank(owner);
        IBaoRoles(stabilityPoolCollateral).grantRoles(address(this), rebalancerRole);
    }

    function _depositWithdraw(address receiver) private {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        // more than holding
        setUp_collateral(20 ether, 0 ether);
        deal(peggedToken, user1, 10 * price);
        assertEq(IERC20(peggedToken).balanceOf(user1), 10 * price, "user1 has");
        vm.expectRevert(); // should be amount exceeds balance, but hey-ho BaoUSD
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(20 * price, receiver, 0);
        // 1 deposit -----------------------------------------------------------

        // $2 deposit
        assertEq(IERC20(peggedToken).balanceOf(user1), 10 * price);
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 0);
        vm.prank(user1);
        uint256 deposited = IStabilityPool(stabilityPoolCollateral).deposit(2 * price, receiver, 0);
        // 2 deposit ------------------------------------------------------------------------------
        assertEq(deposited, 2 * price, "returned value");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 2 * price);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(receiver), 2 * price);
        assertEq(IERC20(peggedToken).balanceOf(user1), 8 * price);

        // $3 withdrawal
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPool.WithdrawAmountExceedsBalance.selector, 3 * price, 2 * price)
        );
        IStabilityPool(stabilityPoolCollateral).withdraw(3 * price, receiver, 0);
        // 1 withdraw ---------------------------------------------
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(receiver), 2 * price);

        // $5 second deposit
        vm.prank(user1);
        deposited = IStabilityPool(stabilityPoolCollateral).deposit(5 * price, receiver, 0);
        // 3 deposit ------------------------------------------------------------
        assertEq(deposited, 5 * price, "returned value 5");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 7 * price);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(receiver), 7 * price);

        // withdraw some
        vm.prank(user1);
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(4 * price, receiver, 0);
        // 2 withdraw ---------------------------------------------------------------------------
        assertEq(withdrawn, 4 * price, "withdraw 4");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 3 * price);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(receiver), 3 * price);

        // withdraw rest
        vm.prank(user1);
        withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(type(uint256).max, receiver, 0);
        // 3 withdraw ---------------------------------------------------------------------------
        assertEq(withdrawn, 3 * price, "withdraw 3 (-1)");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 0);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(receiver), 0);

        // deposit -1
        vm.prank(user1);
        deposited = IStabilityPool(stabilityPoolCollateral).deposit(type(uint256).max, receiver, 0);
        // 4 deposit ------------------------------------------------------------------------------
        assertEq(deposited, 10 * price, "returned value 10");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 10 * price);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(receiver), 10 * price);
        assertEq(IERC20(peggedToken).balanceOf(user1), 0);

        // check min deposit amount
        setUp_collateral(1 ether, 0 ether); // add more minter
        deal(address(peggedToken), user1, 3 * price);
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPool.DepositAmountLessThanMinimum.selector, 1 * price, 2 * price)
        );
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(1 * price, receiver, 2 * price);
        // 5 deposit ------------------------------------------------------------------
    }

    function test_depositWithdraw1() public {
        _depositWithdraw(user1);
    }

    function test_depositWithdraw2() private {
        _depositWithdraw(user2);
    }
}
