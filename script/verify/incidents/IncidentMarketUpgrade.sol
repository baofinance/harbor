// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {UpgradeMarketToV3} from "@harbor-script/src/UpgradeMarketToV3.sol";

import {StabilityPool_v3WithV2Claims} from "@harbor-script/verify/incidents/StabilityPool_v3WithV2Claims.sol";

/// @notice The production upgrade of one exploited market, for running on a fork before its exploit:
///         `upgradeMarketsToV3`, the function the upgrade script runs, given this market and the holder capture at the
///         exploit's block. Its pools are `StabilityPool_v3WithV2Claims`, so the exploit, written against
///         StabilityPool_v2, replays on them.
/// @dev Held by the report and driven through the deploy base's own entry point, `run(saltPrefix)`, which under forge
///      test executes the batch as the owner - the Harbor multisig, which owns the live proxies.
contract IncidentMarketUpgrade is UpgradeMarketToV3 {
    Config_MinterMarket private immutable _market;
    string private _capture;

    constructor(Config_MinterMarket market_, string memory capture_) {
        _market = market_;
        _capture = capture_;
    }

    function build() internal override {
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = _market;
        upgradeMarketsToV3(markets, _capture, "mainnet");
    }

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
