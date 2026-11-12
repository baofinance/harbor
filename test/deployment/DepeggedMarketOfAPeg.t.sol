// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {MarketAddresses} from "@harbor-script/src/MarketAddresses.sol";
import {DeployEURSetUp} from "@harbor-test/deployment/DeployEURSetUp.t.sol";
import {MarketActions} from "@harbor-test/harness/MarketActions.sol";

/// @notice The markets of a peg share one pegged token and nothing else. When one of them falls below the peg, a
///         rebalance there draws on that market's own pools, at its own price, and the other market is as it was:
///         what it has minted, its backing, its pools, and what it pays a redeemer.
/// @dev EUR::fxUSD is the market that falls below the peg. EUR::stETH stays above its threshold. Each is opened with
///      100 of collateral behind its pegged tokens and 50 behind its leveraged tokens, at a price and a rate of one: a
///      ratio of 1.5. The holder deposits 30 pegged in each of EUR::fxUSD's pools and 20 in each of EUR::stETH's.
contract DepeggedMarketOfAPegTest is DeployEURSetUp {
    /// @dev A market as a holder of the pegged token finds it.
    struct MarketState {
        uint256 minted;
        uint256 backing;
        uint256 collateralRatio;
        uint256 collateralPoolSupply;
        uint256 leveragedPoolSupply;
        uint256 collateralPoolPegged;
        uint256 leveragedPoolPegged;
        uint256 redemptionQuote;
    }

    address private holder = makeAddr("holder");
    address private keeper = makeAddr("keeper");

    function setUp() public override {
        super.setUp();
        _open(fxUSD);
        _open(stETH);
        _deposit(fxUSD.collateralPool, 30 ether);
        _deposit(fxUSD.leveragedPool, 30 ether);
        _deposit(stETH.collateralPool, 20 ether);
        _deposit(stETH.leveragedPool, 20 ether);
    }

    /// A rebalance of the market below the peg draws on that market's pools alone and redeems their pegged tokens at
    /// that market's minter alone: the other market's record, pools and redemption quote are unchanged, and the pegged
    /// token's supply falls by exactly what the rebalance took.
    function test_aRebalanceOfTheMarketBelowThePeg_leavesTheOtherMarketAsItWas() public {
        MarketActions belowThePeg = new MarketActions(fxUSD.minter);
        belowThePeg.setCollateralRatioByPrice(0.9 ether);
        MarketState memory fxUSDBefore = _stateOf(fxUSD);
        MarketState memory stETHBefore = _stateOf(stETH);
        uint256 peggedSupplyBefore = IERC20(pegged).totalSupply();
        assertLt(fxUSDBefore.collateralRatio, 1 ether, "precondition: one market is below the peg");
        assertGe(
            stETHBefore.collateralRatio,
            IStabilityPoolManager_v2(stETH.manager).rebalanceThreshold(),
            "precondition: the other is at or above its threshold"
        );
        // Each of its pools gives up what it has had deposited, down to its floor.
        uint256 fxUSDPoolsCanGive = fxUSDBefore.collateralPoolSupply +
            fxUSDBefore.leveragedPoolSupply -
            IStabilityPool_v3(fxUSD.collateralPool).MIN_TOTAL_ASSET_SUPPLY() -
            IStabilityPool_v3(fxUSD.leveragedPool).MIN_TOTAL_ASSET_SUPPLY();

        vm.startPrank(keeper);
        uint256 taken = IStabilityPoolManager_v2(fxUSD.manager).rebalance(keeper, 0);
        vm.stopPrank();

        assertEq(taken, fxUSDPoolsCanGive, "the market below the peg takes all its own pools can give");
        assertEq(
            IMinter(fxUSD.minter).peggedTokenBalance(),
            fxUSDBefore.minted - taken,
            "its minter redeems what its pools gave up"
        );
        assertEq(
            IERC20(pegged).totalSupply(),
            peggedSupplyBefore - taken,
            "the pegged token's supply falls by what was taken, and no more"
        );

        MarketState memory stETHAfter = _stateOf(stETH);
        assertEq(stETHAfter.minted, stETHBefore.minted, "the other market's minter has minted what it had");
        assertEq(stETHAfter.backing, stETHBefore.backing, "its backing is unchanged");
        assertEq(stETHAfter.collateralRatio, stETHBefore.collateralRatio, "its collateral ratio is unchanged");
        assertEq(
            stETHAfter.collateralPoolSupply,
            stETHBefore.collateralPoolSupply,
            "its collateral pool's deposits are unchanged"
        );
        assertEq(
            stETHAfter.leveragedPoolSupply,
            stETHBefore.leveragedPoolSupply,
            "its leveraged pool's deposits are unchanged"
        );
        assertEq(
            stETHAfter.collateralPoolPegged,
            stETHBefore.collateralPoolPegged,
            "its collateral pool holds the pegged tokens it held"
        );
        assertEq(
            stETHAfter.leveragedPoolPegged,
            stETHBefore.leveragedPoolPegged,
            "its leveraged pool holds the pegged tokens it held"
        );
        assertGt(stETHBefore.redemptionQuote, 0, "precondition: the other market pays a redeemer");
        assertEq(stETHAfter.redemptionQuote, stETHBefore.redemptionQuote, "and pays a redeemer what it paid before");
    }

    /// @dev Open `market` at a ratio of 1.5: 50 of collateral behind leveraged tokens, then 100 behind pegged tokens,
    ///      both minted to the holder at no fee.
    function _open(MarketAddresses memory market) private {
        uint256 collateralForLeveraged = 50 ether;
        deal(market.wrappedCollateral, address(this), collateralForLeveraged);
        IERC20(market.wrappedCollateral).approve(market.minter, collateralForLeveraged);
        IMinter(market.minter).freeMintLeveragedToken(collateralForLeveraged, holder);
        _mintPegged(market.minter, holder, 100 ether);
    }

    function _deposit(address pool, uint256 amount) private {
        vm.startPrank(holder);
        IERC20(pegged).approve(pool, amount);
        IStabilityPool_v3(pool).deposit(amount, holder, amount);
        vm.stopPrank();
    }

    function _stateOf(MarketAddresses memory market) private view returns (MarketState memory state) {
        state.minted = IMinter(market.minter).peggedTokenBalance();
        state.backing = IMinter(market.minter).collateralTokenBalance();
        state.collateralRatio = IMinter(market.minter).collateralRatio();
        state.collateralPoolSupply = IStabilityPool_v3(market.collateralPool).totalAssetSupply();
        state.leveragedPoolSupply = IStabilityPool_v3(market.leveragedPool).totalAssetSupply();
        state.collateralPoolPegged = IERC20(pegged).balanceOf(market.collateralPool);
        state.leveragedPoolPegged = IERC20(pegged).balanceOf(market.leveragedPool);
        (, , , , state.redemptionQuote, , ) = IMinter(market.minter).redeemPeggedTokenDryRun(10 ether);
    }
}
