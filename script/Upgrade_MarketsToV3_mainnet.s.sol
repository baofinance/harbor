// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";

import {allMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {UpgradeMarketToV3} from "@harbor-script/src/UpgradeMarketToV3.sol";

/// @dev The holder capture the live markets are upgraded from, made by `script/holders/capture-holders` to block
///      26,248,723 (its manifest's `to-block`), the last before the pause that froze every minter and pool.
string constant FROZEN_MARKETS_CAPTURE = "script/UpgradeStabilityPool_v2_v3/holders-26248723/";

/// @notice Upgrade every live market to Minter_v3, StabilityPool_v3 and StabilityPoolManager_v2, one Safe batch per
///         market, by the two steps of `UpgradeMarketToV3` the tests run: read each market from
///         `FROZEN_MARKETS_CAPTURE` at the last block before the pause that froze it, then deploy the new implementations
///         and save the batches at the chain's head.
/// @dev Rehearse on anvil, executing each batch as the multisig would, then run on mainnet:
///        script/run-script Upgrade_MarketsToV3_mainnet --salt harbor_v1 --network mainnet --broadcast --local
///        script/run-script Upgrade_MarketsToV3_mainnet --salt harbor_v1 --network mainnet --broadcast --account <name>
///      `script/verify/v3-upgrade/run-upgrade-before-after` runs the rehearsal and checks it.
contract Upgrade_MarketsToV3_mainnet is Script, UpgradeMarketToV3 {
    function build() internal override {
        // The config objects are script-side inputs, created outside the broadcast so they are not deployed.
        MarketUpgradeInput[] memory inputs = readFrozenMarketUpgradeInputs(
            allMintersConfig(),
            FROZEN_MARKETS_CAPTURE,
            "mainnet"
        );

        vm.startBroadcast();
        upgradeMarketsToV3(inputs, "mainnet");
        vm.stopBroadcast();
    }
}
