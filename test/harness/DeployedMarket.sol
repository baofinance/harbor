// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {StabilityPoolManager_v2} from "@harbor/minter/StabilityPoolManager_v2.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";

import {MarketReaderV2Lineage, MarketReaderV3Lineage} from "@harbor-test/harness/MarketReader.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {mcapMintersConfig} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";

import {MarketActions} from "@harbor-test/harness/MarketActions.sol";
import {MarketUnderTest} from "@harbor-test/harness/MarketUnderTest.sol";
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

    /// @dev The price the market is founded at, and the wrapped-to-underlying rate. Chosen rather than
    /// carried forward: this market's oracle was never deployed, so there is no prior answer to be
    /// consistent with.
    uint256 internal constant FOUNDING_PRICE = 2000 ether;
    uint256 internal constant WRAP_RATE = 1 ether;
    uint256 internal constant FOUNDING_TRANCHE = 500 ether;

    address internal deployedOwner;

    function marketLabel() internal pure virtual override returns (string memory) {
        return "_main";
    }

    function marketOwner() internal view override returns (address) {
        return deployedOwner;
    }

    function _asOwner() internal override {
        vm.startPrank(deployedOwner);
    }

    function _stopAsOwner() internal override {
        vm.stopPrank();
    }

    function standUpMarket(
        uint256 collateralPoolShare,
        uint256 leveragedPoolShare,
        string memory runName
    ) internal virtual override returns (Market memory) {
        _requireHoldersOutsidePools(collateralPoolShare, leveragedPoolShare);
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);
        // After the fork is selected, which would otherwise discard it.
        productionRun = new HarborDeployRun(address(0), address(0), SALT_PREFIX, "mainnet");

        (, Config_MinterMarket[] memory markets) = mcapMintersConfig();
        Config_MinterMarket config = markets[0]; // MCAP::fxUSD

        // What is behind these proxies TODAY, until and unless the upgrade below moves them.
        reader = new MarketReaderV2Lineage(ConfigTokenNames(address(config)));

        market.minter = productionRun.minterAddress(config);
        marketActions = new MarketActions(market.minter);
        market.collateralPool = productionRun.stabilityPoolAddress(config, HarborDeployer.StabilityPoolType.Collateral);
        market.leveragedPool = productionRun.stabilityPoolAddress(config, HarborDeployer.StabilityPoolType.Leveraged);
        market.manager = productionRun.stabilityPoolManagerAddress(config);
        market.pegged = IMinter(market.minter).PEGGED_TOKEN();
        market.leveraged = IMinter(market.minter).LEVERAGED_TOKEN();
        market.wrappedCollateral = IMinter(market.minter).WRAPPED_COLLATERAL_TOKEN();
        market.oracle = IMinter(market.minter).priceOracle();
        deployedOwner = IBaoOwnable(market.minter).owner();

        // `vm.etch` copies CODE, not storage, so the mock's constructor has not run and its fields are zero
        // until they are set here.
        vm.etch(market.oracle, address(new MockWrappedPriceOracle()).code);
        MockWrappedPriceOracle(market.oracle).setLatestAnswer(FOUNDING_PRICE, WRAP_RATE);

        // EITHER the market as deployed, OR the whole v3 upgrade. There is no third option and none can be
        // written here, which is the point: a candidate behind the minter proxy is a v3-family minter, and
        // the rest of the market has to move with it.
        if (bytes(overrideLabel()).length > 0) {
            _upgradeMarketToV3(config);
        } else {
            // The deployed manager carries the production keeper bounty and harvest cut - one percent each -
            // and the managers the harness builds carry none. Zeroed, so that a column read against a local
            // run compares the RULE and not the fee schedule: a deployed conversion paid its pool exactly 0.99
            // of fair value before this, and the 0.01 was the bounty, not the rule.
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

        _foundMarket();
        _fundInitialConditions(collateralPoolShare, leveragedPoolShare);
        _recordMarketProvenance(runName);
        return market;
    }

    /// @dev THE WHOLE v3 UPGRADE, IN ONE FUNCTION, because there is no smaller one that works. Minter,
    /// manager and BOTH pools move together; a caller cannot ask for part of it.
    ///
    /// Each dependency here was found the hard way, which is why they are written down rather than left to be
    /// rediscovered:
    ///
    ///   - The MANAGER must move with the minter. The deployed manager speaks v2: it calls
    ///     `redeemPeggedForCollateralRatio(uint256)`, selector `0x510d20e7`, which `Minter_v3` replaced with a
    ///     five-argument version - so the deployed manager's first call into an upgraded minter reverts on an
    ///     unrecognised selector. Measured, not assumed: that selector is present on `Minter_v2` and absent
    ///     from `Minter_v3`.
    ///   - BOTH POOLS must move with the manager. `StabilityPoolManager_v2.rebalance` calls `maxAssetLoss()`
    ///     on each pool, unconditionally and whatever their balances, and that function is declared only on
    ///     `IStabilityPool_v3`. A new manager over deployed pools reverts on the first rebalance.
    ///
    /// The second of those was found only because the old pools happen to LACK that selector. Had they
    /// carried it with different meaning, this market would have produced numbers and we would have plotted
    /// them. That is the reason this is one function instead of three calls a caller must remember to make.
    ///
    /// The implementations are built HERE while the proxies are the ones on chain, which is the general
    /// shape: only the contract whose behaviour is measured need be deployed bytecode. Upgrading in place
    /// leaves every address, role, balance and immutable exactly where it was, so what changes between this
    /// run and the un-upgraded one is the code and nothing else.
    /// @dev The pool implementations are built from names the CURRENT reader supplies - the v2 one, since
    /// that is what is behind the proxies until the line after. Its answers come from the config, because a
    /// v2 pool is not an ERC20 and cannot be asked. The reader is replaced as part of the same step, so the
    /// market's dialect and its bytecode move together and cannot disagree.
    function _upgradeMarketToV3(Config_MinterMarket config) internal {
        // The minter FIRST, and inside this function rather than beside it. It was once called separately,
        // and when this function was introduced the separate call was dropped by accident - the pools and the
        // manager moved, the minter stayed on `Minter_v2`, and the market reverted on a selector the manager
        // expected it to have. One function that performs the whole upgrade is what stops that being possible
        // a second time.
        installMinterOverride();

        address collateralImplementation = _buildStabilityPool(config, market.collateralPool, true);
        address leveragedImplementation = _buildStabilityPool(config, market.leveragedPool, false);

        _asOwner();
        UUPSUpgradeable(market.collateralPool).upgradeToAndCall(collateralImplementation, "");
        UUPSUpgradeable(market.leveragedPool).upgradeToAndCall(leveragedImplementation, "");
        _stopAsOwner();

        _replaceManager();
        reader = new MarketReaderV3Lineage();
    }

    /// @dev A `StabilityPool_v3` implementation for an EXISTING pool proxy.
    ///
    /// WHERE EACH ARGUMENT COMES FROM IS THE WHOLE OF THIS FUNCTION. The two withdrawal figures come from the
    /// market CONFIG, exactly as the deploy script reads them, and not off the proxy - they are immutables
    /// declared on no interface, so reading them back would mean guessing which version is behind that proxy
    /// today, which is the mistake this upgrade exists to stop being possible. The floor comes off the proxy
    /// through the BASE `IStabilityPool`, which every deployed version implements. The deployed pool's
    /// liquidation token is not carried over: a v3 pool has none, the rebalancer naming one of the pool's
    /// registered reward tokens per liquidation, and the proxy keeps its registrations across the upgrade.
    function _buildStabilityPool(
        Config_MinterMarket config,
        address pool,
        bool isCollateralPool
    ) internal returns (address) {
        IHarborConfig cfg = IHarborConfig(address(config));
        return
            address(
                new StabilityPool_v3(
                    market.minter,
                    cfg.stabilityPoolWithdrawalDelay(),
                    cfg.stabilityPoolWithdrawalPeriod(),
                    IStabilityPool(pool).MIN_TOTAL_ASSET_SUPPLY(),
                    reader.poolName(pool, isCollateralPool),
                    reader.poolSymbol(pool, isCollateralPool)
                )
            );
    }

    /// @dev A manager from THIS tree - or the rule's own, via `buildManager` - constructed with the deployed
    /// minter proxy and the deployed pools, and granted the roles the deployed one holds. The pools grant
    /// `REBALANCER` and the minter `ZERO_FEE`.
    function _replaceManager() private {
        market.manager = UnsafeUpgrades.deployUUPSProxy(
            ruleUnderTest.buildManager(market.minter, market.collateralPool, market.leveragedPool),
            abi.encodeCall(StabilityPoolManager_v2.initialize, (address(this), deployedOwner))
        );
        IStabilityPoolManager(market.manager).updateRebalanceThreshold(1.3 ether);

        vm.startPrank(deployedOwner);
        IBaoRoles(market.collateralPool).grantRoles(
            market.manager,
            IStabilityPool(market.collateralPool).REBALANCER_ROLE()
        );
        IBaoRoles(market.leveragedPool).grantRoles(
            market.manager,
            IStabilityPool(market.leveragedPool).REBALANCER_ROLE()
        );
        IBaoRoles(market.minter).grantRoles(market.manager, IMinter(market.minter).ZERO_FEE_ROLE());
        vm.stopPrank();
    }

    function _foundMarket() internal virtual {
        deal(market.wrappedCollateral, address(this), 2 * FOUNDING_TRANCHE);
        IERC20(market.wrappedCollateral).approve(market.minter, type(uint256).max);
        IMinter(market.minter).freeMintPeggedToken(FOUNDING_TRANCHE, address(this));
        IMinter(market.minter).freeMintLeveragedToken(FOUNDING_TRANCHE, address(this));
    }

    /// @dev The founding pegged, split between the pools as the run asked for. Whatever the two shares leave
    /// over stays here, an ordinary pegged holder beside the pools.
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

    function setMarketCollateralRatio(uint256 target) internal virtual override {
        MockWrappedPriceOracle(market.oracle).setLatestAnswer(
            Math.mulDiv(
                target,
                IMinter(market.minter).peggedTokenBalance(),
                IMinter(market.minter).collateralTokenBalance()
            ),
            WRAP_RATE
        );
    }
}
