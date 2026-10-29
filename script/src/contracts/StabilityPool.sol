// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";
import {MarketAddresses} from "@harbor-script/src/MarketAddresses.sol";

/// @notice Harbor StabilityPool deployment logic.
/// @dev Each market has TWO stability pools: Collateral (wrapped collateral) and Leveraged (leveraged token).
/// @dev Both pools grant: REBALANCER_ROLE, REWARD_DEPOSITOR_ROLE to StabilityPoolManager.
///
/// @dev `deployStabilityPool` deploys AND configures: it registers the pool's reward tokens and grants
///      the manager's roles, because those are part of standing a pool up rather than a later step a
///      caller must remember. It needs nothing else deployed: the minter, the pegged token and the manager are
///      predicted addresses, and the pool's constructor calls none of them.
abstract contract StabilityPool is HarborDeployer {
    // ========== STABILITY POOL DEPLOYMENT ==========

    /// @notice Deploy StabilityPool impl only, record in state.
    /// @dev Uniform with every other implementation function: `(stateData, key, …)` first, then what this
    ///      constructor needs. Reading non-address values off the config is fine here — the invariant this
    ///      layer keeps is that no ADDRESS resolution happens in it, so a test override never has to
    ///      reproduce address prediction. The addresses arrive already resolved, and are taken by name.
    function deployStabilityPoolImplementation(
        DeploymentTypes.State memory stateData,
        string memory key,
        StabilityPoolType poolType,
        Config_MinterMarket marketConfig,
        MarketAddresses memory addresses
    ) internal virtual returns (address impl) {
        ConfigTokenNames names = ConfigTokenNames(address(marketConfig));
        bool isCollateral = poolType == StabilityPoolType.Collateral;
        string memory tokenName = isCollateral
            ? names.stabilityPoolCollateralName()
            : names.stabilityPoolLeveragedName();
        string memory tokenSymbol = isCollateral
            ? names.stabilityPoolCollateralSymbol()
            : names.stabilityPoolLeveragedSymbol();

        IHarborConfig cfg = IHarborConfig(address(marketConfig));

        impl = address(
            new StabilityPool_v3(
                addresses.minter,
                addresses.pegged,
                cfg.stabilityPoolWithdrawalDelay(),
                cfg.stabilityPoolWithdrawalPeriod(),
                cfg.aboutADollarInPegged(),
                tokenName,
                tokenSymbol
            )
        );
        _reportImplementation(impl);
        _reportToken(tokenName, tokenSymbol);

        _recordImplementation(stateData, key, "@harbor/minter/StabilityPool_v3.sol", "StabilityPool_v3", impl);
    }

    /// @notice Deploy one of a market's two stability pools: impl+proxy, its reward tokens, its roles.
    /// @param poolType Which of the market's two stability pools.
    function deployStabilityPool(
        StabilityPoolType poolType,
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig
    ) internal returns (address proxy) {
        string memory spKey = stabilityPoolKey(marketConfig, poolType);
        _reportContract(spKey);

        IHarborConfig cfg = IHarborConfig(address(marketConfig));
        MarketAddresses memory addresses = marketAddresses(marketConfig);

        address impl = deployStabilityPoolImplementation(stateData, spKey, poolType, marketConfig, addresses);

        bytes memory initData = abi.encodeCall(
            StabilityPool_v3.initialize,
            (deployerOwner(), owner(), cfg.stabilityPoolEarlyWithdrawalFeeRatio(), treasury())
        );

        proxy = _deployProxyAndRecord(stateData, spKey, impl, initData);

        // A pool's type lives in the reward tokens it distributes, which are the tokens a rebalance may pay it
        // in. Both pools earn harvest rewards in wrapped collateral, and either may be paid collateral by a
        // rebalance where the market sells no leverage; the leveraged pool is additionally paid the leveraged
        // token where it does.
        IMultipleRewardDistributor(proxy).registerRewardToken(addresses.wrappedCollateral);
        if (poolType == StabilityPoolType.Leveraged) {
            IMultipleRewardDistributor(proxy).registerRewardToken(addresses.leveraged);
        }

        // The manager rebalances into the pool and deposits its rewards. It is not deployed yet — this is
        // its predicted address — but the ROLES are read off this pool, which is why the grant lives here:
        // the pool exists by this line, and nothing above it needs to.
        _grantRoles(
            spKey,
            proxy,
            addresses.manager,
            "stabilityPoolManager",
            IStabilityPool_v3(proxy).REBALANCER_ROLE() | IMultipleRewardDistributor(proxy).REWARD_DEPOSITOR_ROLE(),
            "REBALANCER | REWARD_DEPOSITOR"
        );
    }
}
