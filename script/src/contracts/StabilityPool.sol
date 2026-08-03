// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";

/// @notice Harbor StabilityPool deployment logic.
/// @dev Each market has TWO stability pools: Collateral (wrapped collateral) and Leveraged (leveraged token).
/// @dev Both pools grant: REBALANCER_ROLE, REWARD_DEPOSITOR_ROLE to StabilityPoolManager.
abstract contract StabilityPool is HarborDeployer {
    // ========== STABILITY POOL DEPLOYMENT ==========

    /// @notice Deploy StabilityPool impl only, record in state.
    /// @dev Uniform with every other implementation function: `(stateData, key, …)` first, then what this
    ///      constructor needs. Reading non-address values off the config is fine here — the invariant this
    ///      layer keeps is that no ADDRESS resolution happens in it, so a test override never has to
    ///      reproduce address prediction. Both addresses arrive already resolved.
    function deployStabilityPoolImplementation(
        DeploymentTypes.State memory stateData,
        string memory key,
        StabilityPoolType poolType,
        Config_MinterMarket marketConfig,
        address minter,
        address liquidationToken
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
                minter,
                liquidationToken,
                cfg.stabilityPoolWithdrawalDelay(),
                cfg.stabilityPoolWithdrawalPeriod(),
                cfg.minTotalSupply(),
                tokenName,
                tokenSymbol
            )
        );
        _reportImplementation(impl);
        _reportToken(tokenName, tokenSymbol);

        _recordImplementation(stateData, key, "@harbor/minter/StabilityPool_v3.sol", "StabilityPool_v3", impl);
    }

    /// @notice Deploy StabilityPool impl+proxy, record in state.
    function deployStabilityPool(
        StabilityPoolType poolType,
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig,
        address minter,
        address liquidationToken
    ) internal returns (address proxy) {
        string memory spKey = stabilityPoolKey(marketConfig, poolType);
        _reportContract(spKey);

        address impl = deployStabilityPoolImplementation(
            stateData,
            spKey,
            poolType,
            marketConfig,
            minter,
            liquidationToken
        );

        IHarborConfig cfg = IHarborConfig(address(marketConfig));
        bytes memory initData = abi.encodeCall(
            StabilityPool_v3.initialize,
            (address(this), owner(), cfg.stabilityPoolEarlyWithdrawalFeeRatio(), treasury())
        );

        proxy = _deployProxyAndRecord(stateData, spKey, impl, initData);
    }

    /// @notice Grant StabilityPool roles to StabilityPoolManager.
    /// @param poolType Which of the market's two stability pools.
    function grantStabilityPoolRoles(Config_MinterMarket marketConfig, StabilityPoolType poolType) internal {
        string memory spKey = stabilityPoolKey(marketConfig, poolType);
        address sp = stabilityPoolAddress(marketConfig, poolType);

        // SPM gets REBALANCER + REWARD_DEPOSITOR
        address spm = stabilityPoolManagerAddress(marketConfig);
        StabilityPool_v3 pool = StabilityPool_v3(sp);
        uint256 roles = pool.REBALANCER_ROLE() | pool.REWARD_DEPOSITOR_ROLE();
        _grantRoles(spKey, sp, spm, "stabilityPoolManager", roles, "REBALANCER | REWARD_DEPOSITOR");
    }
}
