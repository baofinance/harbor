// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";

import {MockERC20} from "test/mock/MockERC20.sol";
import {MockLinearMultipleRewardDistributor} from "test/mock/reward/distributor/MockLinearMultipleRewardDistributor.sol";
import "forge-std/Test.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {Useful} from "test/Useful.sol";

contract LinearMultipleRewardDistributorTest is Test {
    address owner;
    address manager;
    uint256 REWARD_MANAGER_ROLE = 1;
    address holder0;
    address holder1;
    address holder2;

    MockERC20 token0;
    MockERC20 token1;
    MockERC20 token2;

    // Constants
    address constant ZERO_ADDRESS = address(0);
    uint256 constant MAX_UINT = type(uint256).max;

    function setUp() public {
        owner = makeAddr("owner"); // need to transferOwnership for this to be the actual owner
        manager = makeAddr("manager");
        holder0 = makeAddr("holder0");
        holder1 = makeAddr("holder1");
        holder2 = makeAddr("holder2");

        token0 = new MockERC20("R0", "R0", 18);
        token1 = new MockERC20("R1", "R1", 18);
        token2 = new MockERC20("R2", "R2", 18);
    }

    // ======================= CONSTRUCTOR TESTS =======================

    function test_constructor_RevertOnInvalidPeriodLength() public {
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.InvalidPeriodLength.selector, 1));
        new MockLinearMultipleRewardDistributor(REWARD_MANAGER_ROLE, 1);

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.InvalidPeriodLength.selector, 1 days - 1));
        new MockLinearMultipleRewardDistributor(REWARD_MANAGER_ROLE, 1 days - 1);

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.InvalidPeriodLength.selector, 4 weeks + 1));
        new MockLinearMultipleRewardDistributor(REWARD_MANAGER_ROLE, 4 weeks + 1);
    }

    function test_constructor_SucceedsWithValidPeriodLength_Zero() public {
        MockLinearMultipleRewardDistributor distributor = new MockLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            0
        );
        // there is no easy way to check the reward period length
        // TODO: maybe warp forward and check it's function?
        // assertEq(distributor.REWARD_PERIOD_LENGTH(), 0);
        assert(address(distributor) != address(0));
    }

    function test_constructor_SucceedsWithValidPeriodLength_OneDay() public {
        MockLinearMultipleRewardDistributor distributor = new MockLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            1 days
        );
        // TODO: assertEq(distributor.REWARD_PERIOD_LENGTH(), 1 days);
        assert(address(distributor) != address(0));
    }

    function test_constructor_SucceedsWithValidPeriodLength_OneWeek() public {
        MockLinearMultipleRewardDistributor distributor = new MockLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            1 weeks
        );
        // TODO: assertEq(distributor.REWARD_PERIOD_LENGTH(), 1 weeks);
        assert(address(distributor) != address(0));
    }

    function test_constructor_SucceedsWithValidPeriodLength_TwoWeeks() public {
        MockLinearMultipleRewardDistributor distributor = new MockLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            2 weeks
        );
        // TODO: assertEq(distributor.REWARD_PERIOD_LENGTH(), 2 weeks);
        assert(address(distributor) != address(0));
    }

    function test_constructor_SucceedsWithValidPeriodLength_FourWeeks() public {
        MockLinearMultipleRewardDistributor distributor = new MockLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            4 weeks
        );
        // TODO: assertEq(distributor.REWARD_PERIOD_LENGTH(), 4 weeks);
        assert(address(distributor) != address(0));
    }

    // ======================= INITIALIZATION TESTS =======================

    function test_initialization_ZeroPeriod() public {
        MockLinearMultipleRewardDistributor distributor = new MockLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            0
        );
        distributor.initialize(owner);
        distributor.transferOwnership(owner);
        assertEq(distributor.owner(), owner);

        // TODO: assertEq(distributor.REWARD_PERIOD_LENGTH(), 0);
        assertEq(distributor.activeRewardTokens().length, 0);
        assertEq(distributor.historicalRewardTokens().length, 0);
        assertFalse(distributor.hasAnyRole(address(this), REWARD_MANAGER_ROLE));
    }

    function test_initialization_WithPeriod() public {
        MockLinearMultipleRewardDistributor distributor = new MockLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            1 days
        );
        distributor.initialize(owner);
        distributor.transferOwnership(owner);
        assertEq(distributor.owner(), owner);

        // TODO: assertEq(distributor.REWARD_PERIOD_LENGTH(), 1 days);
        assertEq(distributor.activeRewardTokens().length, 0);
        assertEq(distributor.historicalRewardTokens().length, 0);
        assertFalse(distributor.hasAnyRole(address(this), REWARD_MANAGER_ROLE));
    }

    // ======================= REWARD TOKEN MANAGEMENT TESTS =======================

    function _setupDistributor(uint40 rewardPeriodLength) internal returns (MockLinearMultipleRewardDistributor) {
        MockLinearMultipleRewardDistributor distributor = new MockLinearMultipleRewardDistributor(
            REWARD_MANAGER_ROLE,
            rewardPeriodLength
        );
        distributor.initialize(owner);
        distributor.grantRoles(manager, REWARD_MANAGER_ROLE);
        distributor.transferOwnership(owner);
        assertEq(distributor.owner(), owner);
        return distributor;
    }

    function test_registerRewardToken_RevertWhenNonManagerCall() public {
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        distributor.registerRewardToken(address(token0), holder0);
    }

    function test_registerRewardToken_RevertWhenDistributorIsZero() public {
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.RewardDistributorIsZero.selector));
        distributor.registerRewardToken(address(token0), ZERO_ADDRESS);
    }

    function test_registerRewardToken_RevertWhenDuplicated() public {
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);

        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.RegisterRewardToken(address(token0), holder0);
        distributor.registerRewardToken(address(token0), holder0);

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.DuplicatedRewardToken.selector));
        distributor.registerRewardToken(address(token0), holder0);

        vm.stopPrank();
    }

    function test_registerRewardToken_SucceedWithNewTokens() public {
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);

        // Register first token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.RegisterRewardToken(address(token0), holder0);
        distributor.registerRewardToken(address(token0), holder0);

        address[] memory activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 1);
        assertEq(activeTokens[0], address(token0));
        assertEq(distributor.distributors(address(token0)), holder0);

        // Register second token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.RegisterRewardToken(address(token1), holder1);
        distributor.registerRewardToken(address(token1), holder1);

        activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 2);
        assertEq(activeTokens[0], address(token0));
        assertEq(activeTokens[1], address(token1));
        assertEq(distributor.distributors(address(token1)), holder1);

        // Register third token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.RegisterRewardToken(address(token2), holder2);
        distributor.registerRewardToken(address(token2), holder2);

        activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 3);
        assertEq(activeTokens[0], address(token0));
        assertEq(activeTokens[1], address(token1));
        assertEq(activeTokens[2], address(token2));
        assertEq(distributor.distributors(address(token2)), holder2);

        vm.stopPrank();
    }

    function test_unregisterRewardToken_Success() public {
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);

        // Register all tokens
        distributor.registerRewardToken(address(token0), holder0);
        distributor.registerRewardToken(address(token1), holder1);
        distributor.registerRewardToken(address(token2), holder2);

        // Unregister first token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.UnregisterRewardToken(address(token0));
        distributor.unregisterRewardToken(address(token0));

        address[] memory activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 2);
        assertEq(distributor.distributors(address(token0)), ZERO_ADDRESS);

        address[] memory historicalTokens = distributor.historicalRewardTokens();
        assertEq(historicalTokens.length, 1);
        assertEq(historicalTokens[0], address(token0));

        // Unregister second token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.UnregisterRewardToken(address(token1));
        distributor.unregisterRewardToken(address(token1));

        activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 1);
        assertEq(activeTokens[0], address(token2));
        assertEq(distributor.distributors(address(token1)), ZERO_ADDRESS);

        historicalTokens = distributor.historicalRewardTokens();
        assertEq(historicalTokens.length, 2);
        assertEq(historicalTokens[0], address(token0));
        assertEq(historicalTokens[1], address(token1));

        // Unregister third token
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.UnregisterRewardToken(address(token2));
        distributor.unregisterRewardToken(address(token2));

        activeTokens = distributor.activeRewardTokens();
        assertEq(activeTokens.length, 0);
        assertEq(distributor.distributors(address(token2)), ZERO_ADDRESS);

        historicalTokens = distributor.historicalRewardTokens();
        assertEq(historicalTokens.length, 3);
        assertEq(historicalTokens[0], address(token0));
        assertEq(historicalTokens[1], address(token1));
        assertEq(historicalTokens[2], address(token2));

        vm.stopPrank();
    }

    function test_updateRewardDistributor_RevertWhenNonManagerCall() public {
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.prank(manager);
        distributor.registerRewardToken(address(token0), holder0);

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        distributor.updateRewardDistributor(address(token0), holder1);
    }

    function test_updateRewardDistributor_RevertWhenDistributorIsZero() public {
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);
        distributor.registerRewardToken(address(token0), holder0);

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.RewardDistributorIsZero.selector));
        distributor.updateRewardDistributor(address(token0), ZERO_ADDRESS);
        vm.stopPrank();
    }

    function test_updateRewardDistributor_RevertWhenNotActive() public {
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);
        distributor.registerRewardToken(address(token0), holder0);

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.NotActiveRewardToken.selector));
        distributor.updateRewardDistributor(address(token1), holder1);
        vm.stopPrank();
    }

    function test_updateRewardDistributor_Succeeds() public {
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);
        distributor.registerRewardToken(address(token0), holder0);

        assertEq(distributor.distributors(address(token0)), holder0);

        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.UpdateRewardDistributor(address(token0), holder0, holder1);
        distributor.updateRewardDistributor(address(token0), holder1);

        assertEq(distributor.distributors(address(token0)), holder1);
        vm.stopPrank();
    }

    function test_unregisterRewardToken_RevertWhenNonManagerCall() public {
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.prank(manager);
        distributor.registerRewardToken(address(token0), holder0);

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        distributor.unregisterRewardToken(address(token0));
    }

    function test_unregisterRewardToken_RevertWhenNotActive() public {
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.startPrank(manager);
        distributor.registerRewardToken(address(token0), holder0);
        distributor.unregisterRewardToken(address(token0));

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.NotActiveRewardToken.selector));
        distributor.unregisterRewardToken(address(token0));
        vm.stopPrank();
    }

    function test_unregisterRewardToken_RevertWhenDistributionNotFinished() public {
        // Skip test for zero period since it doesn't apply
        uint40 REWARD_PERIOD_LENGTH = 1 days;
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(REWARD_PERIOD_LENGTH);

        vm.startPrank(manager);
        distributor.registerRewardToken(address(token0), holder0);
        vm.stopPrank();

        // Mint tokens and approve
        token0.mint(holder0, 1000 ether);
        vm.prank(holder0);
        token0.approve(address(distributor), MAX_UINT);

        // Deposit reward
        vm.prank(holder0);
        distributor.depositReward(address(token0), 1000 ether);

        // Try to unregister
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.RewardDistributionNotFinished.selector));
        distributor.unregisterRewardToken(address(token0));
    }

    // ======================= DEPOSIT REWARD TESTS =======================

    function test_depositReward_RevertWhenTokenNotActive() public {
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.prank(manager);
        distributor.registerRewardToken(address(token0), holder0);

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.NotActiveRewardToken.selector));
        distributor.depositReward(address(token1), 0);
    }

    function test_depositReward_RevertWhenCallerNotDistributor() public {
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(1 days);

        vm.prank(manager);
        distributor.registerRewardToken(address(token0), holder0);

        vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.NotRewardDistributor.selector));
        distributor.depositReward(address(token0), 0);
    }

    function test_depositReward_SucceedsWithZeroPeriod() public {
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(0);

        vm.prank(manager);
        distributor.registerRewardToken(address(token0), holder0);

        // Mint tokens and approve
        token0.mint(holder0, 100_000 ether);
        vm.prank(holder0);
        token0.approve(address(distributor), MAX_UINT);

        // Deposit reward
        uint256 depositAmount = 1000 ether;

        vm.prank(holder0);
        vm.expectEmit(address(distributor));
        emit MockLinearMultipleRewardDistributor._accumulateReward_called(address(token0), depositAmount);
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.DepositReward(address(token0), depositAmount);
        distributor.depositReward(address(token0), depositAmount);

        assertEq(token0.balanceOf(address(distributor)), depositAmount);
    }

    struct RewardData {
        uint256 lastUpdate;
        uint256 finishAt;
        uint256 rate;
        uint256 queued;
    }

    struct PendingRewards {
        uint256 unlocked;
        uint256 locked;
    }

    function test_depositReward_SucceedsWithPeriod() public {
        uint40 rewardPeriodLength = 1 days;
        MockLinearMultipleRewardDistributor distributor = _setupDistributor(rewardPeriodLength);

        vm.prank(manager);
        distributor.registerRewardToken(address(token0), holder0);

        // Mint tokens and approve
        token0.mint(holder0, 100_000 ether);
        vm.prank(holder0);
        token0.approve(address(distributor), MAX_UINT);

        // Deposit reward
        uint256 depositAmount0 = 1000 ether;
        uint256 timestamp0 = block.timestamp;

        // no _accumulateReward call when we have a non-zero period
        vm.prank(holder0);
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.DepositReward(address(token0), depositAmount0);
        distributor.depositReward(address(token0), depositAmount0);

        assertEq(token0.balanceOf(address(distributor)), depositAmount0);

        // Check reward data
        RewardData memory rd;
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));
        uint256 expectedRate0 = depositAmount0 / rewardPeriodLength;

        assertEq(rd.lastUpdate, timestamp0);
        assertEq(rd.finishAt, timestamp0 + rewardPeriodLength);
        assertEq(rd.rate, expectedRate0);

        // Check pending rewards
        PendingRewards memory pending;
        (pending.unlocked, pending.locked) = distributor.pendingRewards(address(token0));
        assertEq(pending.unlocked, 0);
        assertEq(pending.locked, expectedRate0 * rewardPeriodLength);

        // Advance time to 1/3 period
        uint256 oneThirdPeriod = rewardPeriodLength / 3;
        vm.warp(timestamp0 + oneThirdPeriod);

        // Check pending rewards after time advance
        (pending.unlocked, pending.locked) = distributor.pendingRewards(address(token0));
        assertEq(pending.unlocked, expectedRate0 * oneThirdPeriod);
        assertEq(pending.locked, expectedRate0 * (rewardPeriodLength - oneThirdPeriod));

        // Deposit 89% of expected unlocked rewards, should be queued
        uint256 depositAmount1 = (expectedRate0 * oneThirdPeriod * 89) / 100;

        vm.prank(holder0);
        vm.expectEmit(address(distributor));
        emit MockLinearMultipleRewardDistributor._accumulateReward_called(
            address(token0),
            expectedRate0 * oneThirdPeriod
        );
        vm.expectEmit(address(distributor));
        emit IMultipleRewardDistributor.DepositReward(address(token0), depositAmount1);
        distributor.depositReward(address(token0), depositAmount1);

        uint256 timestamp1 = block.timestamp;

        // Check reward data after second deposit
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));

        assertEq(rd.lastUpdate, timestamp1);
        assertEq(rd.finishAt, timestamp0 + rewardPeriodLength);
        assertEq(rd.rate, expectedRate0);
        assertApproxEqAbs(rd.queued, depositAmount1, rewardPeriodLength);

        // Deposit another 2% of expected unlocked rewards, should trigger distribution
        uint256 depositAmount2 = (expectedRate0 * oneThirdPeriod * 2) / 100;

        vm.prank(holder0);
        vm.expectEmit(address(distributor));
        // no _accumulateReward call since we trigger distribution
        emit IMultipleRewardDistributor.DepositReward(address(token0), depositAmount2);
        distributor.depositReward(address(token0), depositAmount2);

        uint256 timestamp2 = block.timestamp;

        // Check reward data after third deposit
        (rd.lastUpdate, rd.finishAt, rd.rate, rd.queued) = distributor.rewardData(address(token0));

        uint256 expectedRate2 = (depositAmount1 +
            depositAmount2 +
            expectedRate0 *
            (timestamp0 + rewardPeriodLength - timestamp2)) / rewardPeriodLength;

        assertEq(rd.lastUpdate, timestamp2);
        assertEq(rd.finishAt, timestamp2 + rewardPeriodLength);
        assertApproxEqAbs(rd.rate, expectedRate2, rewardPeriodLength);
        assertApproxEqAbs(rd.queued, 0, rewardPeriodLength);
    }
}
/*
describe("LinearMultipleRewardDistributor.spec", async () => {
  context("constructor", async () => {
    it("should revert, when period length is invalid", async () => {
      const [deployer] = await ethers.getSigners();
      const MockLinearMultipleRewardDistributor = await ethers.getContractFactory(
        "MockLinearMultipleRewardDistributor",
        deployer
      );

      await expect(MockLinearMultipleRewardDistributor.deploy(1)).to.revertedWith("invalid period length");
      await expect(MockLinearMultipleRewardDistributor.deploy(86400 - 1)).to.revertedWith("invalid period length");
      await expect(MockLinearMultipleRewardDistributor.deploy(86400 * 28 + 1)).to.revertedWith("invalid period length");
    });

    for (const REWARD_PERIOD_LENGTH of [0, 86400, 86400 * 7, 86400 * 14, 86400 * 28]) {
      it(`should succeed with period[${REWARD_PERIOD_LENGTH}]`, async () => {
        const [deployer] = await ethers.getSigners();
        const MockLinearMultipleRewardDistributor = await ethers.getContractFactory(
          "MockLinearMultipleRewardDistributor",
          deployer
        );
        const distributor = await MockLinearMultipleRewardDistributor.deploy(REWARD_PERIOD_LENGTH);
        expect(await distributor.REWARD_PERIOD_LENGTH()).to.eq(REWARD_PERIOD_LENGTH);
      });
    }
  });

  for (const REWARD_PERIOD_LENGTH of [0, 86400, 86400 * 7, 86400 * 14, 86400 * 28]) {
    let deployer: HardhatEthersSigner;
    let manager: HardhatEthersSigner;
    let holder0: HardhatEthersSigner;
    let holder1: HardhatEthersSigner;
    let holder2: HardhatEthersSigner;

    let token0: MockERC20;
    let token1: MockERC20;
    let token2: MockERC20;
    let distributor: MockLinearMultipleRewardDistributor;

    context(`run with period[${REWARD_PERIOD_LENGTH}]`, async () => {
      beforeEach(async () => {
        [deployer, manager, holder0, holder1, holder2] = await ethers.getSigners();
        const MockERC20 = await ethers.getContractFactory("MockERC20", deployer);
        const MockLinearMultipleRewardDistributor = await ethers.getContractFactory(
          "MockLinearMultipleRewardDistributor",
          deployer
        );

        token0 = await MockERC20.deploy("R0", "R0", 18);
        token1 = await MockERC20.deploy("R1", "R1", 18);
        token2 = await MockERC20.deploy("R2", "R2", 18);
        distributor = await MockLinearMultipleRewardDistributor.deploy(REWARD_PERIOD_LENGTH);
        await distributor.initialize();
      });

      context("initialization", async () => {
        it("should initialize correctly", async () => {
          expect(await distributor.REWARD_PERIOD_LENGTH()).to.eq(REWARD_PERIOD_LENGTH);
          expect(await distributor.activeRewardTokens()).to.deep.eq([]);
          expect(await distributor.historicalRewardTokens()).to.deep.eq([]);
          expect(await distributor.hasRole(ZeroHash, deployer.address)).to.eq(true);
        });
      });

      context("reward manage", async () => {
        beforeEach(async () => {
          await distributor.grantRole(await distributor.REWARD_MANAGER_ROLE(), manager.address);
        });

        context("#registerRewardToken", async () => {
          it("should revert when non-manager call", async () => {
            const role = await distributor.REWARD_MANAGER_ROLE();
            await expect(distributor.registerRewardToken(await token0.getAddress(), holder0.address)).to.revertedWith(
              "AccessControl: account " + deployer.address.toLowerCase() + " is missing role " + role
            );
          });

          it("should revert, when distributor is zero", async () => {
            await expect(
              distributor.connect(manager).registerRewardToken(await token0.getAddress(), ZeroAddress)
            ).to.revertedWithCustomError(distributor, "RewardDistributorIsZero");
          });

          it("should revert, when duplicated rewards", async () => {
            await expect(distributor.connect(manager).registerRewardToken(await token0.getAddress(), holder0.address))
              .to.emit(distributor, "RegisterRewardToken")
              .withArgs(await token0.getAddress(), holder0.address);
            await expect(
              distributor.connect(manager).registerRewardToken(await token0.getAddress(), holder0.address)
            ).to.revertedWithCustomError(distributor, "DuplicatedRewardToken");
          });

          it("should succeed when add new tokens", async () => {
            await expect(distributor.connect(manager).registerRewardToken(await token0.getAddress(), holder0.address))
              .to.emit(distributor, "RegisterRewardToken")
              .withArgs(await token0.getAddress(), holder0.address);
            expect(await distributor.activeRewardTokens()).to.deep.eq([await token0.getAddress()]);
            expect(await distributor.distributors(await token0.getAddress())).to.eq(holder0.address);
            await expect(distributor.connect(manager).registerRewardToken(await token1.getAddress(), holder1.address))
              .to.emit(distributor, "RegisterRewardToken")
              .withArgs(await token1.getAddress(), holder1.address);
            expect(await distributor.distributors(await token1.getAddress())).to.eq(holder1.address);
            expect(await distributor.activeRewardTokens()).to.deep.eq([
              await token0.getAddress(),
              await token1.getAddress(),
            ]);
            await expect(distributor.connect(manager).registerRewardToken(await token2.getAddress(), holder2.address))
              .to.emit(distributor, "RegisterRewardToken")
              .withArgs(await token2.getAddress(), holder2.address);
            expect(await distributor.distributors(await token2.getAddress())).to.eq(holder2.address);
            expect(await distributor.activeRewardTokens()).to.deep.eq([
              await token0.getAddress(),
              await token1.getAddress(),
              await token2.getAddress(),
            ]);
          });

          it("should succeed when remove token from historical", async () => {
            await expect(distributor.connect(manager).registerRewardToken(await token0.getAddress(), holder0.address))
              .to.emit(distributor, "RegisterRewardToken")
              .withArgs(await token0.getAddress(), holder0.address);
            expect(await distributor.activeRewardTokens()).to.deep.eq([await token0.getAddress()]);
            expect(await distributor.distributors(await token0.getAddress())).to.eq(holder0.address);
            await expect(distributor.connect(manager).registerRewardToken(await token1.getAddress(), holder1.address))
              .to.emit(distributor, "RegisterRewardToken")
              .withArgs(await token1.getAddress(), holder1.address);
            expect(await distributor.distributors(await token1.getAddress())).to.eq(holder1.address);
            expect(await distributor.activeRewardTokens()).to.deep.eq([
              await token0.getAddress(),
              await token1.getAddress(),
            ]);
            await expect(distributor.connect(manager).registerRewardToken(await token2.getAddress(), holder2.address))
              .to.emit(distributor, "RegisterRewardToken")
              .withArgs(await token2.getAddress(), holder2.address);
            expect(await distributor.distributors(await token2.getAddress())).to.eq(holder2.address);
            expect(await distributor.activeRewardTokens()).to.deep.eq([
              await token0.getAddress(),
              await token1.getAddress(),
              await token2.getAddress(),
            ]);

            await expect(distributor.connect(manager).unregisterRewardToken(await token0.getAddress()))
              .to.emit(distributor, "UnregisterRewardToken")
              .withArgs(await token0.getAddress());
            expect(await distributor.activeRewardTokens()).to.deep.eq([
              await token2.getAddress(),
              await token1.getAddress(),
            ]);
            expect(await distributor.historicalRewardTokens()).to.deep.eq([await token0.getAddress()]);
            expect(await distributor.distributors(await token0.getAddress())).to.eq(ZeroAddress);
          });
        });

        context("#updateRewardDistributor", async () => {
          beforeEach(async () => {
            await distributor.connect(manager).registerRewardToken(await token0.getAddress(), holder0.address);
          });

          it("should revert when non-manager call", async () => {
            const role = await distributor.REWARD_MANAGER_ROLE();
            await expect(distributor.updateRewardDistributor(ZeroAddress, ZeroAddress)).to.revertedWith(
              "AccessControl: account " + deployer.address.toLowerCase() + " is missing role " + role
            );
          });

          it("should revert, when distributor is zero", async () => {
            await expect(
              distributor.connect(manager).updateRewardDistributor(await token0.getAddress(), ZeroAddress)
            ).to.revertedWithCustomError(distributor, "RewardDistributorIsZero");
          });

          it("should revert, when reward is not active", async () => {
            await expect(
              distributor.connect(manager).updateRewardDistributor(await token1.getAddress(), holder1.address)
            ).to.revertedWithCustomError(distributor, "NotActiveRewardToken");
          });

          it("should succeed", async () => {
            expect(await distributor.distributors(await token0.getAddress())).to.eq(holder0.address);
            await expect(
              distributor.connect(manager).updateRewardDistributor(await token0.getAddress(), holder1.address)
            )
              .to.emit(distributor, "UpdateRewardDistributor")
              .withArgs(await token0.getAddress(), holder0.address, holder1.address);
            expect(await distributor.distributors(await token0.getAddress())).to.eq(holder1.address);
          });
        });

        context("#unregisterRewardToken", async () => {
          beforeEach(async () => {
            await distributor.connect(manager).registerRewardToken(await token0.getAddress(), holder0.address);
            await distributor.connect(manager).registerRewardToken(await token1.getAddress(), holder1.address);
            await distributor.connect(manager).registerRewardToken(await token2.getAddress(), holder2.address);
          });

          it("should revert when non-manager call", async () => {
            const role = await distributor.REWARD_MANAGER_ROLE();
            await expect(distributor.unregisterRewardToken(ZeroAddress)).to.revertedWith(
              "AccessControl: account " + deployer.address.toLowerCase() + " is missing role " + role
            );
          });

          it("should revert, when reward is not active", async () => {
            await distributor.connect(manager).unregisterRewardToken(await token0.getAddress());
            await expect(
              distributor.connect(manager).unregisterRewardToken(await token0.getAddress())
            ).to.revertedWithCustomError(distributor, "NotActiveRewardToken");
          });

          if (REWARD_PERIOD_LENGTH > 0) {
            it("should revert, when reward distribution is not over", async () => {
              await token0.mint(holder0.address, ethers.parseEther("1000"));
              await token0.connect(holder0).approve(await distributor.getAddress(), MaxUint256);
              await distributor.connect(holder0).depositReward(await token0.getAddress(), ethers.parseEther("1000"));
              await expect(
                distributor.connect(manager).unregisterRewardToken(await token0.getAddress())
              ).to.revertedWithCustomError(distributor, "RewardDistributionNotFinished");
            });
          }

          it("should succeed", async () => {
            await expect(distributor.connect(manager).unregisterRewardToken(await token0.getAddress()))
              .to.emit(distributor, "UnregisterRewardToken")
              .withArgs(await token0.getAddress());
            expect(await distributor.distributors(await token0.getAddress())).to.eq(ZeroAddress);
            expect(await distributor.activeRewardTokens()).to.deep.eq([
              await token2.getAddress(),
              await token1.getAddress(),
            ]);
            expect(await distributor.historicalRewardTokens()).to.deep.eq([await token0.getAddress()]);

            await expect(distributor.connect(manager).unregisterRewardToken(await token1.getAddress()))
              .to.emit(distributor, "UnregisterRewardToken")
              .withArgs(await token1.getAddress());
            expect(await distributor.distributors(await token1.getAddress())).to.eq(ZeroAddress);
            expect(await distributor.activeRewardTokens()).to.deep.eq([await token2.getAddress()]);
            expect(await distributor.historicalRewardTokens()).to.deep.eq([
              await token0.getAddress(),
              await token1.getAddress(),
            ]);

            await expect(distributor.connect(manager).unregisterRewardToken(await token2.getAddress()))
              .to.emit(distributor, "UnregisterRewardToken")
              .withArgs(await token2.getAddress());
            expect(await distributor.distributors(await token2.getAddress())).to.eq(ZeroAddress);
            expect(await distributor.activeRewardTokens()).to.deep.eq([]);
            expect(await distributor.historicalRewardTokens()).to.deep.eq([
              await token0.getAddress(),
              await token1.getAddress(),
              await token2.getAddress(),
            ]);
          });
        });
      });

      context("#depositReward", async () => {
        beforeEach(async () => {
          await distributor.grantRole(await distributor.REWARD_MANAGER_ROLE(), manager.address);
          await distributor.connect(manager).registerRewardToken(await token0.getAddress(), holder0.address);
        });

        it("should revert, when token is not active", async () => {
          await expect(distributor.depositReward(await token1.getAddress(), 0)).to.revertedWithCustomError(
            distributor,
            "NotActiveRewardToken"
          );
        });

        it("should revert, when caller is not distributor", async () => {
          await expect(distributor.depositReward(await token0.getAddress(), 0)).to.revertedWithCustomError(
            distributor,
            "NotRewardDistributor"
          );
        });

        it("should succeed", async () => {
          await token0.mint(holder0.address, ethers.parseEther("100000"));
          await token0.connect(holder0).approve(await distributor.getAddress(), MaxUint256);
          const depositAmount0 = ethers.parseEther("1000");
          let tx = distributor.connect(holder0).depositReward(await token0.getAddress(), depositAmount0);
          await expect(tx)
            .to.emit(distributor, "DepositReward")
            .withArgs(await token0.getAddress(), depositAmount0);
          expect(await token0.balanceOf(await distributor.getAddress())).to.eq(depositAmount0);
          if (REWARD_PERIOD_LENGTH === 0) {
            await expect(tx)
              .to.emit(distributor, "_accumulateReward_called")
              .withArgs(await token0.getAddress(), depositAmount0);
          } else {
            const timestamp0 = (await ethers.provider.getBlock("latest"))!.timestamp;
            const rewardData0 = await distributor.rewardData(await token0.getAddress());
            const expectedRate0 = depositAmount0 / toBigInt(REWARD_PERIOD_LENGTH);
            expect(rewardData0.lastUpdate).to.eq(timestamp0);
            expect(rewardData0.finishAt).to.eq(timestamp0 + REWARD_PERIOD_LENGTH);
            expect(rewardData0.rate).to.eq(expectedRate0);
            expect(await distributor.pendingRewards(await token0.getAddress())).to.deep.eq([
              0n,
              expectedRate0 * toBigInt(REWARD_PERIOD_LENGTH),
            ]);

            // 1/3 period
            await network.provider.send("evm_setNextBlockTimestamp", [timestamp0 + Math.floor(REWARD_PERIOD_LENGTH / 3)]);
            await network.provider.send("evm_mine", []);
            expect(await distributor.pendingRewards(await token0.getAddress())).to.deep.eq([
              expectedRate0 * toBigInt(Math.floor(REWARD_PERIOD_LENGTH / 3)),
              expectedRate0 * toBigInt(REWARD_PERIOD_LENGTH - Math.floor(REWARD_PERIOD_LENGTH / 3)),
            ]);

            // deposit 89% of expectedRate * toBigInt(Math.floor(REWARD_PERIOD_LENGTH / 3)), should be queued
            const depositAmount1 = (expectedRate0 * toBigInt(Math.floor(REWARD_PERIOD_LENGTH / 3)) * 89n) / 100n;
            tx = distributor.connect(holder0).depositReward(await token0.getAddress(), depositAmount1);
            await expect(tx)
              .to.emit(distributor, "DepositReward")
              .withArgs(await token0.getAddress(), depositAmount1);

            const timestamp1 = (await ethers.provider.getBlock("latest"))!.timestamp;
            await expect(tx)
              .to.emit(distributor, "_accumulateReward_called")
              .withArgs(await token0.getAddress(), expectedRate0 * toBigInt(timestamp1 - timestamp0));
            const rewardData1 = await distributor.rewardData(await token0.getAddress());
            expect(rewardData1.lastUpdate).to.eq(timestamp1);
            expect(rewardData1.finishAt).to.eq(timestamp0 + REWARD_PERIOD_LENGTH);
            expect(rewardData1.rate).to.eq(expectedRate0);
            expect(rewardData1.queued).to.closeTo(depositAmount1, REWARD_PERIOD_LENGTH);

            // deposit another 2% expectedRate * toBigInt(Math.floor(REWARD_PERIOD_LENGTH / 3)), should distribute
            const depositAmount2 = (expectedRate0 * toBigInt(Math.floor(REWARD_PERIOD_LENGTH / 3)) * 2n) / 100n;
            tx = distributor.connect(holder0).depositReward(await token0.getAddress(), depositAmount2);
            await expect(tx)
              .to.emit(distributor, "DepositReward")
              .withArgs(await token0.getAddress(), depositAmount2)
              .to.emit(distributor, "_accumulateReward_called");
            const timestamp2 = (await ethers.provider.getBlock("latest"))!.timestamp;
            const rewardData2 = await distributor.rewardData(await token0.getAddress());
            const expectedRate2 =
              (depositAmount1 + depositAmount2 + expectedRate0 * toBigInt(timestamp0 + REWARD_PERIOD_LENGTH - timestamp2)) /
              toBigInt(REWARD_PERIOD_LENGTH);
            expect(rewardData2.lastUpdate).to.eq(timestamp2);
            expect(rewardData2.finishAt).to.eq(timestamp2 + REWARD_PERIOD_LENGTH);
            expect(rewardData2.rate).to.closeTo(expectedRate2, REWARD_PERIOD_LENGTH);
            expect(rewardData2.queued).to.closeTo(0n, REWARD_PERIOD_LENGTH);
          }
        });
      });
    });
  }
});
*/
