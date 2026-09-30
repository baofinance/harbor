// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {MarketAddresses} from "@harbor-test/harness/MarketAddresses.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";

/// @notice A deploy run carries its identity — actors, salt namespace, network — from construction, so several
///         independent runs can exist at once.
/// @dev This is what a test needing two deployments composes: two instances rather than one contract asked to
///      do two things. Every address asserted here resolves before anything is deployed, which is the property
///      the whole arrangement relies on — but it still needs the BaoFactory, since predicting an address is a
///      call into it rather than local arithmetic. No fork: the factory is deployed locally.
contract HarborDeployRunTest is BaoTest, Deploy_ETH_Minter {
    address private constant RUN_OWNER = address(0x0117);
    address private constant RUN_TREASURY = address(0x7EA5);

    Config_MinterMarket private market;

    function setUp() public {
        _ensureBaoFactory();

        (, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        market = mktConfigs[0];
    }

    /// Every identity value answers from the constructor, before any deploy call has run.
    function test_identityAnswersBeforeAnythingIsDeployed() public {
        HarborDeployRun run = new HarborDeployRun(RUN_OWNER, RUN_TREASURY, "run_identity", "mainnet");

        assertEq(run.owner(), RUN_OWNER, "owner");
        assertEq(run.treasury(), RUN_TREASURY, "treasury");
        assertEq(run.saltPrefix(), "run_identity", "salt prefix");
        assertEq(run.network(), "mainnet", "network");

        assertNotEq(run.minterAddress(market), address(0), "a minter address resolves with nothing deployed");
    }

    /// The injected actors genuinely replace the production defaults rather than the base values leaking
    /// through, and they are distinct from each other — so a test can measure fees arriving at the treasury
    /// without that balance also being the owner's own holdings.
    function test_theRunsActorsReplaceTheProductionDefaults() public {
        HarborDeployRun run = new HarborDeployRun(RUN_OWNER, RUN_TREASURY, "run_actors", "mainnet");

        assertNotEq(run.owner(), owner(), "not the production multisig this test inherits");
        assertNotEq(run.owner(), run.treasury(), "owner and treasury are separately observable");
    }

    /// Two runs with different salt namespaces are independent deployments that cannot collide.
    function test_runsWithDifferentPrefixesResolveToDifferentContracts() public {
        HarborDeployRun first = new HarborDeployRun(RUN_OWNER, RUN_TREASURY, "run_first", "mainnet");
        HarborDeployRun second = new HarborDeployRun(RUN_OWNER, RUN_TREASURY, "run_second", "mainnet");

        assertNotEq(first.minterAddress(market), second.minterAddress(market), "minter");
        assertNotEq(first.peggedTokenAddress(market), second.peggedTokenAddress(market), "pegged token");
        assertNotEq(first.reservePoolAddress(market), second.reservePoolAddress(market), "reserve pool");
    }

    /// The mirror, and the one that matters for a shared peg: two runs SHARING a namespace resolve to the same
    /// contracts, so several minters can be stood up against one pegged token — each run its own instance,
    /// one peg between them.
    function test_runsSharingAPrefixResolveToTheSameContracts() public {
        HarborDeployRun first = new HarborDeployRun(RUN_OWNER, RUN_TREASURY, "run_shared", "mainnet");
        HarborDeployRun second = new HarborDeployRun(RUN_OWNER, RUN_TREASURY, "run_shared", "mainnet");

        assertEq(first.peggedTokenAddress(market), second.peggedTokenAddress(market), "one pegged token");
        assertEq(first.minterAddress(market), second.minterAddress(market), "one minter for one market");
    }
}

/// A composed run driven entirely from outside: construct it, tell it to deploy, read back what it built.
/// @dev The end-to-end composition path, and the reason `deploy` is public — an internal entry point can only
///      be reached by inheritance, which would leave a composed instance constructible but unusable. The run
///      registers ITSELF as the factory operator, so it deploys on its own account rather than the test's.
contract ComposedHarborDeployRunTest is BaoTest, Deploy_ETH_Minter {
    function test_aComposedRunDeploysOnItsOwnAccountAndHandsOver() public {
        forkMainnetWithBaoFactory();

        address runOwner = makeAddr("composedRunOwner");
        HarborDeployRun run = new HarborDeployRun(runOwner, makeAddr("composedRunTreasury"), "composed", "mainnet");

        // The run registers ITSELF rather than the test doing it for the run: `ensureFactory` is public and
        // inlines the library, so `address(this)` inside it is the run.
        run.ensureFactory();

        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        Config_MinterMarket[] memory marketsToDeploy = new Config_MinterMarket[](1);
        marketsToDeploy[0] = mktConfigs[0];

        run.deploy(peg, mktConfigs, true, marketsToDeploy);

        address minter = run.minterAddress(mktConfigs[0]);
        assertGt(minter.code.length, 0, "the composed run deployed a minter");
        assertEq(IBaoOwnable(minter).owner(), runOwner, "and handed it to ITS owner, not the test's");
        assertNotEq(runOwner, owner(), "which is not the production multisig this test inherits");
    }
}

/// What a run reports about a market it deployed - its addresses - and the mock it stands in for the one dependency
/// it does not deploy, the price oracle.
/// @dev Forked, because the run deploys through the mainnet BaoFactory, as the composed test above does.
contract HarborDeployRunReportsTest is BaoTest, Deploy_ETH_Minter {
    HarborDeployRun private deployRun;
    Config_MinterMarket private config;

    function setUp() public {
        forkMainnetWithBaoFactory();
        deployRun = new HarborDeployRun(
            makeAddr("reportsRunOwner"),
            makeAddr("reportsRunTreasury"),
            "reports",
            "mainnet"
        );
        deployRun.ensureFactory();

        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        config = mktConfigs[0];
        Config_MinterMarket[] memory marketsToDeploy = new Config_MinterMarket[](1);
        marketsToDeploy[0] = config;
        deployRun.deploy(peg, mktConfigs, true, marketsToDeploy);
    }

    /// @dev A run with the same markets in its configuration and a salt namespace of its own, which has deployed none.
    function _undeployedRun() private returns (HarborDeployRun) {
        return
            new HarborDeployRun(
                makeAddr("undeployedRunOwner"),
                makeAddr("undeployedRunTreasury"),
                "reports_undeployed",
                "mainnet"
            );
    }

    /// Each address the run reports belongs to the market it deployed, wired as the market uses it: the minter is the
    /// one deployed, the tokens and the oracle are that minter's own, each pool holds the pegged token and carries its
    /// own kind's name, and the manager serves this minter and these two pools.
    function test_marketAddresses_describesTheMarketTheRunDeployed() public {
        MarketAddresses memory addresses = deployRun.marketAddresses(config);

        assertEq(addresses.minter, deployRun.minterAddress(config), "the minter the run deployed");
        assertGt(addresses.minter.code.length, 0, "which is deployed");
        assertEq(addresses.pegged, IMinter(addresses.minter).PEGGED_TOKEN(), "the minter's pegged token");
        assertEq(addresses.leveraged, IMinter(addresses.minter).LEVERAGED_TOKEN(), "its leveraged token");
        assertEq(
            addresses.wrappedCollateral,
            IMinter(addresses.minter).WRAPPED_COLLATERAL_TOKEN(),
            "its wrapped collateral"
        );
        assertEq(addresses.oracle, IMinter(addresses.minter).priceOracle(), "the oracle it reads");

        ConfigTokenNames names = ConfigTokenNames(address(config));
        assertEq(IStabilityPool_v3(addresses.collateralPool).ASSET_TOKEN(), addresses.pegged, "a pool of pegged");
        assertEq(
            IERC20Metadata(addresses.collateralPool).name(),
            names.stabilityPoolCollateralName(),
            "named the collateral pool"
        );
        assertEq(IStabilityPool_v3(addresses.leveragedPool).ASSET_TOKEN(), addresses.pegged, "a pool of pegged");
        assertEq(
            IERC20Metadata(addresses.leveragedPool).name(),
            names.stabilityPoolLeveragedName(),
            "named the leveraged pool"
        );

        assertEq(IStabilityPoolManager_v2(addresses.manager).MINTER(), addresses.minter, "the manager of this minter");
        address[] memory pools = IStabilityPoolManager(addresses.manager).stabilityPools();
        assertEq(pools.length, 2, "and of two pools");
        assertTrue(
            (pools[0] == addresses.collateralPool && pools[1] == addresses.leveragedPool) ||
                (pools[0] == addresses.leveragedPool && pools[1] == addresses.collateralPool),
            "these two"
        );
    }

    /// Asked about a market it has not deployed, a run refuses, naming the minter it would have deployed.
    function test_marketAddresses_refusesAMarketNotYetDeployed() public {
        HarborDeployRun undeployed = _undeployedRun();
        address minter = undeployed.minterAddress(config);

        vm.expectRevert(abi.encodeWithSelector(HarborDeployRun.MinterNotDeployed.selector, minter));
        undeployed.marketAddresses(config);
    }

    /// The mock goes where the deployed minter reads its price and answers as a freshly constructed mock does - the
    /// same price and wrapped-to-underlying rate bands, and the same quote name, none of which `vm.etch` copies - and
    /// then answers what it is set to.
    function test_installMockPriceOracle_putsTheMockWhereTheMinterReads() public {
        address minter = deployRun.minterAddress(config);
        MockWrappedPriceOracle template = new MockWrappedPriceOracle();
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = template.latestAnswer();

        address oracle = deployRun.installMockPriceOracle(config);

        assertEq(oracle, IMinter(minter).priceOracle(), "where the minter reads its price");
        (uint256 minPriceNow, uint256 maxPriceNow, uint256 minRateNow, uint256 maxRateNow) = IWrappedPriceOracle(
            oracle
        ).latestAnswer();
        assertEq(minPriceNow, minPrice, "the low end of the price band a new mock answers");
        assertEq(maxPriceNow, maxPrice, "the high end");
        assertEq(minRateNow, minRate, "the low end of the wrapped-to-underlying rate band");
        assertEq(maxRateNow, maxRate, "the high end");
        assertEq(MockWrappedPriceOracle(oracle).quoteName(), template.quoteName(), "and the quote name");

        MockWrappedPriceOracle(oracle).setLatestAnswer(1 ether, 2 ether);
        (minPriceNow, , minRateNow, ) = IWrappedPriceOracle(oracle).latestAnswer();
        assertEq(minPriceNow, 1 ether, "a price it is set to");
        assertEq(minRateNow, 2 ether, "and a wrapped-to-underlying rate");
    }

    /// Before its market is deployed there is no minter reading an oracle, and a mock put there first would hide the
    /// deploy's reference to a codeless address; the run refuses, naming the minter.
    function test_installMockPriceOracle_refusesAMarketNotYetDeployed() public {
        HarborDeployRun undeployed = _undeployedRun();
        address minter = undeployed.minterAddress(config);

        vm.expectRevert(abi.encodeWithSelector(HarborDeployRun.MinterNotDeployed.selector, minter));
        undeployed.installMockPriceOracle(config);
    }

    /// A minter wired to an oracle other than the one the run predicts would read none of what the mock is set to; the
    /// run refuses, naming the minter, where it reads, and where the run predicted.
    function test_installMockPriceOracle_refusesAMinterWiredToAnotherOracle() public {
        address minter = deployRun.minterAddress(config);
        address predicted = deployRun.wrappedPriceOracleAddress(config);
        address elsewhere = makeAddr("elsewhere");
        vm.mockCall(minter, abi.encodeCall(IMinter.priceOracle, ()), abi.encode(elsewhere));

        vm.expectRevert(
            abi.encodeWithSelector(HarborDeployRun.MinterReadsAnotherOracle.selector, minter, elsewhere, predicted)
        );
        deployRun.installMockPriceOracle(config);
    }
}
