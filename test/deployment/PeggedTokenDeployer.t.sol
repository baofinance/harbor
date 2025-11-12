// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {HarborAutoDeploymentFoundryTest} from "@harbor-test/deployment/HarborAutoDeployment.sol";
import {PeggedTokenDeployer} from "@harbor-script/deployment/deployers/PeggedTokenDeployer.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";

/**
 * @title PeggedTokenDeployerTest
 * @notice Test the PeggedTokenDeployer library
 */
contract PeggedTokenDeployerTest is Test {
    using stdJson for string;

    HarborAutoDeploymentFoundryTest public harbor;
    address public owner = address(0x1234);
    uint256 private _runId;

    function setUp() public {
        _runId += 1;
        harbor = new HarborAutoDeploymentFoundryTest();
        harbor.deployBaoDeployer();
        string memory network = string.concat("pegged:", vm.toString(_runId));
        harbor.start(_buildConfig(owner), network, false);
    }

    function _buildConfig(address configOwner) internal pure returns (string memory) {
        string memory json = string.concat(
            '{"schemaVersion":1,"version":"v1.0.0","owner":"',
            vm.toString(configOwner),
            '"'
        );

        json = string.concat(
            json,
            ',"pegged":{"registryKey":"pegged"},"collateral":{"registryKey":"wrappedCollateral"}}'
        );
        return json;
    }

    function test_deploy_withExplicitParams() public {
        // Deploy pegged token with explicit parameters
        address token = PeggedTokenDeployer.deploy(harbor, owner, "Bao USD", "baoUSD");

        // Verify deployment
        assertTrue(token != address(0), "Token should be deployed");
        assertTrue(harbor.hasPeggedToken(), "Registry should have pegged token");
        assertEq(harbor.getPeggedToken(), token, "Registry should return correct address");

        // Verify token properties
        assertEq(IERC20Metadata(token).name(), "Bao USD");
        assertEq(IERC20Metadata(token).symbol(), "baoUSD");
        assertEq(IERC20Metadata(token).decimals(), 18);
    }

    function test_deployFromConfig_lazyLoading() public {
        // Set admin first (required)

        // Set parameters in registry (simulating config load)
        harbor.setPeggedName("Test USD");
        harbor.setPeggedSymbol("TUSD");

        // Deploy using config-driven approach
        address token = PeggedTokenDeployer.deployFromConfig(harbor);

        // Verify deployment
        assertTrue(token != address(0), "Token should be deployed");
        assertTrue(harbor.hasPeggedToken(), "Registry should have pegged token");

        // Verify token properties match config
        assertEq(IERC20Metadata(token).name(), "Test USD");
        assertEq(IERC20Metadata(token).symbol(), "TUSD");
    }

    function test_deployFromConfig_usesAdmin() public {
        // Set parameters
        harbor.setPeggedName("Admin Test");
        harbor.setPeggedSymbol("ADMIN");

        // Deploy
        address token = PeggedTokenDeployer.deployFromConfig(harbor);

        // Verify deployment succeeded
        assertTrue(token != address(0), "Token should be deployed");

        // Verify token properties
        assertEq(IERC20Metadata(token).name(), "Admin Test");
        assertEq(IERC20Metadata(token).symbol(), "ADMIN");
    }
}

contract PeggedTokenDeployerDryRunTest is Test {
    using stdJson for string;

    HarborAutoDeploymentFoundryTest public harbor;
    address public owner = address(0x1234);
    uint256 private _runId;

    function setUp() public {
        _runId += 1;
        harbor = new HarborAutoDeploymentFoundryTest();
        harbor.deployBaoDeployer();
        string memory network = string.concat("pegged-dry:", vm.toString(_runId));
        harbor.start(_buildConfig(owner), network, true);
    }

    function _buildConfig(address configOwner) internal pure returns (string memory) {
        string memory json = string.concat(
            '{"schemaVersion":1,"version":"v1.0.0","owner":"',
            vm.toString(configOwner),
            '"'
        );

        json = string.concat(
            json,
            ',"pegged":{"registryKey":"pegged"},"collateral":{"registryKey":"wrappedCollateral"}}'
        );
        return json;
    }

    function test_dryRun_registersWithoutDeploying() public {
        // Enable dry-run mode
        assertTrue(harbor.isDryRun(), "Dry-run should be enabled");

        // Set parameters
        harbor.setPeggedName("Dry Run Test");
        harbor.setPeggedSymbol("DRY");

        // Deploy in dry-run mode
        address predictedToken = PeggedTokenDeployer.deployFromConfig(harbor);

        // Verify predicted address is registered
        assertTrue(predictedToken != address(0), "Predicted address should not be zero");
        assertTrue(harbor.hasPeggedToken(), "Registry should have pegged token");
        assertEq(harbor.getPeggedToken(), predictedToken, "Registry should return predicted address");

        // Verify the contract doesn't actually exist (no code at address)
        uint256 size;
        assembly {
            size := extcodesize(predictedToken)
        }
        assertEq(size, 0, "No code should exist at predicted address in dry-run mode");
    }

    function test_deploymentLog_distinguishesDryRunFromActual() public {
        // Part 1: Dry-run deployment
        harbor.setPeggedName("Test Token");
        harbor.setPeggedSymbol("TEST");

        address predictedAddr = PeggedTokenDeployer.deployFromConfig(harbor);
        harbor.finish();

        DeploymentRegistry.DeploymentMetadata memory metadata = harbor.getMetadata();
        string memory logDir = "results/deployments";
        if (bytes(metadata.network).length != 0) {
            logDir = string.concat(logDir, "/", metadata.network);
        }
        string memory logPath = string.concat(logDir, "/", metadata.systemSaltString, ".json");
        string memory dryRunJson = vm.readFile(logPath);

        // Verify predicted address is in dry-run log
        address dryRunAddr = dryRunJson.readAddress(".deployment.pegged.address");
        assertEq(dryRunAddr, predictedAddr, "Dry-run log should contain predicted address");
        bool dryRunFlag = dryRunJson.readBool(".deployment.pegged.dryRun");
        assertTrue(dryRunFlag, "Dry-run log should mark entry as dry-run");

        // Verify dry-run flag prevents code deployment
        uint256 dryRunSize;
        assembly {
            dryRunSize := extcodesize(dryRunAddr)
        }
        assertEq(dryRunSize, 0, "Dry-run mode should not deploy code");

        // Part 2: Actual deployment with same config
        HarborAutoDeploymentFoundryTest harbor2 = new HarborAutoDeploymentFoundryTest();
        harbor2.deployBaoDeployer();
        harbor2.start(_buildConfig(owner), metadata.network, false);
        harbor2.setPeggedName("Test Token");
        harbor2.setPeggedSymbol("TEST");

        address actualAddr = PeggedTokenDeployer.deployFromConfig(harbor2);
        harbor2.finish();

        // Read actual deployment log (overwrites dry-run file)
        string memory actualJson = vm.readFile(logPath);

        // Verify actual address matches prediction
        address actualLogAddr = actualJson.readAddress(".deployment.pegged.address");
        assertEq(actualLogAddr, predictedAddr, "Actual deployment should match predicted address");
        assertEq(actualAddr, predictedAddr, "CREATE3 should produce same address");
        bool actualRunFlag = actualJson.readBool(".deployment.pegged.dryRun");
        assertFalse(actualRunFlag, "Actual deployment should clear dry-run flag");

        // Verify normal mode (non-dry-run) deploys code
        uint256 actualSize;
        assembly {
            actualSize := extcodesize(actualAddr)
        }
        assertGt(actualSize, 0, "Normal mode should deploy code");
    }
}
