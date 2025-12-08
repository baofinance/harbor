// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborDeploymentJsonScript} from "@harbor-script/deployment/HarborDeploymentJsonScript.sol";

/**
 * @title DeployHarbor
 * @notice Deploy Harbor to a network using configuration from deployments/{salt}.json
 * @dev Usage:
 *   deploy-harbor --salt harbor_v1-USD-stETH --network local --deploy
 *   deploy-harbor --salt harbor_v1-USD-stETH --network local --smoke
 */
contract DeployHarbor is HarborDeploymentJsonScript {
    enum Mode {
        DEPLOY,
        SMOKE
    }

    function _do(Mode mode, string memory salt, string memory network) internal {
        console.log("=== %s Harbor ===", mode == Mode.DEPLOY ? "Deploying" : "Smoke Testing");
        console.log("Salt: %s", salt);
        console.log("Network: %s", network);

        start(network, salt, mode == Mode.DEPLOY ? "" : "latest");

        // do the work
        if (mode == Mode.DEPLOY) {
            // Copy input addresses to output contract slots
            _set(COLLATERAL, _getAddress(COLLATERAL_INPUT));
            _set(WRAPPED_COLLATERAL, _getAddress(WRAPPED_COLLATERAL_INPUT));

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
