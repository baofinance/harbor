// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

import {StabilityPoolManager_v2} from "@harbor/minter/StabilityPoolManager_v2.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

/// @notice Harbor StabilityPoolManager deployment logic (including SPMFeeReceiver).
/// @dev SPM coordinates the two stability pools per market.
/// @dev SPM grants: HARVESTER_ROLE on Minter (obtained via Minter deployment).
/// @dev SPM needs: REBALANCER_ROLE, REWARD_DEPOSITOR_ROLE on both stability pools.
abstract contract StabilityPoolManager is HarborDeployer {
    /// @notice StabilityPoolManager configuration.
    struct SPMConfig {
        uint256 rebalanceThreshold;
        uint256 rebalanceBountyRatio;
        uint256 harvestBountyRatio;
        uint256 harvestCutRatio;
        address feeReceiver;
    }

    // ========== STABILITY POOL MANAGER DEPLOYMENT ==========

    /// @notice Deploy StabilityPoolManager_v2 impl only, record in state.
    function deployStabilityPoolManagerImplementation(
        DeploymentTypes.State memory stateData,
        string memory spmKey,
        address minter,
        address stabilityPoolCollateral,
        address stabilityPoolLeveraged
    ) internal virtual returns (address impl) {
        impl = address(new StabilityPoolManager_v2(minter, stabilityPoolCollateral, stabilityPoolLeveraged));
        console.log("        Impl:  %s", impl);

        _recordImplementation(
            stateData,
            spmKey,
            "@harbor/minter/StabilityPoolManager_v2.sol",
            "StabilityPoolManager_v2",
            impl
        );
    }

    /// @notice Deploy StabilityPoolManager_v2 impl+proxy, record in state.
    function deployStabilityPoolManager(
        DeploymentTypes.State memory stateData,
        string memory marketKey,
        address minter,
        address stabilityPoolCollateral,
        address stabilityPoolLeveraged
    ) internal returns (address proxy) {
        string memory key = stabilityPoolManagerKey(marketKey);
        console.log("    > %s", key);

        address impl = deployStabilityPoolManagerImplementation(
            stateData,
            key,
            minter,
            stabilityPoolCollateral,
            stabilityPoolLeveraged
        );

        bytes memory initData = abi.encodeCall(StabilityPoolManager_v2.initialize, (address(this), owner()));

        proxy = _deployProxyAndRecord(stateData, key, impl, initData);
    }

    /// @notice Configure a deployed StabilityPoolManager with its operational parameters.
    /// @param marketKey The market salt key (e.g., "ETH::fxUSD").
    /// @param config The SPM configuration parameters.
    function configureStabilityPoolManager(string memory marketKey, SPMConfig memory config) internal {
        address spm = stabilityPoolManagerAddress(marketKey);
        IStabilityPoolManager(spm).updateRebalanceThreshold(config.rebalanceThreshold);
        IStabilityPoolManager(spm).updateRebalanceBountyRatio(config.rebalanceBountyRatio);
        IStabilityPoolManager(spm).updateHarvestBountyRatio(config.harvestBountyRatio);
        IStabilityPoolManager(spm).updateHarvestCutRatio(config.harvestCutRatio);
        IStabilityPoolManager(spm).updateFeeReceiver(config.feeReceiver);
    }
}
