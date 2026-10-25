// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";

import {allMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {UpgradeMarketToV3} from "@harbor-script/src/UpgradeMarketToV3.sol";

/// @notice Upgrade every live market to Minter_v3, StabilityPool_v3 and StabilityPoolManager_v2, one Safe batch per
///         market, by the two steps of `UpgradeMarketToV3` the tests run: read each market at the last block before
///         the pause that froze it, then deploy the new implementations and save the batches at the chain's head.
/// @dev Capture the holders to the last block before the pause, then run with the capture:
///        script/holders/capture-holders --to-block <block> --out-dir <capture>
///        HOLDERS_DIR=<capture> script/run-script Upgrade_MarketsToV3_mainnet --salt harbor_v1 --network mainnet --broadcast
///      The capture used for the live markets is `UpgradeStabilityPool_v2_v3/holders-26248723/`, beside the upgrader.
contract Upgrade_MarketsToV3_mainnet is Script, UpgradeMarketToV3 {
    function build() internal override {
        // The config objects are script-side inputs, created outside the broadcast so they are not deployed.
        MarketUpgradeInput[] memory inputs = readFrozenMarketUpgradeInputs(
            allMintersConfig(),
            vm.envString("HOLDERS_DIR"),
            "mainnet"
        );

        vm.startBroadcast();
        upgradeMarketsToV3(inputs, "mainnet");
        vm.stopBroadcast();
    }
}
