// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {HarborDeploymentTestingFoundry} from "@harbor-test/deployment/HarborDeploymentTesting.sol";
import {PeggedTokenDeployer} from "@harbor-script/deployment/deployers/PeggedTokenDeployer.sol";
import {Stem_v1} from "@bao/Stem_v1.sol";
import {HarborKeys} from "@harbor-script/deployment/HarborKeys.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";

/**
 * @title HarborParameterExample
 * @notice Example showing how to use parameters with Harbor deployment
 * @dev This demonstrates setting configuration values before deploying contracts
 *      Uses HarborDeploymentTestingFoundry (non-auto) to test explicit parameter requirements
 */
contract HarborParameterExample is Test {
    HarborDeploymentTestingFoundry public harbor;
    uint256 private _networkCounter;

    function setUp() public {
        harbor = new HarborDeploymentTestingFoundry();
        address baoDeployer = DeploymentInfrastructure.predictBaoDeployerAddress();
        if (baoDeployer.code.length == 0) {
            DeploymentInfrastructure.deployBaoDeployer();
        }
        vm.startPrank(DeploymentInfrastructure.BAOMULTISIG);
        BaoDeployer(baoDeployer).setOperator(address(harbor));
        vm.stopPrank();
        string memory network = _nextNetwork();
        harbor.start(_buildConfig(address(this)), network);
    }

    function _buildConfig(address owner) internal pure returns (string memory) {
        string memory json = string.concat('{"schemaVersion":1,"version":"v1.0.0","owner":"', vm.toString(owner), '"');

        json = string.concat(
            json,
            ',"pegged":{"registryKey":"pegged"},"collateral":{"registryKey":"wrappedCollateral"}}'
        );
        return json;
    }

    function _nextNetwork() internal returns (string memory) {
        _networkCounter += 1;
        return string.concat("parameters:", vm.toString(_networkCounter));
    }

    function test_UseParametersForTokenDeployment() public {
        // Setup admin first (required for Harbor deployments)

        // 1. Set parameters before deployment
        harbor.setString(HarborKeys.PEGGED_NAME, "Bao USD");
        harbor.setString(HarborKeys.PEGGED_SYMBOL, "BAOUSD");
        harbor.setUint(HarborKeys.PEGGED_DECIMALS, 18);

        harbor.setString(HarborKeys.LEVERAGED_NAME, "Bao Leveraged USD");
        harbor.setString(HarborKeys.LEVERAGED_SYMBOL, "BAOLUSD");
        harbor.setUint(HarborKeys.LEVERAGED_DECIMALS, 18);

        // 2. Retrieve parameters for contract deployment
        string memory peggedName = harbor.getPeggedName();
        string memory peggedSymbol = harbor.getPeggedSymbol();
        uint256 peggedDecimals = harbor.getPeggedDecimals();

        // 3. Use in deployment (deployers read these automatically from registry)
        assertEq(peggedName, "Bao USD");
        assertEq(peggedSymbol, "BAOUSD");
        assertEq(peggedDecimals, 18);

        // Deploy tokens using deployer libraries directly
        PeggedTokenDeployer.deploy(harbor);

        // Verify tokens were deployed
        assertTrue(harbor.hasPeggedToken());
    }

    function test_UseParametersForStabilityPools() public {
        // Set minimum deposit amount (shared across both stability pools)
        harbor.setUint(HarborKeys.STABILITY_POOL_MIN_DEPOSIT, 0.01 ether);

        // Get min deposit parameter
        uint256 minDeposit = harbor.getStabilityPoolMinDeposit();

        // Verify parameter was set correctly
        assertEq(minDeposit, 0.01 ether);
    }

    function test_ParametersAsDependencies() public {
        // If a parameter isn't set, deployment should fail gracefully
        vm.expectRevert();
        harbor.getString(HarborKeys.PEGGED_NAME);

        // Set parameter
        harbor.setString(HarborKeys.PEGGED_NAME, "Bao USD");

        // Now it works
        assertEq(harbor.getPeggedName(), "Bao USD");
    }

    function test_MixingContractsAndParameters() public {
        // Setup admin

        // Set parameters first
        harbor.setString(HarborKeys.PEGGED_NAME, "BaoUSD");
        harbor.setString(HarborKeys.PEGGED_SYMBOL, "BAOUSD");
        harbor.setUint(HarborKeys.INITIAL_EXCHANGE_RATE, 1e18);
        harbor.setUint(HarborKeys.FEE_PERCENTAGE, 100);

        // Deploy contract
        PeggedTokenDeployer.deploy(harbor);

        // Get all keys (should include both contracts and parameters)
        string[] memory allKeys = harbor.keys();
        assertTrue(allKeys.length >= 6, "Registry should include contracts and parameters");

        // Verify entry types
        assertEq(harbor.getType(HarborKeys.OWNER), "contract");
        assertEq(harbor.getType(HarborKeys.PEGGED), "proxy");
        assertEq(harbor.getType(HarborKeys.PEGGED_NAME), "string");
        assertEq(harbor.getType(HarborKeys.PEGGED_SYMBOL), "string");
        assertEq(harbor.getType(HarborKeys.INITIAL_EXCHANGE_RATE), "uint256");
        assertEq(harbor.getType(HarborKeys.FEE_PERCENTAGE), "uint256");
    }
}
