// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";

import {LibString} from "@solady/utils/LibString.sol";

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
/**
 * @title DeployHarbor
 * @notice Deploy Harbor to a network using configuration from deployments/{salt}.json
 * @dev Usage:
 *   deploy-harbor --salt harbor_v1-USD-stETH --network local --deploy
 *   deploy-harbor --salt harbor_v1-USD-stETH --network local --smoke
 */
contract DeployHarborMinter is HarborMinterDeploymentJsonScript {
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

    function _doMinter(Mode mode, string memory salt, string memory network) internal {
        console.log("=== %s Harbor ===", mode == Mode.DEPLOY ? "Deploying" : "Smoke Testing");
        console.log("Salt: %s", salt);
        console.log("Network: %s", network);

        // do the work
        if (mode == Mode.DEPLOY) {
            disableIncrementalLogging();

            start(network, salt, "");

            // _deployPegged();
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

            // _smokePegged();
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

    function addr(
        string memory /* prefix */,
        string memory /* peg */,
        string memory /* collateral */,
        string memory /* key */
    ) public pure returns (address) {
        // address factory = LibString.eq(prefix, "test2")
        //     ? 0x232C909F51Ce792e7F39106C75A3ED43F12d3554
        //     : _getAddress(BAO_FACTORY);
        return address(0); // predictAddress(string.concat(prefix, "::", peg, "::", collateral, "::", key), factory);
    }

    function deploySPImpl(
        string memory network,
        string memory salt,
        string memory peg,
        string memory collateral
    ) public {
        console.log("=== Deploying Harbor Stability Pool Implementation ===");
        console.log("Network: %s", network);
        console.log("Salt: %s", salt);
        console.log("Pegged: %s", peg);
        console.log("Collateral: %s", collateral);

        string memory systemSalt = string.concat(salt, "::", peg, "::", collateral);
        console.log("System salt %s", systemSalt);

        disableIncrementalLogging();

        start(network, systemSalt, "");

        console.log(
            "Deploying Stability Pool %s, %s, implementation ...",
            STABILITY_POOL_COLLATERAL,
            WRAPPED_COLLATERAL
        );
        address spCol = _deployStabilityPoolImplementation(
            addr(salt, peg, collateral, "minter"),
            _get(WRAPPED_COLLATERAL)
        );
        console.log("Deployed at %s", spCol);

        console.log("Deploying Stability Pool %s, %s, implementation ...", STABILITY_POOL_COLLATERAL, LEVERAGED);
        address spLev = _deployStabilityPoolImplementation(
            addr(salt, peg, collateral, "minter"),
            addr(salt, peg, collateral, "leveraged")
        );
        console.log("Deployed at %s", spLev);

        console.log("");
        console.log("* %s", string.concat(systemSalt, "::stabilityPoolCollateral"));
        console.log("  * proxy         : %s", addr(salt, peg, collateral, "stabilityPoolCollateral"));
        console.log("  * implementation: %s", spCol);

        console.log("* %s", string.concat(systemSalt, "::stabilityPoolLeveraged"));
        console.log("  * proxy         : %s", addr(salt, peg, collateral, "stabilityPoolLeveraged"));
        console.log("  * implementation: %s", spLev);

        console.log("");
        console.log("* %s", string.concat(systemSalt, "::stabilityPoolCollateral"));
        console.log(
            "  * proxy         : http://etherscan.io/address/%s#code",
            addr(salt, peg, collateral, "stabilityPoolCollateral")
        );
        console.log("  * implementation: http://etherscan.io/address/%s#code", spCol);

        console.log("* %s", string.concat(systemSalt, "::stabilityPoolLeveraged"));
        console.log(
            "  * proxy         : http://etherscan.io/address/%s#code",
            addr(salt, peg, collateral, "stabilityPoolLeveraged")
        );
        console.log("  * implementation: http://etherscan.io/address/%s#code", spLev);

        finish();

        console.log("\n=== Complete ===");
    }
}
