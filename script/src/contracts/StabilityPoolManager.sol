// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {FactoryDeployer} from "../FactoryDeployer.sol";
import {DeploymentState} from "../DeploymentState.sol";
import {DeploymentTypes} from "../DeploymentTypes.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

import {StabilityPoolManager_v1} from "@harbor/minter/StabilityPoolManager_v1.sol";
import {TokenDistributor_v1} from "@harbor/minter/TokenDistributor_v1.sol";

/// @notice Harbor StabilityPoolManager_v1 deployment logic (including SPMFeeReceiver).
/// @dev File Organization Pattern (see deployment2-design.md Section 3.3.2):
/// @dev - This file: contract-specific deployment for StabilityPoolManager and its FeeReceiver
/// @dev - Uses DeploymentOwnership pattern: register deployed contracts, transfer at end
///
/// @dev StabilityPoolManager Ecosystem:
/// @dev - SPM coordinates the two stability pools per market
/// @dev - SPM grants: HARVESTER_ROLE on Minter (obtained via Minter deployment)
/// @dev - SPM needs: REBALANCER_ROLE, REWARD_DEPOSITOR_ROLE on both stability pools
abstract contract StabilityPoolManager is FactoryDeployer {
    /// @notice StabilityPoolManager configuration.
    struct SPMConfig {
        uint256 rebalanceThreshold;
        uint256 rebalanceBountyRatio;
        uint256 harvestBountyRatio;
        uint256 harvestCutRatio;
        address feeReceiver;
    }

    // ========== STABILITY POOL MANAGER DEPLOYMENT ==========

    /// @notice Deploy StabilityPoolManager_v1 implementation.
    /// @dev Constructor takes immutables: minter, treasury, stabilityPoolCollateral, stabilityPoolLeveraged.
    function deployStabilityPoolManagerImpl(
        address minter,
        address treasury,
        address stabilityPoolCollateral,
        address stabilityPoolLeveraged
    ) internal returns (address impl, DeploymentTypes.ImplementationRecord memory implRecord) {
        impl = address(new StabilityPoolManager_v1(minter, treasury, stabilityPoolCollateral, stabilityPoolLeveraged));

        implRecord = DeploymentTypes.ImplementationRecord({
            proxy: "",
            contractSource: "@harbor/minter/StabilityPoolManager_v1.sol",
            contractType: "StabilityPoolManager_v1",
            implementation: impl,
            deploymentTime: uint64(block.timestamp)
        });
    }

    /// @notice Deploy StabilityPoolManager_v1 proxy.
    function deployStabilityPoolManagerProxy(
        address baoFactoryAddr,
        string memory marketKey,
        address implementation,
        address tokenOwner,
        string memory systemSalt
    ) internal returns (address proxy, DeploymentTypes.ProxyRecord memory proxyRecord) {
        string memory spmKey = string.concat(marketKey, "::stabilityPoolManager");

        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", spmKey));
        bytes memory initData = abi.encodeCall(StabilityPoolManager_v1.initialize, (tokenOwner));

        proxy = deployProxy(baoFactoryAddr, salt, implementation, initData);
        console.log("        Proxy: %s", proxy);

        proxyRecord = DeploymentTypes.ProxyRecord({
            id: spmKey,
            fragment: DeploymentTypes.FragmentDescriptor({
                key: marketKey,
                kind: DeploymentTypes.FragmentKind.MinterMarket
            }),
            proxy: proxy,
            implementation: implementation,
            salt: systemSalt,
            deploymentTime: uint64(block.timestamp)
        });
    }

    /// @notice Configure a deployed StabilityPoolManager with its operational parameters.
    function configureStabilityPoolManager(address spmProxy, SPMConfig memory config) internal {
        StabilityPoolManager_v1 spm = StabilityPoolManager_v1(spmProxy);
        spm.updateRebalanceThreshold(config.rebalanceThreshold);
        spm.updateRebalanceBountyRatio(config.rebalanceBountyRatio);
        spm.updateHarvestBountyRatio(config.harvestBountyRatio);
        spm.updateHarvestCutRatio(config.harvestCutRatio);
        spm.updateFeeReceiver(config.feeReceiver);
    }

    // ========== SPM FEE RECEIVER (TOKEN DISTRIBUTOR) DEPLOYMENT ==========

    /// @notice Deploy TokenDistributor_v1 implementation (used as SPMFeeReceiver).
    /// @dev Reuses the same contract as MinterFeeReceiver.
    function deploySPMFeeReceiverImpl()
        internal
        returns (address impl, DeploymentTypes.ImplementationRecord memory implRecord)
    {
        impl = address(new TokenDistributor_v1());
        console.log("      Impl:   %s", impl);

        implRecord = DeploymentTypes.ImplementationRecord({
            proxy: "",
            contractSource: "@harbor/minter/TokenDistributor_v1.sol",
            contractType: "TokenDistributor_v1",
            implementation: impl,
            deploymentTime: uint64(block.timestamp)
        });
    }

    /// @notice Deploy TokenDistributor_v1 proxy for SPM fee receiver.
    function deploySPMFeeReceiverProxy(
        address baoFactoryAddr,
        string memory marketKey,
        address implementation,
        address tokenOwner,
        string memory name,
        string memory systemSalt
    ) internal returns (address proxy, DeploymentTypes.ProxyRecord memory proxyRecord) {
        string memory feeReceiverKey = string.concat(marketKey, "::spmFeeReceiver");
        console.log("    > %s", feeReceiverKey);

        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", feeReceiverKey));
        bytes memory initData = abi.encodeCall(TokenDistributor_v1.initialize, (tokenOwner, name));

        proxy = deployProxy(baoFactoryAddr, salt, implementation, initData);
        console.log("        Proxy: %s", proxy);

        proxyRecord = DeploymentTypes.ProxyRecord({
            id: feeReceiverKey,
            fragment: DeploymentTypes.FragmentDescriptor({
                key: marketKey,
                kind: DeploymentTypes.FragmentKind.MinterMarket
            }),
            proxy: proxy,
            implementation: implementation,
            salt: systemSalt,
            deploymentTime: uint64(block.timestamp)
        });
    }

    /// @notice Configure TokenDistributor with tokens and distribution.
    /// @dev Shared pattern with MinterFeeReceiver.
    function configureSPMFeeReceiver(
        address feeReceiverProxy,
        address[] memory tokens,
        address[] memory recipients,
        uint256[] memory shares
    ) internal {
        TokenDistributor_v1 distributor = TokenDistributor_v1(feeReceiverProxy);

        for (uint256 i = 0; i < tokens.length; i++) {
            distributor.addToken(tokens[i]);
        }

        distributor.setDistribution(recipients, shares);
    }

    // ========== ADDRESS PREDICTION ==========

    /// @notice Predict stability pool manager contract address from salt.
    function predictStabilityPoolManagerAddress(
        address baoFactoryAddr,
        string memory systemSalt,
        string memory marketKey
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", marketKey, "::stabilityPoolManager"));
        return IBaoFactory(baoFactoryAddr).predictAddress(salt);
    }

    /// @notice Predict SPM fee receiver contract address from salt.
    function predictSPMFeeReceiverAddress(
        address baoFactoryAddr,
        string memory systemSalt,
        string memory marketKey
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", marketKey, "::spmFeeReceiver"));
        return IBaoFactory(baoFactoryAddr).predictAddress(salt);
    }
}
