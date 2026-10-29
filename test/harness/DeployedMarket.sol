// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";

import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";

import {MarketReaderV2Lineage, MarketReaderV3Lineage} from "@harbor-test/harness/MarketReader.sol";
import {mcapMintersConfig} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";

import {MarketActions} from "@harbor-test/harness/MarketActions.sol";
import {MarketAddresses} from "@harbor-script/src/MarketAddresses.sol";
import {MarketUnderTest} from "@harbor-test/harness/MarketUnderTest.sol";
import {RuleMarketUpgradeRun} from "@harbor-test/harness/RuleMarketUpgradeRun.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/// @notice The market that is DEPLOYED, driven through its own proxies on a pinned fork.
///
/// Every other market here is built from the code in this tree, so each answers "what would this rule do?".
/// This one answers "what does the system people are holding today actually do?", which is the only question
/// a claim about a production regression can be settled against.
///
/// ADDRESSES COME FROM SALT STRINGS, never from a state file. It holds the production run - its salt prefix
/// and its market configs - and asks it the same `minterAddress(config)` / `stabilityPoolAddress(config, type)`
/// / `stabilityPoolManagerAddress(config)` getters the deploy itself uses, so a deployed address cannot drift
/// from the deploy that produced it and there is no second source of truth to keep in step.
/// `deployments/mainnet/*.state.json` is a RECORD to check against by hand;
/// `script/verify/deployment-state/StateFileAddressConsistency.t.sol` already proves the salts and the file
/// agree, which is what makes the salts trustworthy as the driver.
///
/// WHY MCAP::fxUSD. A measurement needs a market with CLEAN STATE, and this one was deployed and never used:
/// zero pegged, zero collateral, and an oracle address carrying no code at all. That is not the only way to
/// get clean state - forking at a block just after any market's deploy completed gives the same thing, and
/// is the general method - but an unused market is a deployment-block state that has simply persisted, so it
/// costs nothing to fork at a recent block instead of hunting one per market.
///
/// WHAT IS PATCHED, and why neither patch is a convenience:
///   - the ORACLE is replaced by `vm.etch`. It is not a proxy - its ERC1967 and beacon slots both read zero
///     - so there is no implementation to upgrade, and `updateConfig`-style setters are refused on
///     principle: a setter repoints one consumer and leaves the rest reading the real oracle, and it is a
///     configuration function that may be trimmed for size.
///   - the MANAGER is granted `ZERO_FEE_ROLE` on the minter. It does not have it, so it cannot redeem
///     fee-free and a rebalance would revert. That is a known defect of the original deployment, already
///     fixed forward in `script/src/contracts/Minter.sol` and already remediated for the live markets by
///     `script/Grant_Minter_ZeroFeeRoles_mainnet.s.sol` - unexecuted at this block. Applying it measures the
///     market as the fixed deploy builds it, rather than one whose rebalance is disabled by an ordering
///     accident. It would be needed at ANY block, including the deployment block: the grant was missing from
///     the deploy itself.
abstract contract DeployedMarket is Test, MarketUnderTest {
    /// @dev The production run, re-created for its identity alone: the salt prefix that makes its address
    ///      predictions the deployed addresses. It never deploys here, so it has no owner or treasury of its own.
    HarborDeployRun internal productionRun;

    uint256 internal constant FORK_BLOCK = 25272609;
    string internal constant SALT_PREFIX = "harbor_v1";

    /// @dev The price of the market's genesis, and the wrapped-to-underlying rate. Chosen rather than
    /// carried forward: this market's oracle was never deployed, so there is no prior answer to be
    /// consistent with.
    uint256 internal constant GENESIS_PRICE = 2000 ether;
    uint256 internal constant WRAP_RATE = 1 ether;
    uint256 internal constant GENESIS_TRANCHE = 500 ether;

    address internal deployedOwner;

    function marketLabel() internal pure virtual override returns (string memory) {
        return "_main";
    }

    function standUpMarket(
        uint256 collateralPoolShare,
        uint256 leveragedPoolShare,
        string memory runName
    ) internal virtual override returns (MarketAddresses memory) {
        _requireHoldersOutsidePools(collateralPoolShare, leveragedPoolShare);
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);
        // After the fork is selected, which would otherwise discard it.
        productionRun = new HarborDeployRun(address(0), address(0), SALT_PREFIX, "mainnet", HarborDeployRun.Cut.Whole);

        (, Config_MinterMarket[] memory markets) = mcapMintersConfig();
        Config_MinterMarket config = markets[0]; // MCAP::fxUSD

        // What is behind these proxies TODAY, until and unless the upgrade below moves them.
        reader = new MarketReaderV2Lineage(ConfigTokenNames(address(config)));

        market = productionRun.deployedMarketAddresses(config);
        actions = new MarketActions(market.minter);
        deployedOwner = IBaoOwnable(market.minter).owner();

        // The mock goes where the production minter reads its price - which the run checks is where it predicts - and
        // is priced as at the market's genesis.
        productionRun.installMockPriceOracle(config);
        MockWrappedPriceOracle(market.oracle).setLatestAnswer(GENESIS_PRICE, WRAP_RATE);

        // EITHER the market as deployed, OR the whole v3 upgrade. There is no third option and none can be
        // written here, which is the point: a candidate behind the minter proxy is a v3-family minter, and
        // the rest of the market has to move with it.
        //
        // Either way the manager's keeper bounty and harvest ratios are zeroed: the deployed manager carries the
        // production ones, where the local market's config zeroes them, so that a column read against a local run
        // compares the RULE and not the fee schedule - a deployed conversion paid its pool exactly 0.99 of fair value
        // before this, and the 0.01 was the bounty, not the rule.
        if (bytes(overrideLabel()).length > 0) {
            _upgradeMarketToV3(config, string.concat("test/fixtures/holders-", vm.toString(FORK_BLOCK), "/"));
            // The upgraded manager is v2, which sets each action's bounty ratio, bounty ceiling and cut ratio in one
            // call.
            vm.startPrank(IBaoOwnable(market.manager).owner());
            IStabilityPoolManager_v2(market.manager).updateRebalanceConfig(0, 0, 0);
            IStabilityPoolManager_v2(market.manager).updateHarvestConfig(0, 0, 0);
            vm.stopPrank();
        } else {
            // The deployed manager is v1, whose interface this is.
            vm.startPrank(IBaoOwnable(market.manager).owner());
            IStabilityPoolManager(market.manager).updateRebalanceBountyRatio(0);
            IStabilityPoolManager(market.manager).updateHarvestBountyRatio(0);
            IStabilityPoolManager(market.manager).updateHarvestCutRatio(0);
            vm.stopPrank();
        }

        vm.startPrank(deployedOwner);
        IBaoRoles(market.minter).grantRoles(market.manager, IMinter(market.minter).ZERO_FEE_ROLE());
        IBaoRoles(market.minter).grantRoles(address(this), IMinter(market.minter).ZERO_FEE_ROLE());
        vm.stopPrank();

        _mintGenesis();
        _fundInitialConditions(collateralPoolShare, leveragedPoolShare);
        _recordMarketProvenance(runName);
        return market;
    }

    /// @dev THE WHOLE v3 UPGRADE of the live market, as production will make it: `UpgradeMarketToV3`'s
    /// `upgradeMarketsToV3`, the function the upgrade script runs, with the holders the capture in `capture` lists.
    /// Minter, manager and BOTH pools move together - why none can move alone is written on the upgrade - and a
    /// caller cannot ask for part of it. Only the minter and the manager come from the rule under test
    /// (`RuleMarketUpgradeRun`), so a run measures the rule and nothing else.
    ///
    /// Upgrading in place leaves every address, role, balance and immutable exactly where it was, so what
    /// changes between this run and the un-upgraded one is the code and nothing else. The reader is replaced as
    /// part of the same step, so the market's dialect and its bytecode move together and cannot disagree.
    function _upgradeMarketToV3(Config_MinterMarket config, string memory capture) internal {
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
        markets[0] = config;
        new RuleMarketUpgradeRun(ruleUnderTest, markets, capture).run(SALT_PREFIX);
        reader = new MarketReaderV3Lineage();
    }

    function _mintGenesis() internal virtual {
        deal(market.wrappedCollateral, address(this), 2 * GENESIS_TRANCHE);
        IERC20(market.wrappedCollateral).approve(market.minter, type(uint256).max);
        IMinter(market.minter).freeMintPeggedToken(GENESIS_TRANCHE, address(this));
        IMinter(market.minter).freeMintLeveragedToken(GENESIS_TRANCHE, address(this));
    }

    /// @dev The genesis pegged, split between the pools as the run asked for. Whatever the two shares leave
    /// over stays here, an ordinary pegged holder beside the pools. The pools are the deployed ones or their v3
    /// upgrade, so the deposits go through the base `IStabilityPool`, whose `deposit` both versions carry.
    function _fundInitialConditions(uint256 collateralPoolShare, uint256 leveragedPoolShare) internal virtual {
        uint256 held = IERC20(market.pegged).balanceOf(address(this));
        IERC20(market.pegged).approve(market.collateralPool, type(uint256).max);
        IERC20(market.pegged).approve(market.leveragedPool, type(uint256).max);

        uint256 toCollateral = Math.mulDiv(held, collateralPoolShare, 1 ether);
        uint256 toLeveraged = Math.mulDiv(held, leveragedPoolShare, 1 ether);
        if (toCollateral > 0) {
            IStabilityPool(market.collateralPool).deposit(toCollateral, address(this), 0);
        }
        if (toLeveraged > 0) {
            IStabilityPool(market.leveragedPool).deposit(toLeveraged, address(this), 0);
        }
    }
}
