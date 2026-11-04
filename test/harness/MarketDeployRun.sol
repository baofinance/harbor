// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {TestMinterMarketConfig} from "@harbor-test/config/TestMinterMarketConfig.sol";
import {ConfigPeg_BTC} from "@harbor-script/config/pegs/ConfigPeg_BTC.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

/// @notice The deploy run behind the unit-test suites: one minter market on the BTC peg, built from the test
///         market config by the real deploy chain, to the cut a suite asks for.
/// @dev A test HOLDS one of these rather than inheriting the deploy framework (see `HarborDeployRun`). The cut is
///      identity, fixed at construction: what this run deploys is stated here, in one place, rather than
///      assembled by each level of a test class hierarchy adding a step. The identities (owner, treasury) come
///      from the test that holds the run, so the test can prank as them.
contract MarketDeployRun is HarborDeployRun {
    /// @dev The market this run deploys: a production configuration with only the incentive config made
    ///      settable, so a suite's choice reaches the minter by the deploy's own path. Identity, like the cut:
    ///      a suite whose market differs in configuration names the config that says how.
    TestMinterMarketConfig public immutable marketConfig;

    constructor(
        address owner_,
        address treasury_,
        Cut cut_,
        TestMinterMarketConfig marketConfig_
    ) HarborDeployRun(owner_, treasury_, "minter_test", "mainnet", cut_) {
        marketConfig = marketConfig_;
    }

    /// @notice Deploy the market to this run's cut: the factory if it is not there yet, the peg's token, then the
    ///         market's contracts the cut names.
    /// @dev `ensureFactory` registers THIS run as the factory operator, the account the deploy then calls the
    ///      factory from. Call it after the fork is selected: a fork switch discards the registration.
    function deployMinterMarket() external {
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = marketConfig;

        ensureFactory();
        deploy(new ConfigPeg_BTC(), markets, true, markets);
    }
}
