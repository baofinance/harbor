// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

/// @notice Verifies that the deploy's running commentary is a script-run artefact: silent when a test is
///         merely using the deploy to arrange a fixture, and available when a test asks for it.
/// @dev Asserted on the predicate itself rather than on captured output — forge offers no way to read
///      console output back, so scraping stdout would test the harness rather than the layer.
abstract contract DeployReportingSetUp is BaoTest, Deploy_ETH_Minter {
    /// @dev The shipped predicate, reached from a test. Not a copy of it — it calls the real one.
    function shouldReport() public view returns (bool) {
        return _shouldReport();
    }

    function _deployETHfxUSD(string memory saltPrefix) internal {
        address factory = _ensureBaoFactory();
        vm.createSelectFork(vm.rpcUrl("mainnet"), 24699497);
        vm.prank(IBaoFactory(factory).owner());
        IBaoFactory(factory).setOperator(address(this), 365 days);

        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        Config_MinterMarket[] memory toDeploy = new Config_MinterMarket[](1);
        toDeploy[0] = mktConfigs[0];
        deployHarborForPeg(saltPrefix, peg, mktConfigs, "mainnet", true, toDeploy);
    }
}

/// The shipped default: a deploy used as a test fixture reports nothing.
contract DeployReportingDefaultTest is DeployReportingSetUp {
    function test_reportingIsOffByDefaultUnderTest() public view {
        assertFalse(shouldReport(), "the deploy's commentary must be silent under forge test");
    }

    /// The reporting layer's early returns skip only the printing — the deploy still does its work.
    function test_deployCompletesWithReportingOff() public {
        assertFalse(shouldReport(), "precondition: reporting off");
        _deployETHfxUSD("reporting_off");

        (, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        assertGt(minterAddress(mktConfigs[0]).code.length, 0, "minter deployed");
        assertGt(genesisAddress(mktConfigs[0]).code.length, 0, "genesis deployed");
    }
}

/// The escape hatch: a test that is ABOUT the deploy turns the commentary back on, so the layer is a
/// default rather than a permanent mute. This is also the path a test asserting on the manual-transaction
/// output would take — that output is the operator's deliverable, not commentary, and is only observable
/// with reporting enabled.
contract DeployReportingForcedOnTest is DeployReportingSetUp {
    function _shouldReport() internal pure override returns (bool) {
        return true;
    }

    function test_reportingCanBeForcedOnByOverride() public view {
        assertTrue(shouldReport(), "an override must be able to re-enable the commentary");
    }

    function test_deployCompletesWithReportingOn() public {
        assertTrue(shouldReport(), "precondition: reporting on");
        _deployETHfxUSD("reporting_on");

        (, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        assertGt(minterAddress(mktConfigs[0]).code.length, 0, "minter deployed");
    }
}
