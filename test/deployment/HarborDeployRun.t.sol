// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

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
        address factory = _ensureBaoFactory();
        vm.createSelectFork(vm.rpcUrl("mainnet"), 24699497);

        address runOwner = makeAddr("composedRunOwner");
        HarborDeployRun run = new HarborDeployRun(runOwner, makeAddr("composedRunTreasury"), "composed", "mainnet");

        vm.startPrank(IBaoFactory(factory).owner());
        IBaoFactory(factory).setOperator(address(run), 365 days);
        vm.stopPrank();

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
