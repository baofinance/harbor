// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {HarborAutoDeploymentFoundryTest} from "@harbor-test/deployment/HarborAutoDeployment.sol";
import {Minter_v1} from "@harbor/minter/Minter_v1.sol";
import {StabilityPool_v1} from "@harbor/minter/StabilityPool_v1.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Stem_v1} from "@bao/Stem_v1.sol";

import {BaoDeploymentTest} from "@bao-test/deployment/BaoDeploymentTest.sol";

/**
 * @title DeploymentSmokeTest
 * @notice Smoke tests to verify deployments work correctly
 * @dev Tests both full and partial deployments, verifying contracts are properly connected
 */
contract DeploymentSmokeTest is BaoDeploymentTest {
    HarborAutoDeploymentFoundryTest public harbor;

    function setUp() public override {
        super.setUp();

        harbor = new HarborAutoDeploymentFoundryTest();
        // TODO: Migrate to config-driven start
        // harbor.start(jsonConfig);
    }

    // ============================================================================
    // Full Deployment Tests
    // ============================================================================

    function test_fullDeployment_stabilityPoolConnectedToMinter() public {
        console.log("\n=== Full Deployment Smoke Test ===");

        // Deploy full stability pool (includes minter, pegged token, etc.)
        console.log("\n1. Deploying stability pool collateral...");
        address stabilityPool = harbor.deployStabilityPoolCollateralFromConfig();

        console.log("   Stability Pool:", stabilityPool);

        // Get related contracts
        address minter = harbor.getMinter();
        address peggedToken = harbor.getPeggedToken();
        address wrappedCollateral = harbor.getCollateralToken();

        console.log("   Minter:", minter);
        console.log("   Pegged Token:", peggedToken);
        console.log("   Wrapped Collateral:", wrappedCollateral);

        // Verify all addresses are non-zero
        console.log("\n2. Verifying all addresses are known...");
        assertTrue(stabilityPool != address(0), "Stability pool should be deployed");
        assertTrue(minter != address(0), "Minter should be deployed");
        assertTrue(peggedToken != address(0), "Pegged token should be deployed");
        assertTrue(wrappedCollateral != address(0), "Wrapped collateral should be deployed");
        console.log("   [OK] All addresses are non-zero");

        // Verify stability pool's asset token is the pegged token
        console.log("\n3. Verifying stability pool asset token...");
        StabilityPool_v1 sp = StabilityPool_v1(stabilityPool);
        address spAsset = sp.ASSET_TOKEN();
        console.log("   SP asset token:", spAsset);
        console.log("   Pegged token:", peggedToken);
        assertEq(spAsset, peggedToken, "Stability pool asset should be pegged token");
        console.log("   [OK] Stability pool asset matches pegged token");

        // Verify minter's pegged token matches
        console.log("\n4. Verifying minter's pegged token...");
        Minter_v1 minterContract = Minter_v1(minter);
        address minterPegged = address(minterContract.PEGGED_TOKEN());
        console.log("   Minter pegged token:", minterPegged);
        assertEq(minterPegged, peggedToken, "Minter pegged token should match");
        console.log("   [OK] Minter pegged token matches");

        // Verify stability pool's liquidation token is wrapped collateral
        console.log("\n5. Verifying stability pool liquidation token...");
        address spLiquidationToken = sp.LIQUIDATION_TOKEN();
        console.log("   SP liquidation token:", spLiquidationToken);
        console.log("   Wrapped collateral:", wrappedCollateral);
        assertEq(spLiquidationToken, wrappedCollateral, "SP liquidation token should be wrapped collateral");
        console.log("   [OK] Stability pool liquidation token matches");

        // Verify all contracts are registered in deployment
        console.log("\n6. Verifying all contracts are registered...");
        assertTrue(harbor.hasStabilityPoolCollateral(), "SP should be registered");
        assertTrue(harbor.hasMinter(), "Minter should be registered");
        assertTrue(harbor.hasPeggedToken(), "Pegged should be registered");
        assertTrue(harbor.hasCollateralToken(), "Collateral should be registered");
        assertTrue(harbor.hasAdmin(), "Admin should be registered");
        console.log("   [OK] All contracts are registered");

        console.log("\n=== Full Deployment Test PASSED [OK] ===\n");
    }

    function test_fullDeployment_allAddressesKnown() public {
        console.log("\n=== Full Deployment - All Addresses Test ===");

        // Deploy everything
        console.log("\n1. Deploying full system...");
        harbor.deployStabilityPoolCollateralFromConfig();

        // Check all expected contracts exist
        console.log("\n2. Verifying all expected contracts exist...");
        address admin = harbor.getAdmin();
        console.log("   [Admin]", admin);
        assertTrue(harbor.hasAdmin(), "Admin should be registered");
        assertNotEq(admin, address(0), "Admin should be non-zero");

        address wrappedCollateral = harbor.getCollateralToken();
        console.log("   [Wrapped Collateral]", wrappedCollateral);
        assertTrue(harbor.hasCollateralToken(), "Collateral should be registered");
        assertNotEq(wrappedCollateral, address(0), "Collateral should be non-zero");

        address pegged = harbor.getPeggedToken();
        console.log("   [Pegged Token]", pegged);
        assertTrue(harbor.hasPeggedToken(), "Pegged token should be registered");
        assertNotEq(pegged, address(0), "Pegged token should be non-zero");

        address oracle = harbor.getOracle();
        console.log("   [Oracle]", oracle);
        assertTrue(harbor.hasOracle(), "Oracle should be registered");
        assertNotEq(oracle, address(0), "Oracle should be non-zero");

        address minter = harbor.getMinter();
        console.log("   [Minter]", minter);
        assertTrue(harbor.hasMinter(), "Minter should be registered");
        assertNotEq(minter, address(0), "Minter should be non-zero");

        address reservePool = harbor.getReservePool();
        console.log("   [Reserve Pool]", reservePool);
        assertTrue(harbor.hasReservePool(), "Reserve pool should be registered");
        assertNotEq(reservePool, address(0), "Reserve pool should be non-zero");

        address stabilityPool = harbor.getStabilityPoolCollateral();
        console.log("   [Stability Pool Collateral]", stabilityPool);
        assertTrue(harbor.hasStabilityPoolCollateral(), "SP collateral should be registered");
        assertNotEq(stabilityPool, address(0), "SP collateral should be non-zero");

        console.log("\n=== All Addresses Test PASSED [OK] ===\n");
    }

    // ============================================================================
    // Partial Deployment Tests
    // ============================================================================

    function test_partialDeployment_onlyMinter() public {
        console.log("\n=== Partial Deployment Smoke Test (Minter Only) ===");

        // Deploy only minter (not stability pool)
        console.log("\n1. Deploying only minter...");
        address minter = harbor.deployMinterFromConfig();

        console.log("   Minter:", minter);

        // Verify minter exists
        console.log("\n2. Verifying minter is deployed...");
        assertTrue(minter != address(0), "Minter should be deployed");
        assertTrue(harbor.hasMinter(), "Minter should be registered");
        console.log("   [OK] Minter is deployed and registered");

        // Verify minter's dependencies exist
        console.log("\n3. Verifying minter dependencies...");
        address peggedToken = harbor.getPeggedToken();
        address reservePool = harbor.getReservePool();
        address oracle = harbor.getOracle();

        console.log("   Pegged Token:", peggedToken);
        console.log("   Reserve Pool:", reservePool);
        console.log("   Oracle:", oracle);

        assertTrue(peggedToken != address(0), "Pegged token should exist");
        assertTrue(reservePool != address(0), "Reserve pool should exist");
        assertTrue(oracle != address(0), "Oracle should exist");
        console.log("   [OK] Minter dependencies are deployed");

        // Verify stability pool does NOT exist
        console.log("\n4. Verifying stability pool is NOT deployed...");
        bool spExists = harbor.hasStabilityPoolCollateral();
        console.log("   Stability Pool Collateral exists:", spExists);
        assertFalse(spExists, "Stability pool should NOT be deployed");
        console.log("   [OK] Stability pool correctly not deployed");

        // Verify stability pool manager does NOT exist
        console.log("\n5. Verifying stability pool manager is NOT deployed...");
        bool spmExists = harbor.hasStabilityPoolManager();
        console.log("   Stability Pool Manager exists:", spmExists);
        assertFalse(spmExists, "Stability pool manager should NOT be deployed");
        console.log("   [OK] Stability pool manager correctly not deployed");

        // Verify minter works
        console.log("\n6. Testing minter configuration...");
        Minter_v1 minterContract = Minter_v1(minter);
        address minterPegged = minterContract.PEGGED_TOKEN();
        console.log("   Minter's pegged token:", minterPegged);
        assertEq(minterPegged, peggedToken, "Minter should reference correct pegged token");
        console.log("   [OK] Minter is correctly configured");

        console.log("\n=== Partial Deployment Test PASSED [OK] ===\n");
    }

    function test_partialDeployment_limitedRegistry() public {
        console.log("\n=== Partial Deployment - Registry Check ===");

        // Deploy only minter
        console.log("\n1. Deploying only minter...");
        harbor.deployMinterFromConfig();

        // Get all keys count
        console.log("\n2. Checking registry size...");
        string[] memory allKeys = harbor.keys();
        console.log("   Total registered keys:", allKeys.length);
        console.log("   (Expected: minter + dependencies, but NOT stability pools)");

        // Verify specific contracts that should exist
        console.log("\n3. Verifying expected contracts...");
        assertTrue(harbor.hasMinter(), "Minter should exist");
        assertTrue(harbor.hasPeggedToken(), "Pegged should exist");
        assertTrue(harbor.hasReservePool(), "Reserve pool should exist");
        assertTrue(harbor.hasOracle(), "Oracle should exist");
        console.log("   [OK] Expected contracts exist");

        // Verify specific contracts that should NOT exist
        console.log("\n4. Verifying contracts that should NOT exist...");
        assertFalse(harbor.hasStabilityPoolCollateral(), "SP collateral should NOT exist");
        assertFalse(harbor.hasStabilityPoolLeveraged(), "SP leveraged should NOT exist");
        assertFalse(harbor.hasStabilityPoolManager(), "SP manager should NOT exist");
        console.log("   [OK] Unwanted contracts correctly not deployed");

        console.log("\n=== Registry Check PASSED [OK] ===\n");
    }

    // ============================================================================
    // Cross-Contract Verification Tests
    // ============================================================================

    function test_crossContractVerification_tokensMatch() public {
        console.log("\n=== Cross-Contract Token Verification ===");

        // Deploy full system
        console.log("\n1. Deploying full system...");
        harbor.deployStabilityPoolCollateralFromConfig();

        // Get all token addresses
        address peggedToken = harbor.getPeggedToken();
        address wrappedCollateral = harbor.getCollateralToken();

        console.log("   Pegged Token:", peggedToken);
        console.log("   Wrapped Collateral:", wrappedCollateral);

        // Get contract references
        Minter_v1 minter = Minter_v1(harbor.getMinter());
        StabilityPool_v1 spCollateral = StabilityPool_v1(harbor.getStabilityPoolCollateral());

        // Verify minter tokens
        console.log("\n2. Verifying minter tokens...");
        assertEq(minter.PEGGED_TOKEN(), peggedToken, "Minter pegged token should match");
        assertEq(minter.WRAPPED_COLLATERAL_TOKEN(), wrappedCollateral, "Minter collateral should match");
        console.log("   [OK] Minter tokens match");

        // Verify stability pool tokens
        console.log("\n3. Verifying stability pool tokens...");
        assertEq(spCollateral.ASSET_TOKEN(), peggedToken, "SP asset should be pegged");
        assertEq(spCollateral.LIQUIDATION_TOKEN(), wrappedCollateral, "SP liquidation token should be collateral");
        console.log("   [OK] Stability pool tokens match");

        // Verify token names/symbols
        console.log("\n4. Verifying token metadata...");
        IERC20 pegged = IERC20(peggedToken);
        IERC20 collateral = IERC20(wrappedCollateral);

        // Note: MockERC20 should have name() and symbol(), but IERC20 interface doesn't include them
        // This is just to verify the contracts are valid ERC20s
        assertTrue(address(pegged).code.length > 0, "Pegged token should have code");
        assertTrue(address(collateral).code.length > 0, "Collateral token should have code");
        console.log("   [OK] Token contracts are valid");

        console.log("\n=== Cross-Contract Verification PASSED [OK] ===\n");
    }
}
