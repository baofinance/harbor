// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Script} from "forge-std/Script.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {Market} from "@harbor-script/config/ConfigBase.sol";

/// @notice Queue Safe transactions to pause every market's stability pool manager by upgrading its proxy to
/// BaoPauser_v1.
/// @dev Run via: script/run-script Pause_AllStabilityPoolManagers --salt harbor_v1 --network mainnet --local
contract Pause_AllStabilityPoolManagers is Script, HarborDeployer {
    address constant BAO_PAUSER = 0xd8785d5C51aaDEb3AD1D015Cd67C8A34dBf58f61;

    function queueOneSPM(string memory peg, string memory collateral) internal {
        queue(
            stabilityPoolManagerKey(Market(peg, collateral)),
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (BAO_PAUSER, "")),
            string.concat("pause: ", peg, ":", collateral, " upgrade to BaoPauser_v1")
        );
    }

    function build() internal override {
        queueOneSPM("BTC", "fxUSD");
        queueOneSPM("BTC", "stETH");
        queueOneSPM("ETH", "fxUSD");
        queueOneSPM("EUR", "fxUSD");
        queueOneSPM("EUR", "stETH");
        queueOneSPM("GOLD", "fxUSD");
        queueOneSPM("GOLD", "stETH");
        queueOneSPM("MCAP", "fxUSD");
        queueOneSPM("MCAP", "stETH");
        queueOneSPM("SILVER", "fxUSD");
        queueOneSPM("SILVER", "stETH");
    }
}
