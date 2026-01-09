// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborDeployment_MinterTokens} from "./HarborDeployment_MinterTokens.sol";
import {DeploymentState} from "./DeploymentState.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {Config_Peg} from "script/config/pegs/Config_Peg.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";
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
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";

/// @notice Orchestration for minter token deployment.
/// @dev This file contains ONLY orchestration (deployAll* functions).
/// @dev Contract-specific deployment logic lives in HarborDeployment_MinterTokens.sol.
/// @dev See deployment2-design.md Section 3.3.2 for file organization pattern.
abstract contract DeployMintersBase is HarborDeployment_MinterTokens, Config_Protocol {
    constructor() Config_Protocol("") {}

    /// @notice Deploy all Harbor minter tokens (pegged and leveraged) and grant minter roles.
    /// @param systemSalt System salt for CREATE3 deployment (e.g., "harbor_v1").
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    /// @param useLocal Whether to read/write state in the local results directory.
    function deployAllMinters(string memory systemSalt, string memory network, bool useLocal) internal {
        DeploymentTypes.State memory stateData = _shouldPersistState()
            ? DeploymentState.load(network, systemSalt, useLocal, _stateDirectoryPrefix())
            : _seedEphemeralState(systemSalt, network, useLocal);
        stateData.baoFactory = baoFactory();

        console.log("=== Deploying Minter Tokens (Pegged + Leveraged) ===");
        console.log("systemSalt: %s", systemSalt);
        console.log("network: %s", network);

        address[4] memory peggedTokens = _deployAllPeggedTokens(stateData, systemSalt);
        address[] memory leveragedTokens = _deployAllLeveragedTokens(stateData, systemSalt);

        _transferOwnerships(peggedTokens, leveragedTokens);

        if (_shouldPersistState()) {
            DeploymentState.save(stateData, _stateDirectoryPrefix());
        }
        console.log("=== Minter Token Deployment Complete ===");
    }

    /// @notice Deploy all pegged tokens (one per peg: ETH, BTC, GOLD, EUR).
    /// @dev Split from leveraged for composability - can be called independently.
    function _deployAllPeggedTokens(
        DeploymentTypes.State memory stateData,
        string memory systemSalt
    ) private returns (address[4] memory peggedTokens) {
        console.log("\n--- Deploying Pegged Tokens ---");

        address factory = baoFactory();
        address tokenOwner = owner();

        // ETH peg with its markets
        {
            Config_MinterMarket[] memory markets = new Config_MinterMarket[](1);
            markets[0] = new Config_Market_ETH_fxUSD(systemSalt);
            peggedTokens[0] = deployPeggedTokenWithRoles(
                stateData,
                new Config_Peg_ETH(),
                markets,
                factory,
                tokenOwner,
                systemSalt
            );
        }

        // BTC peg with its markets
        {
            Config_MinterMarket[] memory markets = new Config_MinterMarket[](2);
            markets[0] = new Config_Market_BTC_fxUSD(systemSalt);
            markets[1] = new Config_Market_BTC_stETH(systemSalt);
            peggedTokens[1] = deployPeggedTokenWithRoles(
                stateData,
                new Config_Peg_BTC(),
                markets,
                factory,
                tokenOwner,
                systemSalt
            );
        }

        // GOLD peg with its markets
        {
            Config_MinterMarket[] memory markets = new Config_MinterMarket[](2);
            markets[0] = new Config_Market_GOLD_fxUSD(systemSalt);
            markets[1] = new Config_Market_GOLD_stETH(systemSalt);
            peggedTokens[2] = deployPeggedTokenWithRoles(
                stateData,
                new Config_Peg_GOLD(),
                markets,
                factory,
                tokenOwner,
                systemSalt
            );
        }

        // EUR peg with its markets
        {
            Config_MinterMarket[] memory markets = new Config_MinterMarket[](2);
            markets[0] = new Config_Market_EUR_fxUSD(systemSalt);
            markets[1] = new Config_Market_EUR_stETH(systemSalt);
            peggedTokens[3] = deployPeggedTokenWithRoles(
                stateData,
                new Config_Peg_EUR(),
                markets,
                factory,
                tokenOwner,
                systemSalt
            );
        }
    }

    /// @notice Deploy all leveraged tokens (one per market).
    /// @dev Split from pegged for composability - can be called independently.
    function _deployAllLeveragedTokens(
        DeploymentTypes.State memory stateData,
        string memory systemSalt
    ) private returns (address[] memory leveragedTokens) {
        console.log("\n--- Deploying Leveraged Tokens ---");

        leveragedTokens = new address[](7); // 1 + 2 + 2 + 2 = 7 markets total

        address factory = baoFactory();
        address tokenOwner = owner();
        uint256 idx = 0;

        // ETH peg markets
        leveragedTokens[idx++] = deployLeveragedTokenWithRoles(
            stateData,
            new Config_Market_ETH_fxUSD(systemSalt),
            factory,
            tokenOwner,
            systemSalt
        );

        // BTC peg markets
        leveragedTokens[idx++] = deployLeveragedTokenWithRoles(
            stateData,
            new Config_Market_BTC_fxUSD(systemSalt),
            factory,
            tokenOwner,
            systemSalt
        );
        leveragedTokens[idx++] = deployLeveragedTokenWithRoles(
            stateData,
            new Config_Market_BTC_stETH(systemSalt),
            factory,
            tokenOwner,
            systemSalt
        );

        // GOLD peg markets
        leveragedTokens[idx++] = deployLeveragedTokenWithRoles(
            stateData,
            new Config_Market_GOLD_fxUSD(systemSalt),
            factory,
            tokenOwner,
            systemSalt
        );
        leveragedTokens[idx++] = deployLeveragedTokenWithRoles(
            stateData,
            new Config_Market_GOLD_stETH(systemSalt),
            factory,
            tokenOwner,
            systemSalt
        );

        // EUR peg markets
        leveragedTokens[idx++] = deployLeveragedTokenWithRoles(
            stateData,
            new Config_Market_EUR_fxUSD(systemSalt),
            factory,
            tokenOwner,
            systemSalt
        );
        leveragedTokens[idx++] = deployLeveragedTokenWithRoles(
            stateData,
            new Config_Market_EUR_stETH(systemSalt),
            factory,
            tokenOwner,
            systemSalt
        );
    }

    /// @notice Transfer ownership of all deployed tokens to final owner.
    function _transferOwnerships(address[4] memory peggedTokens, address[] memory leveragedTokens) private {
        address finalOwner = owner();

        for (uint256 i = 0; i < peggedTokens.length; i++) {
            _transferTokenOwnership(peggedTokens[i], finalOwner, "pegged");
        }

        for (uint256 i = 0; i < leveragedTokens.length; i++) {
            _transferTokenOwnership(leveragedTokens[i], finalOwner, "leveraged");
        }
    }

    function _transferTokenOwnership(address token, address finalOwner, string memory tokenType) private {
        if (token == address(0)) return;

        address currentOwner = MintableBurnableERC20_v1(token).owner();
        if (currentOwner == finalOwner) return;

        console.log("Transferring %s ownership for %s -> %s", tokenType, token, finalOwner);
        MintableBurnableERC20_v1(token).transferOwnership(finalOwner);
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
