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
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {Minter_v2} from "src/minter/Minter_v2.sol";
import {StabilityPoolManager_v1} from "src/minter/StabilityPoolManager_v1.sol";
import {MockWrappedPriceOracle} from "test/mocks/MockWrappedPriceOracle.sol";

import {console2} from "forge-std/console2.sol";

/// @title RebalanceFairnessTest
/// @notice Worked example from doc/ideas/sp-dynamic-fees.md using real contract code
/// deployed via the production deployment scripts. Simulates all actors through
/// rebalance scenarios to measure the exact income redistribution.
contract RebalanceFairnessSetUp is BaoTest, Deploy_ETH_Minter {
    using MinterMarketConfigLib for Config_MinterMarket;

    // Deployed contract addresses
    address minter;
    address stabilityPoolCollateral;
    address stabilityPoolLeveraged;
    address stabilityPoolManager;
    address pegged;
    address leveraged;
    address wrappedCollateral;

    // Mock oracle for price/rate control
    MockWrappedPriceOracle mockOracle;
    uint256 oraclePrice;
    uint256 oracleRate;

    // Cast — 6 actors, equal amounts, 2 per pool initially (equal pool sizes)
    address alice; // Stays in Collateral SP
    address bob; // Withdraws from Coll SP before rebalance, re-deposits after
    address charlie; // Stays in Leveraged SP
    address dave; // Withdraws from Lev SP before rebalance, re-deposits after
    address fred; // Outside SPs, deposits into Coll SP after rebalance
    address george; // Outside SPs, deposits into Lev SP after rebalance

    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }

    function setUp() public virtual {
        // Deploy BaoFactory locally
        address factory = _ensureBaoFactory();

        // Fork mainnet so real token contracts (fxSAVE, fxUSD, etc.) exist
        uint256 forkId = vm.createSelectFork(vm.rpcUrl("mainnet"));
        vm.selectFork(forkId);

        // Register as factory operator
        vm.prank(IBaoFactory(factory).owner());
        IBaoFactory(factory).setOperator(address(this), 365 days);

        // Deploy a fresh ETH::fxUSD market via the production deployment scripts
        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        // Deploy only the fxUSD market (index 0)
        Config_MinterMarket[] memory toDeploy = new Config_MinterMarket[](1);
        toDeploy[0] = mktConfigs[0];
        deployForPeg("fairness_test", peg, mktConfigs, "mainnet", true, toDeploy);

        // Resolve deployed addresses
        _setSaltPrefix("fairness_test");
        minter = _predictAddress("ETH", "fxUSD", "minter");
        stabilityPoolCollateral = _predictAddress("ETH", "fxUSD", "stabilityPoolCollateral");
        stabilityPoolLeveraged = _predictAddress("ETH", "fxUSD", "stabilityPoolLeveraged");
        stabilityPoolManager = _predictAddress("ETH", "fxUSD", "stabilityPoolManager");
        pegged = _predictAddress("ETH", "pegged");
        leveraged = _predictAddress("ETH", "fxUSD", "leveraged");
        wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();

        // Install mock oracle so we can control price/rate
        // The deployment script sets the oracle to a predicted address that doesn't exist yet
        // (oracles are deployed separately). Override it with our mock.
        mockOracle = new MockWrappedPriceOracle();
        // Price = 1 so collateral and pegged amounts are in the same units (simplifies balance sheets)
        // Rate = 1 means 1 fxSAVE = 1 fxUSD (no yield accrued yet)
        oraclePrice = 1 ether;
        oracleRate = 1 ether;
        mockOracle.setLatestAnswer(oraclePrice, oracleRate);

        vm.prank(Minter_v2(minter).owner());
        Minter_v2(minter).updatePriceOracle(address(mockOracle));

        // Override harvest config: set cut to 0 so harvest goes to pools, not treasury
        vm.startPrank(StabilityPoolManager_v1(stabilityPoolManager).owner());
        StabilityPoolManager_v1(stabilityPoolManager).updateHarvestCutRatio(0);
        StabilityPoolManager_v1(stabilityPoolManager).updateHarvestBountyRatio(0);
        StabilityPoolManager_v1(stabilityPoolManager).updateRebalanceBountyRatio(0);
        vm.stopPrank();

        // Create actors
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        dave = makeAddr("dave");
        fred = makeAddr("fred");
        george = makeAddr("george");

        // Approve both pools for all actors
        address[6] memory actors = [alice, bob, charlie, dave, fred, george];
        for (uint256 i = 0; i < actors.length; i++) {
            vm.startPrank(actors[i]);
            IERC20(pegged).approve(stabilityPoolCollateral, type(uint256).max);
            IERC20(pegged).approve(stabilityPoolLeveraged, type(uint256).max);
            vm.stopPrank();
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // Minting helpers — use the zero-fee role to mint pegged/leveraged
    // ═══════════════════════════════════════════════════════════════

    function _mintPegged(address to, uint256 collateralAmount) internal returns (uint256 peggedMinted) {
        deal(wrappedCollateral, address(this), collateralAmount);
        IERC20(wrappedCollateral).approve(minter, collateralAmount);

        // Mint via zero-fee — this test contract has owner privileges from deployment
        uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
        vm.prank(Minter_v2(minter).owner());
        Minter_v2(minter).grantRoles(address(this), zeroFeeRole);

        peggedMinted = IMinter(minter).freeMintPeggedToken(collateralAmount, to);
    }

    function _mintLeveraged(address to, uint256 collateralAmount) internal returns (uint256 levMinted) {
        deal(wrappedCollateral, address(this), collateralAmount);
        IERC20(wrappedCollateral).approve(minter, collateralAmount);

        uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
        vm.prank(Minter_v2(minter).owner());
        Minter_v2(minter).grantRoles(address(this), zeroFeeRole);

        levMinted = IMinter(minter).freeMintLeveragedToken(collateralAmount, to);
    }

    // ═══════════════════════════════════════════════════════════════
    // SP helpers
    // ═══════════════════════════════════════════════════════════════

    function _deposit(address pool, address who, uint256 amount) internal {
        vm.prank(who);
        IStabilityPool(pool).deposit(amount, who, 0);
    }

    function _withdrawAll(address pool, address who) internal {
        // Use request + window to avoid early withdrawal fee
        vm.prank(who);
        IStabilityPool(pool).requestWithdrawal();
        (uint64 start, ) = IStabilityPool(pool).getWithdrawalRequest(who);
        vm.warp(uint256(start) + 1);
        vm.prank(who);
        IStabilityPool(pool).withdraw(type(uint256).max, who, 0);
    }

    function _triggerHarvest() internal returns (uint256 harvested) {
        // Increase rate by 5% to simulate yield accrual
        oracleRate = oracleRate * 105 / 100;
        mockOracle.setLatestAnswer(oraclePrice, oracleRate);
        harvested = IStabilityPoolManager(stabilityPoolManager).harvest(makeAddr("bountyReceiver"), 0);
    }

    // ═══════════════════════════════════════════════════════════════
    // Logging
    // ═══════════════════════════════════════════════════════════════

    function _logState(string memory label) internal view {
        console2.log("");
        console2.log("=== %s ===", label);
        console2.log("Minter CR:             %e", IMinter(minter).collateralRatio());
        console2.log("Minter harvestable:    %e", IMinter(minter).harvestable());
        console2.log("Minter wstETH:         %e", IERC20(wrappedCollateral).balanceOf(minter));
        console2.log("Coll SP pegged bal:    %e", IERC20(pegged).balanceOf(stabilityPoolCollateral));
        console2.log("Lev SP pegged bal:     %e", IERC20(pegged).balanceOf(stabilityPoolLeveraged));
        console2.log("Coll SP wstETH bal:    %e", IERC20(wrappedCollateral).balanceOf(stabilityPoolCollateral));
        console2.log("Lev SP lev token bal:  %e", IERC20(leveraged).balanceOf(stabilityPoolLeveraged));
        console2.log("Rebalance threshold:   %e", IStabilityPoolManager(stabilityPoolManager).rebalanceThreshold());
    }

    // ═══════════════════════════════════════════════════════════════
    // Claimable snapshots — to separate rebalance from harvest
    // ═══════════════════════════════════════════════════════════════

    struct ClaimableSnapshot {
        uint256 fxSAVE_collSP; // fxSAVE claimable from Coll SP (rebal + harvest combined)
        uint256 fxSAVE_levSP; // fxSAVE claimable from Lev SP (harvest only — rebal pays lev tokens)
        uint256 levToken_levSP; // leveraged token claimable from Lev SP (rebal only)
    }

    function _snapshotClaimable(address who) internal view returns (ClaimableSnapshot memory s) {
        s.fxSAVE_collSP = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(who, wrappedCollateral);
        s.fxSAVE_levSP = IMultipleRewardAccumulator(stabilityPoolLeveraged).claimable(who, wrappedCollateral);
        s.levToken_levSP = IMultipleRewardAccumulator(stabilityPoolLeveraged).claimable(who, leveraged);
    }

    function _logActor(string memory name, address who) internal view {
        console2.log("--- %s ---", name);
        console2.log("  pegged (wallet):               %e", IERC20(pegged).balanceOf(who));
        console2.log("  Coll SP deposit:               %e", IStabilityPool(stabilityPoolCollateral).assetBalanceOf(who));
        console2.log("  Lev SP deposit:                %e", IStabilityPool(stabilityPoolLeveraged).assetBalanceOf(who));
        console2.log("  fxSAVE (wallet):               %e", IERC20(wrappedCollateral).balanceOf(who));
        console2.log("  leveraged (wallet):            %e", IERC20(leveraged).balanceOf(who));
        ClaimableSnapshot memory c = _snapshotClaimable(who);
        console2.log("  claimable fxSAVE (coll SP):    %e", c.fxSAVE_collSP);
        console2.log("  claimable fxSAVE (lev SP):     %e", c.fxSAVE_levSP);
        console2.log("  claimable lev tokens (lev SP): %e", c.levToken_levSP);
    }

    function _logAllActors() internal view {
        _logActor("Alice (Coll, stays)", alice);
        _logActor("Bob (Coll, leaves+returns)", bob);
        _logActor("Charlie (Lev, stays)", charlie);
        _logActor("Dave (Lev, leaves+returns)", dave);
        _logActor("Fred (new->Coll)", fred);
        _logActor("George (new->Lev)", george);
    }

    /// @notice Log the separated rebalance vs harvest breakdown for all actors.
    /// @param label Description of the snapshot point
    /// @param preRebal Claimable snapshots taken before the rebalance (or before harvest)
    /// @param current Claimable snapshots taken now
    /// @param isHarvestDelta If true, subtracts preRebal to show harvest-only delta
    function _logBreakdown(
        string memory label,
        ClaimableSnapshot[6] memory preRebal,
        ClaimableSnapshot[6] memory current,
        bool isHarvestDelta
    ) internal pure {
        console2.log("");
        console2.log("=== %s ===", label);
        string[6] memory names = [
            "Alice (Coll, stays)",
            "Bob (Coll, returns)",
            "Charlie (Lev, stays)",
            "Dave (Lev, returns)",
            "Fred (new->Coll)",
            "George (new->Lev)"
        ];

        for (uint256 i = 0; i < 6; i++) {
            uint256 fxSAVE_coll = isHarvestDelta
                ? current[i].fxSAVE_collSP - preRebal[i].fxSAVE_collSP
                : current[i].fxSAVE_collSP;
            uint256 fxSAVE_lev = isHarvestDelta
                ? current[i].fxSAVE_levSP - preRebal[i].fxSAVE_levSP
                : current[i].fxSAVE_levSP;
            uint256 levToken = isHarvestDelta
                ? current[i].levToken_levSP - preRebal[i].levToken_levSP
                : current[i].levToken_levSP;
            console2.log("  %s", names[i]);
            console2.log("    fxSAVE (coll SP): %e  |  fxSAVE (lev SP): %e  |  lev tokens: %e", fxSAVE_coll, fxSAVE_lev, levToken);
        }
    }

    function _snapshotAll() internal view returns (ClaimableSnapshot[6] memory snaps) {
        address[6] memory actors = [alice, bob, charlie, dave, fred, george];
        for (uint256 i = 0; i < 6; i++) {
            snaps[i] = _snapshotClaimable(actors[i]);
        }
    }
}

contract RebalanceFairnessScenarios is RebalanceFairnessSetUp {
    address marketMaker;

    /// @notice Bootstrap the system: mint pegged + leveraged at healthy CR, distribute to actors,
    /// then drop price to push CR below threshold.
    /// Each actor gets 100 pegged. Market maker keeps the leveraged tokens.
    function _bootstrap() internal returns (uint256 each) {
        marketMaker = makeAddr("marketMaker");
        each = 100 ether;

        // Mint 600 pegged (for 6 actors × 100) and 200 leveraged (for market maker)
        // At price=1: 600 fxSAVE → 600 pegged, 200 fxSAVE → 200 leveraged
        // Total collateral = 800, pegged = 600, CR = 800/600 = 1.333 (healthy)
        _mintPegged(marketMaker, 600 ether);
        _mintLeveraged(marketMaker, 200 ether);

        // Market maker distributes pegged to actors
        vm.startPrank(marketMaker);
        IERC20(pegged).transfer(alice, each);
        IERC20(pegged).transfer(bob, each);
        IERC20(pegged).transfer(charlie, each);
        IERC20(pegged).transfer(dave, each);
        IERC20(pegged).transfer(fred, each);
        IERC20(pegged).transfer(george, each);
        vm.stopPrank();

        // Drop price by 10%: CR = 800 * 0.9 / 600 = 1.20 (below 1.30 threshold)
        oraclePrice = 0.9 ether;
        mockOracle.setLatestAnswer(oraclePrice, oracleRate);
    }

    /// @notice Scenario A: Everyone stays through the rebalance (baseline).
    function test_scenarioA_everyoneStays() public {
        uint256 each = _bootstrap();

        // Deposit into pools: Coll SP = Alice + Bob, Lev SP = Charlie + Dave (equal pool sizes)
        _deposit(stabilityPoolCollateral, alice, each);
        _deposit(stabilityPoolCollateral, bob, each);
        _deposit(stabilityPoolLeveraged, charlie, each);
        _deposit(stabilityPoolLeveraged, dave, each);
        // Fred and George hold pegged outside SPs

        _logState("BEFORE REBALANCE - Scenario A");

        // Snapshot before rebalance
        ClaimableSnapshot[6] memory preRebal = _snapshotAll();
        uint256 collPeggedBefore = IERC20(pegged).balanceOf(stabilityPoolCollateral);
        uint256 levPeggedBefore = IERC20(pegged).balanceOf(stabilityPoolLeveraged);

        // Rebalance
        uint256 liquidated = IStabilityPoolManager(stabilityPoolManager).rebalance(makeAddr("bounty"), 0);

        uint256 collLiquidated = collPeggedBefore - IERC20(pegged).balanceOf(stabilityPoolCollateral);
        uint256 levLiquidated = levPeggedBefore - IERC20(pegged).balanceOf(stabilityPoolLeveraged);
        console2.log("");
        console2.log("--- LIQUIDATION SPLIT ---");
        console2.log("Total liquidated:      %e", liquidated);
        console2.log("From Coll SP:          %e", collLiquidated);
        console2.log("From Lev SP:           %e", levLiquidated);

        // Snapshot after rebalance — delta from preRebal = rebalance rewards only
        ClaimableSnapshot[6] memory postRebal = _snapshotAll();
        _logBreakdown("REBALANCE REWARDS (static, one-off)", preRebal, postRebal, true);

        _logState("AFTER REBALANCE - Scenario A");
        _logAllActors();

        // Trigger harvest
        skip(1 days);
        uint256 harvested = _triggerHarvest();
        console2.log("Harvested: %e", harvested);

        // Wait for full reward distribution period
        skip(8 days);

        // Snapshot after harvest — delta from postRebal = harvest rewards only
        ClaimableSnapshot[6] memory postHarvest = _snapshotAll();
        _logBreakdown("HARVEST REWARDS (streamed, ongoing)", postRebal, postHarvest, true);
        _logBreakdown("TOTAL CLAIMABLE (rebalance + harvest)", preRebal, postHarvest, false);

        _logState("AFTER HARVEST - Scenario A");
        _logAllActors();
    }

    /// @notice Scenario B: Bob and Dave withdraw before rebalance, then re-deposit after.
    /// Fred and George also deposit after rebalance.
    function test_scenarioB_leaversReturn() public {
        uint256 each = _bootstrap();

        // Everyone deposits initially: 2 per pool (equal pool sizes)
        _deposit(stabilityPoolCollateral, alice, each);
        _deposit(stabilityPoolCollateral, bob, each);
        _deposit(stabilityPoolLeveraged, charlie, each);
        _deposit(stabilityPoolLeveraged, dave, each);

        _logState("BEFORE WITHDRAWALS - Scenario B");
        _logAllActors();

        // Step 1: Bob and Dave withdraw before rebalance
        _withdrawAll(stabilityPoolCollateral, bob);
        _withdrawAll(stabilityPoolLeveraged, dave);

        _logState("AFTER WITHDRAWALS - Scenario B");
        _logAllActors();

        // Step 2: Rebalance (Alice and Charlie absorb all losses)
        ClaimableSnapshot[6] memory preRebal = _snapshotAll();
        uint256 collPeggedBefore = IERC20(pegged).balanceOf(stabilityPoolCollateral);
        uint256 levPeggedBefore = IERC20(pegged).balanceOf(stabilityPoolLeveraged);

        uint256 liquidated = IStabilityPoolManager(stabilityPoolManager).rebalance(makeAddr("bounty"), 0);

        uint256 collLiquidated = collPeggedBefore - IERC20(pegged).balanceOf(stabilityPoolCollateral);
        uint256 levLiquidated = levPeggedBefore - IERC20(pegged).balanceOf(stabilityPoolLeveraged);
        console2.log("");
        console2.log("--- LIQUIDATION SPLIT ---");
        console2.log("Total liquidated:      %e", liquidated);
        console2.log("From Coll SP:          %e", collLiquidated);
        console2.log("From Lev SP:           %e", levLiquidated);

        ClaimableSnapshot[6] memory postRebal = _snapshotAll();
        _logBreakdown("REBALANCE REWARDS (static, one-off)", preRebal, postRebal, true);

        _logState("AFTER REBALANCE - Scenario B");

        // Step 3: Re-deposits + new entrants
        uint256 bobPegged = IERC20(pegged).balanceOf(bob);
        _deposit(stabilityPoolCollateral, bob, bobPegged);

        uint256 davePegged = IERC20(pegged).balanceOf(dave);
        _deposit(stabilityPoolLeveraged, dave, davePegged);

        _deposit(stabilityPoolCollateral, fred, each);
        _deposit(stabilityPoolLeveraged, george, each);

        _logState("AFTER RE-DEPOSITS - Scenario B");

        // Step 4: Harvest
        skip(1 days);
        uint256 harvested = _triggerHarvest();
        console2.log("Harvested: %e", harvested);

        // Wait for full distribution
        skip(8 days);

        ClaimableSnapshot[6] memory postHarvest = _snapshotAll();
        _logBreakdown("REBALANCE REWARDS (static, one-off)", preRebal, postRebal, true);
        _logBreakdown("HARVEST REWARDS (streamed, ongoing)", postRebal, postHarvest, true);
        _logBreakdown("TOTAL CLAIMABLE (rebalance + harvest)", preRebal, postHarvest, false);

        _logState("AFTER HARVEST - Scenario B");
    }
}
