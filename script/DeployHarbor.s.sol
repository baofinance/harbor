// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";

import {HarborMinterDeploymentJsonScript} from "@harbor-script/deployment/HarborMinterDeploymentJsonScript.sol";
import {HarborPeggedDeploymentJsonScript} from "@harbor-script/deployment/HarborPeggedDeploymentJsonScript.sol";

enum Mode {
    DEPLOY,
    SMOKE
}

/**
 * @title DeployHarbor
 * @notice Deploy Harbor to a network using configuration from deployments/{salt}.json
 * @dev Usage:
 *   deploy-harbor --salt harbor_v1-USD-stETH --network local --deploy
 *   deploy-harbor --salt harbor_v1-USD-stETH --network local --smoke
 */
contract DeployHarborPegged is HarborPeggedDeploymentJsonScript {
    function _doPegged(
        Mode mode,
        string memory network,
        string memory salt,
        string memory peg,
        string[] memory collaterals
    ) internal {
        console.log("=== %s Harbor Pegged Token (%s) ===", mode == Mode.DEPLOY ? "Deploying" : "Smoke Testing", peg);
        console.log("Network: %s", network);
        console.log("Salt: %s", salt);
        console.log("Pegged: %s", peg);
        for (uint c = 0; c < collaterals.length; ++c) {
            console.log("Collateral: %s", collaterals[c]);
        }

        string memory systemSalt = string.concat(salt, "::", peg);
        console.log("System salt %s", systemSalt);

        // do the work
        if (mode == Mode.DEPLOY) {
            disableIncrementalLogging();

            start(network, systemSalt, "");

            _deployPegged(collaterals);
        } else {
            setReadOnly();

            start(network, systemSalt, "latest");

            _smokePegged();
        }
        finish();
    }

    function deployPegged(
        string memory network,
        string memory salt,
        string memory peg,
        string[] memory collaterals
    ) public {
        _doPegged(Mode.DEPLOY, network, salt, peg, collaterals);
    }

    function smokePegged(
        string memory network,
        string memory salt,
        string memory peg,
        string[] memory collaterals
    ) public {
        _doPegged(Mode.SMOKE, network, salt, peg, collaterals);
    }
}

contract DeployHarborMinter is HarborMinterDeploymentJsonScript {
    function _doMinter(
        Mode mode,
        string memory network,
        string memory salt,
        string memory peg,
        string memory collateral
    ) internal {
        console.log("=== %s Harbor Minter ===", mode == Mode.DEPLOY ? "Deploying" : "Smoke Testing");
        console.log("Network: %s", network);
        console.log("Salt: %s", salt);
        console.log("Pegged: %s", peg);
        console.log("Collateral: %s", collateral);

        string memory systemSalt = string.concat(salt, "::", peg, "::", collateral);
        console.log("System salt %s", systemSalt);

        // do the work
        if (mode == Mode.DEPLOY) {
            disableIncrementalLogging();

            start(network, systemSalt, "");

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
            setReadOnly();

            start(network, systemSalt, "latest");

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

    function deployMinter(
        string memory network,
        string memory salt,
        string memory peg,
        string memory collateral
    ) public {
        _doMinter(Mode.DEPLOY, network, salt, peg, collateral);
    }

    function smokeMinter(
        string memory network,
        string memory salt,
        string memory peg,
        string memory collateral
    ) public {
        _doMinter(Mode.SMOKE, network, salt, peg, collateral);
    }
}
