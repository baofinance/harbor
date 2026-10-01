// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigMarket_ETH_fxUSD_mainnet} from "@harbor-script/config/markets/ConfigMarket_ETH_fxUSD_mainnet.sol";

/// @notice ETH::fxUSD market with the StabilityPoolManager's harvest cut and harvest/rebalance bounties zeroed, so all
/// yield and rewards flow to depositors - a suite measuring the pool mechanics, as the envelope's conservation and
/// read-back assertions do, is then not perturbed by a keeper bounty or a protocol cut. A test-only variant of the
/// production market, changed through the deployment config (the config-axis approach) rather than an imperative
/// setter in setUp.
contract ConfigMarket_ETH_fxUSD_zeroFeesAndBounties is ConfigMarket_ETH_fxUSD_mainnet {
    function harvestCutRatio() public pure virtual override returns (uint256) {
        return 0;
    }

    function harvestBountyRatio() public pure virtual override returns (uint256) {
        return 0;
    }

    function rebalanceBountyRatio() public pure override returns (uint256) {
        return 0;
    }
}
