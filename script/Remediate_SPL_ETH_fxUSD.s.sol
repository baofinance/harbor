// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {LibString} from "@solady/utils/LibString.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PostRebalanceRemediationForStabilityPool_v2} from "src/minter/PostRebalanceRemediationForStabilityPool_v2.sol";
import {SafeBatch} from "script/safe/SafeBatch.s.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

/// @notice Deploy remediation implementation and queue Safe transactions for
/// the ETH::fxUSD sail stability pool remediation.
/// @dev Assumes the proxy is already paused via Pause_SPL_ETH_fxUSD.
/// @dev See doc/remediation-ETH-fxUSD-SPL.md for full context.
/// @dev Run via:
///   script/run-script Remediate_SPL_ETH_fxUSD --salt harbor_v1 --network mainnet --broadcast --local
contract Remediate_SPL_ETH_fxUSD is SafeBatch {
    using LibString for address;

    address constant BAO_PAUSER = 0xd8785d5C51aaDEb3AD1D015Cd67C8A34dBf58f61;
    address constant EXISTING_V2_IMPL = 0x6C0D48839A0B1c9D79dDD4Ad3f407709E0f44be1;
    address constant LIQUIDATION_TOKEN = 0x0Cd6BB1a0cfD95e2779EDC6D17b664B481f2EB4C;
    uint256 constant BURNER_ROLE = 1 << 1; // from MintableBurnableERC20_v1

    function build() internal override {
        string memory splSalt = _saltString("ETH", "fxUSD", "stabilityPoolLeveraged");
        address spl = _predictAddressFromFullSalt(splSalt);

        // Verify the proxy is paused
        address currentImpl = address(uint160(uint256(vm.load(
            spl, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
        ))));
        require(currentImpl == BAO_PAUSER, "SPL is not paused - run Pause_SPL_ETH_fxUSD first");

        // Deploy remediation implementation
        vm.startBroadcast();
        PostRebalanceRemediationForStabilityPool_v2 remediationImpl =
            new PostRebalanceRemediationForStabilityPool_v2(LIQUIDATION_TOKEN, owner());
        vm.stopBroadcast();

        // 1. Grant BURNER_ROLE to SPL on sailETH token
        //    Allows remediation to burn from pool and burnFrom Claimer
        queue(LIQUIDATION_TOKEN,
            abi.encodeCall(IBaoRoles.grantRoles, (spl, BURNER_ROLE)),
            "grant BURNER_ROLE to SPL"
        );

        // 2. Remediate: upgrade to remediation contract, calling remediate()
        //    Corrects integral, burns excess from pool, burns excess from Claimer
        queue(splSalt,
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (
                address(remediationImpl),
                abi.encodeCall(PostRebalanceRemediationForStabilityPool_v2.remediate, ())
            )),
            string.concat("remediate: ", address(remediationImpl).toHexString())
        );

        // 3. Restore: upgrade back to StabilityPool_v2
        queue(splSalt,
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (EXISTING_V2_IMPL, "")),
            string.concat("restore: ", EXISTING_V2_IMPL.toHexString())
        );

        // 4. Revoke BURNER_ROLE from SPL
        queue(LIQUIDATION_TOKEN,
            abi.encodeCall(IBaoRoles.revokeRoles, (spl, BURNER_ROLE)),
            "revoke BURNER_ROLE from SPL"
        );
    }
}
