// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";

/// @notice A deploy run is four phases in a fixed order, and handing ownership over is the last of them.
/// @dev What the sequence guarantees is that the phases AROUND phase 2 happen whatever phase 2 chose to
///      deploy — a run cannot end with contracts still owned by the deployer, and cannot configure after it
///      has given ownership away. Each test below drives the real `deployHarborForPeg`, overriding one phase.
abstract contract DeployRunSetUp is BaoTest, Deploy_ETH_Minter {
    Config_MinterMarket internal market;

    function _run(string memory saltPrefix) internal {
        forkMainnetWithBaoFactory();

        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        market = mktConfigs[0];

        Config_MinterMarket[] memory marketsToDeploy = new Config_MinterMarket[](1);
        marketsToDeploy[0] = market;

        deployHarborForPeg(saltPrefix, peg, mktConfigs, "mainnet", true, marketsToDeploy);
    }
}

/// The full production run: every contract it deploys is handed over by the time it returns.
contract FullDeployRunTest is DeployRunSetUp {
    function setUp() public {
        _run("run_full");
    }

    /// Ownership transfer is a phase of the run, not something a caller does afterwards — so no contract is
    /// left owned by the deploy script, which is the state an interrupted run would leave behind.
    function test_everyDeployedContractEndsOwnedByTheConfiguredOwner() public {
        assertNotEq(owner(), address(this), "the deployer and the final owner are different addresses");

        assertEq(IBaoOwnable(minterAddress(market)).owner(), owner(), "minter");
        assertEq(IBaoOwnable(reservePoolAddress(market)).owner(), owner(), "reserve pool");
        assertEq(
            IBaoOwnable(stabilityPoolAddress(market, StabilityPoolType.Collateral)).owner(),
            owner(),
            "collateral stability pool"
        );
        assertEq(
            IBaoOwnable(stabilityPoolAddress(market, StabilityPoolType.Leveraged)).owner(),
            owner(),
            "leveraged stability pool"
        );
        assertEq(IBaoOwnable(stabilityPoolManagerAddress(market)).owner(), owner(), "stability pool manager");
        assertEq(IBaoOwnable(genesisAddress(market)).owner(), owner(), "genesis");
    }
}

/// A run whose phase 2 deploys less still gets the phases around it.
contract ShorterDeployRunTest is DeployRunSetUp {
    function setUp() public {
        _run("run_shorter");
    }

    /// Stops after the minter. `deployPeg` is ignored: this stack always needs the pegged token.
    function _deployAndConfigure(
        DeploymentTypes.State memory state,
        ConfigPeg peg,
        Config_MinterMarket[] memory allMarkets,
        bool,
        Config_MinterMarket[] memory marketsToDeploy
    ) internal override {
        deployPeggedTokenWithRoles(state, peg, allMarkets);

        _deployLeveragedTokenWithRoles(state, marketsToDeploy[0]);
        deployReservePool(state, marketsToDeploy[0]);
        deployMinter(state, marketsToDeploy[0]);
    }

    function test_theOverriddenPhaseIsTheOnlyThingThatChanged() public {
        assertGt(minterAddress(market).code.length, 0, "the minter this run chose to deploy");
        assertEq(
            stabilityPoolAddress(market, StabilityPoolType.Collateral).code.length,
            0,
            "and nothing the override left out"
        );
        assertEq(stabilityPoolManagerAddress(market).code.length, 0, "stability pool manager NOT deployed");
    }

    /// The phase after phase 2 runs regardless of how much phase 2 deployed — an override cannot leave the
    /// run half-finished, because it has no say in what happens around it.
    function test_whatWasDeployedIsStillHandedOver() public {
        assertEq(IBaoOwnable(minterAddress(market)).owner(), owner(), "minter");
        assertEq(IBaoOwnable(reservePoolAddress(market)).owner(), owner(), "reserve pool");
    }
}

/// The cross-dependency phase, which exists solely to run inside the ownership window.
contract CrossDependencyPhaseTest is DeployRunSetUp {
    /// Distinct from `treasury()`, which is what `deployMinter` sets during phase 2 — so observing this value
    /// afterwards proves phase 3 ran, and ran second.
    address private constant CROSS_WIRED_FEE_RECEIVER = address(0xFEE);

    function setUp() public {
        _run("run_cross");
    }

    /// An `onlyOwner` call, which succeeds only while the deployer is still the owner.
    function _configureCrossDependencies(
        DeploymentTypes.State memory,
        ConfigPeg,
        Config_MinterMarket[] memory marketsToDeploy
    ) internal override {
        IMinter(minterAddress(marketsToDeploy[0])).updateFeeReceiver(CROSS_WIRED_FEE_RECEIVER);
    }

    /// The phase runs after the contracts are configured and before ownership moves — the only window in
    /// which a contract can be told about a counterpart that did not exist when it was deployed.
    function test_theCrossDependencyPhaseRunsWhileTheDeployerStillOwns() public {
        assertEq(
            IMinter(minterAddress(market)).feeReceiver(),
            CROSS_WIRED_FEE_RECEIVER,
            "phase 3 overwrote what phase 2 set"
        );
    }

    /// The other half, and what makes the test above mean anything: the window really does close. Were the
    /// call permissionless, or ownership transferred before phase 3, the assertion above would prove nothing.
    function test_theSameCallFailsOnceTheRunHasFinished() public {
        address minter = minterAddress(market);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        IMinter(minter).updateFeeReceiver(address(0xBEEF));
    }
}
