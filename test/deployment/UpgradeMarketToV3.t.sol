// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {IBaoFixedOwnable} from "@bao/interfaces/IBaoFixedOwnable.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {ConfigMarket_MCAP_fxUSD_mainnet} from "@harbor-script/config/markets/ConfigMarket_MCAP_fxUSD_mainnet.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {btcMintersConfig} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {goldMintersConfig} from "@harbor-script/src/Deploy_GOLD_Minter.sol";
import {mcapMintersConfig} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {pauserNamed} from "@harbor-script/src/Pausers.sol";
import {MarketAddresses} from "@harbor-script/src/MarketAddresses.sol";
import {UpgradeMarketToV3} from "@harbor-script/src/UpgradeMarketToV3.sol";
import {IMinter_v3_Upgrader} from "@harbor-script/UpgradeMinter_v2_v3/IMinter_v3_Upgrader.sol";
import {Minter_v3_Upgrader} from "@harbor-script/UpgradeMinter_v2_v3/Minter_v3_Upgrader.sol";
import {FROZEN_MARKETS_CAPTURE} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";

import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {
    FrozenMarketUpgradeRun,
    MarketUpgradeRun,
    MarketUpgradeRunDecidingWhereToRead
} from "@harbor-test/harness/MarketUpgradeRun.sol";
import {MarketVerification} from "@harbor-test/harness/MarketVerification.sol";

/// @dev MCAP::fxUSD as production configures it, with a floor a wei above its live pools'.
contract ConfigMarket_MCAP_fxUSD_floorAWeiHigher is ConfigMarket_MCAP_fxUSD_mainnet {
    function aboutADollarInPegged() public pure override returns (uint256) {
        return super.aboutADollarInPegged() + 1;
    }
}

/// @dev MCAP::fxUSD as production configures it, with a withdrawal delay a second longer than its live pools'.
contract ConfigMarket_MCAP_fxUSD_delayASecondLonger is ConfigMarket_MCAP_fxUSD_mainnet {
    function stabilityPoolWithdrawalDelay() public pure override returns (uint256) {
        return super.stabilityPoolWithdrawalDelay() + 1;
    }
}

/// @dev MCAP::fxUSD as production configures it, with harvest and rebalance terms unlike any its live manager holds.
contract ConfigMarket_MCAP_fxUSD_otherManagerTerms is ConfigMarket_MCAP_fxUSD_mainnet {
    function rebalanceBountyRatio() public pure override returns (uint256) {
        return 0.02 ether;
    }

    function rebalanceBountyCeiling() public pure override returns (uint256) {
        return 7 ether;
    }

    function rebalanceCutRatio() public pure override returns (uint256) {
        return 0.03 ether;
    }

    function harvestBountyRatio() public pure override returns (uint256) {
        return 0.04 ether;
    }

    function harvestBountyCeiling() public pure override returns (uint256) {
        return 5 ether;
    }

    function harvestCutRatio() public pure override returns (uint256) {
        return 0.05 ether;
    }
}

/// @dev MCAP::fxUSD as production configures it, with the early-withdrawal fee its live pools hold.
contract ConfigMarket_MCAP_fxUSD_feeItsPoolsHold is ConfigMarket_MCAP_fxUSD_mainnet {
    function stabilityPoolEarlyWithdrawalFeeRatio() public pure override returns (uint256) {
        return 1e16;
    }
}

/// @dev The market upgrade, whose deployment state starts from a file, as a script's does. It reads the file and saves
///      nothing.
contract MarketUpgradeRunFromAStateFile is MarketUpgradeRun {
    string private _stateFile;

    constructor(
        Config_MinterMarket[] memory markets_,
        string memory capture_,
        string memory stateFile_
    ) MarketUpgradeRun(markets_, capture_) {
        _stateFile = stateFile_;
    }

    function _shouldPersistState() internal pure override returns (bool) {
        return true;
    }

    function _stateFileRead() internal view override returns (string memory) {
        return _stateFile;
    }

    function _saveState(DeploymentTypes.State memory) internal override {}
}

/// @notice The shared market upgrade - read each market's inputs, then `UpgradeMarketToV3.upgradeMarketsToV3` - on the
///         live MCAP::fxUSD market at the block of a committed holder capture: deployed and never used, so its pools
///         are empty and the capture lists no holders. It checks the minter's config, which the upgrade loads again
///         through Minter_v3's loader, the manager's terms, which it sets to the market config's, and what the upgrade
///         refuses: a pool implementation that would not keep the live
///         pool's floor or withdrawal window, and a capture that misses a holder.
contract UpgradeMarketToV3Test is Test {
    string internal constant CAPTURE = "test/fixtures/holders-25272609/";

    /// @dev A state recording, as a run that built them would: Minter_v3 for MCAP::fxUSD's minter, StabilityPool_v3 for
    ///      BTC::stETH's collateral pool and StabilityPoolManager_v2 for BTC::fxUSD's manager; and for MCAP::stETH only
    ///      what it runs today.
    string internal constant STATE_RECORDING_NEW_IMPLEMENTATIONS =
        "test/fixtures/deployment/harbor_v1-new-implementations.state.json";

    /// @dev A later block, at which BTC::stETH's collateral pool holds a depositor who joined after `CAPTURE`.
    uint256 internal constant AFTER_A_DEPOSITOR_JOINED = 25691117;

    HarborDeployRun internal deployRun;
    MarketUpgradeRun internal upgrade;
    address internal minter;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), HolderCaptureLib.captureBlock(CAPTURE));
        (, Config_MinterMarket[] memory markets) = mcapMintersConfig();
        Config_MinterMarket[] memory upgraded = new Config_MinterMarket[](1);
        upgraded[0] = markets[0]; // MCAP::fxUSD
        upgrade = new MarketUpgradeRun(upgraded, CAPTURE);
        deployRun = new HarborDeployRun(address(0), address(0), "harbor_v1", "mainnet", HarborDeployRun.Cut.Whole);
        minter = deployRun.minterAddress(markets[0]);
    }

    /// A run's markets are all frozen or none. One whose minter runs a pauser beside one whose minter does not is
    /// refused, naming each: here MCAP::stETH's minter is put on BaoPauser_v1 beside MCAP::fxUSD's, which runs as live.
    function test_aRunMixingFrozenAndUnfrozenMarketsIsRefused() public {
        (, Config_MinterMarket[] memory markets) = mcapMintersConfig();
        address pauser = pauserNamed("mainnet", "BaoPauser_v1");
        vm.store(
            deployRun.minterAddress(markets[1]),
            ERC1967Utils.IMPLEMENTATION_SLOT,
            bytes32(uint256(uint160(pauser)))
        );
        MarketUpgradeRunDecidingWhereToRead mixed = new MarketUpgradeRunDecidingWhereToRead(markets, CAPTURE);

        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeMarketToV3.MixedFrozenAndUnfrozenMarkets.selector,
                "MCAP::stETH",
                "MCAP::fxUSD"
            )
        );
        mixed.run("harbor_v1");
    }

    /// The upgrade moves the minter to a new implementation and keeps its stored config: loaded again through
    /// Minter_v3's loader, the config reads back exactly as Minter_v2 stored it.
    function test_upgradeKeepsTheStoredConfig() public {
        IMinter.Config memory stored = IMinter(minter).config();
        bytes32 implementationBefore = vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT);

        upgrade.run("harbor_v1");

        assertNotEq(vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT), implementationBefore, "the minter is upgraded");
        assertEq(keccak256(abi.encode(IMinter(minter).config())), keccak256(abi.encode(stored)), "the config is kept");
    }

    /// The upgrade sets the manager's harvest and rebalance terms to what the market config gives - each action's
    /// bounty ratio, bounty ceiling and cut ratio, none of which the live manager holds - and keeps its rebalance
    /// threshold and fee receiver.
    function test_upgradeSetsTheManagersTermsToTheMarketConfigs() public {
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_MCAP_fxUSD_otherManagerTerms();
        IHarborConfig config = IHarborConfig(address(markets[0]));
        address manager = deployRun.stabilityPoolManagerAddress(markets[0]);
        assertNotEq(
            IStabilityPoolManager(manager).rebalanceBountyRatio(),
            config.rebalanceBountyRatio(),
            "precondition: the manager holds another rebalance bounty ratio"
        );
        assertNotEq(
            IStabilityPoolManager(manager).harvestBountyRatio(),
            config.harvestBountyRatio(),
            "precondition: and another harvest bounty ratio"
        );
        assertNotEq(
            IStabilityPoolManager(manager).harvestCutRatio(),
            config.harvestCutRatio(),
            "precondition: and another harvest cut ratio"
        );
        uint256 threshold = IStabilityPoolManager(manager).rebalanceThreshold();
        address feeReceiver = IStabilityPoolManager(manager).feeReceiver();

        new MarketUpgradeRun(markets, CAPTURE).run("harbor_v1");

        IStabilityPoolManager_v2 upgraded = IStabilityPoolManager_v2(manager);
        assertEq(upgraded.rebalanceBountyRatio(), config.rebalanceBountyRatio(), "the rebalance bounty ratio");
        assertEq(upgraded.rebalanceBountyCeiling(), config.rebalanceBountyCeiling(), "the rebalance bounty ceiling");
        assertEq(upgraded.rebalanceCutRatio(), config.rebalanceCutRatio(), "the rebalance cut ratio");
        assertEq(upgraded.harvestBountyRatio(), config.harvestBountyRatio(), "the harvest bounty ratio");
        assertEq(upgraded.harvestBountyCeiling(), config.harvestBountyCeiling(), "the harvest bounty ceiling");
        assertEq(upgraded.harvestCutRatio(), config.harvestCutRatio(), "the harvest cut ratio");
        assertEq(upgraded.rebalanceThreshold(), threshold, "the rebalance threshold is kept");
        assertEq(upgraded.feeReceiver(), feeReceiver, "the fee receiver is kept");
    }

    /// A config Minter_v3's loader refuses - a subsidy in redeem pegged's highest band, which Minter_v2 accepts - reverts
    /// the market's whole upgrade with the loader's own error, and the minter stays on Minter_v2.
    function test_upgradeRefusesAConfigMinterV3Rejects() public {
        IMinter.Config memory config = IMinter(minter).config();
        uint256 highest = config.redeemPeggedIncentiveConfig.incentiveRatios.length - 1;
        config.redeemPeggedIncentiveConfig.incentiveRatios[highest] = -0.01 ether;
        vm.startPrank(IBaoOwnable(minter).owner());
        IMinter(minter).updateConfig(config);
        vm.stopPrank();
        bytes32 implementationBefore = vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter_v3.InvalidIncentiveRatioValue.selector,
                "redeem pegged",
                highest,
                int256(-0.01 ether),
                "highest band must be >= 0"
            )
        );
        upgrade.run("harbor_v1");

        assertEq(vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT), implementationBefore, "the minter stays on v2");
    }

    /// A new pool implementation that would not keep the live pool's floor is refused when the upgrade is built,
    /// naming the pool and both floors: nothing is saved for the multisig, and the minter stays on Minter_v2.
    function test_upgradeRefusesAPoolWhoseFloorDiffersFromItsNewImplementation() public {
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_MCAP_fxUSD_floorAWeiHigher();
        string memory key = deployRun.stabilityPoolKey(markets[0], HarborDeployer.StabilityPoolType.Collateral);
        address pool = deployRun.stabilityPoolAddress(markets[0], HarborDeployer.StabilityPoolType.Collateral);
        uint256 liveFloor = IStabilityPool(pool).MIN_TOTAL_ASSET_SUPPLY();
        uint256 newFloor = IHarborConfig(address(markets[0])).aboutADollarInPegged();
        assertEq(newFloor, liveFloor + 1, "precondition: the live floor is the production config's");
        MarketUpgradeRun refused = new MarketUpgradeRun(markets, CAPTURE);
        bytes32 implementationBefore = vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT);

        vm.expectRevert(
            bytes(
                string.concat(
                    key,
                    ": the pool's floor is ",
                    LibString.toString(liveFloor),
                    ", its new implementation's ",
                    LibString.toString(newFloor)
                )
            )
        );
        refused.run("harbor_v1");

        assertEq(vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT), implementationBefore, "the minter stays on v2");
    }

    /// A new pool implementation that would not keep the live pool's withdrawal window is refused when the upgrade is
    /// built, naming the pool and both windows: nothing is saved for the multisig, and the minter stays on Minter_v2.
    function test_upgradeRefusesAPoolWhoseWindowDiffersFromItsNewImplementation() public {
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_MCAP_fxUSD_delayASecondLonger();
        string memory key = deployRun.stabilityPoolKey(markets[0], HarborDeployer.StabilityPoolType.Collateral);
        address pool = deployRun.stabilityPoolAddress(markets[0], HarborDeployer.StabilityPoolType.Collateral);
        (uint64 liveDelay, uint64 liveWindow) = IStabilityPool(pool).getWithdrawalWindow();
        uint256 newDelay = IHarborConfig(address(markets[0])).stabilityPoolWithdrawalDelay();
        uint256 newWindow = IHarborConfig(address(markets[0])).stabilityPoolWithdrawalPeriod();
        assertEq(newDelay, liveDelay + 1, "precondition: the live delay is the production config's");
        assertEq(newWindow, liveWindow, "precondition: the live window is the production config's");
        MarketUpgradeRun refused = new MarketUpgradeRun(markets, CAPTURE);
        bytes32 implementationBefore = vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT);

        vm.expectRevert(
            bytes(
                string.concat(
                    key,
                    ": the pool's withdrawal window is ",
                    LibString.toString(liveDelay),
                    " s then ",
                    LibString.toString(liveWindow),
                    " s, its new implementation's ",
                    LibString.toString(newDelay),
                    " s then ",
                    LibString.toString(newWindow),
                    " s"
                )
            )
        );
        refused.run("harbor_v1");

        assertEq(vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT), implementationBefore, "the minter stays on v2");
    }

    /// With every minter and pool paused, a live market's upgrade as the upgrade script runs it - read at the capture's
    /// block, the last before the pause - builds and executes as the multisig: afterwards the minter answers with the
    /// config read before the pause, each pool with the supply read, the manager reports StabilityPoolManager_v2, and
    /// the market's contracts name its tokens and each other.
    function test_theFrozenUpgradeBuildsAtThePauseBlock() public {
        uint256 readBlock = HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE);
        vm.createSelectFork(vm.rpcUrl("mainnet"), readBlock);
        (, Config_MinterMarket[] memory btcMarkets) = btcMintersConfig();
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = btcMarkets[1]; // BTC::stETH
        vm.makePersistent(address(markets[0]));
        HarborDeployRun addresses = new HarborDeployRun(
            address(0),
            address(0),
            "harbor_v1",
            "mainnet",
            HarborDeployRun.Cut.Whole
        );
        vm.makePersistent(address(addresses));
        address frozenMinter = addresses.minterAddress(markets[0]);
        address collateralPool = addresses.stabilityPoolAddress(
            markets[0],
            HarborDeployer.StabilityPoolType.Collateral
        );
        address leveragedPool = addresses.stabilityPoolAddress(markets[0], HarborDeployer.StabilityPoolType.Leveraged);
        IMinter.Config memory config = IMinter(frozenMinter).config();
        uint256 collateralSupply = IStabilityPool(collateralPool).totalAssetSupply();
        uint256 leveragedSupply = IStabilityPool(leveragedPool).totalAssetSupply();

        vm.createSelectFork(vm.rpcUrl("mainnet"), readBlock + 1);
        FrozenMarketUpgradeRun frozenUpgrade = new FrozenMarketUpgradeRun(
            markets,
            FROZEN_MARKETS_CAPTURE,
            _noOperations()
        );
        vm.makePersistent(address(frozenUpgrade));
        frozenUpgrade.run("harbor_v1");

        assertEq(
            keccak256(abi.encode(IMinter(frozenMinter).config())),
            keccak256(abi.encode(config)),
            "the minter answers with the config read"
        );
        assertEq(IStabilityPool_v3(collateralPool).totalAssetSupply(), collateralSupply, "the collateral pool answers");
        assertEq(IStabilityPool_v3(leveragedPool).totalAssetSupply(), leveragedSupply, "the leveraged pool answers");
        assertTrue(
            IERC165(addresses.stabilityPoolManagerAddress(markets[0])).supportsInterface(
                type(IStabilityPoolManager_v2).interfaceId
            ),
            "the manager reports StabilityPoolManager_v2"
        );
        MarketAddresses memory upgraded = addresses.deployedMarketAddresses(markets[0]);
        new MarketVerification().verifyMarket(
            markets[0],
            upgraded,
            upgraded.minter,
            upgraded.collateralPool,
            upgraded.leveragedPool,
            upgraded.manager
        );
    }

    /// @dev GOLD::fxUSD - retired, recording backing and holding no wrapped collateral - and BTC::stETH, which holds its
    ///      backing, as read at the capture's block: what the retired-market tests check the upgrade against. With each,
    ///      the oracle its minter reads and the oracle proxy the deploy predicts for it; for BTC::stETH, what its
    ///      oracle answered at the capture's block and its leveraged token.
    struct RetiredBesideLive {
        Config_MinterMarket[] markets;
        address retiredMinter;
        address retiredCollateral;
        address retiredOracle;
        address retiredPredictedOracle;
        uint256 retiredBacking;
        bytes retiredConfig;
        address liveMinter;
        address liveOracle;
        address livePredictedOracle;
        uint256 liveBacking;
        UpgradeMarketToV3.OracleAnswer liveAnswer;
        address liveLeveraged;
    }

    /// @dev Read GOLD::fxUSD and BTC::stETH at the capture's block, then fork the block after it, where every minter is
    ///      paused and the upgrade runs; return what was read.
    function _retiredBesideLive() private returns (RetiredBesideLive memory fixture) {
        uint256 readBlock = HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE);
        vm.createSelectFork(vm.rpcUrl("mainnet"), readBlock);
        (, Config_MinterMarket[] memory goldMarkets) = goldMintersConfig();
        (, Config_MinterMarket[] memory btcMarkets) = btcMintersConfig();
        fixture.markets = new Config_MinterMarket[](2);
        fixture.markets[0] = goldMarkets[0]; // GOLD::fxUSD
        fixture.markets[1] = btcMarkets[1]; // BTC::stETH
        vm.makePersistent(address(fixture.markets[0]));
        vm.makePersistent(address(fixture.markets[1]));
        HarborDeployRun addresses = new HarborDeployRun(
            address(0),
            address(0),
            "harbor_v1",
            "mainnet",
            HarborDeployRun.Cut.Whole
        );
        fixture.retiredMinter = addresses.minterAddress(fixture.markets[0]);
        fixture.liveMinter = addresses.minterAddress(fixture.markets[1]);
        fixture.retiredCollateral = IMinter(fixture.retiredMinter).WRAPPED_COLLATERAL_TOKEN();
        fixture.retiredOracle = IMinter(fixture.retiredMinter).priceOracle();
        fixture.retiredPredictedOracle = addresses.wrappedPriceOracleAddress(fixture.markets[0]);
        fixture.retiredBacking = IMinter(fixture.retiredMinter).collateralTokenBalance();
        fixture.retiredConfig = abi.encode(IMinter(fixture.retiredMinter).config());
        fixture.liveOracle = IMinter(fixture.liveMinter).priceOracle();
        fixture.livePredictedOracle = addresses.wrappedPriceOracleAddress(fixture.markets[1]);
        fixture.liveBacking = IMinter(fixture.liveMinter).collateralTokenBalance();
        (
            fixture.liveAnswer.minPrice,
            fixture.liveAnswer.maxPrice,
            fixture.liveAnswer.minRate,
            fixture.liveAnswer.maxRate
        ) = IWrappedPriceOracle(fixture.liveOracle).latestAnswer();
        fixture.liveLeveraged = addresses.leveragedTokenAddress(fixture.markets[1]);
        assertGt(fixture.retiredBacking, 0, "precondition: the retired market records backing");
        assertEq(IERC20(fixture.retiredCollateral).balanceOf(fixture.retiredMinter), 0, "precondition: and holds none");

        vm.createSelectFork(vm.rpcUrl("mainnet"), readBlock + 1);
    }

    /// @dev The frozen upgrade of `markets`, built but not run, on the fork selected, each market's batch carrying
    ///      `operations` - one per market, or none at all.
    function _frozenUpgrade(
        Config_MinterMarket[] memory markets,
        UpgradeMarketToV3.OwnerOperations[] memory operations
    ) private returns (FrozenMarketUpgradeRun frozenUpgrade) {
        frozenUpgrade = new FrozenMarketUpgradeRun(markets, FROZEN_MARKETS_CAPTURE, operations);
        vm.makePersistent(address(frozenUpgrade));
    }

    /// @dev No owner operations in any market's batch.
    function _noOperations() private pure returns (UpgradeMarketToV3.OwnerOperations[] memory) {
        return new UpgradeMarketToV3.OwnerOperations[](0);
    }

    /// A minter that holds no wrapped collateral must record no backing. GOLD::fxUSD, retired, holds none and records a
    /// wei: its upgrade sets the record to zero, and says so. Afterwards it runs Minter_v3 with the config it held,
    /// holds nothing and records nothing. A market that holds its backing - BTC::stETH, upgraded beside it - keeps its
    /// record.
    function test_theUpgradeZeroesBackingNothingHolds() public {
        RetiredBesideLive memory fixture = _retiredBesideLive();
        FrozenMarketUpgradeRun frozenUpgrade = _frozenUpgrade(fixture.markets, _noOperations());

        vm.expectEmit(fixture.retiredMinter);
        emit IMinter_v3_Upgrader.BackingZeroed(fixture.retiredBacking);
        frozenUpgrade.run("harbor_v1");

        assertEq(
            IERC20(fixture.retiredCollateral).balanceOf(fixture.retiredMinter),
            0,
            "the retired market holds nothing"
        );
        assertEq(IMinter(fixture.retiredMinter).collateralTokenBalance(), 0, "and records nothing");
        assertEq(
            abi.encode(IMinter(fixture.retiredMinter).config()),
            fixture.retiredConfig,
            "it runs with the config it held"
        );
        assertEq(
            IMinter(fixture.liveMinter).collateralTokenBalance(),
            fixture.liveBacking,
            "the live market keeps its record"
        );
    }

    /// Setting the record to zero reads no price: with GOLD::fxUSD's oracle reverting every call, its upgrade still
    /// sets it.
    function test_theZeroingReadsNoPrice() public {
        RetiredBesideLive memory fixture = _retiredBesideLive();
        FrozenMarketUpgradeRun frozenUpgrade = _frozenUpgrade(fixture.markets, _noOperations());

        vm.mockCallRevert(fixture.retiredOracle, bytes(""), bytes("the oracle answers nothing"));
        frozenUpgrade.run("harbor_v1");

        assertEq(IMinter(fixture.retiredMinter).collateralTokenBalance(), 0, "the retired market records nothing");
    }

    /// Only dust is set to zero: a minter that holds wrapped collateral - a wei given to GOLD::fxUSD after the capture
    /// - is refused, naming what it holds, and the whole upgrade reverts with it.
    function test_theUpgraderRefusesAMinterHoldingCollateral() public {
        RetiredBesideLive memory fixture = _retiredBesideLive();
        FrozenMarketUpgradeRun frozenUpgrade = _frozenUpgrade(fixture.markets, _noOperations());
        deal(fixture.retiredCollateral, fixture.retiredMinter, 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter_v3_Upgrader.MinterHoldsWrappedCollateral.selector,
                fixture.retiredCollateral,
                1
            )
        );
        frozenUpgrade.run("harbor_v1");
    }

    /// A minter reads its price from the oracle proxy the deploy predicts for it, and the upgrade points a minter that
    /// reads another oracle at that proxy: BTC::stETH, reading the very implementation its proxy runs, and GOLD::fxUSD,
    /// reading the XAU oracle's implementation where its config names the GOLD oracle, whose proxy runs other code that
    /// answers alike.
    function test_theUpgradePointsEveryMinterAtItsPredictedOracle() public {
        RetiredBesideLive memory fixture = _retiredBesideLive();
        FrozenMarketUpgradeRun frozenUpgrade = _frozenUpgrade(fixture.markets, _noOperations());
        assertNotEq(fixture.liveOracle, fixture.livePredictedOracle, "precondition: BTC::stETH reads another oracle");
        assertEq(
            _implementation(fixture.livePredictedOracle),
            fixture.liveOracle,
            "precondition: its predicted proxy runs the oracle it reads"
        );
        assertNotEq(
            _implementation(fixture.retiredPredictedOracle),
            fixture.retiredOracle,
            "precondition: GOLD::fxUSD's predicted proxy runs other code"
        );
        assertEq(
            _answer(fixture.retiredPredictedOracle),
            _answer(fixture.retiredOracle),
            "precondition: which answers as the oracle it reads"
        );

        frozenUpgrade.run("harbor_v1");

        assertEq(
            IMinter(fixture.liveMinter).priceOracle(),
            fixture.livePredictedOracle,
            "BTC::stETH reads its predicted oracle"
        );
        assertEq(
            IMinter(fixture.retiredMinter).priceOracle(),
            fixture.retiredPredictedOracle,
            "GOLD::fxUSD reads its predicted oracle"
        );
    }

    /// The owner's operations in a market's batch are priced at the oracle reading of the capture's block - the last
    /// before the pause, where the batch's every other input was read: the batch points the minter at an oracle of its
    /// own answering that reading before them, and at the oracle proxy the deploy predicts after, so the minter never
    /// runs on the frozen answer. A fee-free mint for a named account then reaches it at that price. GOLD::fxUSD
    /// beside it, with no operations, is moved once.
    function test_theOwnerOperatesAtTheCaptureBlocksReading() public {
        RetiredBesideLive memory fixture = _retiredBesideLive();
        address paid = makeAddr("paid");
        FrozenMarketUpgradeRun frozenUpgrade = _frozenUpgrade(fixture.markets, _aMintFor(paid, fixture));

        vm.recordLogs();
        frozenUpgrade.run("harbor_v1");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address[] memory moves = _oracleMoves(logs, fixture.liveMinter);

        assertEq(moves.length, 2, "BTC::stETH's minter is moved twice");
        assertNotEq(moves[0], fixture.livePredictedOracle, "first to an oracle of the batch's own");
        assertEq(
            _answer(moves[0]),
            abi.encode(fixture.liveAnswer),
            "which answers as its oracle did at the capture's block"
        );
        assertEq(moves[1], fixture.livePredictedOracle, "then to the oracle proxy the deploy predicts");
        assertEq(IMinter(fixture.liveMinter).priceOracle(), fixture.livePredictedOracle, "which it reads after");
        assertGt(IERC20(fixture.liveLeveraged).balanceOf(paid), 0, "the account named was minted for");
        assertEq(_oracleMoves(logs, fixture.retiredMinter).length, 1, "GOLD::fxUSD, with no operations, is moved once");
    }

    /// The upgrade records every contract it deploys in the deployment state it saves, the one-shot ones under `*`:
    /// the pool upgrader, the minter upgrader GOLD::fxUSD needs, and the frozen oracle BTC::stETH's operations read,
    /// the very one its batch points the minter at - each with its contract, source and the run's time, so every
    /// address a batch names can be named from the state.
    function test_theUpgradeRecordsItsOneShotContracts() public {
        RetiredBesideLive memory fixture = _retiredBesideLive();
        FrozenMarketUpgradeRun frozenUpgrade = _frozenUpgrade(fixture.markets, _aMintFor(makeAddr("paid"), fixture));

        vm.recordLogs();
        frozenUpgrade.run("harbor_v1");
        address[] memory moves = _oracleMoves(vm.getRecordedLogs(), fixture.liveMinter);
        DeploymentTypes.ImplementationRecord[] memory recorded = frozenUpgrade.recorded();

        DeploymentTypes.ImplementationRecord memory oracle = _recordedAs(recorded, "FrozenPriceOracle");
        assertEq(
            oracle.implementation,
            moves[0],
            "the frozen oracle recorded is the one the batch points the minter at"
        );
        assertEq(oracle.proxy, "*", "recorded as a one-shot");
        assertEq(oracle.contractSource, "@harbor-script/UpgradeMinter_v2_v3/FrozenPriceOracle.sol", "with its source");
        assertEq(oracle.deploymentTime, uint64(block.timestamp), "at the run's time");
        assertEq(_recordedAs(recorded, "StabilityPool_v3_Upgrader").proxy, "*", "the pool upgrader, a one-shot");
        assertEq(_recordedAs(recorded, "Minter_v3_Upgrader").proxy, "*", "the minter upgrader, a one-shot");
    }

    /// @dev The owner's operations with one fee-free mint of 0.001 wstETH for `account` in BTC::stETH's batch, priced
    ///      at the reading its oracle gave at the capture's block, and none in GOLD::fxUSD's.
    function _aMintFor(
        address account,
        RetiredBesideLive memory fixture
    ) private pure returns (UpgradeMarketToV3.OwnerOperations[] memory operations) {
        operations = new UpgradeMarketToV3.OwnerOperations[](2);
        operations[1].answer = fixture.liveAnswer;
        operations[1].accounts = new address[](1);
        operations[1].accounts[0] = account;
        operations[1].mints = new uint256[](1);
        operations[1].mints[0] = 0.001 ether;
    }

    /// @dev The record of the one contract of type `contractType` among `recorded`.
    function _recordedAs(
        DeploymentTypes.ImplementationRecord[] memory recorded,
        string memory contractType
    ) private pure returns (DeploymentTypes.ImplementationRecord memory) {
        for (uint256 i = 0; i < recorded.length; ++i) {
            if (keccak256(bytes(recorded[i].contractType)) == keccak256(bytes(contractType))) {
                return recorded[i];
            }
        }
        revert(string.concat(contractType, " is not recorded"));
    }

    /// @dev Where `minter`'s `UpdatePriceOracle` events in `logs` pointed it, in order.
    function _oracleMoves(Vm.Log[] memory logs, address minter) private pure returns (address[] memory moves) {
        uint256 count;
        for (uint256 l = 0; l < logs.length; ++l) {
            if (logs[l].emitter == minter && logs[l].topics[0] == IMinter.UpdatePriceOracle.selector) {
                ++count;
            }
        }
        moves = new address[](count);
        count = 0;
        for (uint256 l = 0; l < logs.length; ++l) {
            if (logs[l].emitter == minter && logs[l].topics[0] == IMinter.UpdatePriceOracle.selector) {
                moves[count++] = address(uint160(uint256(logs[l].topics[2])));
            }
        }
    }

    /// @dev The oracle at `oracle`'s answer - its price and rate bands - encoded for comparison.
    function _answer(address oracle) private view returns (bytes memory) {
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(oracle)
            .latestAnswer();
        return abi.encode(minPrice, maxPrice, minRate, maxRate);
    }

    /// @dev The implementation the ERC-1967 proxy at `proxy` runs.
    function _implementation(address proxy) private view returns (address) {
        return address(uint160(uint256(vm.load(proxy, ERC1967Utils.IMPLEMENTATION_SLOT))));
    }

    /// Only the owner runs the minter upgrader: any other caller is refused before it reads or writes anything.
    function test_onlyTheOwnerRunsTheUpgrader() public {
        address upgrader = address(new Minter_v3_Upgrader(makeAddr("owner")));

        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert(IBaoFixedOwnable.Unauthorized.selector);
        IMinter_v3_Upgrader(upgrader).zeroBackingAndUpgrade(address(0), "");
        vm.stopPrank();
    }

    /// A capture not taken at the last block before the pause is refused: at the block after an earlier capture's, the
    /// market's minter still answers, and the read names it and that block - before any upgrade is built.
    function test_theFrozenReadRefusesACaptureBeforeTheLastBlock() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE) + 1);
        (, Config_MinterMarket[] memory btcMarkets) = btcMintersConfig();
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = btcMarkets[1]; // BTC::stETH
        vm.makePersistent(address(markets[0]));
        HarborDeployRun addresses = new HarborDeployRun(
            address(0),
            address(0),
            "harbor_v1",
            "mainnet",
            HarborDeployRun.Cut.Whole
        );
        string memory refusal = string.concat(
            addresses.minterKey(markets[0]),
            " answers at block ",
            vm.toString(HolderCaptureLib.captureBlock(CAPTURE) + 1),
            ", the block after the capture's: the capture must end at the last block before the pause"
        );
        FrozenMarketUpgradeRun refused = new FrozenMarketUpgradeRun(markets, CAPTURE, _noOperations());
        vm.makePersistent(address(refused));

        vm.expectRevert(bytes(refusal));
        refused.run("harbor_v1");
    }

    /// A pool whose fee differs from its config's is moved to it by its market's batch, straight after the pool's own
    /// upgrade and before the next pool's. MCAP::fxUSD's pools hold 1% and its config states 5%.
    function test_aPoolWhoseFeeDiffersFromItsConfig_getsTheSetterInItsBatch() public {
        (, Config_MinterMarket[] memory markets) = mcapMintersConfig();
        address collateralPool = deployRun.stabilityPoolAddress(
            markets[0],
            HarborDeployer.StabilityPoolType.Collateral
        );
        address leveragedPool = deployRun.stabilityPoolAddress(markets[0], HarborDeployer.StabilityPoolType.Leveraged);
        assertEq(
            IStabilityPool(collateralPool).getEarlyWithdrawalFee(),
            1e16,
            "precondition: the collateral pool holds 1%"
        );
        assertEq(
            IStabilityPool(leveragedPool).getEarlyWithdrawalFee(),
            1e16,
            "precondition: the leveraged pool holds 1%"
        );
        uint256 configured = IHarborConfig(address(markets[0])).stabilityPoolEarlyWithdrawalFeeRatio();
        assertEq(configured, 5e16, "precondition: the config states 5%");

        vm.recordLogs();
        upgrade.run("harbor_v1");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(
            IStabilityPool_v3(collateralPool).earlyWithdrawalFeeRatio(),
            configured,
            "the collateral pool's new fee"
        );
        assertEq(
            IStabilityPool_v3(leveragedPool).earlyWithdrawalFeeRatio(),
            configured,
            "the leveraged pool's new fee"
        );

        bytes32 upgraded = IERC1967.Upgraded.selector;
        bytes32 feeUpdated = IStabilityPool_v3.EarlyWithdrawalFeeUpdated.selector;
        uint256 collateralFee = _lastLog(logs, collateralPool, feeUpdated);
        assertGt(collateralFee, _lastLog(logs, collateralPool, upgraded), "the setter follows the pool's upgrade");
        assertLt(collateralFee, _firstLog(logs, leveragedPool, upgraded), "and comes before the next pool's");
        assertGt(
            _lastLog(logs, leveragedPool, feeUpdated),
            _lastLog(logs, leveragedPool, upgraded),
            "so does the other's"
        );
    }

    /// A pool already holding its config's fee gets no call to the setter, and its fee stays.
    function test_aPoolHoldingItsConfigsFee_getsNoSetter() public {
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_MCAP_fxUSD_feeItsPoolsHold();
        address collateralPool = deployRun.stabilityPoolAddress(
            markets[0],
            HarborDeployer.StabilityPoolType.Collateral
        );
        address leveragedPool = deployRun.stabilityPoolAddress(markets[0], HarborDeployer.StabilityPoolType.Leveraged);

        vm.recordLogs();
        new MarketUpgradeRun(markets, CAPTURE).run("harbor_v1");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(_firstLog(logs, collateralPool, IERC1967.Upgraded.selector), 0, "precondition: the upgrade ran");
        for (uint256 i = 0; i < logs.length; ++i) {
            assertNotEq(logs[i].topics[0], IStabilityPool_v3.EarlyWithdrawalFeeUpdated.selector, "no setter is called");
        }
        assertEq(IStabilityPool_v3(collateralPool).earlyWithdrawalFeeRatio(), 1e16, "the collateral pool's fee stays");
        assertEq(IStabilityPool_v3(leveragedPool).earlyWithdrawalFeeRatio(), 1e16, "the leveraged pool's fee stays");
    }

    /// An empty pool - no supply, and every reward stream record zero - has nothing to migrate, so its batch upgrades it
    /// directly to its new implementation: one upgrade, not two. A run of only such pools deploys no upgrader. It also
    /// reads no holders: the fixture's capture would not need to list them. MCAP::fxUSD's pools are both empty, one with
    /// one reward token and one with two.
    function test_anEmptyPool_getsAPlainUpgrade() public {
        uint256 readBlock = HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE);
        vm.createSelectFork(vm.rpcUrl("mainnet"), readBlock + 1);
        (, Config_MinterMarket[] memory mcap) = mcapMintersConfig();
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = mcap[0]; // MCAP::fxUSD
        vm.makePersistent(address(markets[0]));
        HarborDeployRun addresses = new HarborDeployRun(
            address(0),
            address(0),
            "harbor_v1",
            "mainnet",
            HarborDeployRun.Cut.Whole
        );
        address[2] memory pools = [
            addresses.stabilityPoolAddress(markets[0], HarborDeployer.StabilityPoolType.Collateral),
            addresses.stabilityPoolAddress(markets[0], HarborDeployer.StabilityPoolType.Leveraged)
        ];
        FrozenMarketUpgradeRun run = new FrozenMarketUpgradeRun(markets, FROZEN_MARKETS_CAPTURE, _noOperations());
        vm.makePersistent(address(run));

        vm.recordLogs();
        run.run("harbor_v1");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 p = 0; p < pools.length; ++p) {
            uint256 upgrades;
            for (uint256 i = 0; i < logs.length; ++i) {
                if (logs[i].emitter == pools[p] && logs[i].topics[0] == IERC1967.Upgraded.selector) {
                    ++upgrades;
                }
            }
            assertEq(upgrades, 1, "upgraded once, directly");
            assertEq(IStabilityPool_v3(pools[p]).MINTER(), addresses.minterAddress(markets[0]), "to StabilityPool_v3");
        }
        DeploymentTypes.ImplementationRecord[] memory recorded = run.recorded();
        for (uint256 i = 0; i < recorded.length; ++i) {
            assertNotEq(recorded[i].contractType, "StabilityPool_v3_Upgrader", "no upgrader is deployed");
        }
    }

    /// A pool with no supply and no holders, but a reward stream record, is not empty: a direct upgrade would drop the
    /// record, so it goes through the upgrader, which keeps it. GOLD::stETH's collateral pool holds one from a stream
    /// that finished on 2026-04-09.
    function test_aPoolWithAStreamRecordAndNoHolders_goesThroughTheUpgrader() public {
        uint256 readBlock = HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE);
        vm.createSelectFork(vm.rpcUrl("mainnet"), readBlock);
        (, Config_MinterMarket[] memory gold) = goldMintersConfig();
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = gold[1]; // GOLD::stETH
        vm.makePersistent(address(markets[0]));
        HarborDeployRun addresses = new HarborDeployRun(
            address(0),
            address(0),
            "harbor_v1",
            "mainnet",
            HarborDeployRun.Cut.Whole
        );
        vm.makePersistent(address(addresses));
        address pool = addresses.stabilityPoolAddress(markets[0], HarborDeployer.StabilityPoolType.Collateral);
        assertEq(IStabilityPool(pool).totalAssetSupply(), 0, "precondition: no supply");
        assertEq(
            HolderCaptureLib
                .holders(
                    FROZEN_MARKETS_CAPTURE,
                    addresses.stabilityPoolKey(markets[0], HarborDeployer.StabilityPoolType.Collateral)
                )
                .length,
            0,
            "precondition: no holders"
        );
        address token = IMultipleRewardDistributor(pool).activeRewardTokens()[0];
        bytes memory recordBefore = _rewardRecordOf(pool, token);
        assertNotEq(recordBefore, abi.encode(uint256(0), uint256(0), uint256(0), uint256(0)), "precondition: a record");

        vm.createSelectFork(vm.rpcUrl("mainnet"), readBlock + 1);
        FrozenMarketUpgradeRun run = new FrozenMarketUpgradeRun(markets, FROZEN_MARKETS_CAPTURE, _noOperations());
        vm.makePersistent(address(run));
        run.run("harbor_v1");

        assertEq(_rewardRecordOf(pool, token), recordBefore, "the record survives the upgrade");
        assertEq(_recordedAs(run.recorded(), "StabilityPool_v3_Upgrader").proxy, "*", "through the upgrader");
    }

    function _rewardRecordOf(address pool, address token) private view returns (bytes memory) {
        (uint256 lastUpdate, uint256 finishAt, uint256 rate, uint256 queued) = IMultipleRewardDistributor(pool)
            .rewardData(token);
        return abi.encode(lastUpdate, finishAt, rate, queued);
    }

    /// A deposit makes an empty pool non-empty, so the upgrade reads its holders, finds the capture does not list the
    /// depositor, and refuses it, naming the pool and what the holders hold, before anything is built.
    function test_aPoolWithADepositTheCaptureDoesNotList_isRefused() public {
        (, Config_MinterMarket[] memory markets) = mcapMintersConfig();
        _assertADepositIsRefused(markets[0]);
    }

    /// The supply alone makes a pool non-empty: with no active reward token, a deposit leaves no reward stream record, so
    /// nothing else shows it. A direct upgrade would lose the depositor's balance, so the upgrade reads its holders and
    /// refuses it.
    function test_aPoolWithADepositAndNoRewardToken_isRefused() public {
        (, Config_MinterMarket[] memory markets) = mcapMintersConfig();
        address pool = deployRun.stabilityPoolAddress(markets[0], HarborDeployer.StabilityPoolType.Collateral);
        address[] memory tokens = IMultipleRewardDistributor(pool).activeRewardTokens();
        assertGt(tokens.length, 0, "precondition: the pool has reward tokens to remove");
        vm.startPrank(IBaoOwnable(pool).owner());
        for (uint256 t = 0; t < tokens.length; ++t) {
            IMultipleRewardDistributor(pool).unregisterRewardToken(tokens[t]);
        }
        vm.stopPrank();
        assertEq(IMultipleRewardDistributor(pool).activeRewardTokens().length, 0, "precondition: no reward token");

        _assertADepositIsRefused(markets[0]);
    }

    /// @dev Deposits into `market`'s collateral pool as an account the capture does not list, and expects the upgrade to
    ///      refuse the pool, naming what the holders hold.
    function _assertADepositIsRefused(Config_MinterMarket market) private {
        address pool = deployRun.stabilityPoolAddress(market, HarborDeployer.StabilityPoolType.Collateral);
        address depositor = makeAddr("depositor");
        uint256 amount = 10 ether;
        address pegged = IMinter(minter).PEGGED_TOKEN();
        deal(pegged, depositor, amount);
        vm.startPrank(depositor);
        IERC20(pegged).approve(pool, amount);
        IStabilityPool(pool).deposit(amount, depositor, 0);
        vm.stopPrank();
        uint256 supply = IStabilityPool(pool).totalAssetSupply();
        assertEq(supply, amount, "precondition: the deposit is the supply");

        vm.expectRevert(
            bytes(
                string.concat(
                    deployRun.stabilityPoolKey(market, HarborDeployer.StabilityPoolType.Collateral),
                    ": the captured holders hold 0 of a supply of ",
                    LibString.toString(supply),
                    ", a gap beyond rounding"
                )
            )
        );
        upgrade.run("harbor_v1");
    }

    /// @dev The position in `logs` of the first log `emitter` emitted with `topic`, plus one, so zero is none.
    function _firstLog(Vm.Log[] memory logs, address emitter, bytes32 topic) private pure returns (uint256) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) {
                return i + 1;
            }
        }
        return 0;
    }

    /// @dev The position in `logs` of the last log `emitter` emitted with `topic`, plus one, so zero is none.
    function _lastLog(Vm.Log[] memory logs, address emitter, bytes32 topic) private pure returns (uint256 position) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) {
                position = i + 1;
            }
        }
    }

    /// A market whose new implementation the state already records is refused before anything is built, naming the
    /// record: a second batch for a market that has executed the first would copy its pools' v2 records over the v3
    /// ones. Any of its contracts' records refuses it. A market the state records only an older implementation for
    /// still builds.
    function test_aMarketTheStateRecordsAsUpgraded_isRefused() public {
        (, Config_MinterMarket[] memory mcap) = mcapMintersConfig();
        (, Config_MinterMarket[] memory btc) = btcMintersConfig();
        _assertRefused(mcap[0], "MCAP::fxUSD::minter", "Minter_v3", 0x1111111111111111111111111111111111111111);
        _assertRefused(
            btc[1],
            "BTC::stETH::stabilityPoolCollateral",
            "StabilityPool_v3",
            0x2222222222222222222222222222222222222222
        );
        _assertRefused(
            btc[0],
            "BTC::fxUSD::stabilityPoolManager",
            "StabilityPoolManager_v2",
            0x3333333333333333333333333333333333333333
        );

        Config_MinterMarket[] memory other = new Config_MinterMarket[](1);
        other[0] = mcap[1]; // MCAP::stETH
        new MarketUpgradeRunFromAStateFile(other, CAPTURE, STATE_RECORDING_NEW_IMPLEMENTATIONS).run("harbor_v1");
        assertEq(
            IStabilityPool_v3(deployRun.stabilityPoolAddress(mcap[1], HarborDeployer.StabilityPoolType.Collateral))
                .MINTER(),
            deployRun.minterAddress(mcap[1]),
            "the other market is upgraded"
        );
    }

    function _assertRefused(
        Config_MinterMarket market,
        string memory proxy,
        string memory contractType,
        address implementation
    ) private {
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = market;
        MarketUpgradeRun refused = new MarketUpgradeRunFromAStateFile(
            markets,
            CAPTURE,
            STATE_RECORDING_NEW_IMPLEMENTATIONS
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeMarketToV3.StateRecordsTheNewImplementation.selector,
                proxy,
                contractType,
                implementation
            )
        );
        refused.run("harbor_v1");
    }

    /// A capture taken before a depositor joined misses what they hold. Read where they have joined, the captured
    /// holders leave a gap far beyond rounding, and the read refuses it, naming the pool, what the captured holders hold
    /// and the supply - before any upgrade is built.
    function test_readRefusesACaptureMissingAHolder() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), AFTER_A_DEPOSITOR_JOINED);
        (, Config_MinterMarket[] memory btcMarkets) = btcMintersConfig();
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = btcMarkets[1]; // BTC::stETH
        HarborDeployRun addresses = new HarborDeployRun(
            address(0),
            address(0),
            "harbor_v1",
            "mainnet",
            HarborDeployRun.Cut.Whole
        );
        string memory key = addresses.stabilityPoolKey(markets[0], HarborDeployer.StabilityPoolType.Collateral);
        address pool = addresses.stabilityPoolAddress(markets[0], HarborDeployer.StabilityPoolType.Collateral);
        address[] memory holders = HolderCaptureLib.holders(CAPTURE, key);
        uint256 held;
        for (uint256 i = 0; i < holders.length; ++i) {
            held += IStabilityPool(pool).assetBalanceOf(holders[i]);
        }
        uint256 supply = IStabilityPool(pool).totalAssetSupply();
        MarketUpgradeRun refused = new MarketUpgradeRun(markets, CAPTURE);

        vm.expectRevert(
            bytes(
                string.concat(
                    key,
                    ": the captured holders hold ",
                    LibString.toString(held),
                    " of a supply of ",
                    LibString.toString(supply),
                    ", a gap beyond rounding"
                )
            )
        );
        refused.run("harbor_v1");
    }
}
