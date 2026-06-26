// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {HarborDeployStack} from "@harbor-script/src/HarborDeployStack.sol";

/// @title MinterDeploySetUp
/// @notice Shared base for deploy-test setups that stand up a Minter stack via the real deploy scripts.
///         It owns the byte-identical scaffolding — factory bootstrap, optional fork, salt prefix, and the
///         `deployHarborForPeg` call — so no `setUp()` re-implements it. A concrete setup derives from BOTH this
///         base AND the peg-specific deploy chain (e.g. `Deploy_ETH_Minter` / `Deploy_EUR_Minter`), then
///         implements only the hooks for what genuinely differs. Both this base and the peg deploy chain
///         extend `HarborDeployStack`; C3 linearization shares the single (stateless) deploy mixin.
/// @dev Mock-install ordering matters. `_beforeDeploy` runs after `_setSaltPrefix` but BEFORE `deployHarborForPeg`
///      — for predicted-address dependencies that must already exist while the chain deploys (`vm.etch` a
///      mock oracle/swapper at its consumer getter). `_afterDeploy` runs after the deploy — for post-deploy
///      work: resolve addresses, install a mock via a setter (`updatePriceOracle`), grant the test contract
///      roles, fund it, and run any downstream deploy. (HarborYield's deploy lives in harbor-yield, which
///      this harbor-side base cannot reference, so harbor-yield setups do it in their `_afterDeploy`.)
abstract contract MinterDeploySetUp is BaoTest, HarborDeployStack {
    /// @notice Fork block to pin; return 0 for a no-fork (local) setup. Default: no fork.
    function _forkBlock() internal view virtual returns (uint256) {
        return 0;
    }

    /// @notice Salt prefix that namespaces this deployment's CREATE3 addresses.
    function _saltPrefix() internal view virtual returns (string memory);

    /// @notice Network string passed to the deploy scripts. Default: "mainnet".
    function _network() internal view virtual returns (string memory) {
        return "mainnet";
    }

    /// @notice The peg, the full market set, and the subset to actually deploy.
    function _mintersConfig()
        internal
        virtual
        returns (ConfigPeg peg, Config_MinterMarket[] memory allMarkets, Config_MinterMarket[] memory marketsToDeploy);

    /// @notice Install mocks that must already exist DURING `deployHarborForPeg` (predicted-address oracles/swapper
    ///         installed with `vm.etch` at the consumer's getter address).
    // solhint-disable-next-line no-empty-blocks
    function _beforeDeploy(ConfigPeg peg, Config_MinterMarket[] memory allMarkets) internal virtual {}

    /// @notice Post-deploy work: resolve addresses, install a mock via setter, grant the test contract its
    ///         roles, fund it, and run any downstream deploy (HarborYield, in harbor-yield setups).
    // solhint-disable-next-line no-empty-blocks
    function _afterDeploy(ConfigPeg peg, Config_MinterMarket[] memory allMarkets) internal virtual {}

    function setUp() public virtual {
        address factory = _ensureBaoFactory();
        uint256 forkBlock = _forkBlock();
        if (forkBlock != 0) {
            vm.createSelectFork(vm.rpcUrl("mainnet"), forkBlock);
        }
        vm.prank(IBaoFactory(factory).owner());
        IBaoFactory(factory).setOperator(address(this), 365 days);

        (
            ConfigPeg peg,
            Config_MinterMarket[] memory allMarkets,
            Config_MinterMarket[] memory marketsToDeploy
        ) = _mintersConfig();
        _setSaltPrefix(_saltPrefix());
        _beforeDeploy(peg, allMarkets);
        deployHarborForPeg(_saltPrefix(), peg, allMarkets, _network(), true, marketsToDeploy);
        _afterDeploy(peg, allMarkets);
    }
}
