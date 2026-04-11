// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {LibString} from "@solady/utils/LibString.sol";
import {IMarketConfig} from "./ConfigBase.sol";

/// @notice Mixin that derives all Harbor token names and symbols from peg() and collateral().
/// @dev Inherited by market configs alongside ConfigPeg and ConfigCollateral.
///      Accesses peg/collateral via IMarketConfig(this) to avoid diamond inheritance conflicts.
abstract contract ConfigTokenNames {
    using LibString for string;

    function _peg() private view returns (string memory) {
        return IMarketConfig(address(this)).peg();
    }

    function _collateral() private view returns (string memory) {
        return IMarketConfig(address(this)).collateral();
    }

    // ── Pegged token ────────────────────────────────────────────────────

    /// @notice Pegged token name (e.g., "Harbor anchored ETH").
    function peggedName() public view returns (string memory) {
        return string.concat("Harbor anchored ", _peg());
    }

    /// @notice Pegged token symbol (e.g., "haETH").
    function peggedSymbol() public view returns (string memory) {
        return string.concat("ha", _peg().upper());
    }

    // ── Leveraged token ─────────────────────────────────────────────────

    /// @notice Leveraged token name (e.g., "Harbor sail: variable leveraged long fxUSD against ETH").
    function leveragedName() public view returns (string memory) {
        return string.concat("Harbor sail: variable leveraged long ", _collateral(), " against ", _peg());
    }

    /// @notice Leveraged token symbol (e.g., "hsFXUSD-ETH").
    function leveragedSymbol() public view returns (string memory) {
        return string.concat("hs", _collateral().upper(), "-", _peg().upper());
    }

    // ── Stability pool tokens ───────────────────────────────────────────

    enum Liquidation {
        Collateral,
        Leveraged
    }

    function _spStrings(Liquidation liquidation) private view returns (string memory name, string memory symbol) {
        string memory liqSymbol = liquidation == Liquidation.Collateral
            ? _collateral()
            : string.concat("hs", _collateral().upper());

        name = string.concat("Harbor stability pool: ", peggedSymbol(), " (", liqSymbol, ")");
        symbol = string.concat("hsp", _peg(), "(", liqSymbol, ")");
    }

    /// @notice Collateral stability pool name (e.g., "Harbor SP: haETH").
    function spCollateralName() public view returns (string memory name) {
        (name, ) = _spStrings(Liquidation.Collateral);
    }

    /// @notice Collateral stability pool symbol (e.g., "sp(haETH)").
    function spCollateralSymbol() public view returns (string memory symbol) {
        (, symbol) = _spStrings(Liquidation.Collateral);
    }

    /// @notice Leveraged stability pool name (e.g., "Harbor SP: hsFXUSD-ETH").
    function spLeveragedName() public view returns (string memory name) {
        (name, ) = _spStrings(Liquidation.Leveraged);
    }

    /// @notice Leveraged stability pool symbol (e.g., "sp(hsFXUSD-ETH)").
    function spLeveragedSymbol() public view returns (string memory symbol) {
        (, symbol) = _spStrings(Liquidation.Leveraged);
    }

    // ── Auto-compounder tokens ─────────────────────────────────────────

    function _acStrings(Liquidation liquidation) private view returns (string memory name, string memory symbol) {
        string memory liqSymbol = liquidation == Liquidation.Collateral
            ? _collateral()
            : string.concat("hs", _collateral().upper());

        name = string.concat("Harbor auto-compounder: ", peggedSymbol(), " (", liqSymbol, ")");
        symbol = string.concat("hc", _peg(), "(", liqSymbol, ")");
    }

    /// @notice Collateral auto-compounder name (e.g., "Harbor auto-compounder: haETH (fxUSD)").
    function acCollateralName() public view returns (string memory name) {
        (name, ) = _acStrings(Liquidation.Collateral);
    }

    /// @notice Collateral auto-compounder symbol (e.g., "hcETH(fxUSD)").
    function acCollateralSymbol() public view returns (string memory symbol) {
        (, symbol) = _acStrings(Liquidation.Collateral);
    }

    /// @notice Leveraged auto-compounder name (e.g., "Harbor auto-compounder: haETH (hsFXUSD)").
    function acLeveragedName() public view returns (string memory name) {
        (name, ) = _acStrings(Liquidation.Leveraged);
    }

    /// @notice Leveraged auto-compounder symbol (e.g., "hcETH(hsFXUSD)").
    function acLeveragedSymbol() public view returns (string memory symbol) {
        (, symbol) = _acStrings(Liquidation.Leveraged);
    }
}
