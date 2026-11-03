// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {marketsToUpgrade} from "@harbor-script/src/AllMintersConfig.sol";
import {
    BTC_STETH_COMPENSATION,
    EUR_STETH_COMPENSATION,
    FROZEN_MARKETS_CAPTURE
} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";
import {CompensationRun} from "@harbor-script/verify/incidents/CompensationRun.sol";
import {MarketHarvestCheck} from "@harbor-script/verify/v3-upgrade/MarketHarvestCheck.sol";

/// @title UpgradedMarketsHarvest - the v3 upgrade's harvest check
/// @notice Each named market, upgraded, harvests on the state the upgrade leaves it in, at the harvest terms its market
///         config gives: the records compare what each contract reads, and this is what it does when a keeper harvests.
///
///         On a fork of mainnet at the block after the capture, where the 11 paused markets' minters and pools are paused:
///         the upgrade as the upgrade script builds it, the compensation included, executed as the multisig; then each
///         market is harvested. A harvest reads the price oracle, and there every answer is as fresh as mainnet keeps it. On
///         anvil it is not: anvil holds each answer from its fork while its clock runs on.
contract UpgradedMarketsHarvest is MarketHarvestCheck {
    Config_MinterMarket[] internal markets;
    address internal keeper;

    function setUp() public {
        vm.createSelectFork("mainnet", HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE) + 1);
        _setSaltPrefix("harbor_v1");
        markets = marketsToUpgrade();
        // A contract made on one fork is absent from another unless persistent: the run reads the frozen markets on
        // forks of its own.
        for (uint256 i = 0; i < markets.length; ++i) {
            vm.makePersistent(address(markets[i]));
        }
        string[] memory files = new string[](2);
        files[0] = BTC_STETH_COMPENSATION;
        files[1] = EUR_STETH_COMPENSATION;
        CompensationRun upgrade = new CompensationRun("harbor_v1", markets, FROZEN_MARKETS_CAPTURE, files);
        vm.makePersistent(address(upgrade));
        upgrade.ensureFactory();
        upgrade.run("harbor_v1");
        keeper = makeAddr("keeper");
    }

    /// Each market holding harvestable yield harvests it at its config's terms. A market holding none says so rather than
    /// failing some other way. Where a named minter holds wrapped collateral, at least one market must harvest, so the
    /// check cannot pass by every market having nothing to do. A run of markets holding none rightly harvests nothing.
    function test_everyUpgradedMarketHarvestsAtItsConfigsTerms() public {
        uint256 marketsHarvested;
        uint256 marketsHoldingCollateral;
        for (uint256 i = 0; i < markets.length; ++i) {
            IHarborConfig config = IHarborConfig(address(markets[i]));
            address manager = stabilityPoolManagerAddress(markets[i]);
            if (IERC20(config.wrappedCollateralToken()).balanceOf(minterAddress(markets[i])) > 0) {
                ++marketsHoldingCollateral;
            }

            // the manager's harvestable is its minter's
            if (IStabilityPoolManager_v2(manager).harvestable() == 0) {
                vm.startPrank(keeper);
                vm.expectRevert(IStabilityPoolManager_v2.NoHarvestable.selector);
                IStabilityPoolManager_v2(manager).harvest(keeper, 0);
                vm.stopPrank();
            } else {
                _harvestAtItsConfigsTerms(markets[i], keeper);
                marketsHarvested++;
            }
        }
        if (marketsHoldingCollateral > 0) {
            assertGt(marketsHarvested, 0, "at least one market had yield to harvest");
        }
    }
}
