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
contract DeployHarbor is Script {
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

    function _do(Mode mode, string memory salt, string memory network) internal {
        console.log("=== %s Harbor ===", mode == Mode.DEPLOY ? "Deploying" : "Smoke Testing");
        console.log("Salt: %s", salt);
        console.log("Network: %s", network);

        HarborMinterDeploymentJsonScript d = new HarborMinterDeploymentJsonScript();

        // do the work
        if (mode == Mode.DEPLOY) {
            d.disableIncrementalLogging();
            d.start(network, salt, "");

            d._deployPegged();
            d._deployLeveraged();
            d._deployFeeReceiver(d.MINTER());
            d._deployPriceOracle();
            d._deployReservePool();
            d._deployMinter();
            d._deployStabilityPool(d.STABILITY_POOL_COLLATERAL(), d.WRAPPED_COLLATERAL());
            d._deployStabilityPool(d.STABILITY_POOL_LEVERAGED(), d.LEVERAGED());
            d._deployFeeReceiver(d.STABILITY_POOL_MANAGER());
            d._deployStabilityPoolManager();
            d._deployGenesis();
        } else {
            d.disableLogging();
            d.start(network, salt, "latest");

            d._smokePegged();
            d._smokeLeveraged();
            d._smokeFeeReceiver(d.MINTER());
            d._smokePriceOracle();
            d._smokeReservePool();
            d._smokeMinter();
            d._smokeStabilityPool(d.STABILITY_POOL_COLLATERAL(), d.WRAPPED_COLLATERAL());
            d._smokeStabilityPool(d.STABILITY_POOL_LEVERAGED(), d.LEVERAGED());
            d._smokeFeeReceiver(d.STABILITY_POOL_MANAGER());
            d._smokeStabilityPoolManager();
            d._smokeGenesis();
        }
        d.finish();

        console.log("\n=== Complete ===");
    }

    function deploy(string memory salt, string memory network) public {
        _do(Mode.DEPLOY, salt, network);
    }

    function smoke(string memory salt, string memory network) public {
        _do(Mode.SMOKE, salt, network);
    }
}
