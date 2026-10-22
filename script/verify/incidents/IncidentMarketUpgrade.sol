// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";

import {MarketUpgradeRun} from "@harbor-test/harness/MarketUpgradeRun.sol";
import {StabilityPool_v3WithV2Claims} from "@harbor-script/verify/incidents/StabilityPool_v3WithV2Claims.sol";

/// @notice The production upgrade of live markets whose pools are `StabilityPool_v3WithV2Claims`, so an exploit
///         written against StabilityPool_v2 replays on them. Everything else is the production upgrade's.
contract IncidentMarketUpgrade is MarketUpgradeRun {
    constructor(Config_MinterMarket[] memory markets_, string memory capture_) MarketUpgradeRun(markets_, capture_) {}

    /// @dev The deploy's pool implementation, with StabilityPool_v2's claim forms put back. Everything the constructor
    ///      takes comes from the market config, as the deploy's own function takes it.
    function deployStabilityPoolImplementation(
        DeploymentTypes.State memory stateData,
        string memory key,
        StabilityPoolType poolType,
        Config_MinterMarket marketConfig,
        address minter
    ) internal override returns (address impl) {
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
            new StabilityPool_v3WithV2Claims(
                minter,
                cfg.stabilityPoolWithdrawalDelay(),
                cfg.stabilityPoolWithdrawalPeriod(),
                cfg.aboutADollar(),
                tokenName,
                tokenSymbol
            )
        );

        _recordImplementation(
            stateData,
            key,
            "@harbor-script/verify/incidents/StabilityPool_v3WithV2Claims.sol",
            "StabilityPool_v3WithV2Claims",
            impl
        );
    }
}
