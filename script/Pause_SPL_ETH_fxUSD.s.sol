// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;
import {SaltString} from "@bao-script/deployment/SaltString.sol";

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Script} from "forge-std/Script.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";

/// @notice Queue a Safe transaction to pause the ETH::fxUSD stabilityPoolLeveraged
/// by upgrading its proxy to BaoPauser_v1.
/// @dev Run via: script/run-script Pause_SPL_ETH_fxUSD --salt harbor_v1 --network mainnet --local
contract Pause_SPL_ETH_fxUSD is Script, HarborDeployer {
    address constant BAO_PAUSER = 0xd8785d5C51aaDEb3AD1D015Cd67C8A34dBf58f61;

    function build() internal override {
        queue(
            stabilityPoolKey(SaltString.key("ETH", "fxUSD"), StabilityPoolType.Leveraged),
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (BAO_PAUSER, "")),
            "pause: upgrade to BaoPauser_v1"
        );
    }
}
