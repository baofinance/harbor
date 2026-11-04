// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Script} from "forge-std/Script.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {Market} from "@harbor-script/config/ConfigBase.sol";
import {pauserNamed} from "@harbor-script/src/Pausers.sol";

/// @notice Queue Safe transactions to pause every market's stability pool manager by upgrading its proxy to
/// BaoPauser_v1.
/// @dev Run via: script/run-script Pause_AllStabilityPoolManagers --salt harbor_v1 --network mainnet --local
contract Pause_AllStabilityPoolManagers is Script, HarborDeployer {
    function queueOneSPM(string memory peg, string memory collateral, address pauser) internal {
        queue(
            stabilityPoolManagerKey(Market(peg, collateral)),
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (pauser, "")),
            string.concat("pause: ", peg, ":", collateral, " upgrade to BaoPauser_v1")
        );
    }

    function build() internal override {
        address pauser = pauserNamed("mainnet", "BaoPauser_v1");
        queueOneSPM("BTC", "fxUSD", pauser);
        queueOneSPM("BTC", "stETH", pauser);
        queueOneSPM("ETH", "fxUSD", pauser);
        queueOneSPM("EUR", "fxUSD", pauser);
        queueOneSPM("EUR", "stETH", pauser);
        queueOneSPM("GOLD", "fxUSD", pauser);
        queueOneSPM("GOLD", "stETH", pauser);
        queueOneSPM("MCAP", "fxUSD", pauser);
        queueOneSPM("MCAP", "stETH", pauser);
        queueOneSPM("SILVER", "fxUSD", pauser);
        queueOneSPM("SILVER", "stETH", pauser);
    }
}
