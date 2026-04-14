// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {HarborYield_v1} from "@harbor/autocompounding/HarborYield_v1.sol";
import {ConfigTokenNames} from "script/config/ConfigTokenNames.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";

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
        ConfigPeg pegConfig
    ) internal virtual returns (address impl) {
        console.log("    > %s", yieldKey);

        ConfigTokenNames names = ConfigTokenNames(address(pegConfig));
        string memory tokenName = names.harborYieldName();
        string memory tokenSymbol = names.harborYieldSymbol();
        address swapper = _predictAddressFromFullSalt("harbor_v1::swapper");
        address pegToken = _predictAddress(_key(pegConfig.key(), "pegged"));

        impl = address(new HarborYield_v1(tokenName, tokenSymbol, swapper, pegToken));
        console.log("        Impl:      %s", impl);
        console.log("          Name:    %s", tokenName);
        console.log("          Symbol:  %s", tokenSymbol);
        console.log("          Asset:   %s", pegToken);

        _recordImplementation(
            stateData,
            yieldKey,
            "@harbor/autocompounding/HarborYield_v1.sol",
            "HarborYield_v1",
            impl
        );
    }

    /// @notice Deploy HarborYield_v1 impl+proxy, record in state.
    function deployHarborYield(
        DeploymentTypes.State memory stateData,
        string memory yieldKey,
        ConfigPeg pegConfig
    ) internal returns (address proxy) {
        address impl = deployHarborYieldImplementation(stateData, yieldKey, pegConfig);

        bytes memory initData = abi.encodeCall(HarborYield_v1.initialize, (address(this), owner()));

        proxy = _deployProxyAndRecord(stateData, yieldKey, impl, initData);
    }

    /// @notice Vault registration config.
    /// @dev For AutoCompounder vaults, leave `valuationOracle` as `address(0)` — HY introspects
    ///      the AC directly. For equivalent-yield vaults, `valuationOracle` must be a deployed
    ///      `IWrappedPriceOracle` pricing the equivalent's asset against the peg token.
    struct VaultConfig {
        address vault; // ERC4626 vault address
        uint64 weight; // target distribution weight
        bool isAutoCompounder; // true if vault implements IAutoCompounder
        address valuationOracle; // only for !isAutoCompounder; must be address(0) for ACs
    }

    /// @notice Register ERC4626 vaults with a deployed HarborYield.
    /// @param hyProxy The HarborYield proxy address.
    /// @param configs Array of vault configurations to register.
    function configureHarborYield(address hyProxy, VaultConfig[] memory configs) internal {
        for (uint256 i = 0; i < configs.length; i++) {
            address vault = configs[i].vault;
            address asset = IERC4626(vault).asset();
            console.log("        addVault: %s (asset: %s, weight: %s)", vault, asset, configs[i].weight);
            if (configs[i].isAutoCompounder) {
                HarborYield_v1(hyProxy).addAutoCompounderVault(vault, configs[i].weight);
            } else {
                HarborYield_v1(hyProxy).addEquivalentVault(vault, configs[i].weight, configs[i].valuationOracle);
            }
        }
    }
}
