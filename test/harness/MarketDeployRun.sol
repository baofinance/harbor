// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {TestMinterMarketConfig} from "@harbor-test/config/TestMinterMarketConfig.sol";
import {ConfigPeg, ConfigPeg_BTC} from "@harbor-script/config/pegs/ConfigPeg_BTC.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

/// @notice The deploy run behind the unit-test suites: one minter market on the BTC peg, built from the test
///         market config by the real deploy chain, to the scope a suite asks for.
/// @dev A test HOLDS one of these rather than inheriting the deploy framework (see `HarborDeployRun`). The scope
///      is identity, fixed at construction: what this run deploys is stated here, in one place, rather than
///      assembled by each level of a test class hierarchy adding a step. The identities (owner, treasury) come
///      from the test that holds the run, so the test can prank as them.
contract MarketDeployRun is HarborDeployRun {
    /// @notice How far along the market's dependency order the run deploys. Each scope includes those before
    ///         it, which is the only way the contracts can be stood up: a pool reads the minter, and the
    ///         manager is wired to both pools.
    enum Scope {
        Minter, // the peg's pegged token, then the market's leveraged token, reserve pool and minter
        CollateralPool, // ... and the stability pool that takes wrapped collateral
        BothPools, // ... and the one that takes the leveraged token
        Market // ... and the manager that coordinates the two
    }

    /// @dev The market this run deploys: a production configuration with only the incentive config made
    ///      settable, so a suite's choice reaches the minter by the deploy's own path.
    TestMinterMarketConfig public immutable marketConfig;

    Scope public immutable scope;

    constructor(
        address owner_,
        address treasury_,
        Scope scope_
    ) HarborDeployRun(owner_, treasury_, "minter_test", "mainnet") {
        marketConfig = new TestMinterMarketConfig();
        scope = scope_;
    }

    /// @notice Deploy the market to this run's scope: the factory if it is not there yet, the peg's token, then
    ///         the market's contracts in dependency order.
    /// @dev `ensureFactory` registers THIS run as the factory operator, the account the deploy then calls the
    ///      factory from. Call it after the fork is selected: a fork switch discards the registration.
    function deployMinterMarket() external {
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = marketConfig;

        ensureFactory();
        deploy(new ConfigPeg_BTC(), markets, true, markets);
    }

    /// @dev Phase 2 of the deploy run, cut at the scope: the prefix of production's dependency order
    ///      (`deployMinterInfrastructure`) that the scope names, and nothing above it - what is not deployed is
    ///      not paid for. `deployPeg` is ignored: the minter cannot be built without its peg's token.
    function _deployAndConfigure(
        DeploymentTypes.State memory state,
        ConfigPeg peg,
        Config_MinterMarket[] memory allMarkets,
        bool,
        Config_MinterMarket[] memory marketsToDeploy
    ) internal virtual override {
        Config_MinterMarket market = marketsToDeploy[0];

        deployPeggedTokenWithRoles(state, peg, allMarkets);

        _deployLeveragedTokenWithRoles(state, market);
        deployReservePool(state, market);
        deployMinter(state, market);
        if (_scopeIncludes(Scope.CollateralPool)) {
            deployStabilityPool(StabilityPoolType.Collateral, state, market);
        }
        if (_scopeIncludes(Scope.BothPools)) {
            deployStabilityPool(StabilityPoolType.Leveraged, state, market);
        }
        if (_scopeIncludes(Scope.Market)) {
            deployStabilityPoolManager(state, market);
        }
    }

    function _scopeIncludes(Scope step) private view returns (bool) {
        return uint8(scope) >= uint8(step);
    }
}
