// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {Minter} from "@harbor-script/src/contracts/Minter.sol";
import {StabilityPool} from "@harbor-script/src/contracts/StabilityPool.sol";
import {StabilityPoolManager} from "@harbor-script/src/contracts/StabilityPoolManager.sol";
import {StabilityPool_v3_Upgrader} from "@harbor-script/UpgradeStabilityPool_v2_v3/StabilityPool_v3_Upgrader.sol";

/// @notice The upgrade of live markets from Minter_v2, StabilityPool_v2 and StabilityPoolManager_v1 to the versions
///         this tree deploys - Minter_v3, StabilityPool_v3 and StabilityPoolManager_v2 - in one function,
///         `upgradeMarketsToV3`, which the upgrade script and the tests both run.
/// @dev A market's four proxies move in one batch for the multisig, because none works beside the others' old
///      versions: the old manager calls a minter function Minter_v3 replaced, and the new manager calls a pool function
///      only StabilityPool_v3 has. Each implementation is built by the deploy's own function, from the addresses a fresh
///      deploy predicts, so the upgrade installs what a fresh deploy would.
///
///      Each pool goes through `StabilityPool_v3_Upgrader`, never a plain upgrade: v3 keeps the reward streams and
///      each holder's reward snapshot in widened storage, which the upgrader copies across, and divides rewards by what
///      the holders hold, which needs the pool's ledger gap. Both come from a holder capture, read while the pools are
///      frozen.
abstract contract UpgradeMarketToV3 is Minter, StabilityPool, StabilityPoolManager {
    /// @dev What this run does, named once so its opening and closing lines cannot drift apart.
    string private constant _WHAT = "upgrade to Minter_v3, StabilityPool_v3 and StabilityPoolManager_v2";

    /// @notice Upgrade each of `markets`: deploy its new implementations and its pools' upgrader, and save, as one
    ///         batch for the multisig, the upgrade of its minter, its two pools - through the upgrader, with every
    ///         holder the capture in `capture` lists - and its manager, in that order.
    /// @dev The deployment state is made as every deploy run makes it: the state file when the run persists, a fresh
    ///      state when it does not.
    function upgradeMarketsToV3(
        Config_MinterMarket[] memory markets,
        string memory capture,
        string memory network
    ) internal {
        DeploymentTypes.State memory state = _shouldPersistState()
            ? DeploymentState.load(_stateFileRead())
            : DeploymentState.fresh(saltPrefix(), network);
        state.baoFactory = baoFactory();
        _reportRun(_WHAT, saltPrefix(), network);

        for (uint256 i = 0; i < markets.length; ++i) {
            Config_MinterMarket config = markets[i];
            address minter = minterAddress(config);
            address minterImplementation = deployMinterImplementation(
                state,
                minterKey(config),
                IHarborConfig(address(config)).wrappedCollateralToken(),
                peggedTokenAddress(config),
                leveragedTokenAddress(config)
            );
            address managerImplementation = deployStabilityPoolManagerImplementation(
                state,
                stabilityPoolManagerKey(config),
                minter,
                stabilityPoolAddress(config, StabilityPoolType.Collateral),
                stabilityPoolAddress(config, StabilityPoolType.Leveraged)
            );
            // The upgrader upgrades each pool away from itself in the call that runs it, so it serves both pools.
            address upgrader = address(new StabilityPool_v3_Upgrader(owner()));

            queue(
                minterKey(config),
                abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (minterImplementation, "")),
                "upgrade to Minter_v3"
            );
            _queuePoolMigration(state, config, StabilityPoolType.Collateral, capture, upgrader);
            _queuePoolMigration(state, config, StabilityPoolType.Leveraged, capture, upgrader);
            queue(
                stabilityPoolManagerKey(config),
                abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (managerImplementation, "")),
                "upgrade to StabilityPoolManager_v2"
            );

            string memory market = MinterMarketConfigLib.salt(config);
            flush(market, string.concat(market, ": ", _WHAT));
        }

        _saveState(state);
        _reportRunComplete(_WHAT);
    }

    /// @dev Queue the `poolType` pool's migration through `upgrader` to a new StabilityPool_v3 implementation, with
    ///      every holder the capture lists and the ledger gap they leave: the pool's supply less what they hold, read
    ///      now. Refuses a capture whose holders leave a gap the capture's rule calls incomplete.
    function _queuePoolMigration(
        DeploymentTypes.State memory state,
        Config_MinterMarket config,
        StabilityPoolType poolType,
        string memory capture,
        address upgrader
    ) private {
        string memory key = stabilityPoolKey(config, poolType);
        address pool = stabilityPoolAddress(config, poolType);
        address implementation = deployStabilityPoolImplementation(state, key, poolType, config, minterAddress(config));

        address[] memory holders = HolderCaptureLib.holders(capture, key);
        uint256 held;
        for (uint256 i = 0; i < holders.length; ++i) {
            held += IStabilityPool(pool).assetBalanceOf(holders[i]);
        }
        uint256 supply = IStabilityPool(pool).totalAssetSupply();
        int256 gap = int256(supply) - int256(held);
        require(
            HolderCaptureLib.classify(gap, supply) != HolderCaptureLib.Gap.Incomplete,
            string.concat(
                key,
                ": the captured holders hold ",
                LibString.toString(held),
                " of a supply of ",
                LibString.toString(supply),
                ", leaving more unheld than rounding allows"
            )
        );

        queue(
            key,
            abi.encodeCall(
                UUPSUpgradeable.upgradeToAndCall,
                (upgrader, abi.encodeCall(StabilityPool_v3_Upgrader.migrateAndUpgrade, (gap, holders, implementation)))
            ),
            "migrate through StabilityPool_v3_Upgrader to StabilityPool_v3"
        );
    }
}
