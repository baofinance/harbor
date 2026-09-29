// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";

import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestStabilityPoolManagerSetUp} from "@harbor-test/StabilityPoolManager.t.sol";

/// @notice A rebalance while the minter's record of its backing overstates what it holds.
///
/// A rebalance updates the market - it redeems the pools' pegged through the minter - so while the minter is halted
/// by an unrecognised impairment it is refused with the minter's own error, and `rebalanceable()` says so in advance
/// rather than inviting a keeper to send a transaction that will revert. The halt lifts, and the rebalance with it,
/// when the owner recognises the loss or when the rate recovers.
///
/// The market: 100 of collateral backing 200,000 pegged, and 25 more behind the leveraged tokens, at the mock's price
/// of 2,000 - a ratio of 1.25, below the 1.3 threshold and above the leverage floor, so it is rebalanceable.
contract StabilityPoolManagerImpairmentTest is TestStabilityPoolManagerSetUp {
    uint256 private constant THRESHOLD = 1.3 ether;

    function setUp() public virtual override {
        super.setUp();
        vm.startPrank(owner());
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceThreshold(THRESHOLD);
        IStabilityPoolManager_v2(stabilityPoolManager).updateRebalanceBountyRatio(0);
        vm.stopPrank();
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

    /// A 1% fall in the rate: small enough to change nothing but whether the record is covered.
    function _impair() private {
        _setRate((_rate() * 99) / 100);
        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
        assertGt(recorded, held, "precondition: the record overstates the holding");
    }

    /// Below the threshold and impaired, the rebalance is refused with the minter's error and both figures, and the
    /// pools keep their pegged.
    function test_rebalance_revertsWhileImpaired() public {
        assertLt(IMinter(minter).collateralRatio(), THRESHOLD, "precondition: below the threshold");
        _impair();
        uint256 collateralPoolPegged = IERC20(peggedToken).balanceOf(stabilityPoolCollateral);
        uint256 leveragedPoolPegged = IERC20(peggedToken).balanceOf(stabilityPoolLeveraged);
        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();

        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.UnrecognisedImpairment.selector, recorded, held));
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(bountyReceiver, 0);

        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), collateralPoolPegged, "collateral pool kept");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolLeveraged), leveragedPoolPegged, "leveraged pool kept");
    }

    /// Below the threshold, `rebalanceable()` is false while the market is impaired, so a keeper reading it does not
    /// send a rebalance that will revert.
    function test_rebalanceable_isFalseWhileImpaired() public {
        assertTrue(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "precondition: rebalanceable");

        _impair();

        assertLt(IMinter(minter).collateralRatio(), THRESHOLD, "still below the threshold, as the record reports");
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
