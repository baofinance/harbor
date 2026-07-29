// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {PeggedToken} from "@harbor-script/src/contracts/PeggedToken.sol";
import {LeveragedToken} from "@harbor-script/src/contracts/LeveragedToken.sol";
import {Minter} from "@harbor-script/src/contracts/Minter.sol";
import {StabilityPool} from "@harbor-script/src/contracts/StabilityPool.sol";
import {StabilityPoolManager} from "@harbor-script/src/contracts/StabilityPoolManager.sol";
import {Genesis} from "@harbor-script/src/contracts/Genesis.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";

/// @notice The shared Harbor deploy stack: aggregates the per-contract deployers and exposes
///         `deployHarborForPeg`, which stands up a peg's full minter market (pegged/leveraged
///         tokens, minter, stability pools, SPM, genesis).
/// @dev Inherited by both the production `Deploy_<PEG>_mainnet` scripts and the `test/` setups
///      (via `Deploy_<PEG>_Minter`), so the real deploy code is exercised throughout the suite,
///      not only in a dedicated deploy test.
abstract contract HarborDeployStack is
    PeggedToken,
    LeveragedToken,
    Minter,
    StabilityPool,
    StabilityPoolManager,
    Genesis
{
    using LibString for string;

    // ========== MARKET LOOKUP ==========

    /// @notice Find a market config by collateral name.
    /// @param markets Array of market configurations.
    /// @param collateral Collateral name to find.
    /// @return The matching market config.
    /// @dev Reverts if not found.
    function findMarket(
        Config_MinterMarket[] memory markets,
        string memory collateral
    ) internal view returns (Config_MinterMarket) {
        bytes32 target = keccak256(bytes(collateral));
        for (uint256 i = 0; i < markets.length; i++) {
            if (keccak256(bytes(MinterMarketConfigLib.collateral(markets[i]))) == target) {
                return markets[i];
            }
        }
        revert(string.concat("Market not found for collateral: ", collateral));
    }

    /// @notice Parse collateral filter string into array of markets.
    /// @param allMarkets All configured markets.
    /// @param collateralFilter "*" for all, or single collateral name.
    /// @return Filtered array of markets.
    function parseCollateralFilter(
        Config_MinterMarket[] memory allMarkets,
        string memory collateralFilter
    ) internal view returns (Config_MinterMarket[] memory) {
        if (collateralFilter.eq("*")) {
            return allMarkets;
        }
        if (bytes(collateralFilter).length == 0) {
            return new Config_MinterMarket[](0);
        }
        Config_MinterMarket[] memory result = new Config_MinterMarket[](1);
        result[0] = findMarket(allMarkets, collateralFilter);
        return result;
    }

    // ========== MAIN ENTRY POINT ==========

    /// @notice Deploy pegged token and/or markets for a peg.
    /// @param saltPrefix Salt prefix for CREATE3 deployment namespacing.
    /// @param peg Peg configuration.
    /// @param allMarkets All configured markets for this peg (used for role grants).
    /// @param network Network name (e.g., "mainnet").
    /// @param deployPeg Whether to deploy the pegged token.
    /// @param marketsToDeploy Markets to deploy (empty array = none).
    function deployHarborForPeg(
        string memory saltPrefix,
        ConfigPeg peg,
        Config_MinterMarket[] memory allMarkets,
        string memory network,
        bool deployPeg,
        Config_MinterMarket[] memory marketsToDeploy
    ) internal {
        _setSaltPrefix(saltPrefix);

        // Load or seed state
        DeploymentTypes.State memory state = _shouldPersistState()
            ? DeploymentState.load(_stateFileRead())
            : DeploymentState.fresh(saltPrefix, network);
        state.baoFactory = baoFactory();

        console.log("=== Deploying Minter Contracts ===");
        console.log("  Salt:    %s", saltPrefix);
        console.log("  Network: %s", network);

        if (deployPeg) {
            console.log("");
            console.log("--- Deploying %s Pegged Token ---", peg.key());
            deployPeggedTokenWithRoles(state, peg, allMarkets);
        }

        for (uint256 i = 0; i < marketsToDeploy.length; i++) {
            _deployMinterInfrastructure(state, marketsToDeploy[i]);
        }

        // Finalize: transfer ownerships and save state
        console.log("");
        console.log("--- Transferring Ownerships ---");
        _transferAllOwnerships();
        _saveState(state);
        console.log("=== Minter Deployment Done ===");
    }

    // ========== MINTER INFRASTRUCTURE DEPLOYMENT ==========

    /// @notice Deploy infrastructure for a single market.
    /// @param state Deployment state (modified in place).
    /// @param market Market configuration.
    function _deployMinterInfrastructure(DeploymentTypes.State memory state, Config_MinterMarket market) private {
        IHarborConfig cfg = IHarborConfig(address(market));
        string memory marketKey = MinterMarketConfigLib.salt(market);

        console.log("");
        console.log("  > Market: %s", marketKey);

        // Deploy LeveragedToken
        _deployLeveragedTokenWithRoles(state, market);

        // Deploy ReservePool
        deployReservePool(state, marketKey);

        // Deploy Minter — fully wired and configured by deployMinter itself
        deployMinter(state, market);

        // Deploy Stability Pools
        _deployStabilityPools(state, cfg, marketKey);

        // Register reward tokens on SPs
        _registerRewardTokens(cfg, marketKey);

        // Deploy StabilityPoolManager — configured by deployStabilityPoolManager itself
        deployStabilityPoolManager(state, market);

        // Deploy Genesis
        deployGenesis(state, marketKey, minterAddress(marketKey));

        // Grant roles
        _grantMarketRoles(marketKey);

        console.log("    [complete]");
    }

    function _deployStabilityPools(
        DeploymentTypes.State memory stateData,
        IHarborConfig cfg,
        string memory marketKey
    ) internal {
        address minter = minterAddress(marketKey);

        deployStabilityPool(
            StabilityPoolType.Collateral,
            stateData,
            Config_MinterMarket(address(cfg)),
            minter,
            cfg.wrappedCollateralToken()
        );

        deployStabilityPool(
            StabilityPoolType.Leveraged,
            stateData,
            Config_MinterMarket(address(cfg)),
            minter,
            leveragedTokenAddress(marketKey)
        );
    }

    function _registerRewardTokens(IHarborConfig cfg, string memory marketKey) internal {
        address spCollateral = stabilityPoolAddress(marketKey, StabilityPoolType.Collateral);
        address spLeveraged = stabilityPoolAddress(marketKey, StabilityPoolType.Leveraged);
        address wrappedCollateral = cfg.wrappedCollateralToken();
        address leveragedToken = leveragedTokenAddress(marketKey);

        // Collateral SP: wrappedCollateral (receives both harvest + rebalance rewards)
        IMultipleRewardDistributor(spCollateral).registerRewardToken(wrappedCollateral);

        // Leveraged SP: wrappedCollateral (harvest) + leveragedToken (rebalance)
        IMultipleRewardDistributor(spLeveraged).registerRewardToken(wrappedCollateral);
        IMultipleRewardDistributor(spLeveraged).registerRewardToken(leveragedToken);
    }

    /// @notice Grant every cross-contract role for a market, once all of its contracts exist.
    /// @dev Roles are the only wiring left to the stack: each grant names two contracts, so it belongs
    ///      to neither one's deploy function. Each helper resolves its own addresses from marketKey.
    function _grantMarketRoles(string memory marketKey) internal {
        grantReservePoolRoles(marketKey);
        grantMinterRoles(marketKey);
        grantStabilityPoolRoles(marketKey, StabilityPoolType.Collateral);
        grantStabilityPoolRoles(marketKey, StabilityPoolType.Leveraged);
    }
}
