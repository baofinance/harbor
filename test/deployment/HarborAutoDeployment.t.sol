// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {HarborDeploymentFoundry} from "@harbor-script/deployment/HarborDeploymentFoundry.sol";
import {HarborAutoDeploymentFoundry} from "@harbor-test/deployment/HarborAutoDeployment.sol";

/**
 * @title HarborAutoDeployTest
 * @notice Demonstrates auto-deploy functionality with recursive dependencies
 */
contract HarborAutoDeployTest is Test {
    /**
     * @notice Test one-line deployment with all dependencies
     */
    function test_autoDeployStabilityPoolCollateral() public {
        // Single line deploys everything:
        // - ADMIN (mocked)
        // - TREASURY (mocked)
        // - ORACLE (MockWrappedPriceOracle)
        // - WRAPPED_COLLATERAL (MockERC20)
        // - FEE_RECEIVER (deployed)
        // - PEGGED (deployed)
        // - LEVERAGED (deployed)
        // - RESERVE_POOL (deployed)
        // - MINTER (deployed)
        // - REWARD_MANAGER/DEPOSITOR/REBALANCER (mocked)
        // - STABILITY_POOL_COLLATERAL (deployed)
        HarborDeploymentFoundry harbor = new HarborDeploymentFoundry();
        address pool = harbor.deployStabilityPoolCollateralFromConfig();

        // Verify deployment
        assertNotEq(pool, address(0), "Pool should be deployed");
        assertTrue(harbor.hasStabilityPoolCollateral(), "Should have pool");

        // Verify dependencies were auto-deployed
        assertTrue(harbor.hasAdmin(), "Should have admin");
        assertTrue(harbor.hasOracle(), "Should have oracle");
        assertTrue(harbor.hasCollateralToken(), "Should have collateral");
        assertTrue(harbor.hasFeeReceiver(), "Should have fee receiver");
        assertTrue(harbor.hasPeggedToken(), "Should have pegged");
        assertTrue(harbor.hasLeveragedToken(), "Should have leveraged");
        assertTrue(harbor.hasMinter(), "Should have minter");
    }

    /**
     * @notice Test auto-deploy with custom parameters
     */
    function test_autoDeployWithCustomParams() public {
        HarborDeploymentFoundry harbor = new HarborDeploymentFoundry();

        // Set custom parameters before deployment
        harbor.setPeggedName("Custom USD");
        harbor.setPeggedSymbol("cUSD");
        harbor.setStabilityPoolEarlyWithdrawalFee(0.05 ether);

        // Deploy uses custom params
        address pool = harbor.deployStabilityPoolCollateralFromConfig();

        // Verify custom params were used
        assertEq(harbor.getPeggedName(), "Custom USD");
        assertEq(harbor.getStabilityPoolEarlyWithdrawalFee(), 0.05 ether);
        assertNotEq(pool, address(0));
    }

    /**
     * @notice Test auto-deploy of full system (STABILITY_POOL_MANAGER)
     */
    function test_autoDeployFullSystem() public {
        HarborDeploymentFoundry harbor = new HarborDeploymentFoundry();

        // Deploy stability pool manager - this needs EVERYTHING
        address manager = harbor.deployStabilityPoolManagerFromConfig();

        // Verify everything was deployed
        assertNotEq(manager, address(0), "Manager should be deployed");
        assertTrue(harbor.hasMinter(), "Should have minter");
        assertTrue(harbor.hasTreasury(), "Should have treasury");
        assertTrue(harbor.hasStabilityPoolCollateral(), "Should have collateral stability pool");
        assertTrue(harbor.hasStabilityPoolLeveraged(), "Should have leveraged stability pool");
    }

    function test_autoDeployCreatesDerivedAddresses() public {
        HarborDeploymentFoundry harbor = new HarborDeploymentFoundry();

        harbor.deployStabilityPoolManagerFromConfig();

        address admin = harbor.getAdmin();
        address treasury = harbor.getTreasury();
        address rewardManager = harbor.getRewardManager();
        address rewardDepositor = harbor.getRewardDepositor();
        address rebalancer = harbor.getRebalancer();

        assertNotEq(admin, address(0));
        assertEq(admin.code.length, 0, "Admin should be mock EOA");
        assertNotEq(treasury, address(0));
        assertEq(treasury.code.length, 0, "Treasury should be mock EOA");
        assertNotEq(rewardManager, address(0));
        assertEq(rewardManager.code.length, 0, "Reward manager should be mock EOA");
        assertNotEq(rewardDepositor, address(0));
        assertEq(rewardDepositor.code.length, 0, "Reward depositor should be mock EOA");
        assertNotEq(rebalancer, address(0));
        assertEq(rebalancer.code.length, 0, "Rebalancer should be mock EOA");
    }

    /**
     * @notice Test that defaults are used when params not set
     */
    function test_autoDeployUsesDefaults() public {
        HarborDeploymentFoundry harbor = new HarborDeploymentFoundry();

        // Don't set any params - should use defaults
        harbor.deployFeeReceiverFromConfig();

        // Verify defaults were used
        assertEq(harbor.getFeeReceiverName(), "Test Fee Receiver", "Should use default name");
    }

    /**
     * @notice Test fuzzed deployment with different fees
     */
    function testFuzz_autoDeployWithDifferentFees(uint256 fee) public {
        vm.assume(fee <= 1 ether); // Max 100% fee

        // Fresh deployment per fuzz iteration
        HarborDeploymentFoundry harbor = new HarborDeploymentFoundry();

        // Set fuzzed fee
        harbor.setStabilityPoolEarlyWithdrawalFee(fee);

        // Deploy with fuzzed param
        address pool = harbor.deployStabilityPoolCollateralFromConfig();

        // Verify it used the fuzzed fee
        assertEq(harbor.getStabilityPoolEarlyWithdrawalFee(), fee);
        assertNotEq(pool, address(0));
    }

    /**
     * @notice Test using framework-agnostic base class (no vm dependency)
     */
    function test_baseClassWorksWithoutVm() public {
        // This would work in Wake or other frameworks too
        HarborAutoDeploymentFoundry harbor = new HarborAutoDeploymentFoundry();

        address pool = harbor.deployStabilityPoolCollateralFromConfig();

        assertNotEq(pool, address(0));
        assertTrue(harbor.hasMinter());
    }

    /**
     * @notice Test mixing useExisting with auto-deploy
     */
    function test_mixUseExistingWithAutoDeploy() public {
        HarborDeploymentFoundry harbor = new HarborDeploymentFoundry();

        // Manually set admin first
        address customAdmin = makeAddr("customAdmin");
        harbor.useAdmin(customAdmin);

        // Auto-deploy still works, uses our custom admin
        address pool = harbor.deployStabilityPoolCollateralFromConfig();

        assertNotEq(pool, address(0));
        assertEq(harbor.getAdmin(), customAdmin, "Should use custom admin");
    }
}
