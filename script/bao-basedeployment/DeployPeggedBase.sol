// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborDeployment_Pegged} from "./HarborDeployment_Pegged.sol";
import {DeploymentState} from "./DeploymentState.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {Config_Peg} from "script/config/pegs/Config_Peg.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {Config_Protocol} from "script/config/chains/Config_Protocol.sol";
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
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @notice Base contract for pegged token deployment orchestration.
/// @dev Provides reusable deployment logic for both production scripts and tests.
abstract contract DeployPeggedBase is HarborDeployment_Pegged, Config_Protocol {
    using LibString for string;

    /// @notice Deploy all Harbor pegged tokens and grant minter roles.
    /// @param systemSalt System salt for CREATE3 deployment (e.g., "harbor_v1").
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    /// @param useLocal Whether to read/write state in the local results directory.
    function deployAllPeggedTokens(string memory systemSalt, string memory network, bool useLocal) internal {
        // Create state store and load existing state
        DeploymentState state = new DeploymentState();
        DeploymentTypes.State memory stateData = state.load(network, systemSalt, useLocal);
        stateData.baoFactory = baoFactory();

        console.log("=== Deploying Pegged Tokens ===");
        console.log("systemSalt: %s", systemSalt);
        console.log("network: %s", network);

        // ETH markets
        Config_MinterMarket[] memory ethMarkets = new Config_MinterMarket[](1);
        ethMarkets[0] = new Config_Market_ETH_fxUSD();

        // BTC markets
        Config_MinterMarket[] memory btcMarkets = new Config_MinterMarket[](2);
        btcMarkets[0] = new Config_Market_BTC_fxUSD();
        btcMarkets[1] = new Config_Market_BTC_stETH();

        // GOLD markets
        Config_MinterMarket[] memory goldMarkets = new Config_MinterMarket[](2);
        goldMarkets[0] = new Config_Market_GOLD_fxUSD();
        goldMarkets[1] = new Config_Market_GOLD_stETH();

        // EUR markets
        Config_MinterMarket[] memory eurMarkets = new Config_MinterMarket[](2);
        eurMarkets[0] = new Config_Market_EUR_fxUSD();
        eurMarkets[1] = new Config_Market_EUR_stETH();

        // Deploy all pegged tokens and grant roles
        _deployPeggedToken(state, stateData, new Config_Peg_ETH(), systemSalt, ethMarkets);
        _deployPeggedToken(state, stateData, new Config_Peg_BTC(), systemSalt, btcMarkets);
        _deployPeggedToken(
            state,
            stateData,
            new Config_Peg_GOLD(),
            systemSalt,
            goldMarkets
        );
        _deployPeggedToken(state, stateData, new Config_Peg_EUR(), systemSalt, eurMarkets);

        // Save state
        state.save(stateData);
        console.log("=== Pegged Token Deployment Complete ===");
    }

    /// @notice Deploy a single pegged token, record in state, and grant minter roles.
    function _deployPeggedToken(
        DeploymentState state,
        DeploymentTypes.State memory stateData,
        Config_Peg pegConfig,
        string memory systemSalt,
        Config_MinterMarket[] memory marketConfigs
    ) private {
        string memory pegKey = pegConfig.key();

        HarborDeployment_Pegged.PeggedTokenDeployment memory deployment = deployPeggedToken(
            baoFactory(),
            pegConfig,
            owner(),
            systemSalt
        );
        state.recordImplementation(stateData, deployment.implRecord);
        state.recordProxy(stateData, deployment.proxyRecord);

        // Grant roles to minters
        address peggedToken = deployment.proxy;
        IBaoFactory factory = IBaoFactory(baoFactory());

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
            bytes32 minterSalt = keccak256(abi.encodePacked(minterKey));
            address minter = factory.predictAddress(minterSalt);

            console.log("  minter: %s (%s)", minterKey, minter);
            IBaoRoles(peggedToken).grantRoles(minter, minterRole | burnerRole);
        }
    }
}
