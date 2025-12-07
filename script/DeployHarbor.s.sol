// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {HarborDeploymentJsonScript} from "@harbor-script/deployment/HarborDeploymentJsonScript.sol";
import {LibString} from "@solady/utils/LibString.sol";

interface ICollateral {
    function symbol() external returns (string memory);
}

/**
 * @title DeployHarbor
 * @notice Deploy Harbor to a network using configuration from deployments/{salt}.json
 * @dev Usage:
 *   deploy-harbor --salt harbor_v1-USD-stETH --network local --deploy
 *   deploy-harbor --salt harbor_v1-USD-stETH --network local --smoke
 */
contract DeployHarbor is HarborDeploymentJsonScript {
    using LibString for string;
    using stdJson for string;

    error ChainIdMismatch(uint256 expected, uint256 actual);
    error SaltMismatch(string expected, string actual);

    enum Mode {
        DEPLOY,
        SMOKE
    }

    function _do(Mode mode, string memory salt, string memory network) internal {
        console.log("=== %s Harbor ===", mode == Mode.DEPLOY ? "Deploying" : "Smoke Testing");
        console.log("Salt: %s", salt);
        console.log("Network: %s", network);

        // Load the config file and validate chain ID
        string memory configJson = vm.readFile(string.concat("deployments/", salt, ".json"));
        string memory networkPath = string.concat("$.networks.", network);

        {
            uint256 expectedChainId = configJson.readUint(string.concat(networkPath, ".chainId"));
            if (block.chainid != expectedChainId) {
                revert ChainIdMismatch(expectedChainId, block.chainid);
            }
        }

        // Get network-specific addresses and collateral info
        address collateral = configJson.readAddress(string.concat(networkPath, ".collateral"));
        address wrappedCollateral = configJson.readAddress(string.concat(networkPath, ".wrappedCollateral"));
        string memory collateralSymbol = ICollateral(collateral).symbol();

        // Validate salt matches config
        {
            string memory expectedSalt = string.concat(
                configJson.readString("$.prefix"), "-", configJson.readString("$.peggedTicker"), "-", collateralSymbol
            );
            if (!salt.eq(expectedSalt)) {
                revert SaltMismatch(expectedSalt, salt);
            }
        }

        // Derive base names (reuse configJson variable since we're done with config)
        string memory baseSymbol =
            string.concat(configJson.readString("$.peggedTicker"), "-", collateralSymbol);
        configJson = string.concat(configJson.readString("$.peggedTicker"), " for ", collateralSymbol); // now baseName

        // Start the deployment session
        start(network, salt, mode == Mode.DEPLOY ? "" : "latest");

        // do the work
        if (mode == Mode.DEPLOY) {
            // save the salt based info
            _set(COLLATERAL, collateral);
            _setString(COLLATERAL_SYMBOL, collateralSymbol);
            _set(WRAPPED_COLLATERAL, wrappedCollateral);

            _setString(PEGGED_SYMBOL, string.concat("ha", baseSymbol));
            _setString(PEGGED_NAME, string.concat("Harbor anchored ", configJson));

            _setString(LEVERAGED_SYMBOL, string.concat("hs", baseSymbol));
            _setString(LEVERAGED_NAME, string.concat("Harbor sail ", configJson));

            _deployPegged();
            _deployLeveraged();
            _deployFeeReceiver(MINTER);
            _deployPriceOracle();
            _deployReservePool();
            _deployMinter();
            _deployStabilityPool(STABILITY_POOL_COLLATERAL, WRAPPED_COLLATERAL);
            _deployStabilityPool(STABILITY_POOL_LEVERAGED, LEVERAGED);
            _deployFeeReceiver(STABILITY_POOL_MANAGER);
            _deployStabilityPoolManager();
            _deployGenesis();
        } else {
            _smokePegged();
            _smokeLeveraged();
            _smokeFeeReceiver(MINTER);
            _smokePriceOracle();
            _smokeReservePool();
            _smokeMinter();
            _smokeStabilityPool(STABILITY_POOL_COLLATERAL, WRAPPED_COLLATERAL);
            _smokeStabilityPool(STABILITY_POOL_LEVERAGED, LEVERAGED);
            _smokeFeeReceiver(STABILITY_POOL_MANAGER);
            _smokeStabilityPoolManager();
            _smokeGenesis();
        }

        finish();
        console.log("\n=== Complete ===");
    }

    function deploy(string memory salt, string memory network) public {
        _do(Mode.DEPLOY, salt, network);
    }

    function smoke(string memory salt, string memory network) public {
        _disableLogging();
        _do(Mode.SMOKE, salt, network);
    }
}
