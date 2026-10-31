// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Script} from "forge-std/Script.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {Market} from "@harbor-script/config/ConfigBase.sol";
import {pauserNamed} from "@harbor-script/src/Pausers.sol";

/// @notice Queue a Safe transaction to pause all the stability pools
/// by upgrading its proxy to BaoPauser_v1.
/// @dev Run via: script/run-script Pause_AllStabilityPools --salt harbor_v1 --network mainnet --local
contract Pause_AllStabilityPools is Script, HarborDeployer {
    function queueOneSPMarket(string memory peg, string memory collateral, address pauser) internal {
        queue(
            stabilityPoolKey(Market(peg, collateral), StabilityPoolType.Collateral),
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (pauser, "")),
            string.concat("pause stabilityPool: ", peg, ":", collateral, "Collateral - upgrade to BaoPauser_v1")
        );
        queue(
            stabilityPoolKey(Market(peg, collateral), StabilityPoolType.Leveraged),
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (pauser, "")),
            string.concat("pause stabilityPool: ", peg, ":", collateral, "Leveraged - upgrade to BaoPauser_v1")
        );
        queue(
            minterKey(Market(peg, collateral)),
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (pauser, "")),
            string.concat("pause Minter: ", peg, ":", collateral, " - upgrade to BaoPauser_v1")
        );
    }

    function build() internal override {
        address pauser = pauserNamed("mainnet", "BaoPauser_v1");
        queueOneSPMarket("BTC", "fxUSD", pauser);
        queueOneSPMarket("BTC", "stETH", pauser);
        queueOneSPMarket("ETH", "fxUSD", pauser);
        queueOneSPMarket("EUR", "fxUSD", pauser);
        queueOneSPMarket("EUR", "stETH", pauser);
        queueOneSPMarket("GOLD", "fxUSD", pauser);
        queueOneSPMarket("GOLD", "stETH", pauser);
        queueOneSPMarket("MCAP", "fxUSD", pauser);
        queueOneSPMarket("MCAP", "stETH", pauser);
        queueOneSPMarket("SILVER", "fxUSD", pauser);
        queueOneSPMarket("SILVER", "stETH", pauser);
    }
}
