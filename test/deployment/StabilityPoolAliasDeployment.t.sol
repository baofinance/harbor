// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {Deploy_ETH_Minter} from "script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "script/config/ConfigBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardAccumulator_v3} from "src/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";
import {IRewardAlias} from "src/interfaces/IRewardAlias.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {MockWrappedPriceOracle} from "test/mocks/MockWrappedPriceOracle.sol";

/// @title StabilityPoolAliasDeploymentTest
/// @notice Tests that v3 stability pools deployed via the production deployment scripts
/// have reward aliases correctly registered and functional.
contract StabilityPoolAliasDeploymentSetUp is BaoTest, Deploy_ETH_Minter {
    using MinterMarketConfigLib for Config_MinterMarket;

    // Deployed contract addresses
    address minter;
    address stabilityPoolCollateral;
    address stabilityPoolLeveraged;
    address stabilityPoolManager;
    address pegged;
    address leveraged;
    address wrappedCollateral;

    // Alias addresses
    address collHarvestAlias;
    address collRebalanceAlias;
    address levHarvestAlias;
    address levRebalanceAlias;

    // Mock oracle
    MockWrappedPriceOracle mockOracle;

    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }

    function setUp() public virtual {
        // Deploy BaoFactory locally
        address factory = _ensureBaoFactory();

        // Fork mainnet so real token contracts (fxSAVE, fxUSD, etc.) exist
        // Pinned after latest Harbor deployment (SPL remediation, 2026-03-25) for caching
        vm.createSelectFork(vm.rpcUrl("mainnet"), 24699497);

        // Register as factory operator
        vm.prank(IBaoFactory(factory).owner());
        IBaoFactory(factory).setOperator(address(this), 365 days);

        // Deploy ETH::fxUSD market via production deployment scripts
        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        Config_MinterMarket[] memory toDeploy = new Config_MinterMarket[](1);
        toDeploy[0] = mktConfigs[0];
        deployForPeg("alias_test", peg, mktConfigs, "mainnet", true, toDeploy);

        // Resolve deployed addresses
        _setSaltPrefix("alias_test");
        string memory marketKey = "ETH::fxUSD";
        minter = _predictAddress(_key(marketKey, "minter"));
        stabilityPoolCollateral = _predictAddress(_key(marketKey, "stabilityPoolCollateral"));
        stabilityPoolLeveraged = _predictAddress(_key(marketKey, "stabilityPoolLeveraged"));
        stabilityPoolManager = _predictAddress(_key(marketKey, "stabilityPoolManager"));
        pegged = _predictAddress(_key("ETH", "pegged"));
        leveraged = _predictAddress(_key(marketKey, "leveraged"));
        wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();

        // Resolve alias addresses
        collHarvestAlias = _predictAddress(_key(marketKey, "stabilityPoolCollateral", "harvest"));
        collRebalanceAlias = _predictAddress(_key(marketKey, "stabilityPoolCollateral", "rebalance"));
        levHarvestAlias = _predictAddress(_key(marketKey, "stabilityPoolLeveraged", "harvest"));
        levRebalanceAlias = _predictAddress(_key(marketKey, "stabilityPoolLeveraged", "rebalance"));

        // Install mock oracle and grant roles for test operations
        mockOracle = new MockWrappedPriceOracle();
        mockOracle.setLatestAnswer(1 ether, 1 ether);

        vm.startPrank(HARBOR_MULTISIG);
        IMinter(minter).updatePriceOracle(address(mockOracle));
        IBaoRoles(minter).grantRoles(address(this), IMinter(minter).ZERO_FEE_ROLE());
        IBaoRoles(stabilityPoolCollateral).grantRoles(
            address(this),
            IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_DEPOSITOR_ROLE()
        );
        vm.stopPrank();
    }

    function _mintPegged(address to, uint256 collateralAmount) internal returns (uint256 peggedMinted) {
        deal(wrappedCollateral, address(this), collateralAmount);
        IERC20(wrappedCollateral).approve(minter, collateralAmount);
        peggedMinted = IMinter(minter).freeMintPeggedToken(collateralAmount, to);
    }
}

contract StabilityPoolAliasDeploymentTest is StabilityPoolAliasDeploymentSetUp {
    // ═══════════════════════════════════════════════════════════════
    // Alias deployment verification
    // ═══════════════════════════════════════════════════════════════

    function test_aliasesDeployed() public view {
        assertGt(collHarvestAlias.code.length, 0, "collHarvestAlias deployed");
        assertGt(collRebalanceAlias.code.length, 0, "collRebalanceAlias deployed");
        assertGt(levHarvestAlias.code.length, 0, "levHarvestAlias deployed");
        assertGt(levRebalanceAlias.code.length, 0, "levRebalanceAlias deployed");
    }

    function test_aliasUnderlyings() public view {
        // Collateral SP aliases both point to wrappedCollateral
        assertEq(IRewardAlias(collHarvestAlias).underlying(), wrappedCollateral, "coll harvest underlying");
        assertEq(IRewardAlias(collRebalanceAlias).underlying(), wrappedCollateral, "coll rebalance underlying");

        // Leveraged SP: harvest → wrappedCollateral, rebalance → leveraged token
        assertEq(IRewardAlias(levHarvestAlias).underlying(), wrappedCollateral, "lev harvest underlying");
        assertEq(IRewardAlias(levRebalanceAlias).underlying(), leveraged, "lev rebalance underlying");
    }

    // ═══════════════════════════════════════════════════════════════
    // Alias registration on SPs
    // ═══════════════════════════════════════════════════════════════

    function test_aliasesRegisteredOnCollateralSP() public view {
        address[] memory tokens = IMultipleRewardDistributor(stabilityPoolCollateral).activeRewardTokens();
        bool foundHarvest;
        bool foundRebalance;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == collHarvestAlias) {
                foundHarvest = true;
            }
            if (tokens[i] == collRebalanceAlias) {
                foundRebalance = true;
            }
        }
        assertTrue(foundHarvest, "harvest alias registered on coll SP");
        assertTrue(foundRebalance, "rebalance alias registered on coll SP");
    }

    function test_aliasesRegisteredOnLeveragedSP() public view {
        address[] memory tokens = IMultipleRewardDistributor(stabilityPoolLeveraged).activeRewardTokens();
        bool foundHarvest;
        bool foundRebalance;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == levHarvestAlias) {
                foundHarvest = true;
            }
            if (tokens[i] == levRebalanceAlias) {
                foundRebalance = true;
            }
        }
        assertTrue(foundHarvest, "harvest alias registered on lev SP");
        assertTrue(foundRebalance, "rebalance alias registered on lev SP");
    }

    // ═══════════════════════════════════════════════════════════════
    // Deposit via alias → claim resolves to underlying
    // ═══════════════════════════════════════════════════════════════

    function test_depositViaAlias_claimReturnsUnderlying() public {
        address alice = makeAddr("alice");
        uint256 depositAmount = 100 ether;
        uint256 rewardAmount = 5 ether;

        // Mint pegged and deposit into collateral SP
        _mintPegged(alice, depositAmount);
        vm.prank(alice);
        IERC20(pegged).approve(stabilityPoolCollateral, depositAmount);
        vm.prank(alice);
        IStabilityPool(stabilityPoolCollateral).deposit(depositAmount, alice, 0);

        // Deposit reward via harvest alias
        deal(wrappedCollateral, address(this), rewardAmount);
        IERC20(wrappedCollateral).approve(stabilityPoolCollateral, rewardAmount);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(collHarvestAlias, rewardAmount);

        // Wait for full distribution
        skip(8 days);

        // Claimable should show under the alias address
        uint256 claimableAlias = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(alice, collHarvestAlias);
        assertApprox(claimableAlias, rewardAmount, 604800, "claimable via alias");

        // Claim via alias — should receive wrappedCollateral (the underlying)
        uint256 balBefore = IERC20(wrappedCollateral).balanceOf(alice);
        vm.prank(alice);
        IMultipleRewardAccumulator_v3(stabilityPoolCollateral).claim(
            alice,
            address(0),
            collHarvestAlias,
            type(uint256).max
        );
        uint256 received = IERC20(wrappedCollateral).balanceOf(alice) - balBefore;

        assertApprox(received, rewardAmount, 604800, "claimed underlying amount");
    }

    function test_separateTracking_harvestVsRebalance() public {
        address alice = makeAddr("alice");
        uint256 depositAmount = 100 ether;
        uint256 harvestReward = 3 ether;
        uint256 rebalanceReward = 7 ether;

        // Mint and deposit
        _mintPegged(alice, depositAmount);
        vm.prank(alice);
        IERC20(pegged).approve(stabilityPoolCollateral, depositAmount);
        vm.prank(alice);
        IStabilityPool(stabilityPoolCollateral).deposit(depositAmount, alice, 0);

        // Deposit harvest reward via harvest alias
        deal(wrappedCollateral, address(this), harvestReward);
        IERC20(wrappedCollateral).approve(stabilityPoolCollateral, harvestReward);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(collHarvestAlias, harvestReward);

        // Deposit rebalance reward via rebalance alias
        deal(wrappedCollateral, address(this), rebalanceReward);
        IERC20(wrappedCollateral).approve(stabilityPoolCollateral, rebalanceReward);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(collRebalanceAlias, rebalanceReward);

        // Wait for distribution
        skip(8 days);

        // Each alias tracks separately
        uint256 claimableHarvest = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            alice,
            collHarvestAlias
        );
        uint256 claimableRebalance = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            alice,
            collRebalanceAlias
        );

        assertApprox(claimableHarvest, harvestReward, 604800, "harvest alias tracked separately");
        assertApprox(claimableRebalance, rebalanceReward, 604800, "rebalance alias tracked separately");

        // Aggregated claimable for underlying should be sum of aliases
        uint256 claimableTotal = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(
            alice,
            wrappedCollateral
        );
        assertApprox(claimableTotal, harvestReward + rebalanceReward, 2 * 604800, "aggregated claimable");
    }

    function test_claimAll_collectsBothAliases() public {
        address alice = makeAddr("alice");
        uint256 depositAmount = 100 ether;
        uint256 harvestReward = 4 ether;
        uint256 rebalanceReward = 6 ether;

        // Mint and deposit
        _mintPegged(alice, depositAmount);
        vm.prank(alice);
        IERC20(pegged).approve(stabilityPoolCollateral, depositAmount);
        vm.prank(alice);
        IStabilityPool(stabilityPoolCollateral).deposit(depositAmount, alice, 0);

        // Deposit via both aliases
        deal(wrappedCollateral, address(this), harvestReward + rebalanceReward);
        IERC20(wrappedCollateral).approve(stabilityPoolCollateral, harvestReward + rebalanceReward);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(collHarvestAlias, harvestReward);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(collRebalanceAlias, rebalanceReward);

        skip(8 days);

        // Claim all — should receive total from both aliases
        uint256 balBefore = IERC20(wrappedCollateral).balanceOf(alice);
        vm.prank(alice);
        IMultipleRewardAccumulator(stabilityPoolCollateral).claim(alice);
        uint256 received = IERC20(wrappedCollateral).balanceOf(alice) - balBefore;

        assertApprox(received, harvestReward + rebalanceReward, 2 * 604800, "claim all collects both aliases");
    }
}
