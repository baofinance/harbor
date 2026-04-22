// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborFactoryDeployer} from "@harbor-script/src/HarborFactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

import {StabilityPoolManager_v1} from "@harbor/minter/StabilityPoolManager_v1.sol";
import {TokenDistributor_v1} from "@harbor/minter/TokenDistributor_v1.sol";

/// @notice Harbor StabilityPoolManager deployment logic (including SPMFeeReceiver).
/// @dev SPM coordinates the two stability pools per market.
/// @dev SPM grants: HARVESTER_ROLE on Minter (obtained via Minter deployment).
/// @dev SPM needs: REBALANCER_ROLE, REWARD_DEPOSITOR_ROLE on both stability pools.
abstract contract StabilityPoolManager is HarborFactoryDeployer {
    /// @notice StabilityPoolManager configuration.
    struct SPMConfig {
        uint256 rebalanceThreshold;
        uint256 rebalanceBountyRatio;
        uint256 harvestBountyRatio;
        uint256 harvestCutRatio;
        address feeReceiver;
    }

    // ========== STABILITY POOL MANAGER DEPLOYMENT ==========

    /// @notice Deploy StabilityPoolManager_v1 impl only, record in state.
    function deployStabilityPoolManagerImplementation(
        DeploymentTypes.State memory stateData,
        string memory spmKey,
        address minter,
        address treasury,
        address stabilityPoolCollateral,
        address stabilityPoolLeveraged
    ) internal virtual returns (address impl) {
        impl = address(new StabilityPoolManager_v1(minter, treasury, stabilityPoolCollateral, stabilityPoolLeveraged));
        console.log("        Impl:  %s", impl);

        _recordImplementation(
            stateData,
            spmKey,
            "@harbor/minter/StabilityPoolManager_v1.sol",
            "StabilityPoolManager_v1",
            impl
        );
    }

    /// @notice Deploy StabilityPoolManager_v1 impl+proxy, record in state.
    function deployStabilityPoolManager(
        DeploymentTypes.State memory stateData,
        string memory marketKey,
        address minter,
        address treasury,
        address stabilityPoolCollateral,
        address stabilityPoolLeveraged
    ) internal virtual returns (address proxy) {
        string memory spmKey = _key(marketKey, "stabilityPoolManager");
        console.log("    > %s", spmKey);

        address impl = deployStabilityPoolManagerImplementation(
            stateData,
            spmKey,
            minter,
            treasury,
            stabilityPoolCollateral,
            stabilityPoolLeveraged
        );

        bytes memory initData = abi.encodeCall(StabilityPoolManager_v1.initialize, (owner()));

        proxy = _deployProxyViaStubAndRecord(stateData, spmKey, impl, initData);
    }

    /// @notice Configure a deployed StabilityPoolManager with its operational parameters.
    /// @param marketKey The market salt key (e.g., "ETH::fxUSD").
    /// @param config The SPM configuration parameters.
    function configureStabilityPoolManager(string memory marketKey, SPMConfig memory config) internal {
        StabilityPoolManager_v1 spm = StabilityPoolManager_v1(_predictAddress(_key(marketKey, "stabilityPoolManager")));
        spm.updateRebalanceThreshold(config.rebalanceThreshold);
        spm.updateRebalanceBountyRatio(config.rebalanceBountyRatio);
        spm.updateHarvestBountyRatio(config.harvestBountyRatio);
        spm.updateHarvestCutRatio(config.harvestCutRatio);
        spm.updateFeeReceiver(config.feeReceiver);
    }

    // ========== SPM FEE RECEIVER (TOKEN DISTRIBUTOR) DEPLOYMENT ==========

    /// @notice Deploy TokenDistributor_v1 (SPMFeeReceiver) impl only, record in state.
    function deploySPMFeeReceiverImplementation(
        DeploymentTypes.State memory stateData,
        string memory feeReceiverKey
    ) internal virtual returns (address impl) {
        impl = address(new TokenDistributor_v1());
        console.log("        Impl:  %s", impl);

        _recordImplementation(
            stateData,
            feeReceiverKey,
            "@harbor/minter/TokenDistributor_v1.sol",
            "TokenDistributor_v1",
            impl
        );
    }

    /// @notice Deploy TokenDistributor_v1 as SPMFeeReceiver impl+proxy, record in state.
    function deploySPMFeeReceiver(
        DeploymentTypes.State memory stateData,
        string memory marketKey,
        string memory name
    ) internal returns (address proxy) {
        string memory feeReceiverKey = _key(marketKey, "spmFeeReceiver");
        console.log("    > %s", feeReceiverKey);

        address impl = deploySPMFeeReceiverImplementation(stateData, feeReceiverKey);

        bytes memory initData = abi.encodeCall(TokenDistributor_v1.initialize, (owner(), name));

        proxy = _deployProxyViaStubAndRecord(stateData, feeReceiverKey, impl, initData);
    }

    /// @notice Configure TokenDistributor with tokens and distribution.
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
}
