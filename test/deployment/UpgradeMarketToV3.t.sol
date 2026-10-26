// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {IBaoFixedOwnable} from "@bao/interfaces/IBaoFixedOwnable.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
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
import {MarketAddresses} from "@harbor-script/src/MarketAddresses.sol";
import {UpgradeMarketToV3} from "@harbor-script/src/UpgradeMarketToV3.sol";
import {IMinter_v3_Upgrader} from "@harbor-script/UpgradeMinter_v2_v3/IMinter_v3_Upgrader.sol";
import {Minter_v3_Upgrader} from "@harbor-script/UpgradeMinter_v2_v3/Minter_v3_Upgrader.sol";
import {FROZEN_MARKETS_CAPTURE} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";

import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {MarketUpgradeRun} from "@harbor-test/harness/MarketUpgradeRun.sol";
import {MarketVerification} from "@harbor-test/harness/MarketVerification.sol";

/// @dev The production upgrade of markets a pause has frozen, as the upgrade script runs it - read at the capture's
///      block, upgraded on the fork selected - for the markets and capture it is constructed with.
contract FrozenMarketUpgradeRun is UpgradeMarketToV3 {
    Config_MinterMarket[] private _markets;
    string private _capture;

    constructor(Config_MinterMarket[] memory markets_, string memory capture_) {
        _markets = markets_;
        _capture = capture_;
    }

    function build() internal override {
        upgradeMarketsToV3(readFrozenMarketUpgradeInputs(_markets, _capture, "mainnet"), "mainnet");
    }
}

/// @dev MCAP::fxUSD as production configures it, with a floor a wei above its live pools'.
contract ConfigMarket_MCAP_fxUSD_floorAWeiHigher is ConfigMarket_MCAP_fxUSD_mainnet {
    function aboutADollar() public pure override returns (uint256) {
        return super.aboutADollar() + 1;
    }
}

/// @dev MCAP::fxUSD as production configures it, with a withdrawal delay a second longer than its live pools'.
contract ConfigMarket_MCAP_fxUSD_delayASecondLonger is ConfigMarket_MCAP_fxUSD_mainnet {
    function stabilityPoolWithdrawalDelay() public pure override returns (uint256) {
        return super.stabilityPoolWithdrawalDelay() + 1;
    }
}

/// @notice The shared market upgrade - read each market's inputs, then `UpgradeMarketToV3.upgradeMarketsToV3` - on the
///         live MCAP::fxUSD market at the block of a committed holder capture: deployed and never used, so its pools
///         are empty and the capture lists no holders. It checks the minter's config, which the upgrade loads again
///         through Minter_v3's loader, and what the upgrade refuses: a pool implementation that would not keep the live
///         pool's floor or withdrawal window, and a capture that misses a holder.
contract UpgradeMarketToV3Test is Test {
    string internal constant CAPTURE = "test/fixtures/holders-25272609/";

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

    /// The upgrade moves the minter to a new implementation and keeps its stored config: loaded again through
    /// Minter_v3's loader, the config reads back exactly as Minter_v2 stored it.
    function test_upgradeKeepsTheStoredConfig() public {
        IMinter.Config memory stored = IMinter(minter).config();
        bytes32 implementationBefore = vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT);

        upgrade.run("harbor_v1");

        assertNotEq(vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT), implementationBefore, "the minter is upgraded");
        assertEq(keccak256(abi.encode(IMinter(minter).config())), keccak256(abi.encode(stored)), "the config is kept");
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
        uint256 newFloor = IHarborConfig(address(markets[0])).aboutADollar();
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
        FrozenMarketUpgradeRun frozenUpgrade = new FrozenMarketUpgradeRun(markets, FROZEN_MARKETS_CAPTURE);
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
    ///      backing, as read at the capture's block: what the retired-market tests check the upgrade against.
    struct RetiredBesideLive {
        Config_MinterMarket[] markets;
        address retiredMinter;
        address retiredCollateral;
        address retiredOracle;
        uint256 retiredBacking;
        bytes retiredConfig;
        address liveMinter;
        uint256 liveBacking;
    }

    /// @dev Read GOLD::fxUSD and BTC::stETH at the capture's block, then fork the block after it, where every minter is
    ///      paused and the upgrade runs; return what was read and the upgrade, built but not run.
    function _retiredBesideLive()
        private
        returns (RetiredBesideLive memory fixture, FrozenMarketUpgradeRun frozenUpgrade)
    {
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
        fixture.retiredBacking = IMinter(fixture.retiredMinter).collateralTokenBalance();
        fixture.retiredConfig = abi.encode(IMinter(fixture.retiredMinter).config());
        fixture.liveBacking = IMinter(fixture.liveMinter).collateralTokenBalance();
        assertGt(fixture.retiredBacking, 0, "precondition: the retired market records backing");
        assertEq(IERC20(fixture.retiredCollateral).balanceOf(fixture.retiredMinter), 0, "precondition: and holds none");

        vm.createSelectFork(vm.rpcUrl("mainnet"), readBlock + 1);
        frozenUpgrade = new FrozenMarketUpgradeRun(fixture.markets, FROZEN_MARKETS_CAPTURE);
        vm.makePersistent(address(frozenUpgrade));
    }

    /// A minter that records backing but holds no wrapped collateral - GOLD::fxUSD, retired, recording a wei - would be
    /// halted by Minter_v3 as impaired. Its upgrade sets the record to zero, and says so: afterwards it runs Minter_v3
    /// with the config it held, records nothing, holds nothing and reports no shortfall. A market that holds its backing
    /// - BTC::stETH, upgraded beside it - keeps its record.
    function test_theUpgradeZeroesBackingNothingHolds() public {
        (RetiredBesideLive memory fixture, FrozenMarketUpgradeRun frozenUpgrade) = _retiredBesideLive();

        vm.expectEmit(fixture.retiredMinter);
        emit IMinter_v3_Upgrader.BackingZeroed(fixture.retiredBacking);
        frozenUpgrade.run("harbor_v1");

        (uint256 recorded, uint256 held) = IMinter_v3(fixture.retiredMinter).impairment();
        assertEq(recorded, 0, "the retired market records nothing");
        assertEq(held, 0, "and holds nothing");
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
        (RetiredBesideLive memory fixture, FrozenMarketUpgradeRun frozenUpgrade) = _retiredBesideLive();

        vm.mockCallRevert(fixture.retiredOracle, bytes(""), bytes("the oracle answers nothing"));
        frozenUpgrade.run("harbor_v1");
        vm.clearMockedCalls();

        (uint256 recorded, ) = IMinter_v3(fixture.retiredMinter).impairment();
        assertEq(recorded, 0, "the retired market records nothing");
    }

    /// Only dust is set to zero: a minter that holds wrapped collateral - a wei given to GOLD::fxUSD after the capture
    /// - is refused, naming what it holds, and the whole upgrade reverts with it.
    function test_theUpgraderRefusesAMinterHoldingCollateral() public {
        (RetiredBesideLive memory fixture, FrozenMarketUpgradeRun frozenUpgrade) = _retiredBesideLive();
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
        FrozenMarketUpgradeRun refused = new FrozenMarketUpgradeRun(markets, CAPTURE);
        vm.makePersistent(address(refused));

        vm.expectRevert(bytes(refusal));
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
