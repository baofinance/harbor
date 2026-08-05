// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";

import {StabilityPoolManager_v2} from "@harbor/minter/StabilityPoolManager_v2.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";

/// @notice Harbor StabilityPoolManager deployment logic (including SPMFeeReceiver).
/// @dev SPM coordinates the two stability pools per market.
/// @dev SPM grants: HARVESTER_ROLE on Minter (obtained via Minter deployment).
/// @dev SPM needs: REBALANCER_ROLE, REWARD_DEPOSITOR_ROLE on both stability pools.
abstract contract StabilityPoolManager is HarborDeployer {
    // ========== STABILITY POOL MANAGER DEPLOYMENT ==========

    /// @notice Deploy StabilityPoolManager_v2 impl only, record in state.
    function deployStabilityPoolManagerImplementation(
        DeploymentTypes.State memory stateData,
        string memory key,
        address minter,
        address stabilityPoolCollateral,
        address stabilityPoolLeveraged
    ) internal virtual returns (address impl) {
        impl = address(new StabilityPoolManager_v2(minter, stabilityPoolCollateral, stabilityPoolLeveraged));
        _reportImplementation(impl);

        _recordImplementation(
            stateData,
            key,
            "@harbor/minter/StabilityPoolManager_v2.sol",
            "StabilityPoolManager_v2",
            impl
        );
    }

    /// @notice Deploy a fully configured StabilityPoolManager: impl+proxy, recorded in state, with its
    ///         operating parameters already set.
    /// @dev Takes the market config, not the contract's constructor arguments — this function is the only
    ///      place that splits those values across constructor, `initialize` calldata and setters.
    ///      The ratios stay setters on the contract deliberately: they are tuned on live markets by
    ///      multisig batch (see `script/UpdateVolatility_*.s.sol`). What changes here is only that the
    ///      deploy stack no longer performs the configuration. The harvest bounty and cut are set as one
    ///      pair, which is the only way to set either - see `updateHarvestRatios`.
    function deployStabilityPoolManager(
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig
    ) internal returns (address proxy) {
        IHarborConfig cfg = IHarborConfig(address(marketConfig));
        string memory key = stabilityPoolManagerKey(marketConfig);
        _reportContract(key);

        address impl = deployStabilityPoolManagerImplementation(
            stateData,
            key,
            minterAddress(marketConfig),
            stabilityPoolAddress(marketConfig, StabilityPoolType.Collateral),
            stabilityPoolAddress(marketConfig, StabilityPoolType.Leveraged)
        );

        bytes memory initData = abi.encodeCall(StabilityPoolManager_v2.initialize, (address(this), owner()));

        proxy = _deployProxyAndRecord(stateData, key, impl, initData);

        IStabilityPoolManager_v2(proxy).updateRebalanceThreshold(cfg.rebalanceThreshold());
        IStabilityPoolManager_v2(proxy).updateRebalanceBountyRatio(cfg.rebalanceBountyRatio());
        IStabilityPoolManager_v2(proxy).updateHarvestRatios(cfg.harvestBountyRatio(), cfg.harvestCutRatio());
        IStabilityPoolManager_v2(proxy).updateFeeReceiver(treasury());
    }
}
