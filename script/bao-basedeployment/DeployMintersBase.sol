// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborDeployment_MinterTokens} from "./HarborDeployment_MinterTokens.sol";
import {DeploymentState} from "./DeploymentState.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {Config_Peg} from "script/config/pegs/Config_Peg.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";
import {Config_Peg_ETH} from "script/config/pegs/Config_Peg_ETH.sol";
import {Config_Peg_BTC} from "script/config/pegs/Config_Peg_BTC.sol";
import {Config_Peg_GOLD} from "script/config/pegs/Config_Peg_GOLD.sol";
import {Config_Peg_EUR} from "script/config/pegs/Config_Peg_EUR.sol";
import {Config_Market_ETH_fxUSD} from "script/config/markets/Config_Market_ETH_fxUSD.sol";
import {Config_Market_BTC_fxUSD} from "script/config/markets/Config_Market_BTC_fxUSD.sol";
import {Config_Market_BTC_stETH} from "script/config/markets/Config_Market_BTC_stETH.sol";
import {Config_Market_EUR_fxUSD} from "script/config/markets/Config_Market_EUR_fxUSD.sol";
import {Config_Market_EUR_stETH} from "script/config/markets/Config_Market_EUR_stETH.sol";
import {Config_Market_GOLD_fxUSD} from "script/config/markets/Config_Market_GOLD_fxUSD.sol";
import {Config_Market_GOLD_stETH} from "script/config/markets/Config_Market_GOLD_stETH.sol";

/// @notice Configuration for all minter tokens deployment.
/// @dev Created BEFORE startBroadcast() so config contracts are NOT deployed on-chain.
/// @dev Defined at file scope for import/export capability.
struct AllMintersConfig {
    Config_Peg pegETH;
    Config_Peg pegBTC;
    Config_Peg pegGOLD;
    Config_Peg pegEUR;
    Config_MinterMarket[] marketsETH; // Markets using ETH peg
    Config_MinterMarket[] marketsBTC; // Markets using BTC peg
    Config_MinterMarket[] marketsGOLD; // Markets using GOLD peg
    Config_MinterMarket[] marketsEUR; // Markets using EUR peg
}

/// @notice Orchestration for minter token deployment.
/// @dev This file contains ONLY orchestration (createAllMintersConfig, deployAllMinters).
/// @dev Contract-specific deployment logic lives in HarborDeployment_MinterTokens.sol.
/// @dev See deployment2-design.md Section 3.3.4 for config-before-broadcast pattern.
/// @dev Config_Protocol inherited via FactoryDeployer → provides baoFactory(), owner(), systemSalt().
abstract contract DeployMintersBase is HarborDeployment_MinterTokens {
    /// @notice Create all config objects - call BEFORE startBroadcast().
    /// @dev Config contracts created here are NOT deployed on-chain.
    /// @dev See deployment2-design.md Section 3.3.4 for pattern.
    function createAllMintersConfig() internal returns (AllMintersConfig memory config) {
        // Peg configs
        config.pegETH = new Config_Peg_ETH();
        config.pegBTC = new Config_Peg_BTC();
        config.pegGOLD = new Config_Peg_GOLD();
        config.pegEUR = new Config_Peg_EUR();

        // ETH peg markets
        config.marketsETH = new Config_MinterMarket[](1);
        config.marketsETH[0] = new Config_Market_ETH_fxUSD();

        // BTC peg markets
        config.marketsBTC = new Config_MinterMarket[](2);
        config.marketsBTC[0] = new Config_Market_BTC_fxUSD();
        config.marketsBTC[1] = new Config_Market_BTC_stETH();

        // GOLD peg markets
        config.marketsGOLD = new Config_MinterMarket[](2);
        config.marketsGOLD[0] = new Config_Market_GOLD_fxUSD();
        config.marketsGOLD[1] = new Config_Market_GOLD_stETH();

        // EUR peg markets
        config.marketsEUR = new Config_MinterMarket[](2);
        config.marketsEUR[0] = new Config_Market_EUR_fxUSD();
        config.marketsEUR[1] = new Config_Market_EUR_stETH();

        return config;
    }

    /// @notice Deploy all Harbor minter tokens (pegged and leveraged) and grant minter roles.
    /// @dev Call INSIDE startBroadcast(). Config must be created before broadcast.
    /// @param config All minter configs (created by createAllMintersConfig()).
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    /// @param useLocal Whether to read/write state in the local results directory.
    function deployAllMinters(AllMintersConfig memory config, string memory network, bool useLocal) internal {
        DeploymentTypes.State memory stateData = _shouldPersistState()
            ? DeploymentState.load(network, systemSalt(), useLocal, _stateDirectoryPrefix())
            : _seedEphemeralState(systemSalt(), network, useLocal);
        stateData.baoFactory = baoFactory();

        console.log("=== Deploying Minter Tokens (Pegged + Leveraged) ===");
        console.log("systemSalt: %s", systemSalt());
        console.log("network: %s", network);

        _deployAllPeggedTokens(stateData, config);
        _deployAllLeveragedTokens(stateData, config);

        _transferAllOwnerships();

        if (_shouldPersistState()) {
            DeploymentState.save(stateData, _stateDirectoryPrefix());
        }
        console.log("=== Minter Token Deployment Complete ===");
    }

    /// @notice Deploy all pegged tokens (one per peg: ETH, BTC, GOLD, EUR).
    function _deployAllPeggedTokens(DeploymentTypes.State memory stateData, AllMintersConfig memory config) private {
        console.log("\n--- Deploying Pegged Tokens ---");

        deployPeggedTokenWithRoles(stateData, config.pegETH, config.marketsETH, baoFactory(), owner(), systemSalt());
        deployPeggedTokenWithRoles(stateData, config.pegBTC, config.marketsBTC, baoFactory(), owner(), systemSalt());
        deployPeggedTokenWithRoles(stateData, config.pegGOLD, config.marketsGOLD, baoFactory(), owner(), systemSalt());
        deployPeggedTokenWithRoles(stateData, config.pegEUR, config.marketsEUR, baoFactory(), owner(), systemSalt());
    }

    /// @notice Deploy all leveraged tokens (one per market).
    function _deployAllLeveragedTokens(DeploymentTypes.State memory stateData, AllMintersConfig memory config)
        private
    {
        console.log("\n--- Deploying Leveraged Tokens ---");

        // ETH peg markets
        for (uint256 i = 0; i < config.marketsETH.length; i++) {
            deployLeveragedTokenWithRoles(stateData, config.marketsETH[i], baoFactory(), owner(), systemSalt());
        }

        // BTC peg markets
        for (uint256 i = 0; i < config.marketsBTC.length; i++) {
            deployLeveragedTokenWithRoles(stateData, config.marketsBTC[i], baoFactory(), owner(), systemSalt());
        }

        // GOLD peg markets
        for (uint256 i = 0; i < config.marketsGOLD.length; i++) {
            deployLeveragedTokenWithRoles(stateData, config.marketsGOLD[i], baoFactory(), owner(), systemSalt());
        }

        // EUR peg markets
        for (uint256 i = 0; i < config.marketsEUR.length; i++) {
            deployLeveragedTokenWithRoles(stateData, config.marketsEUR[i], baoFactory(), owner(), systemSalt());
        }
    }

    function _shouldPersistState() internal pure virtual returns (bool) {
        return true;
    }

    function _stateDirectoryPrefix() internal view virtual returns (string memory) {
        return "";
    }

    function _seedEphemeralState(string memory saltPrefix, string memory network, bool useLocal)
        private
        pure
        returns (DeploymentTypes.State memory stateData)
    {
        stateData.network = network;
        stateData.saltPrefix = saltPrefix;
        stateData.useLocal = useLocal;
        return stateData;
    }
}
