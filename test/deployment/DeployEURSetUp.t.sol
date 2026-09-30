// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {eurMintersConfig} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {MarketAddresses} from "@harbor-test/harness/MarketAddresses.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/// @title Common deployment setup for EUR market tests.
/// @dev Deploys the EUR peg with two collaterals (fxUSD, stETH), each market with its collateral and leveraged
///      stability pools and their manager.
///      Forks mainnet at a pinned block, deploys all market infrastructure via production scripts,
///      grants test contract free-mint and reward-depositor roles, sets mock oracles to price=rate=1.
abstract contract DeployEURSetUp is BaoTest {
    /// @dev The deploy run that stands the peg's markets up, held rather than inherited (see `HarborDeployRun`).
    HarborDeployRun internal deployRun;

    /// @dev The EUR::fxUSD market, as the run reports it.
    MarketAddresses internal fxUSD;

    /// @dev The EUR::stETH market.
    MarketAddresses internal stETH;

    address pegged; // haEUR - shared across markets

    function setUp() public virtual {
        forkMainnet();
        deployRun = new HarborDeployRun(HARBOR_MULTISIG, HARBOR_MULTISIG, "test_eur", "mainnet");
        deployRun.ensureFactory();

        (ConfigPeg peg_, Config_MinterMarket[] memory mktConfigs) = eurMintersConfig();

        deployRun.deploy(peg_, mktConfigs, true, mktConfigs);

        fxUSD = deployRun.marketAddresses(mktConfigs[0]);
        stETH = deployRun.marketAddresses(mktConfigs[1]);
        pegged = fxUSD.pegged;

        // Mock oracles (price=1, rate=1 for simple accounting), where the deploy wired each minter
        MockWrappedPriceOracle(deployRun.installMockPriceOracle(mktConfigs[0])).setLatestAnswer(1 ether, 1 ether);
        MockWrappedPriceOracle(deployRun.installMockPriceOracle(mktConfigs[1])).setLatestAnswer(1 ether, 1 ether);

        vm.startPrank(HARBOR_MULTISIG);
        // Grant free mint role for test helpers
        IBaoRoles(fxUSD.minter).grantRoles(address(this), IMinter(fxUSD.minter).ZERO_FEE_ROLE());
        IBaoRoles(stETH.minter).grantRoles(address(this), IMinter(stETH.minter).ZERO_FEE_ROLE());
        // Grant the reward depositor role on each collateral stability pool
        IBaoRoles(fxUSD.collateralPool).grantRoles(
            address(this),
            IMultipleRewardDistributor(fxUSD.collateralPool).REWARD_DEPOSITOR_ROLE()
        );
        IBaoRoles(stETH.collateralPool).grantRoles(
            address(this),
            IMultipleRewardDistributor(stETH.collateralPool).REWARD_DEPOSITOR_ROLE()
        );
        vm.stopPrank();
    }

    // ── Helpers ────────────────────────────────────────────────────────

    function _mintPegged(
        address minter_,
        address to,
        uint256 collateralAmount
    ) internal returns (uint256 peggedMinted) {
        address wrappedCollateral = IMinter(minter_).WRAPPED_COLLATERAL_TOKEN();
        deal(wrappedCollateral, address(this), collateralAmount);
        IERC20(wrappedCollateral).approve(minter_, collateralAmount);
        peggedMinted = IMinter(minter_).freeMintPeggedToken(collateralAmount, to);
    }

    function _depositReward(
        address stabilityPool,
        address wrappedCollateral,
        address rewardAlias,
        uint256 amount
    ) internal {
        deal(wrappedCollateral, address(this), amount);
        IERC20(wrappedCollateral).approve(stabilityPool, amount);
        IMultipleRewardDistributor(stabilityPool).depositReward(rewardAlias, amount);
    }
}
