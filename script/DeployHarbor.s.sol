// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";

import {HarborMinterDeploymentJsonScript} from "@harbor-script/deployment/HarborMinterDeploymentJsonScript.sol";

/**
 * @title DeployHarbor
 * @notice Deploy Harbor to a network using configuration from deployments/{salt}.json
 * @dev Usage:
 *   deploy-harbor --salt harbor_v1-USD-stETH --network local --deploy
 *   deploy-harbor --salt harbor_v1-USD-stETH --network local --smoke
 */
contract DeployHarbor is HarborMinterDeploymentJsonScript {
    // address constant HARBORMULTISIG = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;

    // function setBaoFactoryOperator() public {
    //     console.log("=== Setting BaoFactory Operator ===");
    //     address baoFactory = _ensureBaoFactory();
    //     if (!BaoFactory(baoFactory).isCurrentOperator(msg.sender)) {
    //         console.log("Setting BaoFactory operator to Harbor Multisig: %s", msg.sender);
    //         vm.prank(BaoFactory(baoFactory).owner());
    //         BaoFactory(baoFactory).setOperator(msg.sender, 365 days);
    //     } else {
    //         console.log("BaoFactory operator is already an operator: %s", msg.sender);
    //     }
    //     console.log("=== BaoFactory Operator Set Complete ===\n");
    // }

    enum Mode {
        DEPLOY,
        SMOKE
    }

    function _doMinter(Mode mode, string memory salt, string memory network) internal {
        console.log("=== %s Harbor ===", mode == Mode.DEPLOY ? "Deploying" : "Smoke Testing");
        console.log("Salt: %s", salt);
        console.log("Network: %s", network);

        // do the work
        if (mode == Mode.DEPLOY) {
            disableIncrementalLogging();

            start(network, salt, "");

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
            disableLogging();
            start(network, salt, "latest");

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

    function deployMinter(string memory salt, string memory network) public {
        _doMinter(Mode.DEPLOY, salt, network);
    }

    function smokeMinter(string memory salt, string memory network) public {
        _doMinter(Mode.SMOKE, salt, network);
    }
}
