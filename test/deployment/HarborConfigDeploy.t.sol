// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "@bao-test/deployment/BaoDeploymentTest.sol";
import {console2 as console} from "forge-std/console2.sol";
import {HarborAutoDeploymentFoundryTest} from "@harbor-test/deployment/HarborAutoDeployment.sol";
import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/**
 * @title HarborConfigDeployTest
 * @notice Tests config-driven deployment via JSON config
 */
contract HarborConfigDeployTest is BaoDeploymentTest {
    HarborAutoDeploymentFoundryTest public harbor;

    address constant CONFIG_OWNER = address(0x000000000000000000000000000000000000A002);
    address constant CONFIG_TREASURY = address(0x000000000000000000000000000000000000a003);
    address constant CONFIG_COLLATERAL = address(0x0000000000000000000000000000000000000001);

    function setUp() public override {
        super.setUp();
        harbor = new HarborAutoDeploymentFoundryTest();
    }

    function _loadFixture() internal view returns (string memory) {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/test/fixtures/deployment/harbor-basic.json");
        return vm.readFile(path);
    }

    /**
     * @notice Test starting deployment from JSON config
     */
    function test_startFromJsonConfig() public {
        string memory json = _loadFixture();
        
        harbor.start(json);

        // Verify system salt derived from pegged:collateral:
        assertEq(harbor.getSystemSaltString(), "pegged:wrappedCollateral:", "System salt should be derived from config");
        
        // Verify owner applied from config
        DeploymentRegistry.DeploymentMetadata memory metadata = harbor.getMetadata();
        assertEq(metadata.owner, CONFIG_OWNER, "Owner should come from config");
        assertEq(metadata.version, "v1.0.0", "Version should come from config");
        assertEq(metadata.network, "", "Network should be empty");
    }

    /**
     * @notice Test config application after start
     */
    function test_configAppliedAfterStart() public {
        string memory json = _loadFixture();
        
        harbor.start(json);

        // Verify treasury applied
        assertTrue(harbor.hasTreasury(), "Should have treasury");
        assertEq(harbor.getTreasury(), CONFIG_TREASURY, "Treasury should come from config");

        // Verify pegged token config applied
        assertTrue(harbor.hasPeggedName(), "Should have pegged name");
        assertEq(harbor.getPeggedName(), "Bao USD", "Pegged name should come from config");
        assertEq(harbor.getPeggedSymbol(), "BAOUSD", "Pegged symbol should come from config");
        assertEq(harbor.getPeggedDecimals(), 18, "Pegged decimals should come from config");

        // Verify collateral registered
        assertTrue(harbor.hasCollateralToken(), "Should have collateral token");
        assertEq(harbor.getCollateralToken(), CONFIG_COLLATERAL, "Collateral should come from config");
    }

    /**
     * @notice Test resume with version validation
     */
    function test_resumeValidatesVersion() public {
        string memory json = _loadFixture();
        
        // Start and finish initial deployment
        harbor.start(json);
        harbor.finish();

        // Create new harness and resume
        HarborAutoDeploymentFoundryTest harbor2 = new HarborAutoDeploymentFoundryTest();
        harbor2.resume(json);

        // Verify resumed successfully
        DeploymentRegistry.DeploymentMetadata memory metadata = harbor2.getMetadata();
        assertEq(metadata.version, "v1.0.0", "Version should match");
    }

    /**
     * @notice Test resume fails with version mismatch
     */
    function test_revertWhen_resumeVersionMismatch() public {
        string memory json = _loadFixture();
        
        // Start and finish initial deployment
        harbor.start(json);
        harbor.finish();

        // Try to resume with different version
        string memory badJson = '{"schemaVersion":1,"version":"v2.0.0","owner":"0x000000000000000000000000000000000000a002","treasury":"0x000000000000000000000000000000000000a003","pegged":{"registryKey":"pegged","id":"fxSAVE","name":"Bao USD","symbol":"BAOUSD","decimals":18},"collateral":{"registryKey":"wrappedCollateral","address":"0x0000000000000000000000000000000000000001"}}';
        
        HarborAutoDeploymentFoundryTest harbor2 = new HarborAutoDeploymentFoundryTest();
        vm.expectRevert();
        harbor2.resume(badJson);
    }
}
