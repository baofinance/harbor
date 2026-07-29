// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";

import {StabilityPoolManager_v2} from "@harbor/minter/StabilityPoolManager_v2.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

/// @notice Harbor StabilityPoolManager deployment logic (including SPMFeeReceiver).
/// @dev SPM coordinates the two stability pools per market.
/// @dev SPM grants: HARVESTER_ROLE on Minter (obtained via Minter deployment).
/// @dev SPM needs: REBALANCER_ROLE, REWARD_DEPOSITOR_ROLE on both stability pools.
abstract contract StabilityPoolManager is HarborDeployer {
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

    /// @notice Deploy a fully configured StabilityPoolManager: impl+proxy, recorded in state, with its
    ///         operating parameters already set.
    /// @dev Takes the market config, not the contract's constructor arguments — this function is the only
    ///      place that splits those values across constructor, `initialize` calldata and setters.
    ///      The four ratios stay setters on the contract deliberately: they are tuned on live markets by
    ///      multisig batch (see `script/UpdateVolatility_*.s.sol`). What changes here is only that the
    ///      deploy stack no longer performs the configuration.
    function deployStabilityPoolManager(
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig
    ) internal returns (address proxy) {
        IHarborConfig cfg = IHarborConfig(address(marketConfig));
        string memory marketKey = MinterMarketConfigLib.salt(marketConfig);
        string memory key = stabilityPoolManagerKey(marketKey);
        console.log("    > %s", key);

        address impl = deployStabilityPoolManagerImplementation(
            stateData,
            key,
            minterAddress(marketKey),
            stabilityPoolAddress(marketKey, StabilityPoolType.Collateral),
            stabilityPoolAddress(marketKey, StabilityPoolType.Leveraged)
        );

        bytes memory initData = abi.encodeCall(StabilityPoolManager_v2.initialize, (address(this), owner()));

        proxy = _deployProxyAndRecord(stateData, key, impl, initData);

        IStabilityPoolManager(proxy).updateRebalanceThreshold(cfg.rebalanceThreshold());
        IStabilityPoolManager(proxy).updateRebalanceBountyRatio(cfg.rebalanceBountyRatio());
        IStabilityPoolManager(proxy).updateHarvestBountyRatio(cfg.harvestBountyRatio());
        IStabilityPoolManager(proxy).updateHarvestCutRatio(cfg.harvestCutRatio());
        IStabilityPoolManager(proxy).updateFeeReceiver(treasury());
    }
}
