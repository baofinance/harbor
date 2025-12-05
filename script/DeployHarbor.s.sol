// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";
import {HarborDeploymentJsonScript} from "@harbor-script/deployment/HarborDeploymentJsonScript.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface ICollateral {
    function symbol() external returns (string memory);
}

/**
 * @title DeployHarbor
 * @notice Simple script to deploy and test Harbor on local Anvil
 * @dev Usage:
 *   1. Start Anvil: anvil
 *   2. Deploy: forge script script/DeployHarbor.s.sol --rpc-url http://localhost:8545 --broadcast
 */
contract DeployHarbor is HarborDeploymentJsonScript {
    enum Mode {
        DEPLOY,
        SMOKE
    }

    // TODO: the 3 parameters should be got from the price oracle - deployed separately?
    function _do(Mode mode, string memory peggedTicker, address collateral, address wrappedCollateral) internal {
        string memory what = (mode == Mode.DEPLOY ? "Deploying" : "Smoke Testing");
        console.log("=== %s Harbor to Anvil ===", what);

        // TODO: get this from somewhere
        string memory network = "anvil";

        // get the system salt from the collateral symbol and the pegged ticker
        string memory collateralSymbol = ICollateral(collateral).symbol();
        string memory baseSymbol = string.concat(peggedTicker, "-", collateralSymbol);
        string memory baseName = string.concat(peggedTicker, " for ", "", collateralSymbol);

        string memory salt = string.concat("harbor_v1-", baseSymbol);

        // now start for that salt
        start(network, salt, mode == Mode.DEPLOY ? "" : "latest");

        // do the work
        if (mode == Mode.DEPLOY) {
            // save the salt based info
            _set(COLLATERAL, collateral);
            _setString(COLLATERAL_SYMBOL, collateralSymbol);
            _set(WRAPPED_COLLATERAL, wrappedCollateral);

            _setString(PEGGED_SYMBOL, string.concat("ha", baseSymbol));
            _setString(PEGGED_NAME, string.concat("Harbor anchored ", baseName));

            _setString(LEVERAGED_SYMBOL, string.concat("hs", baseSymbol));
            _setString(LEVERAGED_NAME, string.concat("Harbor sail ", baseName));

            _deployPegged();
            _deployLeveraged();
            _deployFeeReceiver();
            _deployPriceOracle();
            _deployReservePool();
            _deployMinter();
        } else {
            _smokePegged();
            _smokeLeveraged();
            _smokeFeeReceiver();
            _smokePriceOracle();
            _smokeReservePool();
            _smokeMinter();
        }
        finish();

        console.log("\n=== %s Complete ===", what);
    }

    function run() public {
        _do(Mode.DEPLOY, "USD", 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    }

    function smoke() public {
        _disableLogging();
        _do(Mode.SMOKE, "USD", 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84, 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    }
}
