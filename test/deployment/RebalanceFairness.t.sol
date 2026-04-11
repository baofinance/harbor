// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {Deploy_ETH_Minter} from "script/src/v3/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "script/config/ConfigBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {StabilityPoolManager_v1} from "src/minter/StabilityPoolManager_v1.sol";
import {MockWrappedPriceOracle} from "test/mocks/MockWrappedPriceOracle.sol";

import {console2} from "forge-std/console2.sol";
import {FmtLib} from "src/util/FmtLib.sol";

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

    // Cast — 6 SP actors + Eve who holds only leveraged tokens
    address alice; // Stays in Collateral SP
    address bob; // Withdraws from Coll SP before rebalance, re-deposits after
    address charlie; // Stays in Leveraged SP
    address dave; // Withdraws from Lev SP before rebalance, re-deposits after
    address fred; // Outside SPs, deposits into Coll SP after rebalance
    address george; // Outside SPs, deposits into Lev SP after rebalance
    address eve; // Holds only leveraged tokens (the market maker / leveraged-side liquidity)

    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }

    function setUp() public virtual {
        // Deploy BaoFactory locally
        address factory = _ensureBaoFactory();

        // Fork mainnet so real token contracts (fxSAVE, fxUSD, etc.) exist
        // Pinned after latest Harbor deployment (SPL remediation, 2026-03-25) for caching
        uint256 forkId = vm.createSelectFork(vm.rpcUrl("mainnet"), 24699497);
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
        minter = _predictAddress(_key("ETH", "fxUSD", "minter"));
        stabilityPoolCollateral = _predictAddress(_key("ETH", "fxUSD", "stabilityPoolCollateral"));
        stabilityPoolLeveraged = _predictAddress(_key("ETH", "fxUSD", "stabilityPoolLeveraged"));
        stabilityPoolManager = _predictAddress(_key("ETH", "fxUSD", "stabilityPoolManager"));
        pegged = _predictAddress(_key("ETH", "pegged"));
        leveraged = _predictAddress(_key("ETH", "fxUSD", "leveraged"));
        wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();

        // Install mock oracle so we can control price/rate
        // The deployment script sets the oracle to a predicted address that doesn't exist yet
        // (oracles are deployed separately). Override it with our mock.
        mockOracle = new MockWrappedPriceOracle();
        // Price = 1/4000 ETH per fxUSD (i.e. 4000 fxUSD per ETH, ETH ≈ $4000).
        // Rate = 1 means 1 fxSAVE = 1 fxUSD (no yield accrued yet).
        oraclePrice = 1 ether / 4000;
        oracleRate = 1 ether;
        mockOracle.setLatestAnswer(oraclePrice, oracleRate);

        vm.prank(IBaoOwnable(minter).owner());
        IMinter(minter).updatePriceOracle(address(mockOracle));

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
        eve = makeAddr("eve");

        // Approve both pools for the 6 SP actors (Eve doesn't deposit into pools)
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
        vm.prank(IBaoOwnable(minter).owner());
        IBaoRoles(minter).grantRoles(address(this), zeroFeeRole);

        peggedMinted = IMinter(minter).freeMintPeggedToken(collateralAmount, to);
    }

    function _mintLeveraged(address to, uint256 collateralAmount) internal returns (uint256 levMinted) {
        deal(wrappedCollateral, address(this), collateralAmount);
        IERC20(wrappedCollateral).approve(minter, collateralAmount);

        uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
        vm.prank(IBaoOwnable(minter).owner());
        IBaoRoles(minter).grantRoles(address(this), zeroFeeRole);

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

    /// @notice Bump the oracle rate by 0.1% (~5.2% APY weekly equivalent) and trigger a harvest.
    function _triggerHarvest() internal returns (uint256 harvested) {
        oracleRate = (oracleRate * 1001) / 1000;
        mockOracle.setLatestAnswer(oraclePrice, oracleRate);
        harvested = IStabilityPoolManager(stabilityPoolManager).harvest(makeAddr("bountyReceiver"), 0);
    }

    /// @dev Convert a fxSAVE amount to fxUSD using the current oracle rate.
    /// Rate has units fxUSD-per-fxSAVE, so 1 fxSAVE = `rate` fxUSD.
    function _fxSAVEToFxUSD(uint256 fxSAVEamount) internal view returns (uint256) {
        return (fxSAVEamount * oracleRate) / 1 ether;
    }

    /// @dev Convert a haETH (pegged) amount to fxUSD using the current oracle price.
    /// Price has units ETH-per-fxUSD (since CR = collateral_fxUSD × price / pegged_haETH is dimensionless),
    /// so 1 haETH = 1 ETH = 1/price fxUSD.
    function _haETHToFxUSD(uint256 peggedAmount) internal view returns (uint256) {
        return (peggedAmount * 1 ether) / oraclePrice;
    }

    /// @dev Convert a leveraged-token amount to fxUSD via the Minter's `leveragedTokenPrice()`.
    /// `leveragedTokenPrice()` returns NAV in pegged-token (haETH) units, so:
    ///   $ = lev × levPrice / oraclePrice    (haETH-equivalent → fxUSD)
    function _levToFxUSD(uint256 levAmount) internal view returns (uint256) {
        if (levAmount == 0) {
            return 0;
        }
        uint256 levPrice = IMinter(minter).leveragedTokenPrice();
        return (levAmount * levPrice) / oraclePrice;
    }

    /// @dev Compute an actor's total dollar value across wallet, both SPs, and claimable rewards.
    /// Position (haETH) → $ via price, fxSAVE rewards → $ via rate, lev tokens → $ via levTokenPrice.
    function _totalDollars(address who) internal view returns (uint256) {
        uint256 peggedColl = IERC20(stabilityPoolCollateral).balanceOf(who);
        uint256 peggedLev = IERC20(stabilityPoolLeveraged).balanceOf(who);
        uint256 peggedWallet = IERC20(pegged).balanceOf(who);
        uint256 fxSAVEcoll = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(who, wrappedCollateral);
        uint256 fxSAVElev = IMultipleRewardAccumulator(stabilityPoolLeveraged).claimable(who, wrappedCollateral);
        uint256 levWallet = IERC20(leveraged).balanceOf(who);
        uint256 levClaimable = IMultipleRewardAccumulator(stabilityPoolLeveraged).claimable(who, leveraged);
        return
            _haETHToFxUSD(peggedColl + peggedLev + peggedWallet) +
            _fxSAVEToFxUSD(fxSAVEcoll + fxSAVElev) +
            _levToFxUSD(levWallet + levClaimable);
    }

    /// @dev Emit one row for the rebalance-fairness doc table.
    /// `Position` is the actor's pegged + lev-token holdings.
    /// `Reb` is the rebalance reward delta (postRebal - preRebal) in both fxSAVE and lev tokens.
    /// `Harv` is the harvest accumulation since postRebal (fxSAVE only).
    function _logTableRow(
        string memory name,
        address who,
        ClaimableSnapshot memory preRebalSnap,
        ClaimableSnapshot memory postRebalSnap
    ) internal view {
        {
            uint256 pegPos = IERC20(pegged).balanceOf(who) +
                IERC20(stabilityPoolCollateral).balanceOf(who) +
                IERC20(stabilityPoolLeveraged).balanceOf(who);
            console2.log(
                string.concat(
                    "  ",
                    name,
                    "\n",
                    "    pos_haETH=",
                    FmtLib.sci(pegPos),
                    " pos_lev=",
                    FmtLib.sci(IERC20(leveraged).balanceOf(who))
                )
            );
        }
        {
            uint256 preFxsave = preRebalSnap.fxSAVE_collSP + preRebalSnap.fxSAVE_levSP;
            uint256 postRebFxsave = postRebalSnap.fxSAVE_collSP + postRebalSnap.fxSAVE_levSP;
            ClaimableSnapshot memory cur = _snapshotClaimable(who);
            uint256 curFxsave = cur.fxSAVE_collSP + cur.fxSAVE_levSP;
            console2.log(
                string.concat(
                    "    reb_fxSAVE=",
                    FmtLib.sci(postRebFxsave - preFxsave),
                    " reb_lev=",
                    FmtLib.sci(postRebalSnap.levToken_levSP - preRebalSnap.levToken_levSP),
                    " harv_fxSAVE=",
                    FmtLib.sci(curFxsave - postRebFxsave),
                    "\n    total_$=",
                    FmtLib.sci(_totalDollars(who))
                )
            );
        }
    }

    /// @dev Emit a labelled stage table for all 6 SP actors plus Eve.
    /// Eve never deposits, so her snapshots are always zero.
    function _logStageTable(
        string memory label,
        ClaimableSnapshot[6] memory preRebalSnaps,
        ClaimableSnapshot[6] memory postRebalSnaps
    ) internal view {
        console2.log(
            string.concat(
                "\n=== STAGE TABLE: ",
                label,
                " ===\n",
                "price=",
                FmtLib.sci(oraclePrice),
                " rate=",
                FmtLib.sci(oracleRate)
            )
        );
        _logTableRow("Alice", alice, preRebalSnaps[0], postRebalSnaps[0]);
        _logTableRow("Bob", bob, preRebalSnaps[1], postRebalSnaps[1]);
        _logTableRow("Charlie", charlie, preRebalSnaps[2], postRebalSnaps[2]);
        _logTableRow("Dave", dave, preRebalSnaps[3], postRebalSnaps[3]);
        _logTableRow("Fred", fred, preRebalSnaps[4], postRebalSnaps[4]);
        _logTableRow("George", george, preRebalSnaps[5], postRebalSnaps[5]);
        ClaimableSnapshot memory zero;
        _logTableRow("Eve", eve, zero, zero);
    }

    // ═══════════════════════════════════════════════════════════════
    // Logging
    // ═══════════════════════════════════════════════════════════════

    function _logState(string memory label) internal view {
        console2.log(
            string.concat(
                "\n=== ",
                label,
                " ===\n",
                "Minter CR:             ",
                FmtLib.sci(IMinter(minter).collateralRatio()),
                "\n",
                "Minter harvestable:    ",
                FmtLib.sci(IMinter(minter).harvestable()),
                "\n",
                "Minter fxSAVE:         ",
                FmtLib.sci(IERC20(wrappedCollateral).balanceOf(minter)),
                "\n",
                "Coll SP pegged bal:    ",
                FmtLib.sci(IERC20(pegged).balanceOf(stabilityPoolCollateral)),
                "\n",
                "Lev SP pegged bal:     ",
                FmtLib.sci(IERC20(pegged).balanceOf(stabilityPoolLeveraged)),
                "\n",
                "Coll SP fxSAVE bal:    ",
                FmtLib.sci(IERC20(wrappedCollateral).balanceOf(stabilityPoolCollateral)),
                "\n",
                "Lev SP lev token bal:  ",
                FmtLib.sci(IERC20(leveraged).balanceOf(stabilityPoolLeveraged)),
                "\n",
                "Rebalance threshold:   ",
                FmtLib.sci(IStabilityPoolManager(stabilityPoolManager).rebalanceThreshold())
            )
        );
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
        ClaimableSnapshot memory c = _snapshotClaimable(who);
        console2.log(
            string.concat(
                "--- ",
                name,
                " ---\n",
                "  pegged (wallet):               ",
                FmtLib.sci(IERC20(pegged).balanceOf(who)),
                "\n",
                "  Coll SP deposit:               ",
                FmtLib.sci(IERC20(stabilityPoolCollateral).balanceOf(who)),
                "\n",
                "  Lev SP deposit:                ",
                FmtLib.sci(IERC20(stabilityPoolLeveraged).balanceOf(who)),
                "\n",
                "  fxSAVE (wallet):               ",
                FmtLib.sci(IERC20(wrappedCollateral).balanceOf(who)),
                "\n",
                "  leveraged (wallet):            ",
                FmtLib.sci(IERC20(leveraged).balanceOf(who)),
                "\n",
                "  claimable fxSAVE (coll SP):    ",
                FmtLib.sci(c.fxSAVE_collSP),
                "\n",
                "  claimable fxSAVE (lev SP):     ",
                FmtLib.sci(c.fxSAVE_levSP),
                "\n",
                "  claimable lev tokens (lev SP): ",
                FmtLib.sci(c.levToken_levSP)
            )
        );
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
        console2.log(string.concat("\n=== ", label, " ==="));
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
            console2.log(
                string.concat(
                    "  ",
                    names[i],
                    "\n",
                    "    fxSAVE (coll SP): ",
                    FmtLib.sci(fxSAVE_coll),
                    "  |  fxSAVE (lev SP): ",
                    FmtLib.sci(fxSAVE_lev),
                    "  |  lev tokens: ",
                    FmtLib.sci(levToken)
                )
            );
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
    /// @notice Bootstrap the system: mint pegged + leveraged at healthy CR, distribute to actors.
    /// @dev Does NOT drop the price — call `_dropPriceBelowRebalanceThreshold()` separately so
    ///      the test can capture a Stage 0 snapshot at the healthy CR.
    /// Each actor gets 100 haETH. Eve keeps all 200 leveraged tokens.
    /// At price = 1/4000 (ETH per fxUSD = 4000 fxUSD per ETH, ETH ≈ $4000):
    ///   600 haETH × $4000 = $2.4M obligations
    ///   200 leveraged tokens minted from 800,000 fxSAVE
    ///   Total collateral in Minter = 3,200,000 fxSAVE = $3.2M, CR = 1.333 (healthy)
    function _bootstrap() internal returns (uint256 each) {
        each = 100 ether;

        // 600 haETH from 600 × 4000 = 2,400,000 fxSAVE.
        // 200 leveraged tokens from 200 × 4000 = 800,000 fxSAVE.
        // Total Minter collateral = 3,200,000 fxSAVE; pegged = 600; CR = 1.333.
        _mintPegged(eve, 2_400_000 ether);
        _mintLeveraged(eve, 800_000 ether);

        // Eve distributes pegged to the 6 SP actors and keeps the leveraged tokens herself.
        vm.startPrank(eve);
        IERC20(pegged).transfer(alice, each);
        IERC20(pegged).transfer(bob, each);
        IERC20(pegged).transfer(charlie, each);
        IERC20(pegged).transfer(dave, each);
        IERC20(pegged).transfer(fred, each);
        IERC20(pegged).transfer(george, each);
        vm.stopPrank();
    }

    /// @notice Multiply oracle price by 0.9 so CR drops 10% (1.333 → 1.20), below the rebalance
    ///         threshold (1.30) but well above the depeg point (1.00). Equivalently: ETH appreciates
    ///         by ~11.11% relative to fxUSD.
    function _dropPriceBelowRebalanceThreshold() internal {
        oraclePrice = (oraclePrice * 9) / 10;
        mockOracle.setLatestAnswer(oraclePrice, oracleRate);
    }

    /// @notice Scenario A: Everyone stays through the rebalance (baseline).
    /// @dev Uses 0.1% rate bump per week applied for 2 weeks.
    function test_scenarioA_everyoneStays() public {
        uint256 each = _bootstrap();

        // Deposit into pools: Coll SP = Alice + Bob, Lev SP = Charlie + Dave (equal pool sizes).
        // Fred and George stay in their wallets. Eve holds the leveraged tokens, no SP.
        _deposit(stabilityPoolCollateral, alice, each);
        _deposit(stabilityPoolCollateral, bob, each);
        _deposit(stabilityPoolLeveraged, charlie, each);
        _deposit(stabilityPoolLeveraged, dave, each);

        // ── Stage 0: post-deposit, healthy CR=1.333, price=1/4000, rate=1 ──
        ClaimableSnapshot[6] memory zeroSnaps; // no rebalance has happened yet
        _logStageTable("scenarioA Stage 0 - After initial deposit (CR=1.333, rate=1)", zeroSnaps, zeroSnaps);

        // Drop the oracle price 10% so CR falls below the rebalance threshold
        _dropPriceBelowRebalanceThreshold();

        // ── Stage 1: post price drop, CR=1.20, no rebalance yet ──
        _logStageTable("scenarioA Stage 1 - After price drop (CR=1.20, rate=1)", zeroSnaps, zeroSnaps);

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

        // ── Asserts: rebalance ──────────────────────────────────────
        // Total liquidated to bring CR from 1.20 → 1.30: 75 pegged (37.5 from each pool)
        assertApproxEqAbs(liquidated, 75 ether, 1e16, "scenarioA: total liquidated == 75");
        assertApproxEqAbs(collLiquidated, 37.5 ether, 1e16, "scenarioA: coll liquidated == 37.5");
        assertApproxEqAbs(levLiquidated, 37.5 ether, 1e16, "scenarioA: lev liquidated == 37.5");

        // Each Coll SP depositor lost 18.75 pegged → 81.25 remaining
        assertApproxEqAbs(
            IERC20(stabilityPoolCollateral).balanceOf(alice),
            81.25 ether,
            1e15,
            "scenarioA: alice 81.25 after rebalance"
        );
        assertApproxEqAbs(
            IERC20(stabilityPoolCollateral).balanceOf(bob),
            81.25 ether,
            1e15,
            "scenarioA: bob 81.25 after rebalance"
        );

        // Each Coll SP depositor receives 18.75 haETH / price fxSAVE rebalance reward
        // (since rate = 1.0). At price = 0.9/4000, that's 18.75 / (0.9/4000) ≈ 83,333.33 fxSAVE.
        // Each Lev SP depositor receives 31.25 lev tokens (price-invariant — the lev mint formula
        // has price in both numerator and denominator).
        {
            uint256 expectedCollRebal = (18.75 ether * 1 ether) / oraclePrice;
            assertApproxEqAbs(
                _snapshotClaimable(alice).fxSAVE_collSP - preRebal[0].fxSAVE_collSP,
                expectedCollRebal,
                1e15,
                "scenarioA: alice rebalance fxSAVE == 83333.33"
            );
            assertApproxEqAbs(
                _snapshotClaimable(bob).fxSAVE_collSP - preRebal[1].fxSAVE_collSP,
                expectedCollRebal,
                1e15,
                "scenarioA: bob rebalance fxSAVE == 83333.33"
            );
            assertApproxEqAbs(
                _snapshotClaimable(charlie).levToken_levSP - preRebal[2].levToken_levSP,
                31.25 ether,
                1e15,
                "scenarioA: charlie rebalance lev tokens == 31.25"
            );
            assertApproxEqAbs(
                _snapshotClaimable(dave).levToken_levSP - preRebal[3].levToken_levSP,
                31.25 ether,
                1e15,
                "scenarioA: dave rebalance lev tokens == 31.25"
            );
        }

        // Snapshot after rebalance — delta from preRebal = rebalance rewards only
        ClaimableSnapshot[6] memory postRebal = _snapshotAll();
        _logBreakdown("REBALANCE REWARDS (static, one-off)", preRebal, postRebal, true);

        _logState("AFTER REBALANCE - Scenario A");
        _logAllActors();

        // ── Stage 2: post-rebalance (CR back to 1.30, rate=1) ──
        _logStageTable("scenarioA Stage 2 - After rebalance (CR=1.30, rate=1)", preRebal, postRebal);

        // ── Week 1 harvest (0.1% bump) ──────────────────────────────
        ClaimableSnapshot[6] memory postHarvest1;
        {
            skip(1 days);
            uint256 harvested1 = _triggerHarvest();
            console2.log("Week 1 harvested: %e", harvested1);
            skip(8 days); // full reward distribution period

            // Expected: Minter wstETH after rebalance ≈ 3,033,333 fxSAVE × 0.001 ≈ 3030 fxSAVE.
            // (Was 0.7576 ether in the old 1× test → scaled by 4000.)
            assertApproxEqRel(harvested1, 3030 ether, 0.01 ether, "scenarioA: week 1 harvest ~= 3030");

            postHarvest1 = _snapshotAll();
            _logBreakdown("WEEK 1 HARVEST REWARDS", postRebal, postHarvest1, true);

            _assertScenarioAWeek1(postRebal, postHarvest1);

            // ── Stage 3: after week 1 harvest (rate = 1.001) ──
            _logStageTable("scenarioA Stage 3 - After week 1 harvest (CR=1.30, rate=1.001)", preRebal, postRebal);
        }

        // ── Week 2 harvest (another 0.1% bump) ──────────────────────
        {
            uint256 harvested2 = _triggerHarvest();
            console2.log("Week 2 harvested: %e", harvested2);
            skip(8 days);

            // Week 2 harvest is slightly less because the Minter's wCOL was reduced by week 1 harvest.
            // Was 0.7568 ether in old test → scaled by 4000.
            assertApproxEqRel(harvested2, 3027 ether, 0.01 ether, "scenarioA: week 2 harvest ~= 3027");

            ClaimableSnapshot[6] memory postHarvest2 = _snapshotAll();
            _logBreakdown("WEEK 2 HARVEST REWARDS", postHarvest1, postHarvest2, true);
            _logBreakdown("TOTAL CLAIMABLE (rebalance + 2 weeks harvest)", preRebal, postHarvest2, false);

            _assertScenarioATotals(postRebal, postHarvest2);

            // ── Stage 4: after week 2 harvest (rate = 1.002001) ──
            _logStageTable("scenarioA Stage 4 - After week 2 harvest (CR=1.30, rate=1.002001)", preRebal, postRebal);
        }

        _logState("AFTER 2 WEEKS HARVEST - Scenario A");
        _logAllActors();
    }

    /// @dev Per-actor week 1 harvest assertions for Scenario A.
    /// Each SP depositor gets ~758 fxSAVE: total weekly harvest 3030 → 50% to each pool (1515) →
    /// 50% to each depositor within the pool (757.5). Was 0.190 in the old 1× test, scaled by 4000.
    function _assertScenarioAWeek1(
        ClaimableSnapshot[6] memory postRebal,
        ClaimableSnapshot[6] memory postHarvest1
    ) internal pure {
        uint256 alice_w1 = postHarvest1[0].fxSAVE_collSP - postRebal[0].fxSAVE_collSP;
        uint256 bob_w1 = postHarvest1[1].fxSAVE_collSP - postRebal[1].fxSAVE_collSP;
        uint256 charlie_w1 = postHarvest1[2].fxSAVE_levSP - postRebal[2].fxSAVE_levSP;
        uint256 dave_w1 = postHarvest1[3].fxSAVE_levSP - postRebal[3].fxSAVE_levSP;

        assertApproxEqRel(alice_w1, 758 ether, 0.01 ether, "scenarioA: alice w1 harvest ~= 758");
        assertApproxEqRel(bob_w1, 758 ether, 0.01 ether, "scenarioA: bob w1 harvest ~= 758");
        assertApproxEqRel(charlie_w1, 758 ether, 0.01 ether, "scenarioA: charlie w1 harvest ~= 758");
        assertApproxEqRel(dave_w1, 758 ether, 0.01 ether, "scenarioA: dave w1 harvest ~= 758");

        // Equal harvest for all 4 SP depositors (proportional to equal deposit size)
        assertEq(alice_w1, bob_w1, "scenarioA: alice == bob w1 harvest");
        assertEq(charlie_w1, dave_w1, "scenarioA: charlie == dave w1 harvest");

        // Fred and George get nothing (not in SPs)
        assertEq(postHarvest1[4].fxSAVE_collSP, 0, "scenarioA: fred no harvest");
        assertEq(postHarvest1[5].fxSAVE_levSP, 0, "scenarioA: george no harvest");
    }

    /// @dev 2-week per-actor harvest totals for Scenario A.
    /// Was 0.379 fxSAVE in old test → scaled to ~1515 in the 4000× test.
    function _assertScenarioATotals(
        ClaimableSnapshot[6] memory postRebal,
        ClaimableSnapshot[6] memory postHarvest2
    ) internal pure {
        uint256 alice_total = postHarvest2[0].fxSAVE_collSP - postRebal[0].fxSAVE_collSP;
        uint256 charlie_total = postHarvest2[2].fxSAVE_levSP - postRebal[2].fxSAVE_levSP;
        assertApproxEqRel(alice_total, 1515 ether, 0.01 ether, "scenarioA: alice 2wk harvest ~= 1515");
        assertApproxEqRel(charlie_total, 1515 ether, 0.01 ether, "scenarioA: charlie 2wk harvest ~= 1515");
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

        // ── Stage 0: post-deposit, healthy CR=1.333, price=1/4000, rate=1 ──
        ClaimableSnapshot[6] memory zeroSnaps;
        _logStageTable("scenarioB Stage 0 - After initial deposit (CR=1.333, rate=1)", zeroSnaps, zeroSnaps);

        // Drop the oracle price 10% so CR falls below the rebalance threshold
        _dropPriceBelowRebalanceThreshold();

        // ── Stage 1: post price drop, CR=1.20, no rebalance yet, no withdrawals yet ──
        _logStageTable("scenarioB Stage 1 - After price drop (CR=1.20, rate=1)", zeroSnaps, zeroSnaps);

        _logState("BEFORE WITHDRAWALS - Scenario B");
        _logAllActors();

        // Step 1: Bob and Dave withdraw before rebalance ("the dodge")
        _withdrawAll(stabilityPoolCollateral, bob);
        _withdrawAll(stabilityPoolLeveraged, dave);

        // ── Stage 2: after Bob/Dave withdraw, before rebalance ──
        _logStageTable("scenarioB Stage 2 - After Bob/Dave withdraw (CR=1.20, rate=1)", zeroSnaps, zeroSnaps);

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

        // ── Asserts: rebalance ──────────────────────────────────────
        // Same total liquidation as Scenario A — Alice and Charlie alone absorb everything
        assertApproxEqAbs(liquidated, 75 ether, 1e16, "scenarioB: total liquidated == 75");
        assertApproxEqAbs(collLiquidated, 37.5 ether, 1e16, "scenarioB: coll liquidated == 37.5");
        assertApproxEqAbs(levLiquidated, 37.5 ether, 1e16, "scenarioB: lev liquidated == 37.5");

        // Alice and Charlie each lose 37.5 → 62.5 remaining
        assertApproxEqAbs(
            IERC20(stabilityPoolCollateral).balanceOf(alice),
            62.5 ether,
            1e15,
            "scenarioB: alice 62.5 after rebalance"
        );
        assertApproxEqAbs(
            IERC20(stabilityPoolLeveraged).balanceOf(charlie),
            62.5 ether,
            1e15,
            "scenarioB: charlie 62.5 after rebalance"
        );

        // Alice gets the full Coll SP rebal reward = 37.5 / price fxSAVE ≈ 166,666.67 fxSAVE.
        // Charlie gets the full Lev SP rebal reward = 62.5 lev tokens (price-invariant).
        {
            uint256 expectedAliceRebal = (37.5 ether * 1 ether) / oraclePrice;
            assertApproxEqAbs(
                postRebal[0].fxSAVE_collSP - preRebal[0].fxSAVE_collSP,
                expectedAliceRebal,
                1e15,
                "scenarioB: alice rebalance fxSAVE == 166666.67"
            );
            assertApproxEqAbs(
                postRebal[2].levToken_levSP - preRebal[2].levToken_levSP,
                62.5 ether,
                1e15,
                "scenarioB: charlie rebalance lev tokens == 62.5"
            );
        }

        // Step 3: Re-deposits + new entrants
        uint256 bobPegged = IERC20(pegged).balanceOf(bob);
        _deposit(stabilityPoolCollateral, bob, bobPegged);

        uint256 davePegged = IERC20(pegged).balanceOf(dave);
        _deposit(stabilityPoolLeveraged, dave, davePegged);

        _deposit(stabilityPoolCollateral, fred, each);
        _deposit(stabilityPoolLeveraged, george, each);

        _logState("AFTER RE-DEPOSITS - Scenario B");

        // ── Stage 3: after rebalance + re-deposits (CR=1.30, rate=1) ──
        _logStageTable("scenarioB Stage 3 - After rebalance + re-deposits (CR=1.30, rate=1)", preRebal, postRebal);

        // ── Asserts: pool composition after re-deposits ─────────────
        // Coll SP: Alice 62.5 + Bob 100 + Fred 100 = 262.5
        assertApproxEqAbs(
            IERC20(pegged).balanceOf(stabilityPoolCollateral),
            262.5 ether,
            1e15,
            "scenarioB: coll SP total == 262.5"
        );
        // Lev SP: Charlie 62.5 + Dave 100 + George 100 = 262.5
        assertApproxEqAbs(
            IERC20(pegged).balanceOf(stabilityPoolLeveraged),
            262.5 ether,
            1e15,
            "scenarioB: lev SP total == 262.5"
        );

        // ── Week 1 harvest (0.1% bump) ──────────────────────────────
        ClaimableSnapshot[6] memory postHarvest1;
        {
            skip(1 days);
            uint256 harvested1 = _triggerHarvest();
            console2.log("Week 1 harvested: %e", harvested1);
            skip(8 days);

            // Same Minter wstETH after rebalance as Sc A (same total liquidation), so harvest is identical
            assertApproxEqRel(harvested1, 3030 ether, 0.01 ether, "scenarioB: week 1 harvest ~= 3030");

            postHarvest1 = _snapshotAll();
            _logBreakdown("WEEK 1 HARVEST REWARDS", postRebal, postHarvest1, true);

            _assertScenarioBWeek1(postRebal, postHarvest1);

            // ── Stage 4: after week 1 harvest (rate = 1.001) ──
            _logStageTable("scenarioB Stage 4 - After week 1 harvest (CR=1.30, rate=1.001)", preRebal, postRebal);
        }

        // ── Week 2 harvest ──────────────────────────────────────────
        {
            uint256 harvested2 = _triggerHarvest();
            console2.log("Week 2 harvested: %e", harvested2);
            skip(8 days);

            assertApproxEqRel(harvested2, 3027 ether, 0.01 ether, "scenarioB: week 2 harvest ~= 3027");

            ClaimableSnapshot[6] memory postHarvest2 = _snapshotAll();
            _logBreakdown("WEEK 2 HARVEST REWARDS", postHarvest1, postHarvest2, true);
            _logBreakdown("TOTAL CLAIMABLE (rebalance + 2 weeks harvest)", preRebal, postHarvest2, false);

            _assertScenarioBTotals(postRebal, postHarvest2);

            // ── Stage 5: after week 2 harvest (rate = 1.002001) ──
            _logStageTable("scenarioB Stage 5 - After week 2 harvest (CR=1.30, rate=1.002001)", preRebal, postRebal);
        }

        _logState("AFTER 2 WEEKS HARVEST - Scenario B");
    }

    /// @dev Per-actor harvest assertions for Scenario B week 1.
    /// Each pool has 262.5 pegged after re-deposits (Alice 62.5 + Bob 100 + Fred 100; Charlie/Dave/George same).
    /// Coll SP gets 50% of 3030 = 1515 fxSAVE harvest. Alice 62.5/262.5 × 1515 ≈ 361; Bob/Fred 100/262.5 × 1515 ≈ 577.
    /// (Was 0.0903 / 0.1444 in the old 1× test → scaled by 4000.)
    function _assertScenarioBWeek1(
        ClaimableSnapshot[6] memory postRebal,
        ClaimableSnapshot[6] memory postHarvest1
    ) internal pure {
        uint256 alice_w1 = postHarvest1[0].fxSAVE_collSP - postRebal[0].fxSAVE_collSP;
        uint256 bob_w1 = postHarvest1[1].fxSAVE_collSP - postRebal[1].fxSAVE_collSP;
        uint256 fred_w1 = postHarvest1[4].fxSAVE_collSP - postRebal[4].fxSAVE_collSP;
        uint256 charlie_w1 = postHarvest1[2].fxSAVE_levSP - postRebal[2].fxSAVE_levSP;
        uint256 dave_w1 = postHarvest1[3].fxSAVE_levSP - postRebal[3].fxSAVE_levSP;
        uint256 george_w1 = postHarvest1[5].fxSAVE_levSP - postRebal[5].fxSAVE_levSP;

        assertApproxEqRel(alice_w1, 361 ether, 0.01 ether, "scenarioB: alice w1 harvest ~= 361");
        assertApproxEqRel(bob_w1, 577 ether, 0.01 ether, "scenarioB: bob w1 harvest ~= 577");
        assertApproxEqRel(fred_w1, 577 ether, 0.01 ether, "scenarioB: fred w1 harvest ~= 577");
        assertApproxEqRel(charlie_w1, 361 ether, 0.01 ether, "scenarioB: charlie w1 harvest ~= 361");
        assertApproxEqRel(dave_w1, 577 ether, 0.01 ether, "scenarioB: dave w1 harvest ~= 577");
        assertApproxEqRel(george_w1, 577 ether, 0.01 ether, "scenarioB: george w1 harvest ~= 577");

        // Bob/Fred/Dave/George should all earn the same harvest (equal balance, no boost)
        assertEq(bob_w1, fred_w1, "scenarioB: bob == fred w1 harvest");
        assertEq(dave_w1, george_w1, "scenarioB: dave == george w1 harvest");

        // Alice/Charlie earn LESS than Bob/Dave despite staying — the unfairness
        assertLt(alice_w1, bob_w1, "scenarioB: alice < bob (unfairness)");
        assertLt(charlie_w1, dave_w1, "scenarioB: charlie < dave (unfairness)");
    }

    /// @dev 2-week per-actor harvest totals for Scenario B.
    /// Was 0.181 / 0.289 in old 1× test → scaled by 4000.
    function _assertScenarioBTotals(
        ClaimableSnapshot[6] memory postRebal,
        ClaimableSnapshot[6] memory postHarvest2
    ) internal pure {
        uint256 alice_total = postHarvest2[0].fxSAVE_collSP - postRebal[0].fxSAVE_collSP;
        uint256 bob_total = postHarvest2[1].fxSAVE_collSP - postRebal[1].fxSAVE_collSP;
        uint256 charlie_total = postHarvest2[2].fxSAVE_levSP - postRebal[2].fxSAVE_levSP;
        uint256 dave_total = postHarvest2[3].fxSAVE_levSP - postRebal[3].fxSAVE_levSP;

        assertApproxEqRel(alice_total, 722 ether, 0.01 ether, "scenarioB: alice 2wk harvest ~= 722");
        assertApproxEqRel(bob_total, 1155 ether, 0.01 ether, "scenarioB: bob 2wk harvest ~= 1155");
        assertApproxEqRel(charlie_total, 722 ether, 0.01 ether, "scenarioB: charlie 2wk harvest ~= 722");
        assertApproxEqRel(dave_total, 1155 ether, 0.01 ether, "scenarioB: dave 2wk harvest ~= 1155");
    }
}
