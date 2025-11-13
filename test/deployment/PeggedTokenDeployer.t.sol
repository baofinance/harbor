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
    harbor.start(_buildConfig(owner), network);
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
