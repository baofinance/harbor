// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {allMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {StabilityPoolManager} from "@harbor-script/src/contracts/StabilityPoolManager.sol";

/// @notice Set every market's stability pool manager's harvest and rebalance terms to what its market config gives:
///         each action's bounty ratio, bounty ceiling and cut ratio, in one Safe batch.
/// @dev For managers running StabilityPoolManager_v2; the v3 upgrade's batches set these terms first. Run it when a
///      market config's terms change - for a ceiling, when the price of the wrapped collateral has moved far from what
///      its `aboutADollarInWrappedCollateral` assumes.
///      Rehearse on anvil, executing the batch as the multisig would, then save it for the multisig:
///        script/run-script UpdateHarvestAndRebalanceConfig_AllMarkets --salt harbor_v1 --network mainnet --broadcast --local
///        script/run-script UpdateHarvestAndRebalanceConfig_AllMarkets --salt harbor_v1 --network mainnet
contract UpdateHarvestAndRebalanceConfig_AllMarkets is Script, StabilityPoolManager {
    function build() internal override {
        Config_MinterMarket[] memory markets = allMintersConfig();
        for (uint256 i = 0; i < markets.length; ++i) {
            queueStabilityPoolManagerConfig(markets[i]);
        }
    }
}
