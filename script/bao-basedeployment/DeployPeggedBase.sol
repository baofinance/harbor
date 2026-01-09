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
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";

/// @notice Base contract for pegged token deployment orchestration.
/// @dev Provides reusable deployment logic for both production scripts and tests.
abstract contract DeployPeggedBase is HarborDeployment_Pegged, Config_Protocol {
    using LibString for string;

    constructor() Config_Protocol("") {}

    /// @notice Deploy all Harbor pegged tokens and grant minter roles.
    /// @param systemSalt System salt for CREATE3 deployment (e.g., "harbor_v1").
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    /// @param useLocal Whether to read/write state in the local results directory.
    function deployAllPeggedTokens(string memory systemSalt, string memory network, bool useLocal) internal {
        DeploymentTypes.State memory stateData = _shouldPersistState()
            ? DeploymentState.load(network, systemSalt, useLocal, _stateDirectoryPrefix())
            : _seedEphemeralState(systemSalt, network, useLocal);
        stateData.baoFactory = baoFactory();

        console.log("=== Deploying Pegged Tokens ===");
        console.log("systemSalt: %s", systemSalt);
        console.log("network: %s", network);

        // ETH markets
        Config_MinterMarket[] memory ethMarkets = new Config_MinterMarket[](1);
        ethMarkets[0] = new Config_Market_ETH_fxUSD(systemSalt);

        // BTC markets
        Config_MinterMarket[] memory btcMarkets = new Config_MinterMarket[](2);
        btcMarkets[0] = new Config_Market_BTC_fxUSD(systemSalt);
        btcMarkets[1] = new Config_Market_BTC_stETH(systemSalt);

        // GOLD markets
        Config_MinterMarket[] memory goldMarkets = new Config_MinterMarket[](2);
        goldMarkets[0] = new Config_Market_GOLD_fxUSD(systemSalt);
        goldMarkets[1] = new Config_Market_GOLD_stETH(systemSalt);

        // EUR markets
        Config_MinterMarket[] memory eurMarkets = new Config_MinterMarket[](2);
        eurMarkets[0] = new Config_Market_EUR_fxUSD(systemSalt);
        eurMarkets[1] = new Config_Market_EUR_stETH(systemSalt);

        // Deploy all pegged tokens and grant roles
        address[4] memory peggedTokens;
        peggedTokens[0] = _deployPeggedToken(stateData, new Config_Peg_ETH(), systemSalt, ethMarkets);
        peggedTokens[1] = _deployPeggedToken(stateData, new Config_Peg_BTC(), systemSalt, btcMarkets);
        peggedTokens[2] = _deployPeggedToken(stateData, new Config_Peg_GOLD(), systemSalt, goldMarkets);
        peggedTokens[3] = _deployPeggedToken(stateData, new Config_Peg_EUR(), systemSalt, eurMarkets);

        _transferPeggedOwnerships(peggedTokens);

        // Save state
        if (_shouldPersistState()) {
            DeploymentState.save(stateData, _stateDirectoryPrefix());
        }
        console.log("=== Pegged Token Deployment Complete ===");
    }

    /// @notice Deploy a single pegged token, record in state, and grant minter roles.
    function _deployPeggedToken(
        DeploymentTypes.State memory stateData,
        Config_Peg pegConfig,
        string memory systemSalt,
        Config_MinterMarket[] memory marketConfigs
    ) private returns (address peggedToken) {
        string memory pegKey = pegConfig.key();

        HarborDeployment_Pegged.PeggedTokenDeployment memory deployment = deployPeggedToken(
            baoFactory(),
            pegConfig,
            owner(),
            systemSalt
        );
        DeploymentState.recordImplementation(stateData, deployment.implRecord);
        DeploymentState.recordProxy(stateData, deployment.proxyRecord);

        // Grant roles to minters
        peggedToken = deployment.proxy;
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
            // Legacy mainnet salt format appends "::minter" to the market key
            bytes32 minterSalt = keccak256(abi.encodePacked(systemSalt, "::", minterKey, "::minter"));
            address minter = factory.predictAddress(minterSalt);

            console.log("  minter: %s (%s)", minterKey, minter);
            IBaoRoles(peggedToken).grantRoles(minter, minterRole | burnerRole);
        }
    }

    function _transferPeggedOwnerships(address[4] memory peggedTokens) private {
        address finalOwner = owner();
        for (uint256 i = 0; i < peggedTokens.length; i++) {
            address peggedToken = peggedTokens[i];
            if (peggedToken == address(0)) continue;

            address currentOwner = MintableBurnableERC20_v1(peggedToken).owner();
            if (currentOwner == finalOwner) continue;

            console.log("Transferring ownership for %s -> %s", peggedToken, finalOwner);
            MintableBurnableERC20_v1(peggedToken).transferOwnership(finalOwner);
        }
    }

    function _shouldPersistState() internal pure virtual returns (bool) {
        return true;
    }

    function _stateDirectoryPrefix() internal view virtual returns (string memory) {
        return "";
    }

    function _seedEphemeralState(
        string memory systemSalt,
        string memory network,
        bool useLocal
    ) private pure returns (DeploymentTypes.State memory stateData) {
        stateData.network = network;
        stateData.saltPrefix = systemSalt;
        stateData.useLocal = useLocal;
        return stateData;
    }
}
