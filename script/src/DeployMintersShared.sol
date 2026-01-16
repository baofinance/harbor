// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
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
import {Minter_v1} from "@harbor/minter/Minter_v1.sol";
import {StabilityPool_v1} from "@harbor/minter/StabilityPool_v1.sol";
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
    // Shared helper functions for state management

    function _loadOrSeedState(string memory network) internal returns (DeploymentTypes.State memory stateData) {
        stateData = _shouldPersistState()
            ? DeploymentState.load(network, saltPrefix(), "")
            : _seedEphemeralState(saltPrefix(), network);
        stateData.baoFactory = baoFactory();

        console.log("=== Deploying Minter Contracts ===");
        console.log("  Salt:    %s", saltPrefix());
        console.log("  Network: %s", network);
        return stateData;
    }

    function _finalizeDeploy(DeploymentTypes.State memory stateData) internal {
        _transferAllOwnerships();

        _saveState(stateData);

        console.log("=== Minter Deployment Done ===");
    }

    /// @notice Deploy pegged token and all markets for a peg (public entry point).
    function deployAllForPeg(ConfigPeg peg, Config_MinterMarket[] memory markets, string memory network) internal {
        DeploymentTypes.State memory stateData = _loadOrSeedState(network);
        _deployPegAndMarkets(stateData, peg, markets);
        _finalizeDeploy(stateData);
    }

    // ========== GRANULAR DEPLOYMENT FUNCTIONS (for tests and selective deployments) ==========

    /// @notice Deploy pegged token with roles for all markets that will use it.
    /// @param state Deployment state (modified in place).
    /// @param peg Peg configuration.
    /// @param markets All markets that will use this peg (for role grants).
    function deployPeg(
        DeploymentTypes.State memory state,
        ConfigPeg peg,
        Config_MinterMarket[] memory markets
    ) internal {
        console.log("");
        console.log("--- Deploying %s Pegged Token ---", peg.key());
        deployPeggedTokenWithRoles(state, peg, markets);
    }

    /// @notice Transfer ownerships for all deployed contracts.
    function finalize() internal {
        console.log("");
        console.log("--- Transferring Ownerships ---");
        _transferAllOwnerships();
        console.log("=== Minter Deployment Done ===");
    }

    // ========== INTERNAL DEPLOYMENT HELPERS ==========

    /// @notice Deploy pegged token and all markets for a peg.
    function _deployPegAndMarkets(
        DeploymentTypes.State memory stateData,
        ConfigPeg peg,
        Config_MinterMarket[] memory markets
    ) internal {
        console.log("");
        console.log("--- Deploying %s Peg and Markets ---", peg.key());

        deployPeggedTokenWithRoles(stateData, peg, markets);

        for (uint256 i = 0; i < markets.length; i++) {
            deployMinter(stateData, markets[i]);
        }
    }

    /// @notice Deploy infrastructure for a single market.
    /// @param state Deployment state (modified in place).
    /// @param market Market configuration.
    function deployMinter(DeploymentTypes.State memory state, Config_MinterMarket market) internal {
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
        address peggedToken = _predictAddress(string.concat(cfg.peg(), "::pegged"));
        address leveragedToken = _predictAddress(marketKey, "leveraged");

        deployMinter(stateData, marketKey, wrappedCollateral, peggedToken, leveragedToken);
    }

    function _deployStabilityPools(
        DeploymentTypes.State memory stateData,
        IFullMinterConfig cfg,
        string memory marketKey
    ) internal {
        address minter = _predictAddress(marketKey, "minter");
        address leveragedToken = _predictAddress(marketKey, "leveraged");

        StabilityPoolConfig memory spConfig = StabilityPoolConfig({
            earlyWithdrawalFeeRatio: cfg.stabilityPoolEarlyWithdrawalFeeRatio(),
            withdrawalDelay: cfg.stabilityPoolWithdrawalDelay(),
            withdrawalPeriod: cfg.stabilityPoolWithdrawalPeriod(),
            minTotalAssetSupply: cfg.minTotalSupply(),
            treasury: treasury()
        });

        deployStabilityPoolCollateral(stateData, marketKey, minter, cfg.wrappedCollateralToken(), spConfig);

        deployStabilityPoolLeveraged(stateData, marketKey, minter, leveragedToken, spConfig);
    }

    function _deployStabilityPoolManager(
        DeploymentTypes.State memory stateData,
        IFullMinterConfig,
        string memory marketKey
    ) internal {
        address minter = _predictAddress(marketKey, "minter");
        address spCollateral = _predictAddress(marketKey, "stabilityPoolCollateral");
        address spLeveraged = _predictAddress(marketKey, "stabilityPoolLeveraged");

        deployStabilityPoolManager(stateData, marketKey, minter, treasury(), spCollateral, spLeveraged);
    }

    function _deployGenesis(
        DeploymentTypes.State memory stateData,
        IFullMinterConfig cfg,
        string memory marketKey
    ) internal {
        cfg;
        address minter = _predictAddress(marketKey, "minter");
        deployGenesis(stateData, marketKey, minter);
    }

    function _configureMinter(Config_MinterMarket market, string memory marketKey) internal {
        IFullMinterConfig cfg = IFullMinterConfig(address(market));
        address minter = _predictAddress(marketKey, "minter");
        address reservePool = _predictAddress(marketKey, "reservePool");
        address spCollateral = _predictAddress(marketKey, "stabilityPoolCollateral");
        address spLeveraged = _predictAddress(marketKey, "stabilityPoolLeveraged");
        address spm = _predictAddress(marketKey, "stabilityPoolManager");
        address genesis = _predictAddress(marketKey, "genesis");
        address leveragedToken = _predictAddress(marketKey, "leveraged");
        address priceOracle = _predictAddress(MinterMarketConfigLib.priceOracleKey(market));

        // Update minter configuration (incentive ratios)
        Minter_v1(minter).updateConfig(cfg.minterConfig());
        Minter_v1(minter).updateReservePool(reservePool);
        Minter_v1(minter).updateFeeReceiver(treasury());
        Minter_v1(minter).updatePriceOracle(priceOracle);

        // Grant roles
        grantReservePoolRoles(string.concat(marketKey, "::reservePool"), reservePool, minter);
        grantMinterRoles(string.concat(marketKey, "::minter"), minter, spm, genesis);
        grantStabilityPoolRoles(string.concat(marketKey, "::stabilityPoolCollateral"), spCollateral, spm);
        grantStabilityPoolRoles(string.concat(marketKey, "::stabilityPoolLeveraged"), spLeveraged, spm);

        // Register reward tokens
        StabilityPool_v1(spCollateral).registerRewardToken(cfg.wrappedCollateralToken());
        StabilityPool_v1(spLeveraged).registerRewardToken(cfg.wrappedCollateralToken());
        StabilityPool_v1(spLeveraged).registerRewardToken(leveragedToken);

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

    function _shouldPersistState() internal pure virtual override returns (bool) {
        return true;
    }

    function _seedEphemeralState(
        string memory saltPrefix,
        string memory network
    ) internal pure returns (DeploymentTypes.State memory stateData) {
        stateData.network = network;
        stateData.saltPrefix = saltPrefix;
        return stateData;
    }
}
