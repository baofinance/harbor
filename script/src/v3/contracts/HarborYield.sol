// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {HarborYield_v1} from "@harbor/autocompounding/HarborYield_v1.sol";

/// @notice Harbor HarborYield deployment logic.
/// @dev One HarborYield per peg. Manages multiple ERC4626 vaults (AutoCompounders, wrapped
///      collateral, equivalents) that share the same peg. Standalone -- minimal dependencies
///      on the minter deployment infrastructure.
abstract contract HarborYield is HarborFactoryDeployer {
    // ========== HARBOR YIELD DEPLOYMENT ==========

    /// @notice Deploy HarborYield_v1 impl only, record in state.
    function deployHarborYieldImplementation(
        DeploymentTypes.State memory stateData,
        string memory yieldKey,
        string memory tokenName,
        string memory tokenSymbol,
        address swapper
    ) internal virtual returns (address impl) {
        console.log("    > %s", yieldKey);

        impl = address(new HarborYield_v1(tokenName, tokenSymbol, swapper));
        console.log("        Impl:   %s", impl);
        console.log("          Name:   %s", tokenName);
        console.log("          Symbol: %s", tokenSymbol);

        DeploymentState.recordImplementation(
            stateData,
            DeploymentTypes.ImplementationRecord({
                proxy: yieldKey,
                contractSource: "@harbor/autocompounding/HarborYield_v1.sol",
                contractType: "HarborYield_v1",
                implementation: impl,
                deploymentTime: uint64(block.timestamp)
            })
        );
    }

    /// @notice Deploy HarborYield_v1 impl+proxy, record in state.
    function deployHarborYield(
        DeploymentTypes.State memory stateData,
        string memory yieldKey,
        string memory tokenName,
        string memory tokenSymbol,
        address swapper
    ) internal returns (address proxy) {
        address impl = deployHarborYieldImplementation(stateData, yieldKey, tokenName, tokenSymbol, swapper);

        bytes memory initData = abi.encodeCall(HarborYield_v1.initialize, (address(this), owner()));

        proxy = _deployProxyAndRecord(stateData, yieldKey, impl, initData);
    }

    /// @notice Vault registration config.
    struct VaultConfig {
        address vault;         // ERC4626 vault address
        uint96 weight;         // target distribution weight
        bool isAutoCompounder; // true if vault implements IAutoCompounder
    }

    /// @notice Register ERC4626 vaults with a deployed HarborYield.
    /// @param hyProxy The HarborYield proxy address.
    /// @param configs Array of vault configurations to register.
    function configureHarborYield(address hyProxy, VaultConfig[] memory configs) internal {
        for (uint256 i = 0; i < configs.length; i++) {
            address vault = configs[i].vault;
            address asset = IERC4626(vault).asset();
            console.log("        addVault: %s (asset: %s, weight: %s)", vault, asset, configs[i].weight);
            HarborYield_v1(hyProxy).addVault(vault, configs[i].weight, configs[i].isAutoCompounder);
        }
    }
}
