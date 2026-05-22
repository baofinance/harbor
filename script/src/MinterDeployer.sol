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
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";

/// @notice Shared functionality for all minter deployment contracts.
/// @dev Provides common infrastructure and deployment primitives.
abstract contract MinterDeployer is PeggedToken, LeveragedToken, Minter, StabilityPool, StabilityPoolManager, Genesis {
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
    function deployForPeg(
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
            : DeploymentTypes.State({
                network: network,
                saltPrefix: saltPrefix,
                directoryPrefix: "",
                implementations: new DeploymentTypes.ImplementationRecord[](0),
                proxies: new DeploymentTypes.ProxyRecord[](0),
                baoFactory: address(0)
            });
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

        // Deploy Minter
        _deployMinter(state, cfg, marketKey);

        // Deploy Stability Pools
        _deployStabilityPools(state, cfg, marketKey);

        // Register reward tokens on SPs
        _registerRewardTokens(cfg, marketKey);

        // Deploy StabilityPoolManager
        _deployStabilityPoolManager(state, cfg, marketKey);

        // Deploy Genesis
        _deployGenesis(state, cfg, marketKey);

        // Configure Minter and grant roles
        _configureMinter(market, marketKey);

        console.log("    [complete]");
    }

    function _deployMinter(
        DeploymentTypes.State memory stateData,
        IHarborConfig cfg,
        string memory marketKey
    ) internal {
        address wrappedCollateral = cfg.wrappedCollateralToken();
        address peggedToken = _predictAddress(_key(cfg.peg(), "pegged"));
        address leveragedToken = _predictAddress(_key(marketKey, "leveraged"));

        deployMinter(stateData, marketKey, wrappedCollateral, peggedToken, leveragedToken);
    }

    function _deployStabilityPools(
        DeploymentTypes.State memory stateData,
        IHarborConfig cfg,
        string memory marketKey
    ) internal {
        address minter = _predictAddress(_key(marketKey, "minter"));

        deployStabilityPool(
            StabilityPoolCollateral,
            stateData,
            Config_MinterMarket(address(cfg)),
            minter,
            cfg.wrappedCollateralToken()
        );

        deployStabilityPool(
            StabilityPoolLeveraged,
            stateData,
            Config_MinterMarket(address(cfg)),
            minter,
            _predictAddress(_key(marketKey, "leveraged"))
        );
    }

    function _registerRewardTokens(IHarborConfig cfg, string memory marketKey) internal {
        address spCollateral = _predictAddress(_key(marketKey, StabilityPoolCollateral));
        address spLeveraged = _predictAddress(_key(marketKey, StabilityPoolLeveraged));
        address wrappedCollateral = cfg.wrappedCollateralToken();
        address leveragedToken = _predictAddress(_key(marketKey, "leveraged"));

        // Collateral SP: wrappedCollateral (receives both harvest + rebalance rewards)
        IMultipleRewardDistributor(spCollateral).registerRewardToken(wrappedCollateral);

        // Leveraged SP: wrappedCollateral (harvest) + leveragedToken (rebalance)
        IMultipleRewardDistributor(spLeveraged).registerRewardToken(wrappedCollateral);
        IMultipleRewardDistributor(spLeveraged).registerRewardToken(leveragedToken);
    }

    function _deployStabilityPoolManager(
        DeploymentTypes.State memory stateData,
        IHarborConfig,
        string memory marketKey
    ) internal {
        address minter = _predictAddress(_key(marketKey, "minter"));
        address spCollateral = _predictAddress(_key(marketKey, "stabilityPoolCollateral"));
        address spLeveraged = _predictAddress(_key(marketKey, "stabilityPoolLeveraged"));

        deployStabilityPoolManager(stateData, marketKey, minter, treasury(), spCollateral, spLeveraged);
    }

    function _deployGenesis(
        DeploymentTypes.State memory stateData,
        IHarborConfig cfg,
        string memory marketKey
    ) internal {
        cfg;
        address minter = _predictAddress(_key(marketKey, "minter"));
        deployGenesis(stateData, marketKey, minter);
    }

    function _configureMinter(Config_MinterMarket market, string memory marketKey) internal {
        IHarborConfig cfg = IHarborConfig(address(market));
        address minter = _predictAddress(_key(marketKey, "minter"));
        address priceOracle = _predictAddress(MinterMarketConfigLib.priceOracleKey(market));

        // Update minter configuration (incentive ratios)
        IMinter(minter).updateConfig(cfg.minterConfig());
        IMinter(minter).updateReservePool(_predictAddress(_key(marketKey, "reservePool")));
        IMinter(minter).updateFeeReceiver(treasury());
        IMinter(minter).updatePriceOracle(priceOracle);

        // Grant roles — each helper predicts its own addresses from marketKey
        grantReservePoolRoles(marketKey);
        grantMinterRoles(marketKey);
        grantStabilityPoolRoles(marketKey, StabilityPoolCollateral);
        grantStabilityPoolRoles(marketKey, StabilityPoolLeveraged);

        // Configure StabilityPoolManager
        configureStabilityPoolManager(
            marketKey,
            SPMConfig({
                rebalanceThreshold: cfg.rebalanceThreshold(),
                rebalanceBountyRatio: cfg.rebalanceBountyRatio(),
                harvestBountyRatio: cfg.harvestBountyRatio(),
                harvestCutRatio: cfg.harvestCutRatio(),
                feeReceiver: treasury()
            })
        );
    }
}
