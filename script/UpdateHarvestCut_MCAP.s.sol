// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {Market} from "@harbor-script/config/ConfigBase.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {ConfigMarket_MCAP_fxUSD_mainnet} from "@harbor-script/config/markets/ConfigMarket_MCAP_fxUSD_mainnet.sol";
import {ConfigMarket_MCAP_stETH_mainnet} from "@harbor-script/config/markets/ConfigMarket_MCAP_stETH_mainnet.sol";

/// @notice Bring the two MCAP markets' harvest cut down to the configured ratio.
/// @dev Both MCAP stability pool managers hold a cut of 100% alongside a bounty of 1%, so the two sum to 101% - the
///      pair the deploy config carried before it was corrected. The bounty and the cut are slices of the same harvest
///      gross, so a pair over 100% describes a split that does not exist: StabilityPoolManager_v1 underflows working
///      out what is left for the pools, and so would v2. Every other market already sums to exactly 100%.
///      Run BEFORE the StabilityPoolManager_v2 upgrade - v2 has no single-ratio setter to repair a stored pair with,
///      only `updateHarvestRatios`, which takes both.
///      Run with: ./script/safe-batch UpdateHarvestCut_MCAP --salt harbor_v1
contract UpdateHarvestCut_MCAP is Script, HarborDeployer {
    function build() internal override {
        queue(
            stabilityPoolManagerKey(Market("MCAP", "fxUSD")),
            abi.encodeCall(
                IStabilityPoolManager.updateHarvestCutRatio,
                (new ConfigMarket_MCAP_fxUSD_mainnet().harvestCutRatio())
            ),
            "updateHarvestCutRatio(configured)"
        );
        queue(
            stabilityPoolManagerKey(Market("MCAP", "stETH")),
            abi.encodeCall(
                IStabilityPoolManager.updateHarvestCutRatio,
                (new ConfigMarket_MCAP_stETH_mainnet().harvestCutRatio())
            ),
            "updateHarvestCutRatio(configured)"
        );
    }
}
