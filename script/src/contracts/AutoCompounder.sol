// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborFactoryDeployer} from "@harbor-script/src/HarborFactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";

import {AutoCompounder_v1} from "@harbor/autocompounding/AutoCompounder_v1.sol";
import {Config_MinterMarket, MinterMarketConfigLib, IMarketConfig} from "@harbor-script/config/ConfigBase.sol";
import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";

/// @notice Config interface for auto-compounder deployment parameters.
interface IAutoCompounderMarketConfig {
    function autoCompounderMintMaxFeeRatio() external pure returns (uint256);
}

/// @notice Harbor AutoCompounder deployment logic.
/// @dev Each market has TWO auto-compounders: Collateral and Leveraged (one per stability pool).
///      Post-deployment: approveCompoundTokens.
///      EXEMPT_WITHDRAWAL_FEE_ROLE is granted via grantStabilityPoolAutoCompounderRole (using predicted address).
///
///      yieldManager: pass address(0) for standalone ACs (MAX_FEE_RATIO is used instead).
///                    For HY-connected ACs (harbor-yield repo), pass the HY predicted address and
///                    maxFeeRatio = 0 (exactly one of the two must be non-zero).
///      pegOracle: IWrappedPriceOracle for the wrapped collateral. Required; provides the
///                 gas floor for compound() via maxUnderlyingPrice.
abstract contract AutoCompounder is HarborFactoryDeployer {
    string AutoCompounderCollateral = "autoCompounderCollateral";
    string AutoCompounderLeveraged = "autoCompounderLeveraged";

    // ========== AUTO-COMPOUNDER DEPLOYMENT ==========

    /// @notice Predict the address of the ETH price oracle for a peg.
    /// @dev Salt: {saltPrefix}::{peg}::ethPriceAggregator. Deployed by harbor-price-aggregators scripts.
    function predictEthPriceOracleAddress(string memory peg) internal returns (address) {
        return _predictAddress(string.concat(peg, "::ethPriceAggregator"));
    }

    /// @notice Deploy AutoCompounder impl only, record in state.
    /// @param yieldManager HarborYield address, or address(0) for standalone AC.
    /// @param pegOracle IWrappedPriceOracle for the peg/ETH price (gas floor). Required.
    function deployAutoCompounderImplementation(
        string memory acType,
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig,
        address stabilityPool,
        address minter,
        address yieldManager,
        address pegOracle
    ) internal virtual returns (address impl) {
        string memory marketKey = MinterMarketConfigLib.salt(marketConfig);
        string memory acKey = _key(marketKey, acType);
        console.log("    > %s", acKey);

        ConfigTokenNames names = ConfigTokenNames(address(marketConfig));
        bool isCollateral = keccak256(bytes(acType)) == keccak256("autoCompounderCollateral");
        string memory tokenName = isCollateral ? names.acCollateralName() : names.acLeveragedName();
        string memory tokenSymbol = isCollateral ? names.acCollateralSymbol() : names.acLeveragedSymbol();

        uint256 maxFeeRatio = yieldManager == address(0)
            ? IAutoCompounderMarketConfig(address(marketConfig)).autoCompounderMintMaxFeeRatio()
            : 0;

        impl = address(new AutoCompounder_v1(stabilityPool, minter, yieldManager, maxFeeRatio, pegOracle, tokenName, tokenSymbol));
        console.log("        Impl:   %s", impl);
        console.log("          Name:   %s", tokenName);
        console.log("          Symbol: %s", tokenSymbol);

        _recordImplementation(
            stateData,
            acKey,
            "@harbor/autocompounding/AutoCompounder_v1.sol",
            "AutoCompounder_v1",
            impl
        );
    }

    /// @notice Deploy AutoCompounder impl+proxy, record in state.
    /// @param yieldManager HarborYield address, or address(0) for standalone AC.
    /// @param pegOracle IWrappedPriceOracle for the wrapped collateral (required).
    function deployAutoCompounder(
        string memory acType,
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig,
        address stabilityPool,
        address minter,
        address yieldManager,
        address pegOracle
    ) internal returns (address proxy) {
        string memory marketKey = MinterMarketConfigLib.salt(marketConfig);
        string memory acKey = _key(marketKey, acType);

        address impl = deployAutoCompounderImplementation(acType, stateData, marketConfig, stabilityPool, minter, yieldManager, pegOracle);

        bytes memory initData = abi.encodeCall(AutoCompounder_v1.initialize, (address(this), owner()));

        proxy = _deployProxyAndRecord(stateData, acKey, impl, initData);
    }

    /// @notice Post-deployment configuration: approve compound tokens.
    /// @param marketKey The market salt key (e.g., "ETH::fxUSD").
    /// @param acType "autoCompounderCollateral" or "autoCompounderLeveraged".
    function configureAutoCompounder(string memory marketKey, string memory acType) internal {
        address acProxy = _predictAddress(_key(marketKey, acType));
        AutoCompounder_v1(acProxy).approveCompoundTokens();
    }
}
