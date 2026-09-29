// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";

import {MarketDeployRun} from "@harbor-test/harness/MarketDeployRun.sol";
import {MockStabilityPool} from "@harbor-test/mocks/MockStabilityPool.sol";

/// @notice A `MarketDeployRun` that puts `MockStabilityPool` behind each stability pool it deploys:
///         `StabilityPool_v3` plus the `__`-prefixed accessors the pool unit tests read internals through.
/// @dev The implementation hook is the deploy chain's mock seam, so everything else - the proxy, the reward
///      tokens, the roles - is the deploy's own. Everything the constructor needs still comes from the market
///      config, so a pool deployed here is the one the deploy script would produce, bar the accessors.
contract MockStabilityPoolMarketDeployRun is MarketDeployRun {
    constructor(address owner_, address treasury_, Scope scope_) MarketDeployRun(owner_, treasury_, scope_) {}

    function deployStabilityPoolImplementation(
        DeploymentTypes.State memory stateData,
        string memory key,
        StabilityPoolType poolType,
        Config_MinterMarket marketConfig_,
        address minter_
    ) internal virtual override returns (address impl) {
        ConfigTokenNames names = ConfigTokenNames(address(marketConfig_));
        bool isCollateral = poolType == StabilityPoolType.Collateral;
        string memory tokenName = isCollateral
            ? names.stabilityPoolCollateralName()
            : names.stabilityPoolLeveragedName();
        string memory tokenSymbol = isCollateral
            ? names.stabilityPoolCollateralSymbol()
            : names.stabilityPoolLeveragedSymbol();

        IHarborConfig cfg = IHarborConfig(address(marketConfig_));

        impl = address(
            new MockStabilityPool(
                minter_,
                cfg.stabilityPoolWithdrawalDelay(),
                cfg.stabilityPoolWithdrawalPeriod(),
                cfg.minTotalSupply(),
                tokenName,
                tokenSymbol
            )
        );

        _recordImplementation(stateData, key, "@harbor-test/mocks/MockStabilityPool.sol", "MockStabilityPool", impl);
    }
}
