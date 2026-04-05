// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {PeggedToken} from "./contracts/PeggedToken.sol";
import {LeveragedToken} from "./contracts/LeveragedToken.sol";
import {Minter} from "./contracts/Minter.sol";
import {StabilityPool} from "./contracts/StabilityPool.sol";
import {StabilityPoolManager} from "./contracts/StabilityPoolManager.sol";
import {Genesis} from "./contracts/Genesis.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {Minter_v2} from "@harbor/minter/Minter_v2.sol";
import {StabilityPool_v2} from "@harbor/minter/StabilityPool_v2.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

/// @notice Extended market config interface with methods from collateral and chain configs.
interface IFullMinterConfig {
    function peg() external view returns (string memory);
    function collateral() external view returns (string memory);
    function wrappedCollateralToken() external view returns (address);
    function minterConfig() external pure returns (IMinter.Config memory);
    // Peg config
    function minTotalSupply() external view returns (uint256);
    // Stability pool config
    function stabilityPoolWithdrawalDelay() external pure returns (uint256);
    function stabilityPoolWithdrawalPeriod() external pure returns (uint256);
    function stabilityPoolEarlyWithdrawalFeeRatio() external pure returns (uint256);
    // StabilityPoolManager config (rebalanceThreshold comes from volatility config)
    function rebalanceThreshold() external pure returns (uint256);
    function rebalanceBountyRatio() external pure returns (uint256);
    function harvestBountyRatio() external pure returns (uint256);
    function harvestCutRatio() external pure returns (uint256);
}

/// @notice Shared functionality for all minter deployment contracts.
/// @dev Provides common infrastructure and deployment primitives.
abstract contract DeployMintersShared is
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
        IFullMinterConfig cfg = IFullMinterConfig(address(market));
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
        IFullMinterConfig cfg,
        string memory marketKey
    ) internal {
        address wrappedCollateral = cfg.wrappedCollateralToken();
        address peggedToken = _predictAddress(_key(cfg.peg(), "pegged"));
        address leveragedToken = _predictAddress(_key(marketKey, "leveraged"));

        deployMinter(stateData, marketKey, wrappedCollateral, peggedToken, leveragedToken);
    }

    function _deployStabilityPools(
        DeploymentTypes.State memory stateData,
        IFullMinterConfig cfg,
        string memory marketKey
    ) internal {
        address minter = _predictAddress(_key(marketKey, "minter"));

        deployStabilityPool(
            StabilityPoolCollateral,
            stateData,
            marketKey,
            minter,
            cfg.wrappedCollateralToken(),
            address(cfg)
        );

        deployStabilityPool(
            StabilityPoolLeveraged,
            stateData,
            marketKey,
            minter,
            _predictAddress(_key(marketKey, "leveraged")),
            address(cfg)
        );
    }

    function _deployStabilityPoolManager(
        DeploymentTypes.State memory stateData,
        IFullMinterConfig,
        string memory marketKey
    ) internal {
        address minter = _predictAddress(_key(marketKey, "minter"));
        address spCollateral = _predictAddress(_key(marketKey, "stabilityPoolCollateral"));
        address spLeveraged = _predictAddress(_key(marketKey, "stabilityPoolLeveraged"));

        deployStabilityPoolManager(stateData, marketKey, minter, treasury(), spCollateral, spLeveraged);
    }

    function _deployGenesis(
        DeploymentTypes.State memory stateData,
        IFullMinterConfig cfg,
        string memory marketKey
    ) internal {
        cfg;
        address minter = _predictAddress(_key(marketKey, "minter"));
        deployGenesis(stateData, marketKey, minter);
    }

    function _configureMinter(Config_MinterMarket market, string memory marketKey) internal {
        IFullMinterConfig cfg = IFullMinterConfig(address(market));
        address minter = _predictAddress(_key(marketKey, "minter"));
        address reservePool = _predictAddress(_key(marketKey, "reservePool"));
        address spCollateral = _predictAddress(_key(marketKey, "stabilityPoolCollateral"));
        address spLeveraged = _predictAddress(_key(marketKey, "stabilityPoolLeveraged"));
        address spm = _predictAddress(_key(marketKey, "stabilityPoolManager"));
        address genesis = _predictAddress(_key(marketKey, "genesis"));
        address leveragedToken = _predictAddress(_key(marketKey, "leveraged"));
        address priceOracle = _predictAddress(MinterMarketConfigLib.priceOracleKey(market));

        // Update minter configuration (incentive ratios)
        Minter_v2(minter).updateConfig(cfg.minterConfig());
        Minter_v2(minter).updateReservePool(reservePool);
        Minter_v2(minter).updateFeeReceiver(treasury());
        Minter_v2(minter).updatePriceOracle(priceOracle);

        // Grant roles
        grantReservePoolRoles(string.concat(marketKey, "::reservePool"), reservePool, minter);
        grantMinterRoles(string.concat(marketKey, "::minter"), minter, spm, genesis);
        grantStabilityPoolRoles(string.concat(marketKey, "::stabilityPoolCollateral"), spCollateral, spm);
        grantStabilityPoolRoles(string.concat(marketKey, "::stabilityPoolLeveraged"), spLeveraged, spm);

        // Register reward tokens
        StabilityPool_v2(spCollateral).registerRewardToken(cfg.wrappedCollateralToken());
        StabilityPool_v2(spLeveraged).registerRewardToken(cfg.wrappedCollateralToken());
        StabilityPool_v2(spLeveraged).registerRewardToken(leveragedToken);

        // Configure StabilityPoolManager
        configureStabilityPoolManager(
            spm,
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
