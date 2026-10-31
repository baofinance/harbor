// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";

/// @title MarketHarvestCheck - what a market's harvest must pay
/// @notice A keeper's harvest of a market, checked against the harvest terms the market's config gives.
abstract contract MarketHarvestCheck is BaoTest, HarborDeployer {
    /// @dev Wrapped collateral held by, or paid to, a harvest's caller, its fee receiver and its two pools together.
    struct Holdings {
        uint256 caller;
        uint256 feeReceiver;
        uint256 pools;
    }

    /// @dev `keeper` harvests `market`, which must hold harvestable yield, and is paid the config's bounty ratio of the
    ///      harvest, or the config's bounty ceiling where that is lower; the whole harvest goes to the caller, the fee
    ///      receiver and the pools; and the minter's harvestable falls by what is harvested.
    ///
    ///      The bounty's band: the manager floors the bounty, `floor(G * b)`, and the cut, `floor(G * c)`, on the gross G
    ///      it distributes, and a ceiling moves part of the bounty into the cut, not out of the two. A harvest streams to
    ///      the pools where they hold deposits, and pays the treasury - the fee receiver - where they hold none and are
    ///      owed none:
    ///      - pools holding deposits: the caller's and the fee receiver's receipts sum to `S = floor(G * b) + floor(G * c)`,
    ///        so `G * (b + c)` lies in `[S, S + 2)`;
    ///      - pools holding none: the fee receiver also takes the residual, `floor(G * (1 - b - c))`, so S is three floored
    ///        parts of G and G lies in `[S, S + 3)`.
    ///      So, with k the skimmed ratio (`b + c`, or the whole) and m the parts floored (2, or 3), `floor(G * b)` lies in
    ///      `[floor(S * b / k), floor((S + m) * b / k)]` - one wei wide at the configured ratios.
    /// @return bounty What the harvest paid `keeper`.
    function _harvestAtItsConfigsTerms(Config_MinterMarket market, address keeper) internal returns (uint256 bounty) {
        string memory name = MinterMarketConfigLib.salt(market);
        IHarborConfig config = IHarborConfig(address(market));
        address manager = stabilityPoolManagerAddress(market);
        uint256 harvestableBefore = IStabilityPoolManager_v2(manager).harvestable();

        uint256 harvested;
        bool poolsHoldDeposits;
        Holdings memory received;
        {
            address token = config.wrappedCollateralToken();
            address feeReceiver = IStabilityPoolManager_v2(manager).feeReceiver();
            address[] memory pools = IStabilityPoolManager_v2(manager).stabilityPools();
            poolsHoldDeposits =
                IStabilityPool_v3(pools[0]).totalAssetSupply() + IStabilityPool_v3(pools[1]).totalAssetSupply() >
                0;
            Holdings memory before;
            before.caller = IERC20(token).balanceOf(keeper);
            before.feeReceiver = IERC20(token).balanceOf(feeReceiver);
            before.pools = IERC20(token).balanceOf(pools[0]) + IERC20(token).balanceOf(pools[1]);

            vm.startPrank(keeper);
            harvested = IStabilityPoolManager_v2(manager).harvest(keeper, 0);
            vm.stopPrank();

            received.caller = IERC20(token).balanceOf(keeper) - before.caller;
            received.feeReceiver = IERC20(token).balanceOf(feeReceiver) - before.feeReceiver;
            received.pools = IERC20(token).balanceOf(pools[0]) + IERC20(token).balanceOf(pools[1]) - before.pools;
        }
        assertEq(
            received.caller + received.feeReceiver + received.pools,
            harvested,
            string.concat(name, ": the harvest goes to the caller, the fee receiver and the pools")
        );
        assertEq(
            harvestableBefore - IStabilityPoolManager_v2(manager).harvestable(),
            harvested,
            string.concat(name, ": the minter's harvestable falls by what is harvested")
        );

        uint256 bountyRatio = config.harvestBountyRatio();
        uint256 skimRatio = poolsHoldDeposits ? bountyRatio + config.harvestCutRatio() : 1 ether;
        uint256 ceiling = config.harvestBountyCeiling() == 0
            ? type(uint256).max // a ceiling of zero is none
            : config.harvestBountyCeiling();
        uint256 skimmed = received.caller + received.feeReceiver;
        assertGe(
            received.caller,
            Math.min(Math.mulDiv(skimmed, bountyRatio, skimRatio), ceiling),
            string.concat(name, ": the bounty is the config's ratio of the harvest, or its ceiling")
        );
        assertLe(
            received.caller,
            Math.min(Math.mulDiv(skimmed + (poolsHoldDeposits ? 2 : 3), bountyRatio, skimRatio), ceiling),
            string.concat(name, ": the bounty is the config's ratio of the harvest, or its ceiling")
        );
        bounty = received.caller;
    }
}
