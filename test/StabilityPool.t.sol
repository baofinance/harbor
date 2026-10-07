// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {Token} from "@bao/Token.sol";

import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";

import {DecrementalFloatingPoint_v2} from "@harbor/math/DecrementalFloatingPoint_v2.sol";

import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";

import {TestMinterFeeSetUp} from "@harbor-test/Minter_fees.t.sol";
import {TestMinterMarketConfig} from "@harbor-test/config/TestMinterMarketConfig.sol";
import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {MarketDeployRun} from "@harbor-test/harness/MarketDeployRun.sol";
import {MockStabilityPoolMarketDeployRun} from "@harbor-test/harness/MockStabilityPoolMarketDeployRun.sol";
import {MockStabilityPool} from "@harbor-test/mocks/MockStabilityPool.sol";
import {MockSTEAM} from "@harbor-test/mocks/MockSTEAM.sol";
import {StabilityPool_vN} from "@harbor-test/mocks/StabilityPool_vN.sol";

contract TestStabilityPoolSetUp is TestMinterFeeSetUp {
    address stabilityPoolCollateral;
    address steam; // the reward token formerly known as STEAM
    address user1;
    address user2;
    address rewardDepositor;
    address rebalancer;
    address rewardManager;

    /// @dev The suite's own actors and reward token. Each pool the run deploys has them granted and registered
    ///      afterwards (`_grantPoolTestRoles`).
    function setUpFork() internal virtual override {
        super.setUpFork();

        steam = address(new MockSTEAM());
        vm.label(steam, "STEAM");

        rewardDepositor = makeAddr("rewardDepositor");
        rebalancer = makeAddr("rebalancer");
        // A real address, not the zero one it defaulted to: registering reward tokens is `onlyOwnerOrRoles`,
        // so a reward manager distinct from the owner is what keeps the ROLE path covered rather than the
        // owner path standing in for it.
        rewardManager = makeAddr("rewardManager");
    }

    /// @dev The pool suites read pool internals, so the run puts `MockStabilityPool` behind each pool it
    ///      deploys; this level of the suites uses the collateral pool alone.
    function newDeployRun() internal virtual override returns (MarketDeployRun) {
        return
            new MockStabilityPoolMarketDeployRun(
                owner(),
                treasury(),
                HarborDeployRun.Cut.CollateralPool,
                new TestMinterMarketConfig()
            );
    }

    /// @dev The roles and reward token this SUITE needs, which the deploy has no reason to know about: it
    ///      grants the pool's roles to the predicted manager, not to test actors, and `steam` is a reward
    ///      token that exists only here. Shared because every pool the suites stand up needs the same.
    /// @dev Granted after the deploy, as the owner the run handed the pool to - test-actor glue, kept out of
    ///      the deploy so the run's sequence stays production's.
    function _grantPoolTestRoles(address stabilityPool) internal {
        vm.startPrank(owner());
        IBaoRoles(stabilityPool).grantRoles(
            rewardManager,
            IMultipleRewardDistributor(stabilityPool).REWARD_MANAGER_ROLE()
        );
        IBaoRoles(stabilityPool).grantRoles(
            rewardDepositor,
            IMultipleRewardDistributor(stabilityPool).REWARD_DEPOSITOR_ROLE()
        );
        IBaoRoles(stabilityPool).grantRoles(rebalancer, IStabilityPool_v3(stabilityPool).REBALANCER_ROLE());
        IMultipleRewardDistributor(stabilityPool).registerRewardToken(steam);
        vm.stopPrank();
    }

    function setUp() public virtual override {
        super.setUp();

        // Deployed by the run, already carrying its config, its reward tokens and the roles the deploy grants.
        // Only what is test-specific is added below.
        stabilityPoolCollateral = deployRun.stabilityPoolAddress(
            marketConfig,
            HarborDeployer.StabilityPoolType.Collateral
        );
        vm.label(stabilityPoolCollateral, "stabilityPoolCollateral");
        _grantPoolTestRoles(stabilityPoolCollateral);

        user1 = makeAddr("user1");
        vm.startPrank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();

        user2 = makeAddr("user2");
        vm.startPrank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        vm.stopPrank();
    }

    function _beginWithdrawal(address user) internal {
        vm.startPrank(user);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user);
        vm.warp(start + 1);
    }

    function test_initOnly(address stabilityPool) internal view {
        assertEq(IBaoOwnable(stabilityPool).owner(), owner());
        assertEq(IStabilityPool_v3(stabilityPool).ASSET_TOKEN(), peggedToken);
        assertEq(IERC20(stabilityPool).totalSupply(), 0);
    }
}

contract TestStabilityPoolInit is TestStabilityPoolSetUp {
    using SafeERC20 for IERC20;

    /// The deployed pool is owned by the market owner, takes the pegged token, and starts with nothing deposited.
    function test_initOnly() public view {
        test_initOnly(stabilityPoolCollateral);
    }

    /// Only the owner upgrades the pool: for anyone else it reverts, and the owner's upgrade installs the new
    /// implementation.
    function testUpgrade() public {
        // Only owner can upgrade
        vm.startPrank(user1);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        UUPSUpgradeable(stabilityPoolCollateral).upgradeToAndCall(address(0), "");
        vm.stopPrank();

        address newImplementation = address(new StabilityPool_vN(minter));

        // Perform the upgrade as the owner
        vm.startPrank(owner());
        UUPSUpgradeable(stabilityPoolCollateral).upgradeToAndCall(newImplementation, "");
        vm.stopPrank();

        // Verify the upgrade was successful by calling the new version function
        assertEq(
            StabilityPool_vN(stabilityPoolCollateral).version(),
            "v3",
            "Upgrade should succeed and new function should be available"
        );
    }
}

contract TestStabilityPoolInitEvents is TestStabilityPoolSetUp {
    /// @dev A pool implementation built from the market config, as the deploy builds one. Building it reads the
    ///      config - external calls - so it must not sit under a cheatcode that binds to the next call.
    function _newStabilityPoolImplementation() private returns (address implementation) {
        implementation = address(
            new StabilityPool_v3(
                minter,
                marketConfig.stabilityPoolWithdrawalDelay(),
                marketConfig.stabilityPoolWithdrawalPeriod(),
                marketConfig.minTotalSupply(),
                "Test SP",
                "tSP"
            )
        );
    }

    /// Constructing the implementation disables its initializers, so only a proxy in front of it can be initialised.
    function test_initEventsImplementation() public {
        // Hoisted: the config reads are external calls, and the `expectEmit` below binds to the NEXT call - which
        // must be the construction, not these reads.
        uint256 withdrawalDelay = marketConfig.stabilityPoolWithdrawalDelay();
        uint256 withdrawalPeriod = marketConfig.stabilityPoolWithdrawalPeriod();
        uint256 minTotalSupply = marketConfig.minTotalSupply();

        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        address(new StabilityPool_v3(minter, withdrawalDelay, withdrawalPeriod, minTotalSupply, "Test SP", "tSP"));
    }

    /// The implementation's initializers are disabled when it is constructed, so initialising it directly reverts.
    function test_initialize_onTheImplementation_reverts() public {
        address implementation = _newStabilityPoolImplementation();
        // Hoisted: reading the fee off the config is an external call, and under `expectRevert` it would be the call
        // the expectation binds to.
        uint256 earlyWithdrawalFee = marketConfig.stabilityPoolEarlyWithdrawalFeeRatio();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        StabilityPool_v3(implementation).initialize(address(this), owner(), earlyWithdrawalFee, treasury());
    }

    /// The deployed pool, initialised once by its deploy, refuses a second initialisation.
    function test_initialize_aSecondTime_reverts() public {
        // Hoisted: reading the fee off the config is an external call, and under `expectRevert` it would be the call
        // the expectation binds to.
        uint256 earlyWithdrawalFee = marketConfig.stabilityPoolEarlyWithdrawalFeeRatio();

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        StabilityPool_v3(stabilityPoolCollateral).initialize(address(this), owner(), earlyWithdrawalFee, treasury());
    }

    /// Initialising a proxy points it at the implementation, makes the deployer its owner and marks it initialised;
    /// handed to the market owner, it is a pool like the deployed one.
    function test_initEvents() public {
        address implementation = _newStabilityPoolImplementation();
        // Hoisted: reading the fee off the config is an external call that emits nothing, and the
        // `expectEmit`s below bind to the NEXT call - which must be the proxy deployment, not this read.
        uint256 earlyWithdrawalFee = marketConfig.stabilityPoolEarlyWithdrawalFeeRatio();

        vm.expectEmit();
        emit IERC1967.Upgraded(implementation);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call

        address stabilityPool = UnsafeUpgrades.deployUUPSProxy(
            implementation, // "StabilityPool_v3.sol",
            abi.encodeCall(StabilityPool_v3.initialize, (address(this), owner(), earlyWithdrawalFee, treasury()))
        );
        IBaoOwnable(stabilityPool).transferOwnership(owner());

        test_initOnly(stabilityPool);
    }

    /// Initialisation reverts on an early-withdrawal fee above 100%, naming the fee.
    function test_initialize_invalidFee_reverts() public {
        address implementation = _newStabilityPoolImplementation();
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.InvalidFee.selector, 1 ether + 1));
        UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeCall(StabilityPool_v3.initialize, (address(this), owner(), 1 ether + 1, treasury()))
        );
    }

    /// Initialisation reverts on an early-withdrawal fee of exactly 100%, naming the fee: at 100% a withdrawal outside the
    /// window would pay its whole amount as fee, leave the receiver nothing and be refused - the window a lock.
    function test_initialize_feeOfOneHundredPercent_reverts() public {
        address implementation = _newStabilityPoolImplementation();
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.InvalidFee.selector, 1 ether));
        UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeCall(StabilityPool_v3.initialize, (address(this), owner(), 1 ether, treasury()))
        );
    }

    /// The largest fee initialisation accepts is one wei below 100%.
    function test_initialize_feeJustBelowOneHundredPercent_isAccepted() public {
        address implementation = _newStabilityPoolImplementation();
        address stabilityPool = UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeCall(StabilityPool_v3.initialize, (address(this), owner(), 1 ether - 1, treasury()))
        );
        assertEq(IStabilityPool_v3(stabilityPool).getEarlyWithdrawalFee(), 1 ether - 1, "the largest fee accepted");
    }

    /// Initialisation reverts on a zero fee receiver.
    function test_initialize_invalidFeeAddress_reverts() public {
        address implementation = _newStabilityPoolImplementation();
        // Hoisted: reading the fee off the config is an external call, and under `expectRevert` it would be
        // the call the expectation binds to - which succeeds, so the test would fail claiming no revert.
        uint256 earlyWithdrawalFee = marketConfig.stabilityPoolEarlyWithdrawalFeeRatio();

        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.InvalidFeeAddress.selector, address(0)));
        UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeCall(StabilityPool_v3.initialize, (address(this), owner(), earlyWithdrawalFee, address(0)))
        );
    }
}

contract TestStabilityPoolDepositWithdraw is TestStabilityPoolSetUp {
    /// Only the owner grants the pool's roles: for anyone else it reverts, and the owner's grant takes effect.
    function test_access() public {
        uint256 rebalancerRole = IStabilityPool_v3(stabilityPoolCollateral).REBALANCER_ROLE();
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoRoles(stabilityPoolCollateral).grantRoles(address(this), rebalancerRole);

        vm.startPrank(owner());
        IBaoRoles(stabilityPoolCollateral).grantRoles(address(this), rebalancerRole);
        vm.stopPrank();
        assertTrue(
            IBaoRoles(stabilityPoolCollateral).hasAllRoles(address(this), rebalancerRole),
            "the owner's grant takes effect"
        );
    }

    /// A depositor's round trip through the pool: a deposit beyond the caller's balance reverts in the token;
    /// deposits and withdrawals move tokens and stake one-for-one; a withdrawal beyond the stake reverts; the
    /// last holder's full withdrawal stops at the pool's supply floor, which stays theirs; a deposit-all takes the
    /// caller's whole balance; and a deposit that would credit less than the caller's minimum reverts.
    function test_depositWithdraw() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        // more than holding
        setUp_collateral(20 ether, 0 ether);
        deal(peggedToken, user1, 10 * price);
        assertEq(IERC20(peggedToken).balanceOf(user1), 10 * price, "user1 has");
        // user1 holds 10*price but deposits 20*price; the OZ-ERC20 pegged token's transferFrom reverts on
        // insufficient balance (allowance is max from setUp), and SafeERC20 bubbles it unchanged.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user1, 10 * price, 20 * price)
        );
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(20 * price, user1, 0);
        vm.stopPrank();
        // 1 deposit -----------------------------------------------------------

        // $2 deposit
        assertEq(IERC20(peggedToken).balanceOf(user1), 10 * price);
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 0);
        vm.startPrank(user1);
        uint256 deposited = IStabilityPool_v3(stabilityPoolCollateral).deposit(2 * price, user1, 0);
        vm.stopPrank();
        // 2 deposit ------------------------------------------------------------------------------
        assertEq(deposited, 2 * price, "returned value");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 2 * price);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 2 * price);
        assertEq(IERC20(peggedToken).balanceOf(user1), 8 * price);

        // $3 withdrawal
        _beginWithdrawal(user1);
        vm.startPrank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPool_v3.WithdrawAmountExceedsBalance.selector, 3 * price, 2 * price)
        );
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(3 * price, user1, 0);
        vm.stopPrank();
        // 1 withdraw ---------------------------------------------
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 2 * price);

        // $5 second deposit
        vm.startPrank(user1);
        deposited = IStabilityPool_v3(stabilityPoolCollateral).deposit(5 * price, user1, 0);
        vm.stopPrank();
        // 3 deposit ------------------------------------------------------------
        assertEq(deposited, 5 * price, "returned value 5");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 7 * price);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 7 * price);

        // withdraw some
        _beginWithdrawal(user1);
        vm.startPrank(user1);
        uint256 withdrawn = IStabilityPool_v3(stabilityPoolCollateral).withdraw(4 * price, user1, 0);
        vm.stopPrank();
        // 2 withdraw ---------------------------------------------------------------------------
        assertEq(withdrawn, 4 * price, "withdraw 4");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 3 * price);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 3 * price);

        // withdraw rest - the last holder is capped at the headroom, so the floor stays behind (and stays theirs)
        uint256 floor = IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY();
        _beginWithdrawal(user1);
        vm.startPrank(user1);
        withdrawn = IStabilityPool_v3(stabilityPoolCollateral).withdraw(type(uint256).max, user1, 0);
        vm.stopPrank();
        // 3 withdraw ---------------------------------------------------------------------------
        assertEq(withdrawn, 3 * price - floor, "withdraw 3 (capped at the floor)");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), floor);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), floor);

        // deposit all remaining - on top of the retained floor, restoring the full 10
        vm.startPrank(user1);
        deposited = IStabilityPool_v3(stabilityPoolCollateral).deposit(type(uint256).max, user1, 0);
        vm.stopPrank();
        // 4 deposit ------------------------------------------------------------------------------
        assertEq(deposited, 10 * price - floor, "returned value 10 less the floor already held");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 10 * price);
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 10 * price);
        assertEq(IERC20(peggedToken).balanceOf(user1), 0);

        // check min deposit amount
        setUp_collateral(1 ether, 0 ether); // add more minter
        deal(address(peggedToken), user1, 3 * price);
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPool_v3.DepositAmountLessThanMinimum.selector, 1 * price, 2 * price)
        );
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(1 * price, user1, 2 * price);
        vm.stopPrank();
        // 5 deposit ------------------------------------------------------------------
    }

    /// A deposit made for another account takes the caller's tokens and credits the receiver's stake: the caller
    /// gains no stake, the receiver's own tokens are untouched, and the event names the caller as the payer.
    function test_deposit_forAnotherAccount_takesTheCallersTokensAndCreditsTheReceiver() public {
        (uint256 callerHolds, ) = setUp_collateral(2 ether, 0 ether, user1);
        (uint256 receiverHolds, ) = setUp_collateral(2 ether, 0 ether, user2);
        uint256 amount = callerHolds / 4;

        vm.startPrank(user1);
        vm.expectEmit(stabilityPoolCollateral);
        emit IStabilityPool_v3.Deposit(user1, user2, amount);
        uint256 deposited = IStabilityPool_v3(stabilityPoolCollateral).deposit(amount, user2, 0);
        vm.stopPrank();

        assertEq(deposited, amount, "the whole amount is deposited");
        assertEq(IERC20(peggedToken).balanceOf(user1), callerHolds - amount, "the caller pays the amount");
        assertEq(IERC20(peggedToken).balanceOf(user2), receiverHolds, "the receiver's own tokens are untouched");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), amount, "the pool holds the amount");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), amount, "the receiver is credited");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user1), 0, "the caller is credited nothing");
    }

    /// A deposit of nothing reverts, naming the pegged token: an amount of 0 from a holder of pegged, and the
    /// deposit-all sentinel from a holder of none.
    function test_deposit_ofNothing_revertsZeroInputBalance() public {
        setUp_collateral(2 ether, 0 ether, user1);
        assertEq(IERC20(peggedToken).balanceOf(user2), 0, "fixture: user2 holds no pegged");

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, peggedToken));
        IStabilityPool_v3(stabilityPoolCollateral).deposit(0, user1, 0);
        vm.stopPrank();

        vm.startPrank(user2);
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, peggedToken));
        IStabilityPool_v3(stabilityPoolCollateral).deposit(type(uint256).max, user2, 0);
        vm.stopPrank();
    }

    /// A deposit credited to the zero address reverts, naming it; the same deposit credited to the caller succeeds.
    function test_deposit_toTheZeroAddress_reverts() public {
        (uint256 amount, ) = setUp_collateral(2 ether, 0 ether, user1);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.InvalidReceiver.selector, address(0)));
        IStabilityPool_v3(stabilityPoolCollateral).deposit(amount, address(0), 0);
        assertEq(IStabilityPool_v3(stabilityPoolCollateral).deposit(amount, user1, 0), amount, "to the caller it succeeds");
        vm.stopPrank();
    }

    /// A withdrawal paid to the zero address reverts, naming it - for the depositor, inside their window - and the
    /// same withdrawal paid to the depositor succeeds.
    function test_withdraw_toTheZeroAddress_reverts() public {
        (uint256 amount, ) = setUp_collateral(2 ether, 0 ether, user1);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(amount, user1, 0);
        vm.stopPrank();
        _beginWithdrawal(user1);

        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.InvalidReceiver.selector, address(0)));
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(amount / 2, address(0), 0);
        assertEq(
            IStabilityPool_v3(stabilityPoolCollateral).withdraw(amount / 2, user1, 0),
            amount / 2,
            "to the depositor it succeeds"
        );
        vm.stopPrank();
    }

    /// A withdrawal debits the caller's own stake, so paying for another account's deposit gives the payer nothing
    /// to withdraw: inside its own window, and even naming the stake's owner as the receiver, the payer's withdrawal
    /// reverts against its zero balance.
    function test_withdraw_revertsForThePayerOfADepositForAnotherAccount() public {
        (uint256 payment, ) = setUp_collateral(2 ether, 0 ether, user1);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(payment, user2, 0);
        vm.stopPrank();

        _beginWithdrawal(user1);
        vm.startPrank(user1);
        vm.expectRevert(abi.encodeWithSelector(IStabilityPool_v3.WithdrawAmountExceedsBalance.selector, payment, 0));
        IStabilityPool_v3(stabilityPoolCollateral).withdraw(payment, user2, 0);
        vm.stopPrank();
    }

    /// A withdrawal pays whichever receiver the caller names: it debits the caller's stake - here one another
    /// account paid for - and sends the tokens to the receiver, not to the caller.
    function test_withdraw_toAnotherAccount_debitsTheCallersStakeAndPaysTheReceiver() public {
        (uint256 payment, ) = setUp_collateral(2 ether, 0 ether, user1);
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(payment, user2, 0);
        vm.stopPrank();
        address receiver = makeAddr("receiver");
        uint256 amount = payment / 4;

        _beginWithdrawal(user2);
        vm.startPrank(user2);
        vm.expectEmit(stabilityPoolCollateral);
        emit IStabilityPool_v3.Withdraw(user2, receiver, amount);
        uint256 withdrawn = IStabilityPool_v3(stabilityPoolCollateral).withdraw(amount, receiver, 0);
        vm.stopPrank();

        assertEq(withdrawn, amount, "inside the window, the whole amount is withdrawn");
        assertEq(IERC20(peggedToken).balanceOf(receiver), amount, "the receiver is paid");
        assertEq(IERC20(peggedToken).balanceOf(user2), 0, "the caller is paid nothing");
        assertEq(IERC20(stabilityPoolCollateral).balanceOf(user2), payment - amount, "the caller's stake is debited");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), payment - amount, "the pool pays it out");
    }

    /// @notice previewDeposit forecasts exactly what deposit credits — for an explicit amount and for
    ///         the deposit-all sentinel — so a caller pricing a deposit never has to assume it is 1:1.
    ///         This is the guard that keeps the two in step if a deposit charge is ever introduced.
    function test_previewDeposit_matchesWhatDepositCredits() public {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(20 ether, 0 ether);
        deal(peggedToken, user1, 10 * price);

        vm.startPrank(user1);
        uint256 previewedExplicit = IStabilityPool_v3(stabilityPoolCollateral).previewDeposit(4 * price);
        uint256 creditedExplicit = IStabilityPool_v3(stabilityPoolCollateral).deposit(4 * price, user1, 0);
        assertEq(previewedExplicit, creditedExplicit, "explicit amount: forecast matches the credit");

        // The sentinel resolves against the caller's remaining balance, exactly as deposit reads it.
        uint256 previewedAll = IStabilityPool_v3(stabilityPoolCollateral).previewDeposit(type(uint256).max);
        assertEq(previewedAll, 6 * price, "deposit-all previews the caller's whole remaining balance");
        uint256 creditedAll = IStabilityPool_v3(stabilityPoolCollateral).deposit(type(uint256).max, user1, 0);
        vm.stopPrank();
        assertEq(previewedAll, creditedAll, "deposit-all: forecast matches the credit");
    }

    /// A withdrawal request opens the configured window: it starts the configured delay after the request and stays
    /// open for the configured period.
    function test_requestWithdrawal_applies_startDelay_and_window() public {
        uint256 requestedAt = block.timestamp;
        vm.startPrank(user1);
        IStabilityPool_v3(stabilityPoolCollateral).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, uint64 end) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalRequest(user1);
        assertEq(start, requestedAt + marketConfig.stabilityPoolWithdrawalDelay(), "opens after the configured delay");
        assertEq(end, start + marketConfig.stabilityPoolWithdrawalPeriod(), "open for the configured period");
    }

    /// The pool reports the withdrawal window its market's config sets.
    function test_getWithdrawalWindow_matches_config() public view {
        (uint64 startDelay, uint64 endWindow) = IStabilityPool_v3(stabilityPoolCollateral).getWithdrawalWindow();
        assertEq(startDelay, marketConfig.stabilityPoolWithdrawalDelay(), "the configured delay");
        assertEq(endWindow, marketConfig.stabilityPoolWithdrawalPeriod(), "the configured period");
    }
}

contract StabilityPoolCompoundingTest is TestStabilityPoolSetUp {
    using DecrementalFloatingPoint_v2 for uint128;

    /// A balance compounds by the ratio of the pool's current product to its product at deposit: scaled by the ratio
    /// of their magnitudes, then divided by 1e9 for each exponent rung between them, rounding down - and zero beyond
    /// eight rungs.
    function test_CompoundedAmount_() public view {
        // Each case: [initialAmount, initialExponent, initialMagnitude, currentExponent, currentMagnitude,
        // expectedResult]
        uint256[6][16] memory testCases;

        // No change (exponentDiff = 0, same magnitude)
        testCases[0] = [uint256(1e18), 0, 1e36, 0, 1e36, 1e18];

        // No exponent change, magnitude reduced by half
        testCases[1] = [uint256(1e18), 0, 1e36, 0, 5e35, 5e17];

        // Single exponent change (exponentDiff = 1), same magnitude
        testCases[2] = [uint256(1e18), 0, 1e36, 1, 1e36, 1e9]; // divided by SCALE_FACTOR (1e9)

        // Single exponent change with magnitude reduction
        testCases[3] = [uint256(1e18), 0, 1e36, 1, 5e35, 5e8]; // (1e18 * 5e35 / 1e36) / 1e9

        // Double exponent change (exponentDiff = 2)
        testCases[4] = [uint256(1e18), 0, 1e36, 2, 1e36, 1]; // divided by SCALE_FACTOR^2 (1e18)

        // Maximum allowed exponent change (exponentDiff = 8)
        testCases[5] = [uint256(1e27), 0, 1e36, 8, 1e36, 0]; // 1e27 / 1e9^8 = 1e27 / 1e72, rounds down to 0

        // A much larger balance still rounds down to nothing at the maximum change: only 1e72 and above survive it
        testCases[6] = [uint256(1e45), 0, 1e36, 8, 1e36, 0]; // 1e45 / 1e72, rounds down to 0

        // Or test a smaller exponent difference:
        testCases[7] = [uint256(1e36), 0, 1e36, 4, 1e36, 1e0]; // 1e36 / 1e36 = 1

        // Beyond maximum (exponentDiff = 9) - should return 0
        testCases[8] = [uint256(1e18), 0, 1e36, 9, 1e36, 0];

        // Large initial amount, small exponent change
        testCases[9] = [uint256(1e24), 0, 1e36, 1, 1e36, 1e15];

        // Edge case - very small initial amount
        testCases[10] = [uint256(1000), 0, 1e36, 1, 1e36, 0]; // 1000 / 1e9 = 0 (integer division)

        // Starting with non-zero exponent
        testCases[11] = [uint256(1e18), 2, 1e36, 3, 1e36, 1e9]; // exponentDiff = 1

        // Magnitude increase (theoretical, though unlikely in practice)
        testCases[12] = [uint256(1e18), 0, 5e35, 0, 1e36, 2e18];

        // Complex case with both exponent and magnitude changes
        testCases[13] = [uint256(2e18), 1, 8e35, 3, 4e35, 1]; // (2e18 * 4e35 / 8e35) / 1e9^2 = 1e18 / 1e18 = 1

        // The widest amount the balance record stores (uint128), unchanged
        testCases[14] = [uint256(type(uint128).max), 0, 1e36, 0, 1e36, type(uint128).max];

        // Precision loss edge case
        testCases[15] = [uint256(1e12), 0, 1e36, 3, 1e27, 0]; // (1e12 * 1e27 / 1e36) / 1e9^3 = 1e3 / 1e27, rounds to 0

        for (uint i = 0; i < testCases.length; i++) {
            uint256 initialAmount = testCases[i][0];
            uint8 initialExponent = uint8(testCases[i][1]);
            uint120 initialMagnitude = uint120(testCases[i][2]);
            uint8 currentExponent = uint8(testCases[i][3]);
            uint120 currentMagnitude = uint120(testCases[i][4]);
            uint256 expectedResult = testCases[i][5];

            uint128 initialProduct = DecrementalFloatingPoint_v2.encode(initialExponent, initialMagnitude);
            uint128 currentProduct = DecrementalFloatingPoint_v2.encode(currentExponent, currentMagnitude);

            uint256 actualResult = MockStabilityPool(stabilityPoolCollateral).__getCompoundedBalance(
                initialAmount,
                initialProduct,
                currentProduct
            );

            assertEq(actualResult, expectedResult, string(abi.encodePacked("Test case ", vm.toString(i), " failed")));
        }
    }

    function test_CompoundedAmountEdgeCases() public view {
        // Test the boundary at exponent difference = 8 vs 9
        uint128 initialProduct = DecrementalFloatingPoint_v2.encode(0, DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION);

        // Exactly 8 exponent difference - should work
        uint128 maxAllowedProduct = DecrementalFloatingPoint_v2.encode(
            8,
            DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION
        );
        uint256 result8 = MockStabilityPool(stabilityPoolCollateral).__getCompoundedBalance(
            1e72,
            initialProduct,
            maxAllowedProduct
        );
        assertEq(result8, 1, "8 exponent difference: 1e72 / 1e9^8 = 1");

        // 9 exponent difference - should return 0
        uint128 tooMuchProduct = DecrementalFloatingPoint_v2.encode(9, DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION);
        uint256 result9 = MockStabilityPool(stabilityPoolCollateral).__getCompoundedBalance(
            1e27,
            initialProduct,
            tooMuchProduct
        );
        assertEq(result9, 0, "9 exponent difference should return 0");
    }

    /// The ceiling rescale the reward divisor moves through on a loss takes nothing to nothing.
    function test_scaleAdjustedValueCeil_isZero_forAZeroValue() public view {
        uint128 fromProduct = DecrementalFloatingPoint_v2.encode(0, DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION);
        uint128 toProduct = DecrementalFloatingPoint_v2.encode(1, DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION);
        assertEq(
            MockStabilityPool(stabilityPoolCollateral).__scaleAdjustedValueCeil(0, toProduct, fromProduct),
            0,
            "nothing rescales to nothing"
        );
    }

    /// A product only ever falls, so a rescale to an earlier exponent than its own has no value: it gives 0 rather
    /// than underflowing the exponent difference.
    function test_scaleAdjustedValueCeil_isZero_whenTheProductRose() public view {
        uint128 fromProduct = DecrementalFloatingPoint_v2.encode(3, DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION);
        uint128 toProduct = DecrementalFloatingPoint_v2.encode(1, DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION);
        assertEq(
            MockStabilityPool(stabilityPoolCollateral).__scaleAdjustedValueCeil(1e27, toProduct, fromProduct),
            0,
            "a rescale to an earlier exponent gives 0"
        );
    }

    /// Like the floor rescale, the ceiling rescale reaches eight exponent rungs and no further: past eight it gives 0
    /// (1e9^9 has no representation), and at exactly eight 1e72 still rescales to 1 - rounded up from exactly 1.
    function test_scaleAdjustedValueCeil_pastEightRungsIsZero_atEightRescales() public view {
        uint128 fromProduct = DecrementalFloatingPoint_v2.encode(0, DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION);
        uint128 eightRungsOn = DecrementalFloatingPoint_v2.encode(8, DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION);
        uint128 nineRungsOn = DecrementalFloatingPoint_v2.encode(9, DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION);
        assertEq(
            MockStabilityPool(stabilityPoolCollateral).__scaleAdjustedValueCeil(1e72, eightRungsOn, fromProduct),
            1,
            "eight rungs: 1e72 / 1e9^8 = 1"
        );
        assertEq(
            MockStabilityPool(stabilityPoolCollateral).__scaleAdjustedValueCeil(1e72, nineRungsOn, fromProduct),
            0,
            "nine rungs: past the reach of the rescale"
        );
    }
    function test_CompoundedAmountScaleFactorProgression() public view {
        // Test that each exponent increment divides by SCALE_FACTOR
        uint256 initialAmount = 1e72; // 1e9^8: every one of the eight rungs divides it exactly, leaving at least 1
        uint128 baseProduct = DecrementalFloatingPoint_v2.encode(0, DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION);

        uint256 previousResult = initialAmount;

        for (uint8 exponent = 1; exponent <= 8; exponent++) {
            uint128 currentProduct = DecrementalFloatingPoint_v2.encode(
                exponent,
                DecrementalFloatingPoint_v2.MAGNITUDE_PRECISION
            );
            uint256 currentResult = MockStabilityPool(stabilityPoolCollateral).__getCompoundedBalance(
                initialAmount,
                baseProduct,
                currentProduct
            );

            // Each step should divide by SCALE_FACTOR (1e9)
            uint256 expectedResult = previousResult / DecrementalFloatingPoint_v2.SCALE_FACTOR;

            assertEq(
                currentResult,
                expectedResult,
                string(abi.encodePacked("Scale factor progression failed at exponent ", vm.toString(exponent)))
            );

            previousResult = expectedResult;
        }
    }

    function test_CompoundedAmountConsistencyWithMul() public view {
        // Verify that compoundedAmount is consistent with the mul function's behavior

        uint256 initialAmount = 1e18;
        uint128 initialProduct = DecrementalFloatingPoint_v2.init();

        // Apply a factor using mul
        uint128 factor = 5e17; // 0.5
        uint128 afterMulProduct = initialProduct.mul(factor);

        // Calculate what the balance should be
        uint256 expectedBalance = (initialAmount * factor) / 1e18;
        uint256 actualBalance = MockStabilityPool(stabilityPoolCollateral).__getCompoundedBalance(
            initialAmount,
            initialProduct,
            afterMulProduct
        );

        assertEq(actualBalance, expectedBalance, "CompoundedAmount should be consistent with mul operation");
    }

    function test_CompoundedAmountOverflowSafety_() public view {
        // Test with maximum values to ensure no overflow
        uint256 maxAmount = type(uint128).max; // the widest amount the balance record stores
        uint128 maxMagnitudeProduct = DecrementalFloatingPoint_v2.encode(0, type(uint120).max);
        uint128 minMagnitudeProduct = DecrementalFloatingPoint_v2.encode(0, 1);

        // This should not overflow or revert
        uint256 result = MockStabilityPool(stabilityPoolCollateral).__getCompoundedBalance(
            maxAmount,
            minMagnitudeProduct,
            maxMagnitudeProduct
        );

        // The full product, under 2^248: no overflow, and nothing lost
        assertEq(result, maxAmount * type(uint120).max, "the amount scaled by the whole magnitude ratio");
    }
}
