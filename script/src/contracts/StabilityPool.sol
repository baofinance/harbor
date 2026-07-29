// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";

/// @notice Config interface for stability pool deployment parameters.
interface IStabilityPoolMarketConfig {
    function stabilityPoolWithdrawalDelay() external pure returns (uint256);
    function stabilityPoolWithdrawalPeriod() external pure returns (uint256);
    function stabilityPoolEarlyWithdrawalFeeRatio() external pure returns (uint256);
    function minTotalSupply() external view returns (uint256);
}

/// @notice Harbor StabilityPool deployment logic.
/// @dev Each market has TWO stability pools: Collateral (wrapped collateral) and Leveraged (leveraged token).
/// @dev Both pools grant: REBALANCER_ROLE, REWARD_DEPOSITOR_ROLE to StabilityPoolManager.
abstract contract StabilityPool is HarborDeployer {
    // ========== STABILITY POOL DEPLOYMENT ==========

    /// @notice Deploy StabilityPool impl only, record in state.
    function deployStabilityPoolImplementation(
        StabilityPoolType poolType,
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig,
        address minter,
        address liquidationToken
    ) internal virtual returns (address impl) {
        string memory marketKey = MinterMarketConfigLib.salt(marketConfig);
        string memory spKey = stabilityPoolKey(marketKey, poolType);
        console.log("    > %s", spKey);

        ConfigTokenNames names = ConfigTokenNames(address(marketConfig));
        bool isCollateral = poolType == StabilityPoolType.Collateral;
        string memory tokenName = isCollateral
            ? names.stabilityPoolCollateralName()
            : names.stabilityPoolLeveragedName();
        string memory tokenSymbol = isCollateral
            ? names.stabilityPoolCollateralSymbol()
            : names.stabilityPoolLeveragedSymbol();

        IStabilityPoolMarketConfig cfg = IStabilityPoolMarketConfig(address(marketConfig));

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
        console.log("        Impl:   %s", impl);
        console.log("          Name:   %s", tokenName);
        console.log("          Symbol: %s", tokenSymbol);

        _recordImplementation(stateData, spKey, "@harbor/minter/StabilityPool_v3.sol", "StabilityPool_v3", impl);
    }

    /// @notice Deploy StabilityPool impl+proxy, record in state.
    function deployStabilityPool(
        StabilityPoolType poolType,
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig,
        address minter,
        address liquidationToken
    ) internal returns (address proxy) {
        string memory marketKey = MinterMarketConfigLib.salt(marketConfig);
        string memory spKey = stabilityPoolKey(marketKey, poolType);
        console.log("    > %s", spKey);

        address impl = deployStabilityPoolImplementation(poolType, stateData, marketConfig, minter, liquidationToken);

        IStabilityPoolMarketConfig cfg = IStabilityPoolMarketConfig(address(marketConfig));
        bytes memory initData = abi.encodeCall(
            StabilityPool_v3.initialize,
            (address(this), owner(), cfg.stabilityPoolEarlyWithdrawalFeeRatio(), treasury())
        );

        proxy = _deployProxyAndRecord(stateData, spKey, impl, initData);
    }

    /// @notice Grant StabilityPool roles to StabilityPoolManager.
    /// @param marketKey The market salt key (e.g., "ETH::fxUSD").
    /// @param poolType Which of the market's two stability pools.
    function grantStabilityPoolRoles(string memory marketKey, StabilityPoolType poolType) internal {
        string memory spKey = stabilityPoolKey(marketKey, poolType);
        address sp = stabilityPoolAddress(marketKey, poolType);

        // SPM gets REBALANCER + REWARD_DEPOSITOR
        address spm = stabilityPoolManagerAddress(marketKey);
        StabilityPool_v3 pool = StabilityPool_v3(sp);
        uint256 roles = pool.REBALANCER_ROLE() | pool.REWARD_DEPOSITOR_ROLE();
        _grantRoles(spKey, sp, spm, "stabilityPoolManager", roles, "REBALANCER | REWARD_DEPOSITOR");
    }
}
