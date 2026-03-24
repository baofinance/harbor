// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {LibString} from "@solady/utils/LibString.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PostRebalanceRemediationForStabilityPool_v2} from "src/minter/PostRebalanceRemediationForStabilityPool_v2.sol";
import {SafeBatch} from "script/safe/SafeBatch.s.sol";
import {WellKnownAddress} from "@bao-script/deployment/FactoryDeployer.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";

/// @notice Deploy remediation implementation and queue a Safe batch transaction for
/// the ETH::fxUSD sail stability pool (SPL) remediation.
///
/// Produces one Safe batch file (03_remediate) containing 8 atomic transactions:
///   1. Grant BURNER_ROLE to SPL on sailETH
///   2. Grant ZERO_FEE_ROLE to SPL on minter
///   3. Transfer 82.47 fxSAVE to SPL for collateral restoration
///   4. Upgrade SPL to remediation contract and execute remediate()
///   5. Restore SPL to StabilityPool_v2
///   6. Revoke BURNER_ROLE from SPL
///   7. Revoke ZERO_FEE_ROLE from SPL
///
/// Prerequisites (already executed on mainnet):
///   - SPL paused via Pause_SPL_ETH_fxUSD (proxy points to BaoPauser_v1)
///   - Claimer approved SPL to burnFrom 0.052 sailETH
///   - Bounty receiver approved SPL to burnFrom 0.088 sailETH
/// Minter_v2 upgrade is handled separately via Deploy_Minter_v2_mainnet.
///
/// @dev See doc/remediation-ETH-fxUSD-SPL.md for full context.
/// @dev Run via:
///   script/run-script Remediate_SPL_ETH_fxUSD --salt harbor_v1 --network mainnet --broadcast --local
contract Remediate_SPL_ETH_fxUSD is SafeBatch {
    using LibString for address;

    // ── Addresses ────────────────────────────────────────────────────────
    address constant BAO_PAUSER = 0xd8785d5C51aaDEb3AD1D015Cd67C8A34dBf58f61;
    address constant EXISTING_V2_IMPL = 0x6C0D48839A0B1c9D79dDD4Ad3f407709E0f44be1;
    address constant LEVERAGED = 0x0Cd6BB1a0cfD95e2779EDC6D17b664B481f2EB4C;  // sailETH token
    address constant MINTER = 0xd6E2F8e57b4aFB51C6fA4cbC012e1cE6aEad989F;
    address constant WRAPPED_COLLATERAL = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;  // fxSAVE
    address constant SPL = 0x438B29EC7a1770dDbA37D792F1A6e76231Ef8E06;

    // ── Burn targets ─────────────────────────────────────────────────────
    // Claimer claimed between v1 rebalances; holds 0.052 excess sailETH in wallet
    address constant CLAIMER = 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F;
    uint256 constant CLAIMER_EXCESS = 0.052087080191248362 ether;

    // Bounty receiver from v1 rebalance #1; holds 0.088 excess sailETH
    address constant BOUNTY_RECEIVER = 0xf1674FE69b2920b4de51E909cbf060dd78724CD8;
    uint256 constant BOUNTY_EXCESS = 0.087632380029141447 ether;

    // ── Collateral gap ───────────────────────────────────────────────────
    // fxSAVE to deposit into minter to restore collateral extracted by Exiter's redeems
    uint256 constant COLLATERAL_GAP = 82.466171119621162782 ether;

    function getWellKnownAddresses() public view override returns (WellKnownAddress[] memory addrs) {
        WellKnownAddress[] memory base = super.getWellKnownAddresses();
        addrs = new WellKnownAddress[](base.length + 1);
        for (uint256 i = 0; i < base.length; i++) addrs[i] = base[i];
        addrs[base.length] = WellKnownAddress({addr: CLAIMER, label: "claimer"});
    }

    function build() internal override {
        string memory splSalt = _saltString("ETH", "fxUSD", "stabilityPoolLeveraged");
        address spl = _predictAddressFromFullSalt(splSalt);

        require(
            LEVERAGED == _predictAddressFromFullSalt(_saltString("ETH", "fxUSD", "leveraged")),
            "LEVERAGED is not the correct address"
        );

        // Verify the proxy is paused
        address currentImpl = address(
            uint160(uint256(vm.load(spl, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)))
        );
        require(currentImpl == BAO_PAUSER, "SPL is not paused - run Pause_SPL_ETH_fxUSD first");

        // Deploy remediation implementation
        vm.startBroadcast();
        PostRebalanceRemediationForStabilityPool_v2 remediationImpl = new PostRebalanceRemediationForStabilityPool_v2(
            LEVERAGED,
            MINTER,
            owner()
        );
        vm.stopBroadcast();

        // Claimer and bounty receiver approvals already executed on mainnet.

        // ── Single batch: grant, fund, remediate, restore, revoke, upgrade ──
        // Signed by: harbor multisig
        // All transactions execute atomically in one Safe batch.
        uint256 ZERO_FEE_ROLE = IMinter(MINTER).ZERO_FEE_ROLE();
        uint256 BURNER_ROLE = IBurnableRole(LEVERAGED).BURNER_ROLE();

        // 1. Grant temporary roles
        queue(LEVERAGED,
            abi.encodeCall(IBaoRoles.grantRoles, (spl, BURNER_ROLE)),
            "grant BURNER_ROLE to SPL on sailETH");
        queue(MINTER,
            abi.encodeCall(IBaoRoles.grantRoles, (spl, ZERO_FEE_ROLE)),
            "grant ZERO_FEE_ROLE to SPL on minter");

        // 2. Transfer fxSAVE to SPL for collateral restoration
        queue(WRAPPED_COLLATERAL,
            abi.encodeCall(IERC20.transfer, (spl, COLLATERAL_GAP)),
            "transfer 82.47 fxSAVE to SPL");

        // 3. Upgrade SPL to remediation contract and execute remediate()
        queue(splSalt,
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall,
                (address(remediationImpl), abi.encodeCall(PostRebalanceRemediationForStabilityPool_v2.remediate, ()))),
            string.concat("remediate: ", address(remediationImpl).toHexString()));

        // 4. Restore SPL to StabilityPool_v2
        queue(splSalt,
            abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (EXISTING_V2_IMPL, "")),
            string.concat("restore SPL: ", EXISTING_V2_IMPL.toHexString()));

        // 5. Revoke temporary roles
        queue(LEVERAGED,
            abi.encodeCall(IBaoRoles.revokeRoles, (spl, BURNER_ROLE)),
            "revoke BURNER_ROLE from SPL on sailETH");
        queue(MINTER,
            abi.encodeCall(IBaoRoles.revokeRoles, (spl, ZERO_FEE_ROLE)),
            "revoke ZERO_FEE_ROLE from SPL on minter");

        // No flush — run() saves and executes the single batch automatically.
    }
}
