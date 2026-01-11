// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborDeployment_Pegged} from "./HarborDeployment_Pegged.sol";
import {DeploymentState} from "./DeploymentState.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {ConfigPeg_ETH} from "script/config/pegs/ConfigPeg_ETH.sol";
import {ConfigPeg_BTC} from "script/config/pegs/ConfigPeg_BTC.sol";
import {ConfigPeg_GOLD} from "script/config/pegs/ConfigPeg_GOLD.sol";
import {ConfigPeg_EUR} from "script/config/pegs/ConfigPeg_EUR.sol";
import {ConfigMarket_ETH_fxUSD_mainnet} from "script/config/markets/ConfigMarket_ETH_fxUSD_mainnet.sol";
import {ConfigMarket_BTC_fxUSD_mainnet} from "script/config/markets/ConfigMarket_BTC_fxUSD_mainnet.sol";
import {ConfigMarket_BTC_stETH_mainnet} from "script/config/markets/ConfigMarket_BTC_stETH_mainnet.sol";
import {ConfigMarket_EUR_fxUSD_mainnet} from "script/config/markets/ConfigMarket_EUR_fxUSD_mainnet.sol";
import {ConfigMarket_EUR_stETH_mainnet} from "script/config/markets/ConfigMarket_EUR_stETH_mainnet.sol";
import {ConfigMarket_GOLD_fxUSD_mainnet} from "script/config/markets/ConfigMarket_GOLD_fxUSD_mainnet.sol";
import {ConfigMarket_GOLD_stETH_mainnet} from "script/config/markets/ConfigMarket_GOLD_stETH_mainnet.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @notice Configuration for all pegged tokens deployment.
/// @dev Created BEFORE startBroadcast() so config contracts are NOT deployed on-chain.
/// @dev Defined at file scope for import/export capability.
struct AllPeggedConfig {
    ConfigPeg pegETH;
    ConfigPeg pegBTC;
    ConfigPeg pegGOLD;
    ConfigPeg pegEUR;
    Config_MinterMarket[] marketsETH;
    Config_MinterMarket[] marketsBTC;
    Config_MinterMarket[] marketsGOLD;
    Config_MinterMarket[] marketsEUR;
}

/// @notice Base contract for pegged token deployment orchestration.
/// @dev Provides reusable deployment logic for both production scripts and tests.
/// @dev ConfigProtocol inherited via FactoryDeployer → provides baoFactory(), owner(), systemSalt().
/// @dev See deployment2-design.md Section 3.3.4 for config-before-broadcast pattern.
abstract contract DeployPeggedBase is HarborDeployment_Pegged {
    using LibString for string;

    /// @notice Create all config objects - call BEFORE startBroadcast().
    /// @dev Config contracts created here are NOT deployed on-chain.
    function createAllPeggedConfig() internal returns (AllPeggedConfig memory config) {
        // Peg configs
        config.pegETH = new ConfigPeg_ETH();
        config.pegBTC = new ConfigPeg_BTC();
        config.pegGOLD = new ConfigPeg_GOLD();
        config.pegEUR = new ConfigPeg_EUR();

        // ETH peg markets
        config.marketsETH = new Config_MinterMarket[](1);
        config.marketsETH[0] = new ConfigMarket_ETH_fxUSD_mainnet();

        // BTC peg markets
        config.marketsBTC = new Config_MinterMarket[](2);
        config.marketsBTC[0] = new ConfigMarket_BTC_fxUSD_mainnet();
        config.marketsBTC[1] = new ConfigMarket_BTC_stETH_mainnet();

        // GOLD peg markets
        config.marketsGOLD = new Config_MinterMarket[](2);
        config.marketsGOLD[0] = new ConfigMarket_GOLD_fxUSD_mainnet();
        config.marketsGOLD[1] = new ConfigMarket_GOLD_stETH_mainnet();

        // EUR peg markets
        config.marketsEUR = new Config_MinterMarket[](2);
        config.marketsEUR[0] = new ConfigMarket_EUR_fxUSD_mainnet();
        config.marketsEUR[1] = new ConfigMarket_EUR_stETH_mainnet();

        return config;
    }

    /// @notice Deploy all Harbor pegged tokens and grant minter roles.
    /// @dev Call INSIDE startBroadcast(). Config must be created before broadcast.
    /// @param config All pegged configs (created by createAllPeggedConfig()).
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    /// @param useLocal Whether to read/write state in the local results directory.
    function deployAllPeggedTokens(AllPeggedConfig memory config, string memory network, bool useLocal) internal {
        // Load existing state to resume partial deployments, or seed fresh if not persisting.
        DeploymentTypes.State memory stateData = _shouldPersistState()
            ? DeploymentState.load(network, systemSalt(), useLocal, _stateDirectoryPrefix())
            : _seedEphemeralState(systemSalt(), network, useLocal);
        stateData.baoFactory = baoFactory();

        console.log("=== Deploying Pegged Tokens ===");
        console.log("systemSalt: %s", systemSalt());
        console.log("network: %s", network);

        // Deploy all pegged tokens and grant roles
        _deployPeggedTokenAndGrantRoles(stateData, config.pegETH, config.marketsETH);
        _deployPeggedTokenAndGrantRoles(stateData, config.pegBTC, config.marketsBTC);
        _deployPeggedTokenAndGrantRoles(stateData, config.pegGOLD, config.marketsGOLD);
        _deployPeggedTokenAndGrantRoles(stateData, config.pegEUR, config.marketsEUR);

        _transferAllOwnerships();

        // Save state
        if (_shouldPersistState()) {
            DeploymentState.save(stateData, _stateDirectoryPrefix());
        }
        console.log("=== Pegged Token Deployment Complete ===");
    }

    /// @notice Deploy a single pegged token, record in state, and grant minter roles.
    function _deployPeggedTokenAndGrantRoles(
        DeploymentTypes.State memory stateData,
        ConfigPeg pegConfig,
        Config_MinterMarket[] memory marketConfigs
    ) private {
        string memory pegKey = pegConfig.key();

        HarborDeployment_Pegged.PeggedTokenDeployment memory deployment = deployPeggedToken(pegConfig);
        DeploymentState.recordImplementation(stateData, deployment.implRecord);
        DeploymentState.recordProxy(stateData, deployment.proxyRecord);

        // Register for ownership transfer at end
        address peggedToken = deployment.proxy;
        _registerForOwnershipTransfer(peggedToken, _saltString(deployment.proxyRecord.id));

        // Grant roles to minters while we still own the token
        console.log("Granting roles for %s", pegKey);
        uint256 minterRole = IMintableRole(peggedToken).MINTER_ROLE();
        uint256 burnerRole = IBurnableRole(peggedToken).BURNER_ROLE();

        for (uint256 i = 0; i < marketConfigs.length; i++) {
            IMarketConfig market = IMarketConfig(address(marketConfigs[i]));
            string memory configPeg = market.peg();

            // Validate that config peg matches this pegged token
            require(
                configPeg.eq(pegKey),
                string.concat("Market config peg '", configPeg, "' does not match pegged token '", pegKey, "'")
            );

            string memory minterKey = MinterMarketConfigLib.salt(marketConfigs[i]);
            address minter = _predictAddress(minterKey, "minter");

            console.log("  minter: %s (%s)", minterKey, minter);
            IBaoRoles(peggedToken).grantRoles(minter, minterRole | burnerRole);
        }
    }

    function _shouldPersistState() internal pure virtual returns (bool) {
        return true;
    }

    function _stateDirectoryPrefix() internal view virtual returns (string memory) {
        return "";
    }

    function _seedEphemeralState(
        string memory systemSaltArg,
        string memory network,
        bool useLocal
    ) private pure returns (DeploymentTypes.State memory stateData) {
        stateData.network = network;
        stateData.saltPrefix = systemSaltArg;
        stateData.useLocal = useLocal;
        return stateData;
    }
}
