// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {StabilityPoolManager_v2} from "@harbor/minter/StabilityPoolManager_v2.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {MarketReaderV3Lineage} from "@harbor-test/harness/MarketReader.sol";

import {MarketAddresses} from "@harbor-test/harness/MarketAddresses.sol";
import {MarketDeployRun} from "@harbor-test/harness/MarketDeployRun.sol";
import {MarketUnderTest} from "@harbor-test/harness/MarketUnderTest.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestStabilityPool2SetUp} from "@harbor-test/TestStabilityPool2SetUp.sol";

/// @notice A market built here, by the real deploy chain, with whatever implementation a measurement wants
///         behind the minter.
///
/// The deploy chain is USED rather than reproduced - the pools, the tokens and the minter all come from it -
/// so a measurement is run against what the deploy actually produces and not against a fixture that
/// resembles it. What this adds is the manager, which the base chain does not deploy, and the override seam.
///
/// The manager is wired to the LEVERAGED POOL AND AN EMPTY COLLATERAL POOL, so a rebalance has only the
/// conversion to work with. The collateral leg is value-neutral below the peg by construction - it pays each
/// pegged token its share of the backing, which is the average, so burning some leaves the ratio where it
/// was - and including it would mix a leg that cannot recapitalise into a measurement of the one that can.
abstract contract LocalMarket is TestStabilityPool2SetUp, MarketUnderTest {
    /// @dev The collateral each of the two founding tranches puts in. Half to pegged and half to leveraged
    /// opens the market at a collateral ratio of two, which is what `GraphsLiquidate` founds with.
    ///
    /// The SAME figure `DeployedMarket` founds with, deliberately: a graph comparing the two should compare
    /// raw columns, and a graph that has to normalise them is one where a mistake in the normalising cannot
    /// be told from a difference in the thing measured. The market size is an input here, so there is no
    /// reason to correct for it afterwards.
    uint256 internal constant FOUNDING_TRANCHE = 500 ether;

    uint256 internal startCollateralRatio;
    uint256 internal startPriceLocal;

    /// @dev THE REAL `StabilityPool_v3` behind both pools, not the `MockStabilityPool` the pool unit tests' run
    /// installs. Those tests substitute the mock to reach `__totalSupply`, `__notifyLoss` and the rest; no
    /// measurement here touches any of them - they read balances, prices and ratios, every one of them public -
    /// so these graphs are produced by the bytecode a deploy installs.
    function newDeployRun() internal virtual override returns (MarketDeployRun) {
        return new MarketDeployRun(owner(), treasury(), MarketDeployRun.Scope.BothPools);
    }

    function marketLabel() internal pure virtual override returns (string memory) {
        return "_local";
    }

    function marketOwner() internal view override returns (address) {
        return owner();
    }

    function _asOwner() internal override {
        vm.startPrank(owner());
    }

    function _stopAsOwner() internal override {
        vm.stopPrank();
    }

    function standUpMarket(
        uint256 collateralPoolShare,
        uint256 leveragedPoolShare,
        string memory runName
    ) internal virtual override returns (MarketAddresses memory) {
        _requireHoldersOutsidePools(collateralPoolShare, leveragedPoolShare);
        // Everything here comes from THIS tree's deploy chain, so every question is asked the v3 way.
        reader = new MarketReaderV3Lineage();
        market.minter = minter;
        // The object the unit-test base made for this minter when it deployed it.
        actions = marketActions;
        market.pegged = peggedToken;
        market.leveraged = leveragedToken;
        market.wrappedCollateral = wrappedCollateralToken;
        market.oracle = priceOracle;
        market.leveragedPool = stabilityPoolLeveraged;

        // The override goes in BEFORE the market is founded, because the escrow per leveraged token is
        // written by the first mint into an empty supply - a rule installed afterwards would inherit a
        // figure the rule it replaced had chosen.
        installMinterOverride();

        // The collateral pool the DEPLOY CHAIN stood up, not one built here. `_setupStabilityPool` assembles
        // a pool by hand with the withdrawal window hardcoded instead of read from the market config, which
        // is deploy logic reproduced in a test and a pool that differs from the deployed one in its
        // configuration as well as its bytecode. Nothing deposits into this pool unless a measurement asks
        // for a collateral share, so the inherited one is already the empty pool this wants.
        market.collateralPool = stabilityPoolCollateral;
        market.manager = UnsafeUpgrades.deployUUPSProxy(
            ruleUnderTest.buildManager(minter, market.collateralPool, stabilityPoolLeveraged),
            abi.encodeCall(StabilityPoolManager_v2.initialize, (address(this), owner()))
        );
        IStabilityPoolManager(market.manager).updateRebalanceThreshold(1.3 ether);

        vm.startPrank(owner());
        IBaoRoles(market.collateralPool).grantRoles(
            market.manager,
            IStabilityPool(market.collateralPool).REBALANCER_ROLE()
        );
        IBaoRoles(stabilityPoolLeveraged).grantRoles(
            market.manager,
            IStabilityPool(stabilityPoolLeveraged).REBALANCER_ROLE()
        );
        IBaoRoles(minter).grantRoles(market.manager, IMinter(minter).ZERO_FEE_ROLE());
        IBaoRoles(minter).grantRoles(address(this), IMinter(minter).ZERO_FEE_ROLE());
        vm.stopPrank();

        _foundMarket();
        _fundInitialConditions(collateralPoolShare, leveragedPoolShare);

        startCollateralRatio = IMinter(minter).collateralRatio();
        (startPriceLocal, , , ) = MockWrappedPriceOracle(priceOracle).latestAnswer();
        _recordMarketProvenance(runName);
        return market;
    }

    /// @dev Half the collateral into pegged and half into leveraged, the same free mints `GraphsLiquidate`
    /// founds its market with.
    function _foundMarket() internal virtual {
        deal(address(wrappedCollateralToken), address(this), 2 * FOUNDING_TRANCHE);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IMinter(minter).freeMintPeggedToken(FOUNDING_TRANCHE, address(this));
        IMinter(minter).freeMintLeveragedToken(FOUNDING_TRANCHE, address(this));
    }

    /// @dev The founding pegged, split between the pools as the run asked for - the starting state, which
    /// the harness owns so that two measurements of this market begin from the same place. Whatever the two
    /// shares leave over stays here, an ordinary pegged holder beside the pools.
    function _fundInitialConditions(uint256 collateralPoolShare, uint256 leveragedPoolShare) internal virtual {
        uint256 held = IERC20(peggedToken).balanceOf(address(this));
        IERC20(peggedToken).approve(market.collateralPool, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);

        uint256 toCollateral = Math.mulDiv(held, collateralPoolShare, 1 ether);
        uint256 toLeveraged = Math.mulDiv(held, leveragedPoolShare, 1 ether);
        if (toCollateral > 0) {
            IStabilityPool(market.collateralPool).deposit(toCollateral, address(this), 0);
        }
        if (toLeveraged > 0) {
            IStabilityPool(stabilityPoolLeveraged).deposit(toLeveraged, address(this), 0);
        }
    }
}
