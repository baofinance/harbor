// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {Deploy_ETH_Minter} from "script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "script/config/ConfigBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC5313} from "@openzeppelin/contracts/interfaces/IERC5313.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IStabilityPool_v3} from "src/interfaces/IStabilityPool_v3.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";
import {IRewardAlias} from "src/interfaces/IRewardAlias.sol";
import {RewardAlias_v1} from "src/reward/RewardAlias_v1.sol";
import {Minter_v2} from "src/minter/Minter_v2.sol";
import {StabilityPoolManager_v1} from "src/minter/StabilityPoolManager_v1.sol";
import {MockWrappedPriceOracle} from "test/mocks/MockWrappedPriceOracle.sol";

/// @title Reward system tests — aliases, accumulator, distributor — using deployment framework
contract RewardSystemSetUp is BaoTest, Deploy_ETH_Minter {
    address minter;
    address stabilityPoolCollateral;
    address stabilityPoolLeveraged;
    address stabilityPoolManager;
    address pegged;
    address leveraged;
    address wrappedCollateral;

    address collHarvestAlias;
    address collRebalanceAlias;

    MockWrappedPriceOracle mockOracle;

    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }

    function setUp() public virtual {
        address factory = _ensureBaoFactory();
        // Pinned after latest Harbor deployment (SPL remediation, 2026-03-25) for caching
        vm.createSelectFork(vm.rpcUrl("mainnet"), 24699497);

        vm.prank(IBaoFactory(factory).owner());
        IBaoFactory(factory).setOperator(address(this), 365 days);

        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        Config_MinterMarket[] memory toDeploy = new Config_MinterMarket[](1);
        toDeploy[0] = mktConfigs[0];
        deployForPeg("reward_cov", peg, mktConfigs, "mainnet", true, toDeploy);

        _setSaltPrefix("reward_cov");
        string memory marketKey = "ETH::fxUSD";
        minter = _predictAddress(_key(marketKey, "minter"));
        stabilityPoolCollateral = _predictAddress(_key(marketKey, "stabilityPoolCollateral"));
        stabilityPoolLeveraged = _predictAddress(_key(marketKey, "stabilityPoolLeveraged"));
        stabilityPoolManager = _predictAddress(_key(marketKey, "stabilityPoolManager"));
        pegged = _predictAddress(_key("ETH", "pegged"));
        leveraged = _predictAddress(_key(marketKey, "leveraged"));
        wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();

        collHarvestAlias = _predictAddress(_key(marketKey, "stabilityPoolCollateral", "harvest"));
        collRebalanceAlias = _predictAddress(_key(marketKey, "stabilityPoolCollateral", "rebalance"));

        mockOracle = new MockWrappedPriceOracle();
        mockOracle.setLatestAnswer(1 ether, 1 ether);

        vm.startPrank(HARBOR_MULTISIG);
        IMinter(minter).updatePriceOracle(address(mockOracle));
        uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
        IBaoRoles(minter).grantRoles(address(this), zeroFeeRole);
        uint256 depositorRole = IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_DEPOSITOR_ROLE();
        IBaoRoles(stabilityPoolCollateral).grantRoles(address(this), depositorRole);
        vm.stopPrank();
    }

    function _mintAndDeposit(address user, uint256 amount) internal {
        deal(wrappedCollateral, address(this), amount);
        IERC20(wrappedCollateral).approve(minter, amount);
        uint256 peggedMinted = IMinter(minter).freeMintPeggedToken(amount, user);
        vm.startPrank(user);
        IERC20(pegged).approve(stabilityPoolCollateral, peggedMinted);
        IStabilityPool(stabilityPoolCollateral).deposit(peggedMinted, user, 0);
        vm.stopPrank();
    }

    function _depositReward(address token, uint256 amount) internal {
        deal(wrappedCollateral, address(this), amount);
        IERC20(wrappedCollateral).approve(stabilityPoolCollateral, amount);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(token, amount);
    }
}

// ═══════════════════════════════════════════════════════════════
// RewardAlias_v1 contract coverage
// ═══════════════════════════════════════════════════════════════

contract RewardAliasTest is RewardSystemSetUp {
    function test_constructorRevertsZeroAddress() public {
        vm.expectRevert();
        new RewardAlias_v1(address(0));
    }

    function test_supportsInterface() public view {
        assertTrue(IERC165(collHarvestAlias).supportsInterface(type(IERC5313).interfaceId), "IERC5313");
        assertTrue(IERC165(collHarvestAlias).supportsInterface(type(IERC165).interfaceId), "IERC165");
        assertFalse(IERC165(collHarvestAlias).supportsInterface(0xdeadbeef), "random");
    }

    function test_upgradeByOwner() public {
        RewardAlias_v1 newImpl = new RewardAlias_v1(wrappedCollateral);

        // Owner (multisig after transferAllOwnerships) can upgrade
        vm.prank(HARBOR_MULTISIG);
        UUPSUpgradeable(collHarvestAlias).upgradeToAndCall(address(newImpl), "");

        // Underlying unchanged (immutable in new impl)
        assertEq(IRewardAlias(collHarvestAlias).underlying(), wrappedCollateral, "underlying preserved");
    }

    function test_upgradeRevertsNotOwner() public {
        RewardAlias_v1 newImpl = new RewardAlias_v1(wrappedCollateral);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        UUPSUpgradeable(collHarvestAlias).upgradeToAndCall(address(newImpl), "");
    }
}

// ═══════════════════════════════════════════════════════════════
// Accumulator v3 coverage (via SP deployed with deployment scripts)
// ═══════════════════════════════════════════════════════════════

contract AccumulatorTest is RewardSystemSetUp {
    address alice;
    address bob;
    address carol;

    function setUp() public override {
        super.setUp();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        _mintAndDeposit(alice, 100 ether);
        _mintAndDeposit(bob, 100 ether);
        _mintAndDeposit(carol, 100 ether);
    }

    // ── claimable / claimed views ──────────────────────────────

    function test_claimedView() public {
        _depositReward(wrappedCollateral, 10 ether);
        skip(8 days);

        uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(alice, wrappedCollateral);
        assertGt(claimable, 0, "has claimable");

        // Claim
        vm.prank(alice);
        IStabilityPool_v3(stabilityPoolCollateral).claimSingle(alice, wrappedCollateral);

        // claimed() should return the claimed amount
        uint256 claimedAmount = IMultipleRewardAccumulator(stabilityPoolCollateral).claimed(alice, wrappedCollateral);
        assertEq(claimedAmount, claimable, "claimed matches");
    }

    // ── checkpoint ─────────────────────────────────────────────

    function test_checkpoint() public {
        _depositReward(wrappedCollateral, 10 ether);
        skip(4 days);

        // Checkpoint updates state without claiming
        IMultipleRewardAccumulator(stabilityPoolCollateral).checkpoint(alice);

        // Claimable should reflect distributed rewards
        uint256 claimable = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(alice, wrappedCollateral);
        assertGt(claimable, 0, "claimable after checkpoint");
    }

    function test_checkpointBeforeAnyRewardTokens() public {
        // Deploy a fresh SP with no reward tokens registered — but we can't easily do that
        // via the deployment framework. Instead, checkpoint with address(0) which is the
        // "distribute all" path — exercises the early return when called before deposits change.
        IMultipleRewardAccumulator(stabilityPoolCollateral).checkpoint(makeAddr("nobody"));
    }

    // ── claim() and claim(account, receiver) ───────────────────

    function test_claimAll() public {
        _depositReward(wrappedCollateral, 10 ether);
        skip(8 days);

        uint256 balBefore = IERC20(wrappedCollateral).balanceOf(alice);
        vm.prank(alice);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(alice);
        uint256 received = IERC20(wrappedCollateral).balanceOf(alice) - balBefore;
        assertGt(received, 0, "claimed via claim()");
    }

    function test_claimToReceiver() public {
        _depositReward(wrappedCollateral, 10 ether);
        skip(8 days);

        address receiver = makeAddr("receiver");
        vm.prank(alice);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(alice, receiver);
        assertGt(IERC20(wrappedCollateral).balanceOf(receiver), 0, "receiver got tokens");
    }

    function test_claimOthersToSelf() public {
        _depositReward(wrappedCollateral, 10 ether);
        skip(8 days);

        // bob claims alice's rewards — tokens go to alice (receiver=address(0))
        vm.prank(bob);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(alice, address(0));
        assertGt(IERC20(wrappedCollateral).balanceOf(alice), 0, "alice received");
    }

    function test_claimOthersToThirdParty_reverts() public {
        _depositReward(wrappedCollateral, 10 ether);
        skip(8 days);

        // bob tries to claim alice's rewards to a third party — should revert
        vm.prank(bob);
        vm.expectRevert();
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(alice, makeAddr("thirdParty"));
    }

    // ── claimHistorical ────────────────────────────────────────

    function test_claimHistorical() public {
        _depositReward(collHarvestAlias, 30 ether);
        skip(8 days);

        // Checkpoint alice to update her pending — but don't claim
        IMultipleRewardAccumulator(stabilityPoolCollateral).checkpoint(alice);

        // Bob and carol claim to drain the pool's distributable balance
        vm.prank(bob);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(bob);
        vm.prank(carol);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(carol);

        // Flush any remaining queued dust
        _depositReward(collHarvestAlias, 1);
        skip(8 days);
        vm.prank(bob);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(bob);
        vm.prank(carol);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(carol);
        // Alice still hasn't claimed — her pending is sitting in her snapshot

        // Unregister
        uint256 managerRole = IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_MANAGER_ROLE();
        vm.prank(HARBOR_MULTISIG);
        IBaoRoles(stabilityPoolCollateral).grantRoles(address(this), managerRole);
        IMultipleRewardDistributor(stabilityPoolCollateral).unregisterRewardToken(collHarvestAlias);

        // Verify it's historical
        address[] memory historical = IMultipleRewardDistributor(stabilityPoolCollateral).historicalRewardTokens();
        bool found;
        for (uint256 i = 0; i < historical.length; i++) {
            if (historical[i] == collHarvestAlias) {
                found = true;
            }
        }
        assertTrue(found, "alias is historical");

        // Alice claims via claimHistorical — her pending should still be there
        address[] memory tokens = new address[](1);
        tokens[0] = collHarvestAlias;
        uint256 balBefore = IERC20(wrappedCollateral).balanceOf(alice);
        vm.prank(alice);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claimHistorical(tokens);
        assertGt(IERC20(wrappedCollateral).balanceOf(alice) - balBefore, 0, "claimed historical");
    }

    function test_claimHistorical_forAccount() public {
        _depositReward(collHarvestAlias, 30 ether);
        skip(8 days);

        // Checkpoint alice but don't claim
        IMultipleRewardAccumulator(stabilityPoolCollateral).checkpoint(alice);

        // Drain via bob and carol
        vm.prank(bob);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(bob);
        vm.prank(carol);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(carol);
        _depositReward(collHarvestAlias, 1);
        skip(8 days);
        vm.prank(bob);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(bob);
        vm.prank(carol);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(carol);

        uint256 managerRole = IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_MANAGER_ROLE();
        vm.prank(HARBOR_MULTISIG);
        IBaoRoles(stabilityPoolCollateral).grantRoles(address(this), managerRole);
        IMultipleRewardDistributor(stabilityPoolCollateral).unregisterRewardToken(collHarvestAlias);

        // Bob triggers historical claim for alice — tokens go to alice
        address[] memory tokens = new address[](1);
        tokens[0] = collHarvestAlias;
        uint256 balBefore = IERC20(wrappedCollateral).balanceOf(alice);
        vm.prank(bob);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claimHistorical(alice, tokens);
        assertGt(IERC20(wrappedCollateral).balanceOf(alice) - balBefore, 0, "alice got historical claim");
    }
}

// ═══════════════════════════════════════════════════════════════
// Distributor v3 coverage
// ═══════════════════════════════════════════════════════════════

contract DistributorTest is RewardSystemSetUp {
    function test_historicalRewardTokens_empty() public view {
        // No tokens have been unregistered yet
        address[] memory historical = IMultipleRewardDistributor(stabilityPoolCollateral).historicalRewardTokens();
        assertEq(historical.length, 0, "no historical tokens initially");
    }

    function test_registerRewardToken_zeroAddress_reverts() public {
        uint256 managerRole = IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_MANAGER_ROLE();
        vm.prank(HARBOR_MULTISIG);
        IBaoRoles(stabilityPoolCollateral).grantRoles(address(this), managerRole);

        vm.expectRevert();
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(address(0));
    }

    function test_registerRewardToken_duplicate_reverts() public {
        uint256 managerRole = IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_MANAGER_ROLE();
        vm.prank(HARBOR_MULTISIG);
        IBaoRoles(stabilityPoolCollateral).grantRoles(address(this), managerRole);

        // wrappedCollateral is already registered
        vm.expectRevert();
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(wrappedCollateral);
    }

    function test_unregisterRewardToken_withPendingRewards_reverts() public {
        address alice = makeAddr("alice");
        _mintAndDeposit(alice, 100 ether);

        // Deposit reward that hasn't fully distributed
        _depositReward(collHarvestAlias, 10 ether);
        // Don't wait — rewards still pending

        uint256 managerRole = IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_MANAGER_ROLE();
        vm.prank(HARBOR_MULTISIG);
        IBaoRoles(stabilityPoolCollateral).grantRoles(address(this), managerRole);

        vm.expectRevert();
        IMultipleRewardDistributor(stabilityPoolCollateral).unregisterRewardToken(collHarvestAlias);
    }

    function test_unregisterAndReregister() public {
        address alice = makeAddr("alice");
        _mintAndDeposit(alice, 100 ether);

        _depositReward(collHarvestAlias, 10 ether);
        skip(8 days); // Wait for full distribution

        // Claim all so pending is zero
        vm.prank(alice);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(alice);

        uint256 managerRole = IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_MANAGER_ROLE();
        vm.prank(HARBOR_MULTISIG);
        IBaoRoles(stabilityPoolCollateral).grantRoles(address(this), managerRole);

        // Unregister
        IMultipleRewardDistributor(stabilityPoolCollateral).unregisterRewardToken(collHarvestAlias);

        // Historical should contain it
        address[] memory historical = IMultipleRewardDistributor(stabilityPoolCollateral).historicalRewardTokens();
        assertEq(historical.length, 1, "one historical token");

        // Re-register — moves from historical back to active
        IMultipleRewardDistributor(stabilityPoolCollateral).registerRewardToken(collHarvestAlias);

        // Historical should be empty again
        historical = IMultipleRewardDistributor(stabilityPoolCollateral).historicalRewardTokens();
        assertEq(historical.length, 0, "historical cleared after re-register");
    }
}
