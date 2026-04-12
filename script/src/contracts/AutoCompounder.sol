// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {AutoCompounder_v1} from "@harbor/autocompounding/AutoCompounder_v1.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {ConfigTokenNames} from "script/config/ConfigTokenNames.sol";

/// @notice Config interface for auto-compounder deployment parameters.
interface IAutoCompounderMarketConfig {
    function autoCompounderMaxFeeRatio() external pure returns (uint256);
}

/// @notice Harbor AutoCompounder deployment logic.
/// @dev Each market has TWO auto-compounders: Collateral and Leveraged (one per stability pool).
///      Post-deployment: setMaxFeeRatio, approveCompoundTokens.
///      EXEMPT_WITHDRAWAL_FEE_ROLE is granted via grantStabilityPoolAutoCompounderRole (using predicted address).
abstract contract AutoCompounder is HarborFactoryDeployer {
    string AutoCompounderCollateral = "autoCompounderCollateral";
    string AutoCompounderLeveraged = "autoCompounderLeveraged";

    // ========== AUTO-COMPOUNDER DEPLOYMENT ==========

    /// @notice Deploy AutoCompounder impl only, record in state.
    function deployAutoCompounderImplementation(
        string memory acType,
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig,
        address stabilityPool,
        address minter
    ) internal virtual returns (address impl) {
        string memory marketKey = MinterMarketConfigLib.salt(marketConfig);
        string memory acKey = _key(marketKey, acType);
        console.log("    > %s", acKey);

        ConfigTokenNames names = ConfigTokenNames(address(marketConfig));
        bool isCollateral = keccak256(bytes(acType)) == keccak256("autoCompounderCollateral");
        string memory tokenName = isCollateral ? names.acCollateralName() : names.acLeveragedName();
        string memory tokenSymbol = isCollateral ? names.acCollateralSymbol() : names.acLeveragedSymbol();

        impl = address(new AutoCompounder_v1(stabilityPool, minter, tokenName, tokenSymbol));
        console.log("        Impl:   %s", impl);
        console.log("          Name:   %s", tokenName);
        console.log("          Symbol: %s", tokenSymbol);

        DeploymentState.recordImplementation(
            stateData,
            DeploymentTypes.ImplementationRecord({
                proxy: acKey,
                contractSource: "@harbor/autocompounding/AutoCompounder_v1.sol",
                contractType: "AutoCompounder_v1",
                implementation: impl,
                deploymentTime: uint64(block.timestamp)
            })
        );
    }

    /// @notice Deploy AutoCompounder impl+proxy, record in state.
    function deployAutoCompounder(
        string memory acType,
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig,
        address stabilityPool,
        address minter
    ) internal returns (address proxy) {
        string memory marketKey = MinterMarketConfigLib.salt(marketConfig);
        string memory acKey = _key(marketKey, acType);

        address impl = deployAutoCompounderImplementation(acType, stateData, marketConfig, stabilityPool, minter);

        bytes memory initData = abi.encodeCall(AutoCompounder_v1.initialize, (address(this), owner()));

        proxy = _deployProxyAndRecord(stateData, acKey, impl, initData);
    }

    /// @notice Post-deployment configuration: set maxFeeRatio and approve tokens.
    /// @param marketKey The market salt key (e.g., "ETH::fxUSD").
    /// @param acType "autoCompounderCollateral" or "autoCompounderLeveraged".
    /// @param maxFeeRatio The max fee ratio for compound minting (18 decimals).
    function configureAutoCompounder(string memory marketKey, string memory acType, uint256 maxFeeRatio) internal {
        address acProxy = _predictAddress(_key(marketKey, acType));
        AutoCompounder_v1(acProxy).setMaxFeeRatio(maxFeeRatio);
        AutoCompounder_v1(acProxy).approveCompoundTokens();
    }
}
