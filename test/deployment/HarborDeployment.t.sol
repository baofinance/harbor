// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {HarborDeploymentFoundry} from "@harbor-script/deployment/HarborDeploymentFoundry.sol";
import {Minter_v1} from "@harbor/minter/Minter_v1.sol";
import {StabilityPool_v1} from "@harbor/minter/StabilityPool_v1.sol";
import {StabilityPoolManager_v1} from "@harbor/minter/StabilityPoolManager_v1.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

// Test deployment contract with mock methods
contract HarborDeploymentTestContract is Test, HarborDeploymentFoundry {
    // Mock deployment methods for testing
    function mockAdmin() public returns (address) {
        address admin = makeAddr("admin");
        useAdmin(admin);
        return admin;
    }

    function mockFeeReceiver() public returns (address) {
        address feeReceiver = makeAddr("feeReceiver");
        useFeeReceiver(feeReceiver);
        return feeReceiver;
    }

    function mockTreasury() public returns (address) {
        address treasury = makeAddr("treasury");
        useTreasury(treasury);
        return treasury;
    }

    function mockCollateralToken(string memory name, string memory symbol, uint8 decimals) public returns (address) {
        MockERC20 token = new MockERC20(name, symbol, decimals);
        useCollateralToken(address(token));
        return address(token);
    }

    function mockPeggedToken(string memory name, string memory symbol, uint8 decimals) public returns (address) {
        MockERC20 token = new MockERC20(name, symbol, decimals);
        usePeggedToken(address(token));
        return address(token);
    }

    function mockLeveragedToken(string memory name, string memory symbol) public returns (address) {
        MockERC20 token = new MockERC20(name, symbol, 18);
        useLeveragedToken(address(token));
        return address(token);
    }

    function mockOracle() public returns (address) {
        MockWrappedPriceOracle oracle = new MockWrappedPriceOracle();
        useOracle(address(oracle));
        return address(oracle);
    }

    function mockRewardManager() public returns (address) {
        address rewardManager = makeAddr("rewardManager");
        useRewardManager(rewardManager);
        return rewardManager;
    }

    function mockRewardDepositor() public returns (address) {
        address rewardDepositor = makeAddr("rewardDepositor");
        useRewardDepositor(rewardDepositor);
        return rewardDepositor;
    }

    function mockRebalancer() public returns (address) {
        address rebalancer = makeAddr("rebalancer");
        useRebalancer(rebalancer);
        return rebalancer;
    }
}

contract HarborDeploymentTest is Test {
    HarborDeploymentTestContract public harbor;

    function setUp() public {
        harbor = new HarborDeploymentTestContract();
    }

    // ========== Harbor Deployment Tests ==========

    function test_deployHarborBasics() public {
        // Deploy admin
        harbor.useAdmin(address(this));
        assertEq(harbor.getAdmin(), address(this), "Admin should be set");

        // Deploy fee receiver (one step now - Stem proxy created automatically)
        harbor.setFeeReceiverName("Test Fee Receiver");
        address feeReceiver = harbor.deployFeeReceiverFromConfig();
        assertNotEq(feeReceiver, address(0), "Fee receiver should be deployed");

        // Mock tokens
        harbor.mockCollateralToken("Wrapped Collateral", "wCOLL", 18);
        harbor.mockPeggedToken("BaoUSD", "BAOUSD", 18);
        harbor.mockLeveragedToken("BaoUSD-Leveraged", "BAOUSD-L");

        // Mock oracle
        harbor.mockOracle();

        // Verify all registered
        assertTrue(harbor.hasAdmin(), "Should have admin");
        assertTrue(harbor.hasFeeReceiver(), "Should have fee receiver");
        assertTrue(harbor.hasCollateralToken(), "Should have collateral");
        assertTrue(harbor.hasPeggedToken(), "Should have pegged");
        assertTrue(harbor.hasLeveragedToken(), "Should have leveraged");
        assertTrue(harbor.hasOracle(), "Should have oracle");
    }

    function test_deployHarborMinter() public {
        // Setup dependencies with real tokens (minter needs to grant roles)
        harbor.useAdmin(address(harbor));
        harbor.mockCollateralToken("Wrapped Collateral", "wCOLL", 18);

        // Set parameters for tokens
        harbor.setPeggedName("BaoUSD");
        harbor.setPeggedSymbol("BAOUSD");
        harbor.setLeveragedName("BaoUSD-Leveraged");
        harbor.setLeveragedSymbol("BAOUSD-L");
        harbor.setFeeReceiverName("Fee Receiver");

        // Deploy real tokens (one step each - Stem proxy created automatically)
        harbor.deployPeggedTokenFromConfig();
        harbor.deployLeveragedTokenFromConfig();

        harbor.mockOracle();

        // Deploy dependencies
        harbor.deployFeeReceiverFromConfig();
        harbor.deployReservePoolFromConfig();

        // Deploy minter (automatically grants roles on tokens)
        address minter = harbor.deployMinterFromConfig();
        assertNotEq(minter, address(0), "Minter should be deployed");

        // Verify minter has correct dependencies
        assertEq(
            Minter_v1(minter).WRAPPED_COLLATERAL_TOKEN(),
            harbor.getCollateralToken(),
            "Minter should have correct collateral"
        );
        assertEq(Minter_v1(minter).PEGGED_TOKEN(), harbor.getPeggedToken(), "Minter should have correct pegged");
        assertEq(
            Minter_v1(minter).LEVERAGED_TOKEN(),
            harbor.getLeveragedToken(),
            "Minter should have correct leveraged"
        );
    }

    function test_deployStabilityPool() public {
        // Setup dependencies with real tokens
        harbor.useAdmin(address(harbor));
        harbor.mockCollateralToken("Wrapped Collateral", "wCOLL", 18);

        // Set parameters
        harbor.setPeggedName("BaoUSD");
        harbor.setPeggedSymbol("BAOUSD");
        harbor.setLeveragedName("BaoUSD-Leveraged");
        harbor.setLeveragedSymbol("BAOUSD-L");
        harbor.setFeeReceiverName("Fee Receiver");
        harbor.setStabilityPoolEarlyWithdrawalFee(0.01 ether);

        // Deploy real tokens
        harbor.deployPeggedTokenFromConfig();
        harbor.deployLeveragedTokenFromConfig();
        harbor.mockOracle();

        // Register role addresses
        harbor.mockRewardManager();
        harbor.mockRewardDepositor();
        harbor.mockRebalancer();

        // Deploy dependencies
        harbor.deployFeeReceiverFromConfig();
        harbor.deployReservePoolFromConfig();
        harbor.deployMinterFromConfig();

        // Deploy stability pool
        address stabilityPool = harbor.deployStabilityPoolCollateralFromConfig();
        assertNotEq(stabilityPool, address(0), "Stability pool should be deployed");

        // Verify stability pool has correct asset token (pegged token)
        assertEq(
            StabilityPool_v1(stabilityPool).ASSET_TOKEN(),
            harbor.getPeggedToken(),
            "Stability pool should have correct asset token"
        );

        // Verify stability pool has correct liquidation token
        address collateral = harbor.getCollateralToken();
        assertEq(
            StabilityPool_v1(stabilityPool).LIQUIDATION_TOKEN(),
            collateral,
            "Stability pool should have correct liquidation token"
        );
    }

    function test_deployStabilityPoolManager() public {
        // Setup full system with real tokens
        harbor.useAdmin(address(harbor));
        harbor.mockCollateralToken("Wrapped Collateral", "wCOLL", 18);

        // Set parameters
        harbor.setPeggedName("BaoUSD");
        harbor.setPeggedSymbol("BAOUSD");
        harbor.setLeveragedName("BaoUSD-Leveraged");
        harbor.setLeveragedSymbol("BAOUSD-L");
        harbor.setFeeReceiverName("Fee Receiver");
        harbor.setStabilityPoolEarlyWithdrawalFee(0.01 ether);

        // Deploy real tokens
        harbor.deployPeggedTokenFromConfig();
        harbor.deployLeveragedTokenFromConfig();
        harbor.mockOracle();

        // Register role addresses
        harbor.mockRewardManager();
        harbor.mockRewardDepositor();
        harbor.mockRebalancer();

        // Register treasury
        address treasury = address(0x9999);
        harbor.useTreasury(treasury);

        // Deploy all dependencies
        harbor.deployFeeReceiverFromConfig();
        harbor.deployReservePoolFromConfig();
        harbor.deployMinterFromConfig();
        harbor.deployStabilityPoolCollateralFromConfig();
        harbor.deployStabilityPoolLeveragedFromConfig();

        // Deploy stability pool manager
        address stabilityPoolManager = harbor.deployStabilityPoolManagerFromConfig();
        assertNotEq(stabilityPoolManager, address(0), "Stability pool manager should be deployed");

        // Verify stability pool manager has correct dependencies
        assertEq(
            StabilityPoolManager_v1(stabilityPoolManager).MINTER(),
            harbor.getMinter(),
            "Stability pool manager should have correct minter"
        );
        assertEq(
            StabilityPoolManager_v1(stabilityPoolManager).TREASURY(),
            treasury,
            "Stability pool manager should have correct treasury"
        );

        // Verify stability pools are registered correctly
        address stabilityPoolCollateral = harbor.getStabilityPoolCollateral();
        address stabilityPoolLeveraged = harbor.getStabilityPoolLeveraged();
        address[] memory pools = StabilityPoolManager_v1(stabilityPoolManager).stabilityPools();
        assertEq(pools.length, 2, "Should have 2 stability pools");
        assertEq(pools[0], stabilityPoolCollateral, "First pool should be collateral pool");
        assertEq(pools[1], stabilityPoolLeveraged, "Second pool should be leveraged pool");
    }

    function test_useExistingContracts() public {
        // Use existing contracts instead of deploying
        harbor.useAdmin(address(0x1111));
        harbor.useFeeReceiver(address(0x2222));
        harbor.useCollateralToken(address(0x3333));
        harbor.usePeggedToken(address(0x4444));
        harbor.useLeveragedToken(address(0x5555));
        harbor.useOracle(address(0x6666));
        harbor.useReservePool(address(0x7777));
        harbor.useMinter(address(0x8888));
        harbor.useStabilityPoolManager(address(0x9999));

        // Verify all registered with correct addresses
        assertEq(harbor.getAdmin(), address(0x1111));
        assertEq(harbor.getFeeReceiver(), address(0x2222));
        assertEq(harbor.getCollateralToken(), address(0x3333));
        assertEq(harbor.getPeggedToken(), address(0x4444));
        assertEq(harbor.getLeveragedToken(), address(0x5555));
        assertEq(harbor.getOracle(), address(0x6666));
        assertEq(harbor.getReservePool(), address(0x7777));
        assertEq(harbor.getMinter(), address(0x8888));
        assertEq(harbor.getStabilityPoolManager(), address(0x9999));
    }

    function test_saveAndLoadFullHarborDeployment() public {
        // Deploy full Harbor system with real tokens
        harbor.useAdmin(address(harbor));
        harbor.mockCollateralToken("Wrapped Collateral", "wCOLL", 18);

        // Set parameters
        harbor.setPeggedName("BaoUSD");
        harbor.setPeggedSymbol("BAOUSD");
        harbor.setLeveragedName("BaoUSD-Leveraged");
        harbor.setLeveragedSymbol("BAOUSD-L");
        harbor.setFeeReceiverName("Fee Receiver");
        harbor.setStabilityPoolEarlyWithdrawalFee(0.01 ether);

        // Deploy real tokens
        harbor.deployPeggedTokenFromConfig();
        harbor.deployLeveragedTokenFromConfig();
        harbor.mockOracle();

        // Register role addresses
        harbor.mockRewardManager();
        harbor.mockRewardDepositor();
        harbor.mockRebalancer();

        // Deploy all contracts
        harbor.deployFeeReceiverFromConfig();
        harbor.deployReservePoolFromConfig();
        harbor.deployMinterFromConfig();
        harbor.deployStabilityPoolCollateralFromConfig();

        // Save to JSON
        harbor.toJsonFile("results/deployments/harbor-full-system.json");

        // Create new contract and load
        HarborDeploymentTestContract harbor2 = new HarborDeploymentTestContract();
        harbor2.fromJsonFile("results/deployments/harbor-full-system.json");

        // Verify all contracts loaded correctly
        assertEq(harbor2.getAdmin(), harbor.getAdmin(), "Admin should match");
        assertEq(harbor2.getFeeReceiver(), harbor.getFeeReceiver(), "Fee receiver should match");
        assertEq(harbor2.getCollateralToken(), harbor.getCollateralToken(), "Collateral should match");
        assertEq(harbor2.getPeggedToken(), harbor.getPeggedToken(), "Pegged should match");
        assertEq(harbor2.getLeveragedToken(), harbor.getLeveragedToken(), "Leveraged should match");
        assertEq(harbor2.getOracle(), harbor.getOracle(), "Oracle should match");
        assertEq(harbor2.getReservePool(), harbor.getReservePool(), "Reserve pool should match");
        assertEq(harbor2.getMinter(), harbor.getMinter(), "Minter should match");
        assertEq(
            harbor2.getStabilityPoolCollateral(),
            harbor.getStabilityPoolCollateral(),
            "Stability pool should match"
        );
    }
}
