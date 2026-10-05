// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";

import {MarketReaderV3Lineage} from "@harbor-test/harness/MarketReader.sol";

import {TestMinterMarketConfig_rebalanceThreshold130} from "@harbor-test/config/TestMinterMarketConfig_rebalanceThreshold130.sol";
import {MarketAddresses} from "@harbor-test/harness/MarketAddresses.sol";
import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {MarketDeployRun} from "@harbor-test/harness/MarketDeployRun.sol";
import {MarketUnderTest} from "@harbor-test/harness/MarketUnderTest.sol";
import {TestStabilityPool2SetUp} from "@harbor-test/TestStabilityPool2SetUp.sol";

/// @notice A market built here, whole, by the real deploy chain, running this tree's rule.
///
/// The deploy chain is USED rather than reproduced - the tokens, the minter, both pools and the manager all come
/// from it, configured and granted their roles by it - so a measurement is run against what the deploy actually
/// produces and not against a fixture that resembles it. What this adds is what a test does to a market: mint its
/// genesis, and split the genesis pegged between the pools.
///
/// The manager is wired to the LEVERAGED POOL AND AN EMPTY COLLATERAL POOL, so a rebalance has only the
/// conversion to work with. The collateral leg is value-neutral below the peg by construction - it pays each
/// pegged token its share of the backing, which is the average, so burning some leaves the ratio where it
/// was - and including it would mix a leg that cannot recapitalise into a measurement of the one that can.
///
/// THE TREE'S RULE, AND NO OTHER. Nothing here puts another rule's minter or manager behind the ones the deploy
/// chain built, so a run that names another rule reverts, with its label, rather than measured as the tree under
/// that label.
abstract contract LocalMarket is TestStabilityPool2SetUp, MarketUnderTest {
    /// @dev The collateral each of the two genesis tranches puts in. Half to pegged and half to leveraged
    /// opens the market at a collateral ratio of two, which is the genesis `GraphsLiquidate` mints.
    ///
    /// The SAME figure as `DeployedMarket`'s genesis, deliberately: a graph comparing the two should compare
    /// raw columns, and a graph that has to normalise them is one where a mistake in the normalising cannot
    /// be told from a difference in the thing measured. The market size is an input here, so there is no
    /// reason to correct for it afterwards.
    uint256 internal constant GENESIS_TRANCHE = 500 ether;

    /// @notice The run names a rule other than the tree's, and a local market runs the tree's alone.
    error LocalMarketRunsOnlyTheTreesRule(string label);

    /// @dev The market cut - both pools and their manager - with the deployed market's rebalance threshold, and THE REAL
    /// `StabilityPool_v3` behind both pools, not the `MockStabilityPool` the pool unit tests' run installs. Those
    /// tests substitute the mock to reach `__totalSupply`, `__notifyLoss` and the rest; no measurement here touches
    /// any of them - they read balances, prices and ratios, every one of them public - so these graphs are produced
    /// by the bytecode a deploy installs.
    function newDeployRun() internal virtual override returns (MarketDeployRun) {
        return
            new MarketDeployRun(
                owner(),
                treasury(),
                HarborDeployRun.Cut.Market,
                new TestMinterMarketConfig_rebalanceThreshold130()
            );
    }

    function marketLabel() internal pure virtual override returns (string memory) {
        return "_local";
    }

    function standUpMarket(
        uint256 collateralPoolShare,
        uint256 leveragedPoolShare,
        string memory runName
    ) internal virtual override returns (MarketAddresses memory) {
        // Before the market is touched, so a run naming another rule measures nothing.
        string memory ruleLabel = overrideLabel();
        if (bytes(ruleLabel).length > 0) {
            revert LocalMarketRunsOnlyTheTreesRule(ruleLabel);
        }
        _requireHoldersOutsidePools(collateralPoolShare, leveragedPoolShare);
        // Everything here comes from THIS tree's deploy chain, so every question is asked the v3 way.
        reader = new MarketReaderV3Lineage();
        market = deployRun.marketAddresses(marketConfig);
        // The object the unit-test base made for this minter when it deployed it.
        actions = marketActions;

        // The harness mints the market's genesis with free mints: a test actor, which the deploy has no reason to
        // know of.
        vm.startPrank(owner());
        IBaoRoles(minter).grantRoles(address(this), IMinter(minter).ZERO_FEE_ROLE());
        vm.stopPrank();

        _mintGenesis();
        _fundInitialConditions(collateralPoolShare, leveragedPoolShare);
        _recordMarketProvenance(runName);
        return market;
    }

    /// @dev Half the collateral into pegged and half into leveraged, the same free mints as `GraphsLiquidate`'s
    /// genesis.
    function _mintGenesis() internal virtual {
        deal(address(wrappedCollateralToken), address(this), 2 * GENESIS_TRANCHE);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        IMinter(minter).freeMintPeggedToken(GENESIS_TRANCHE, address(this));
        IMinter(minter).freeMintLeveragedToken(GENESIS_TRANCHE, address(this));
    }

    /// @dev The genesis pegged, split between the pools as the run asked for - the starting state, which
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
