// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";

import {frozenMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {CompensateRebalanceDilution} from "@harbor-script/src/CompensateRebalanceDilution.sol";

/// @dev The holder capture the live markets are upgraded from, made by `script/holders/capture-holders` to block
///      26,248,723 (its manifest's `to-block`), the last before the pause that froze every minter and pool.
string constant FROZEN_MARKETS_CAPTURE = "script/UpgradeStabilityPool_v2_v3/holders-26248723/";

/// @dev The compensation files the incident's report wrote for the two markets the rebalance dilution exploits of
///      2026-10-16 hit, and where the upgrade writes the payout it queued from them.
string constant BTC_STETH_COMPENSATION = "doc/incidents/2026-10-16-rebalance-dilution/BTC-stETH-compensation.json";
string constant EUR_STETH_COMPENSATION = "doc/incidents/2026-10-16-rebalance-dilution/EUR-stETH-compensation.json";
string constant PAYOUT_REPORT = "doc/incidents/2026-10-16-rebalance-dilution/phase1.md";

/// @notice Upgrade every live market to Minter_v3, StabilityPool_v3 and StabilityPoolManager_v2, one Safe batch per
///         market, by the two steps of `UpgradeMarketToV3` the tests run: read each market from
///         `FROZEN_MARKETS_CAPTURE` at the last block before the pause that froze it, then deploy the new implementations
///         and save the batches at the chain's head. The two exploited markets' batches carry their compensation
///         (`CompensateRebalanceDilution`), read from the incident's files.
/// @dev Rehearse on anvil, executing each batch as the multisig would, then run on mainnet:
///        script/run-script Upgrade_MarketsToV3_mainnet --salt harbor_v1 --network mainnet --broadcast --local
///        script/run-script Upgrade_MarketsToV3_mainnet --salt harbor_v1 --network mainnet --broadcast --account <name>
///      `script/verify/v3-upgrade/run-upgrade-rehearsal` runs the rehearsal and checks it.
contract Upgrade_MarketsToV3_mainnet is Script, CompensateRebalanceDilution {
    function build() internal override {
        // The config objects are script-side inputs, created outside the broadcast so they are not deployed.
        MarketUpgradeInput[] memory inputs = readFrozenMarketUpgradeInputs(
            frozenMintersConfig(),
            FROZEN_MARKETS_CAPTURE,
            "mainnet"
        );
        MarketCompensation[] memory compensated = new MarketCompensation[](2);
        compensated[0] = readCompensation(BTC_STETH_COMPENSATION);
        compensated[1] = readCompensation(EUR_STETH_COMPENSATION);
        FrozenMarket[] memory frozen = readFrozenMarkets(compensated, FROZEN_MARKETS_CAPTURE, "mainnet");
        Payout memory payout = compensate(inputs, compensated, frozen);

        vm.startBroadcast();
        upgradeMarketsToV3(inputs, "mainnet");
        vm.stopBroadcast();

        writePayoutReport(PAYOUT_REPORT, compensated, payout);
    }
}
