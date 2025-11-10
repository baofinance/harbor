// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {DeploymentRegistry} from "@bao-script/deployment/DeploymentRegistry.sol";
import {DeploymentRegistryJson} from "@bao-script/deployment/DeploymentRegistryJson.sol";
import {DeploymentFoundryTest} from "@bao-script/deployment/DeploymentFoundry.sol";
import {DeploymentInfrastructure} from "@bao-script/deployment/DeploymentInfrastructure.sol";
import {BaoDeployer} from "@bao-script/deployment/BaoDeployer.sol";
import {HarborDeployment} from "@harbor-script/deployment/HarborDeployment.sol";
import {HarborKeys} from "@harbor-script/deployment/HarborKeys.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {MockMinter} from "@bao-test/mocks/upgradeable/MockMinter.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/**
 * @title HarborAutoDeployment
 * @notice Test/development deployment helper with auto-deploy and auto-mock
 * @dev Framework-agnostic (works in Foundry, Wake, etc.)
 *      Instantiate per test, not in setUp, to enable fuzzing
 *
 *      Usage:
 *        HarborAutoDeployment harbor = new HarborAutoDeployment();
 *        harbor.deploy(Contract.STABILITY_POOL_COLLATERAL);
 *        // ^ Recursively deploys all dependencies with sensible defaults
 */
abstract contract HarborAutoDeployment is HarborDeployment {
    // ============================================================================
    // Auto-Deploy Override
    // ============================================================================

    // TODO: confirm this function override is needed - seems to just intercept mocks,
    // but they should just be treated the same as other contracts
    // function get(string memory key) public view override(DeploymentRegistry) returns (address) {
    //     if (has(key)) {
    //         return super.get(key);
    //     }

    //     if (_eq(key, HarborKeys.ORACLE)) {
    //         MockWrappedPriceOracle oracle = new MockWrappedPriceOracle();
    //         useOracle(address(oracle));
    //         return address(oracle);
    //     }

    //     if (_eq(key, HarborKeys.WRAPPED_COLLATERAL)) {
    //         MockERC20 token = new MockERC20("Wrapped Collateral", "wCOLL", 18);
    //         useCollateralToken(address(token));
    //         return address(token);
    //     }

    //     if (
    //         _eq(key, HarborKeys.ADMIN) ||
    //         _eq(key, HarborKeys.TREASURY) ||
    //         _eq(key, HarborKeys.REWARD_MANAGER) ||
    //         _eq(key, HarborKeys.REWARD_DEPOSITOR) ||
    //         _eq(key, HarborKeys.REBALANCER)
    //     ) {
    //         address mockAddr = _deriveAddress(key);
    //         if (_eq(key, HarborKeys.ADMIN)) {
    //             useAdmin(mockAddr);
    //             return mockAddr;
    //         }
    //         if (_eq(key, HarborKeys.TREASURY)) {
    //             useTreasury(mockAddr);
    //             return mockAddr;
    //         }
    //         if (_eq(key, HarborKeys.REWARD_MANAGER)) {
    //             useRewardManager(mockAddr);
    //             return mockAddr;
    //         }
    //         if (_eq(key, HarborKeys.REWARD_DEPOSITOR)) {
    //             useRewardDepositor(mockAddr);
    //             return mockAddr;
    //         }
    //         useRebalancer(mockAddr);
    //         return mockAddr;
    //     }

    //     if (_eq(key, HarborKeys.FEE_RECEIVER)) {
    //         return deployFeeReceiverFromConfig();
    //     }
    //     if (_eq(key, HarborKeys.PEGGED)) {
    //         return deployPeggedTokenFromConfig();
    //     }
    //     if (_eq(key, HarborKeys.LEVERAGED)) {
    //         return deployLeveragedTokenFromConfig();
    //     }
    //     if (_eq(key, HarborKeys.RESERVE_POOL)) {
    //         return deployReservePoolFromConfig();
    //     }
    //     if (_eq(key, HarborKeys.MINTER)) {
    //         return deployMinterFromConfig();
    //     }
    //     if (_eq(key, HarborKeys.STABILITY_POOL_COLLATERAL)) {
    //         return deployStabilityPoolCollateralFromConfig();
    //     }
    //     if (_eq(key, HarborKeys.STABILITY_POOL_LEVERAGED)) {
    //         return deployStabilityPoolLeveragedFromConfig();
    //     }
    //     if (_eq(key, HarborKeys.STABILITY_POOL_MANAGER)) {
    //         return deployStabilityPoolManagerFromConfig();
    //     }
    //     if (_eq(key, HarborKeys.GENESIS)) {
    //         return deployGenesisFromConfig();
    //     }

    //     return super.get(key);
    // }

    // =========================================================================
    // Parameter Overrides (Lazy Defaults)
    // =========================================================================

    function getFeeReceiverName() public view override returns (string memory) {
        if (hasFeeReceiverName()) {
            return super.getFeeReceiverName();
        }
        return "Test Fee Receiver";
    }

    function getPeggedName() public view override returns (string memory) {
        if (hasPeggedName()) {
            return super.getPeggedName();
        }
        return "BaoUSD";
    }

    function getPeggedSymbol() public view override returns (string memory) {
        if (hasPeggedSymbol()) {
            return super.getPeggedSymbol();
        }
        return "BAOUSD";
    }

    function getLeveragedName() public view override returns (string memory) {
        if (hasLeveragedName()) {
            return super.getLeveragedName();
        }
        return "BaoUSD-L";
    }

    function getLeveragedSymbol() public view override returns (string memory) {
        if (hasLeveragedSymbol()) {
            return super.getLeveragedSymbol();
        }
        return "BAOUSD-L";
    }

    function getStabilityPoolEarlyWithdrawalFee() public view override returns (uint256) {
        if (has(HarborKeys.STABILITY_POOL_EARLY_WITHDRAWAL_FEE)) {
            return super.getStabilityPoolEarlyWithdrawalFee();
        }
        return 0.01 ether;
    }

    // ============================================================================
    // Address Derivation & Labeling
    // ============================================================================

    /**
     * @notice Derive deterministic address from string key
     * @dev Uses keccak256 for deterministic, consistent addresses across test runs
     */
    function _deriveAddress(string memory key) internal virtual returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(key)))));
    }

    // =========================================================================
    // Test Helpers
    // =========================================================================

    function mockMinter() public returns (address) {
        if (has(HarborKeys.MINTER)) {
            revert ContractAlreadyExists(HarborKeys.MINTER);
        }

        address collateral = getCollateralToken();
        address pegged = getPeggedToken();
        address leveraged = getLeveragedToken();

        MockMinter minter = new MockMinter(collateral, pegged, leveraged);
        useMinter(address(minter));
        return address(minter);
    }
}

/**
 * @title HarborAutoDeploymentFoundry
 * @notice Foundry-specific deployment WITHOUT test infrastructure
 * @dev For scripts that need VM but don't auto-deploy BaoDeployer
 *      Writes to deployments/ directory (production)
 */
contract HarborAutoDeploymentFoundry is HarborAutoDeployment, DeploymentRegistryJson {
    Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function _getBaseDirPrefix()
        internal
        view
        virtual
        override(DeploymentRegistry, DeploymentRegistryJson)
        returns (string memory)
    {
        if (VM.envExists("BAO_DEPLOYMENT_LOGS_ROOT")) {
            return VM.envString("BAO_DEPLOYMENT_LOGS_ROOT");
        }
        return "results";
    }
}

/**
 * @title HarborAutoDeploymentFoundryTest
 * @notice Foundry test deployment with auto-deploy infrastructure
 * @dev For use in forge test files
 *      Auto-deploys BaoDeployer, writes to results/ directory
 *      Inherits from DeploymentFoundryTest for test infrastructure
 */
contract HarborAutoDeploymentFoundryTest is HarborAutoDeployment, DeploymentFoundryTest {
    function _ensureBaoDeployerOperator() internal virtual override(Deployment, DeploymentFoundryTest) {
        DeploymentFoundryTest._ensureBaoDeployerOperator();
    }

    function _getBaseDirPrefix()
        internal
        view
        virtual
        override(DeploymentFoundryTest, DeploymentRegistry)
        returns (string memory)
    {
        return DeploymentFoundryTest._getBaseDirPrefix();
    }
}
