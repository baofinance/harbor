// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Script} from "forge-std/Script.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {Market} from "@harbor-script/config/ConfigBase.sol";
import {pauserNamed} from "@harbor-script/src/Pausers.sol";

/// @notice Queue a Safe transaction to pause the ETH::fxUSD stabilityPoolLeveraged
/// by upgrading its proxy to BaoPauser_v1.
/// @dev Run via: script/run-script Pause_SPL_ETH_fxUSD --salt harbor_v1 --network mainnet --local
contract Pause_SPL_ETH_fxUSD is Script, HarborDeployer {
    function build() internal override {
        queue(
            stabilityPoolKey(Market("ETH", "fxUSD"), StabilityPoolType.Leveraged),
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (pauserNamed("mainnet", "BaoPauser_v1"), "")),
            "pause: upgrade to BaoPauser_v1"
        );
    }
}
