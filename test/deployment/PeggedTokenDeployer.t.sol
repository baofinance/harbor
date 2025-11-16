// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {HarborDeploymentTestingFoundry} from "@harbor-test/deployment/HarborDeploymentTesting.sol";
import {HarborKeys} from "@harbor-script/deployment/HarborKeys.sol";
import {PeggedTokenDeployer} from "@harbor-script/deployment/deployers/PeggedTokenDeployer.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";

/**
 * @title PeggedTokenDeployerTest
 * @notice Test the PeggedTokenDeployer library
 */
contract PeggedTokenDeployerTest is Test {
    using stdJson for string;

    HarborDeploymentTestingFoundry public harbor;
    address public owner = makeAddr("owner");
    uint256 private _runId;

    function setUp() public {
        _runId += 1;
        harbor = new HarborDeploymentTestingFoundry();
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

    function test_deploy_lazyLoadingUsesRegistryDefaults() public {
        // Set admin first (required)

        // Set parameters in registry (simulating config load)
        harbor.setString(HarborKeys.PEGGED_NAME, "Test USD");
        harbor.setString(HarborKeys.PEGGED_SYMBOL, "TUSD");

        // Deploy using config-driven approach
        address token = PeggedTokenDeployer.deploy(harbor);

        // Verify deployment
        assertTrue(token != address(0), "Token should be deployed");
        assertTrue(harbor.hasPeggedToken(), "Registry should have pegged token");

        assertEq(MintableBurnableERC20_v1(token).owner(), address(this));

        // Complete deployment lifecycle to transfer ownership to configured owner
        harbor.finish();

        // Verify token properties match config
        assertEq(IERC20Metadata(token).name(), "Test USD");
        assertEq(IERC20Metadata(token).symbol(), "TUSD");
        assertEq(MintableBurnableERC20_v1(token).owner(), owner);
    }

    function test_deploy_usesConfiguredAdmin() public {
        // Set parameters
        harbor.setString(HarborKeys.PEGGED_NAME, "Admin Test");
        harbor.setString(HarborKeys.PEGGED_SYMBOL, "ADMIN");

        // Deploy
        address token = PeggedTokenDeployer.deploy(harbor);

        // Verify deployment succeeded
        assertTrue(token != address(0), "Token should be deployed");

        harbor.finish();

        // Verify token properties
        assertEq(IERC20Metadata(token).name(), "Admin Test");
        assertEq(IERC20Metadata(token).symbol(), "ADMIN");
        assertEq(MintableBurnableERC20_v1(token).owner(), owner);
    }
}
