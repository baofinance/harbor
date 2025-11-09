// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoDeploymentTest} from "@bao-test/deployment/BaoDeploymentTest.sol";
import {HarborAutoDeploymentFoundryTest} from "@harbor-test/deployment/HarborAutoDeployment.sol";
import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";
import {DeploymentFoundryTest} from "@bao-script/deployment/DeploymentFoundry.sol";
import {Minter_v1} from "@harbor/minter/Minter_v1.sol";
import {StabilityPool_v1} from "@harbor/minter/StabilityPool_v1.sol";
import {StabilityPoolManager_v1} from "@harbor/minter/StabilityPoolManager_v1.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/**
 * @title HarborDeploymentTest
 * @notice Tests Harbor deployment lifecycle (start, deploy, finish)
 */
contract HarborDeploymentTest is BaoDeploymentTest {
    HarborAutoDeploymentFoundryTest public harbor;

    function setUp() public override {
        super.setUp();
        harbor = new HarborAutoDeploymentFoundryTest();
    }

    // ========== Harbor Deployment Tests ==========
    // TODO: Migrate these tests to new config-driven deployment

    function test_deployHarborBasics() public pure {
        revert("deployFeeReceiverFromConfig: not yet migrated");
    }

    function test_deployHarborMinter() public pure {
        revert("deployMinterFromConfig: not yet migrated");
    }

    function test_deployStabilityPool() public pure {
        revert("deployStabilityPoolFromConfig: not yet migrated");
    }

    function test_deployStabilityPoolManager() public pure {
        revert("deployStabilityPoolManagerFromConfig: not yet migrated");
    }

    function test_useExistingContracts() public pure {
        revert("useExistingContracts: not yet migrated");
    }
}
