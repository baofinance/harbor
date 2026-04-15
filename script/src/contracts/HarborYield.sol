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
    // Salt-type constant for the collateral AC — mirrors the value in
    // script/src/contracts/AutoCompounder.sol. Kept local to avoid cross-abstract inheritance.
    string private constant _AUTOCOMPOUNDER_COLLATERAL = "autoCompounderCollateral";

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

    /// @notice Register an AutoCompounder for a market as a managed vault in HY.
    /// @param marketKey Salt key of the market whose collateral AutoCompounder is being registered
    ///                  (e.g., "EUR::fxUSD"). The collateral AC address is derived from this.
    /// @param weight Target distribution weight for this AC in the HY basket.
    struct AutoCompounderVaultConfig {
        string marketKey;
        uint64 weight;
    }

    /// @notice Register an equivalent-yield ERC4626 as a managed vault in HY.
    /// @param vault The ERC4626 vault address (e.g., an fxSAVE wrapper).
    /// @param weight Target distribution weight.
    /// @param valuationOracle IWrappedPriceOracle pricing the vault's asset against the peg token.
    struct EquivalentVaultConfig {
        address vault;
        uint64 weight;
        address valuationOracle;
    }

    /// @notice Register a set of collateral AutoCompounders and equivalents with a deployed HY.
    /// @dev Two distinct config arrays — no flag. ACs are identified by market key (the script
    ///      predicts their address from the existing salt namespace); equivalents carry their
    ///      own vault address and oracle because they're external to the market infrastructure.
    /// @param hyProxy The HarborYield proxy address.
    /// @param autoCompounders ACs to register — one per collateral market in this peg.
    /// @param equivalents Equivalent-yield vaults to register alongside the ACs.
    function configureHarborYield(
        address hyProxy,
        AutoCompounderVaultConfig[] memory autoCompounders,
        EquivalentVaultConfig[] memory equivalents
    ) internal {
        for (uint256 i = 0; i < autoCompounders.length; i++) {
            address acVault = _predictAddress(_key(autoCompounders[i].marketKey, _AUTOCOMPOUNDER_COLLATERAL));
            console.log("        addAutoCompounderVault: %s (weight: %s)", acVault, autoCompounders[i].weight);
            HarborYield_v1(hyProxy).addAutoCompounderVault(acVault, autoCompounders[i].weight);
        }
        for (uint256 i = 0; i < equivalents.length; i++) {
            address eqVault = equivalents[i].vault;
            address asset = IERC4626(eqVault).asset();
            console.log(
                "        addEquivalentVault: %s (asset: %s, weight: %s)",
                eqVault,
                asset,
                equivalents[i].weight
            );
            HarborYield_v1(hyProxy).addEquivalentVault(eqVault, equivalents[i].weight, equivalents[i].valuationOracle);
        }
    }
}
