// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";

import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestStabilityPoolManagerSetUp_rebalanceThreshold130} from "@harbor-test/StabilityPoolManager.t.sol";

/// @notice A rebalance while the minter's record of its backing overstates what it holds.
///
/// A rebalance updates the market - it redeems the pools' pegged through the minter - so while the minter is halted
/// by an unrecognised impairment it reverts with the minter's own error, and `rebalanceable()` says so in advance
/// rather than inviting a keeper to send a transaction that will revert. The halt lifts, and the rebalance with it,
/// when the owner recognises the loss or when the rate recovers.
///
/// The market: 100 of collateral backing 200,000 pegged, and 25 more behind the leveraged tokens, at the mock's price
/// of 2,000 - a ratio of 1.25, below the 1.3 threshold and above the leverage floor, so it is rebalanceable.
contract StabilityPoolManagerImpairmentTest is TestStabilityPoolManagerSetUp_rebalanceThreshold130 {
    function setUp() public virtual override {
        super.setUp();
        setUp_collateral(100 ether, 25 ether, user);

        // a third of the pegged supply in each pool
        uint256 supply = IMinter(minter).peggedTokenBalance();
        vm.startPrank(user);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        IStabilityPool_v3(stabilityPoolCollateral).deposit(supply / 3, user, 0);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(supply / 3, user, 0);
        vm.stopPrank();
    }

    function _rate() private view returns (uint256 rate) {
        (, , rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
    }

    function _setRate(uint256 rate) private {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, rate);
    }

    /// @dev What `pool` is owed for all it can give - its deposits down to its floor: that pegged's share of the
    ///      backing. The record holds the backing in collateral, and a pool is paid in wrapped collateral, at the rate.
    /// @return wrapped The share as wrapped collateral, floored.
    /// @return unconverted The share left in collateral: what a payment that skipped the rate would be.
    function _owedForAllItCanGive(address pool) private view returns (uint256 wrapped, uint256 unconverted) {
        uint256 gives = IERC20(pool).totalSupply() - IStabilityPool_v3(pool).MIN_TOTAL_ASSET_SUPPLY();
        uint256 backing = IMinter(minter).collateralTokenBalance();
        uint256 supply = IMinter(minter).peggedTokenBalance();
        wrapped = Math.mulDiv(gives * backing, 1 ether, supply * _rate());
        unconverted = Math.mulDiv(gives, backing, supply);
    }

    /// A 1% fall in the rate: small enough to change nothing but whether the record is covered.
    function _impair() private {
        _setRate((_rate() * 99) / 100);
        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
        assertGt(recorded, held, "precondition: the record overstates the holding");
    }

    /// Below the threshold and impaired, the rebalance reverts with the minter's error and both figures.
    function test_rebalance_revertsWhileImpaired() public {
        assertLt(
            IMinter(minter).collateralRatio(),
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceThreshold(),
            "precondition: below the threshold"
        );
        _impair();
        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();

        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.UnrecognisedImpairment.selector, recorded, held));
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
    }

    /// Below the threshold, `rebalanceable()` is false while the market is impaired, so a keeper reading it does not
    /// send a rebalance that will revert.
    function test_rebalanceable_isFalseWhileImpaired() public {
        assertTrue(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "precondition: rebalanceable");

        _impair();

        assertLt(
            IMinter(minter).collateralRatio(),
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceThreshold(),
            "still below the threshold, as the record reports"
        );
        assertFalse(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "but not rebalanceable");
    }

    /// Recognising the loss lifts the halt: the market is rebalanceable again, and the rebalance runs.
    function test_rebalanceResumesAfterRecognition() public {
        _impair();

        vm.startPrank(owner());
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();

        assertTrue(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "rebalanceable again");
        uint256 ratioBefore = IMinter(minter).collateralRatio();
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
        assertGt(IMinter(minter).collateralRatio(), ratioBefore, "and the rebalance lifts the ratio");
    }

    /// A fall in the rate deep enough to put the market below the peg once it is recognised. Until then the market is
    /// halted and the rebalance reverts with the minter's error. Once the owner recognises the loss the rebalance runs
    /// there: it draws on both pools down to their floors and pays each its pegged's share of the backing, as wrapped
    /// collateral at the fallen rate.
    function test_onceALossThatPutsTheMarketBelowThePegIsRecognised_theRebalanceRuns() public {
        _setRate((_rate() * 70) / 100);
        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
        assertGt(recorded, held, "precondition: the record overstates the holding");
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.UnrecognisedImpairment.selector, recorded, held));
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);

        vm.startPrank(owner());
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();
        assertLt(IMinter(minter).collateralRatio(), 1 ether, "recognised, the market is below the peg");
        assertTrue(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "and a rebalance is offered");
        uint256 collateralPoolBefore = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        uint256 leveragedPoolBefore = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged);
        (uint256 collateralPoolOwed, uint256 collateralPoolUnconverted) = _owedForAllItCanGive(stabilityPoolCollateral);
        (uint256 leveragedPoolOwed, uint256 leveragedPoolUnconverted) = _owedForAllItCanGive(stabilityPoolLeveraged);

        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);

        assertEq(
            IERC20(stabilityPoolCollateral).totalSupply(),
            IStabilityPool_v3(stabilityPoolCollateral).MIN_TOTAL_ASSET_SUPPLY(),
            "the collateral pool gave up all it could"
        );
        assertEq(
            IERC20(stabilityPoolLeveraged).totalSupply(),
            IStabilityPool_v3(stabilityPoolLeveraged).MIN_TOTAL_ASSET_SUPPLY(),
            "the leveraged pool gave up all it could"
        );
        // The minter floors the two pools' wrapped collateral once, as one redemption. The manager splits it by the
        // pegged each pool gave up: it floors the collateral pool's part and gives the leveraged pool the rest. So
        // each payment is within a wei of its own floored share. The wrong value is that share left in collateral,
        // not converted at the fallen rate: three tenths less.
        assertDiscriminates(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral) - collateralPoolBefore,
            collateralPoolOwed,
            1,
            collateralPoolUnconverted,
            "the collateral pool is paid its pegged's share of the backing, as wrapped collateral"
        );
        assertDiscriminates(
            IERC20(wrappedCollateralToken).balanceOf(stabilityPoolLeveraged) - leveragedPoolBefore,
            leveragedPoolOwed,
            1,
            leveragedPoolUnconverted,
            "the leveraged pool is paid its pegged's share of the backing, as wrapped collateral"
        );
    }

    /// A minter that has lost its whole holding, and recognised the loss, has nothing to pay a pool with. No
    /// rebalance is offered, and one sent anyway takes nothing and reverts by the rebalance's own name.
    function test_onceALossOfTheWholeHoldingIsRecognised_noRebalanceIsOffered() public {
        uint256 wholeHolding = IERC20(wrappedCollateralToken).balanceOf(minter);
        vm.startPrank(minter);
        IERC20(wrappedCollateralToken).transfer(makeAddr("lost"), wholeHolding);
        vm.stopPrank();
        vm.startPrank(owner());
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();
        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
        assertEq(recorded, 0, "precondition: the minter has no backing on record");
        assertEq(held, 0, "precondition: and none in hand, so it is not halted");
        assertGt(IMinter(minter).peggedTokenBalance(), 0, "precondition: its pegged is still outstanding");
        assertGt(
            IStabilityPool_v3(stabilityPoolCollateral).maxAssetLoss(),
            0,
            "precondition: the collateral pool has deposits to give"
        );
        assertGt(
            IStabilityPool_v3(stabilityPoolLeveraged).maxAssetLoss(),
            0,
            "precondition: the leveraged pool has deposits to give"
        );

        assertFalse(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "no rebalance is offered");
        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager_v2.NoTokensToLiquidate.selector, peggedToken));
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
    }

    /// With both edges of the wrap rate at zero a wrapped token converts to no collateral, so no collateral leg is
    /// paid anything. Here, below the minter's floor, the rebalance's one step is the collateral route: it takes
    /// nothing and reverts by its own name, though the loss is unrecognised.
    function test_atAZeroRate_belowTheFloor_theRebalanceTakesNothing() public {
        marketActions.setCollateralRatioByPrice(0.9 ether);
        _setRate(0);
        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
        assertGt(recorded, held, "precondition: the loss is unrecognised");
        assertFalse(IMinter_v3(minter).leveragedMintable(), "precondition: the market sells no leverage");

        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager_v2.NoTokensToLiquidate.selector, peggedToken));
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
    }

    /// From the minter's floor the leveraged pool's pegged is converted, which a zero rate does not stop. So a
    /// redemption is sent, and the minter's guard on the unrecognised loss answers it: the minter's error is passed
    /// up.
    function test_atAZeroRate_withALeveragedLeg_theRebalanceRevertsWithTheMintersError() public {
        _setRate(0);
        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
        assertGt(recorded, held, "precondition: the loss is unrecognised");
        assertTrue(IMinter_v3(minter).leveragedMintable(), "precondition: the market sells leverage");

        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.UnrecognisedImpairment.selector, recorded, held));
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
    }

    /// Once a loss that took the rate to zero is recognised the minter has no backing on record. No rebalance is
    /// offered, and one sent anyway takes nothing and reverts by its own name.
    function test_atAZeroRate_onceRecognised_theRebalanceTakesNothing() public {
        _setRate(0);
        vm.startPrank(owner());
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();
        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
        assertEq(recorded, 0, "precondition: the minter has no backing on record");
        assertEq(held, 0, "precondition: and none in hand, so it is not halted");

        assertFalse(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "no rebalance is offered");
        vm.expectRevert(abi.encodeWithSelector(IStabilityPoolManager_v2.NoTokensToLiquidate.selector, peggedToken));
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
    }

    /// A rise in the wrap rate leaves the minter holding more than its record needs: yield, which a harvest takes.
    /// With the rate then at zero the minter reports nothing harvestable, so a harvest has nothing to take: none is
    /// reported by the manager, and one sent anyway reverts by its own name.
    function test_atAZeroRate_aHarvestHasNothingToTake() public {
        _setRate((_rate() * 110) / 100);
        assertGt(
            IStabilityPoolManager_v2(stabilityPoolManager).harvestable(),
            0,
            "precondition: at the risen rate there is yield to harvest"
        );
        _setRate(0);

        assertEq(IStabilityPoolManager_v2(stabilityPoolManager).harvestable(), 0, "nothing is harvestable");
        vm.expectRevert(IStabilityPoolManager_v2.NoHarvestable.selector);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(bountyReceiver, 0);
    }

    /// A rate that recovers lifts the halt with no owner call: the guard states a condition about the present.
    function test_rebalanceResumesWhenTheRateRecovers() public {
        uint256 rateBefore = _rate();
        _impair();

        _setRate(rateBefore);

        assertTrue(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "rebalanceable again");
        uint256 ratioBefore = IMinter(minter).collateralRatio();
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);
        assertGt(IMinter(minter).collateralRatio(), ratioBefore, "and the rebalance lifts the ratio");
    }
}
