// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {HarborAutoDeploymentFoundry} from "@harbor-test/deployment/HarborAutoDeployment.sol";

import {Stem_v1} from "@bao/Stem_v1.sol";

/**
 * @title HarborParameterExample
 * @notice Example showing how to use parameters with Harbor deployment
 * @dev This demonstrates setting configuration values before deploying contracts
 *      Uses HarborAutoDeploymentFoundry (non-auto) to test explicit parameter requirements
 */
contract HarborParameterExample is Test {
    HarborAutoDeploymentFoundry public harbor;

    function setUp() public {
        harbor = new HarborAutoDeploymentFoundry();
        // TODO: Migrate to config-driven start
        // harbor.start(jsonConfig);
    }

    function test_UseParametersForTokenDeployment() public {
        // Setup admin first (required for Harbor deployments)
        harbor.useAdmin(address(this));

        // 1. Set parameters before deployment
        harbor.setPeggedName("Bao USD");
        harbor.setPeggedSymbol("BAOUSD");
        harbor.setPeggedDecimals(18);

        harbor.setLeveragedName("Bao Leveraged USD");
        harbor.setLeveragedSymbol("BAOLUSD");
        harbor.setLeveragedDecimals(18);

        // 2. Retrieve parameters for contract deployment
        string memory peggedName = harbor.getPeggedName();
        string memory peggedSymbol = harbor.getPeggedSymbol();
        uint256 peggedDecimals = harbor.getPeggedDecimals();

        // 3. Use in deployment (deployPeggedTokenFromConfig now reads these automatically)
        assertEq(peggedName, "Bao USD");
        assertEq(peggedSymbol, "BAOUSD");
        assertEq(peggedDecimals, 18);

        // Deploy tokens using config-driven approach (reads parameters automatically)
        harbor.deployPeggedTokenFromConfig();
        harbor.deployLeveragedTokenFromConfig();

        // Verify tokens were deployed
        assertTrue(harbor.hasPeggedToken());
        assertTrue(harbor.hasLeveragedToken());
    }

    function test_UseParametersForStabilityPools() public {
        // Set minimum deposit amount (shared across both stability pools)
        harbor.setStabilityPoolMinDeposit(0.01 ether);

        // Get min deposit parameter
        uint256 minDeposit = harbor.getStabilityPoolMinDeposit();

        // Verify parameter was set correctly
        assertEq(minDeposit, 0.01 ether);
    }

    function test_ParametersAsDependencies() public {
        // If a parameter isn't set, deployment should fail gracefully
        vm.expectRevert();
        harbor.getPeggedName();

        // Set parameter
        harbor.setPeggedName("Bao USD");

        // Now it works
        assertEq(harbor.getPeggedName(), "Bao USD");
    }

    function test_MixingContractsAndParameters() public {
        // Setup admin
        harbor.useAdmin(address(this));

        // Set parameters first
        harbor.setPeggedName("BaoUSD");
        harbor.setPeggedSymbol("BAOUSD");
        harbor.setInitialExchangeRate(1e18);
        harbor.setFeePercentage(100);

        // Deploy contract
        harbor.deployPeggedTokenFromConfig();

        // Get all keys (should include both contracts and parameters)
        string[] memory allKeys = harbor.keys();

        // Should have: admin, pegged, peggedName, peggedSymbol, initialExchangeRate, feePercentage
        assertEq(allKeys.length, 6);

        // Verify entry types
        assertEq(harbor.getType("admin"), "contract");
        assertEq(harbor.getType("pegged"), "proxy");
        assertEq(harbor.getType("peggedName"), "string");
        assertEq(harbor.getType("peggedSymbol"), "string");
        assertEq(harbor.getType("initialExchangeRate"), "uint256");
        assertEq(harbor.getType("feePercentage"), "uint256");
    }
}
