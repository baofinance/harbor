// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {HarborAutoDeploymentFoundry} from "@harbor-test/deployment/HarborAutoDeployment.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/**
 * @title HarborConfigDeployTest
 * @notice Tests config-driven deployment via deploy(Contract) function
 */
contract HarborConfigDeployTest is Test {
    HarborAutoDeploymentFoundry public harbor;

    function setUp() public {
        harbor = new HarborAutoDeploymentFoundry();
        harbor.start(address(this), "test", "v1.0.0", "HarborConfigDeploy");
    }

    /**
     * @notice Test deploying fee receiver via deploy() function
     */
    function test_deployFeeReceiverViaConfig() public {
        // Set up dependencies
        harbor.useAdmin(address(this));

        // Set parameters
        harbor.setFeeReceiverName("Test Fee Receiver");

        // Deploy using config-driven function
        address feeReceiver = harbor.deployFeeReceiverFromConfig();

        // Verify deployment
        assertNotEq(feeReceiver, address(0), "Fee receiver should be deployed");
        assertEq(harbor.getFeeReceiver(), feeReceiver, "Fee receiver should be registered");
    }

    /**
     * @notice Test deploying pegged token via deploy() function
     */
    function test_deployPeggedTokenViaConfig() public {
        // Set up dependencies
        harbor.useAdmin(address(this));

        // Set parameters
        harbor.setPeggedName("BaoUSD");
        harbor.setPeggedSymbol("BAOUSD");

        // Deploy using config-driven function
        address peggedToken = harbor.deployPeggedTokenFromConfig();

        // Verify deployment
        assertNotEq(peggedToken, address(0), "Pegged token should be deployed");
        assertEq(harbor.getPeggedToken(), peggedToken, "Pegged token should be registered");
    }

    /**
     * @notice Test deploying multiple contracts via deploy() function
     */
    function test_deployMultipleContractsViaConfig() public {
        // Set up dependencies
        harbor.useAdmin(address(this));

        // Mock existing contracts
        MockERC20 collateral = new MockERC20("Wrapped Collateral", "wCOLL", 18);
        harbor.useCollateralToken(address(collateral));

        MockWrappedPriceOracle oracle = new MockWrappedPriceOracle();
        harbor.useOracle(address(oracle));

        // Set parameters for tokens
        harbor.setFeeReceiverName("Harbor Fee Receiver");
        harbor.setPeggedName("BaoUSD");
        harbor.setPeggedSymbol("BAOUSD");
        harbor.setLeveragedName("BaoUSD-Leveraged");
        harbor.setLeveragedSymbol("BAOUSD-L");

        // Deploy contracts using config-driven approach
        address feeReceiver = harbor.deployFeeReceiverFromConfig();
        address peggedToken = harbor.deployPeggedTokenFromConfig();
        address leveragedToken = harbor.deployLeveragedTokenFromConfig();
        address reservePool = harbor.deployReservePoolFromConfig();

        // Verify all deployed
        assertNotEq(feeReceiver, address(0), "Fee receiver should be deployed");
        assertNotEq(peggedToken, address(0), "Pegged token should be deployed");
        assertNotEq(leveragedToken, address(0), "Leveraged token should be deployed");
        assertNotEq(reservePool, address(0), "Reserve pool should be deployed");

        // Verify all registered
        assertTrue(harbor.hasFeeReceiver(), "Should have fee receiver");
        assertTrue(harbor.hasPeggedToken(), "Should have pegged token");
        assertTrue(harbor.hasLeveragedToken(), "Should have leveraged token");
        assertTrue(harbor.hasReservePool(), "Should have reserve pool");
    }

    /**
     * @notice Test deploying full minter system via deploy() function
     */
    function test_deployFullSystemViaConfig() public {
        // Set up dependencies
        harbor.useAdmin(address(this));

        // Mock existing contracts
        MockERC20 collateral = new MockERC20("Wrapped Collateral", "wCOLL", 18);
        harbor.useCollateralToken(address(collateral));

        MockWrappedPriceOracle oracle = new MockWrappedPriceOracle();
        harbor.useOracle(address(oracle));

        // Set all required parameters
        harbor.setFeeReceiverName("Harbor Fee Receiver");
        harbor.setPeggedName("BaoUSD");
        harbor.setPeggedSymbol("BAOUSD");
        harbor.setLeveragedName("BaoUSD-Leveraged");
        harbor.setLeveragedSymbol("BAOUSD-L");

        // Deploy contracts in order
        harbor.deployFeeReceiverFromConfig();
        harbor.deployPeggedTokenFromConfig();
        harbor.deployLeveragedTokenFromConfig();
        harbor.deployReservePoolFromConfig();
        address minter = harbor.deployMinterFromConfig();

        // Verify minter deployed and configured
        assertNotEq(minter, address(0), "Minter should be deployed");
        assertTrue(harbor.hasMinter(), "Should have minter");
    }

    /**
     * @notice Test that deploy() reverts for non-deployable contracts
     */
    function test_revertWhen_AdminMissingForDeployment() public {
        // Without an admin configured, deployments that depend on it should revert
        vm.expectRevert();
        harbor.deployFeeReceiverFromConfig();
    }
}
