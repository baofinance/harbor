// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

import {StabilityPoolManager_v1} from "@harbor/minter/StabilityPoolManager_v1.sol";
import {TokenDistributor_v1} from "@harbor/minter/TokenDistributor_v1.sol";

/// @notice Harbor StabilityPoolManager_v1 deployment logic (including SPMFeeReceiver).
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

    /// @notice Deploy StabilityPoolManager impl+proxy, record in state.
    function deployStabilityPoolManager(
        DeploymentTypes.State memory stateData,
        string memory marketKey,
        address minter,
        address treasury,
        address stabilityPoolCollateral,
        address stabilityPoolLeveraged
    ) internal virtual returns (address proxy) {
        string memory spmKey = string.concat(marketKey, "::stabilityPoolManager");
        console.log("    > %s", spmKey);

        address impl = address(
            new StabilityPoolManager_v1(minter, treasury, stabilityPoolCollateral, stabilityPoolLeveraged)
        );
        console.log("        Impl:  %s", impl);

        bytes memory initData = abi.encodeCall(StabilityPoolManager_v1.initialize, (owner()));

        proxy = _deployProxyAndRecord(
            stateData,
            spmKey,
            impl,
            "@harbor/minter/StabilityPoolManager_v1.sol",
            "StabilityPoolManager_v1",
            initData
        );
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

    /// @notice Deploy TokenDistributor_v1 as SPMFeeReceiver impl+proxy, record in state.
    function deploySPMFeeReceiver(
        DeploymentTypes.State memory stateData,
        string memory marketKey,
        string memory name
    ) internal returns (address proxy) {
        string memory feeReceiverKey = string.concat(marketKey, "::spmFeeReceiver");
        console.log("    > %s", feeReceiverKey);

        address impl = address(new TokenDistributor_v1());
        console.log("        Impl:  %s", impl);

        bytes memory initData = abi.encodeCall(TokenDistributor_v1.initialize, (owner(), name));

        proxy = _deployProxyAndRecord(
            stateData,
            feeReceiverKey,
            impl,
            "@harbor/minter/TokenDistributor_v1.sol",
            "TokenDistributor_v1",
            initData
        );
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

    // ========== ADDRESS PREDICTION ==========

    /// @notice Predict stability pool manager contract address from salt.
    function predictStabilityPoolManagerAddress(
        address baoFactoryAddr,
        string memory saltPrefix,
        string memory marketKey
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(saltPrefix, "::", marketKey, "::stabilityPoolManager"));
        return IBaoFactory(baoFactoryAddr).predictAddress(salt);
    }

    /// @notice Predict SPM fee receiver contract address from salt.
    function predictSPMFeeReceiverAddress(
        address baoFactoryAddr,
        string memory saltPrefix,
        string memory marketKey
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(saltPrefix, "::", marketKey, "::spmFeeReceiver"));
        return IBaoFactory(baoFactoryAddr).predictAddress(salt);
    }
}
