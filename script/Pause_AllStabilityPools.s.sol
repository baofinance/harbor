// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Script} from "forge-std/Script.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {Market} from "@harbor-script/config/ConfigBase.sol";

/// @notice Queue a Safe transaction to pause all the stability pools
/// by upgrading its proxy to BaoPauser_v1.
/// @dev Run via: script/run-script Pause_AllStabilityPools --salt harbor_v1 --network mainnet --local
contract Pause_AllStabilityPools is Script, HarborDeployer {
    address constant BAO_PAUSER = 0xd8785d5C51aaDEb3AD1D015Cd67C8A34dBf58f61;

    function queueOneSPMarket(string memory peg, string memory collateral) internal {
        queue(
            stabilityPoolKey(Market(peg, collateral), StabilityPoolType.Collateral),
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (BAO_PAUSER, "")),
            string.concat("pause stabilityPool: ", peg, ":", collateral, "Collateral - upgrade to BaoPauser_v1")
        );
        queue(
            stabilityPoolKey(Market(peg, collateral), StabilityPoolType.Leveraged),
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (BAO_PAUSER, "")),
            string.concat("pause stabilityPool: ", peg, ":", collateral, "Leveraged - upgrade to BaoPauser_v1")
        );
        queue(
            minterKey(Market(peg, collateral)),
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (BAO_PAUSER, "")),
            string.concat("pause Minter: ", peg, ":", collateral, " - upgrade to BaoPauser_v1")
        );
    }

    function build() internal override {
        queueOneSPMarket("BTC", "fxUSD");
        queueOneSPMarket("BTC", "stETH");
        queueOneSPMarket("ETH", "fxUSD");
        queueOneSPMarket("EUR", "fxUSD");
        queueOneSPMarket("EUR", "stETH");
        queueOneSPMarket("GOLD", "fxUSD");
        queueOneSPMarket("GOLD", "stETH");
        queueOneSPMarket("MCAP", "fxUSD");
        queueOneSPMarket("MCAP", "stETH");
        queueOneSPMarket("SILVER", "fxUSD");
        queueOneSPMarket("SILVER", "stETH");
    }
}
