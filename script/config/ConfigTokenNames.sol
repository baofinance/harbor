// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {LibString} from "@solady/utils/LibString.sol";
import {IMarketConfig} from "@harbor-script/config/ConfigBase.sol";

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

    // ── Liquidation / stability pool tokens ─────────────────────────────

    enum Liquidation {
        Collateral,
        Leveraged
    }

    /// @notice The liquidation symbol embedded in stability-pool token names: the collateral for a
    ///         collateral liquidation, else the leveraged ("hs…") symbol for a leveraged liquidation.
    function liquidationSymbol(Liquidation liquidation) public view returns (string memory) {
        return liquidation == Liquidation.Collateral ? _collateral() : string.concat("hs", _collateral().upper());
    }

    function _stabilityPoolStrings(
        Liquidation liquidation
    ) private view returns (string memory name, string memory symbol) {
        string memory liqSymbol = liquidationSymbol(liquidation);
        name = string.concat("Harbor stability pool: ", peggedSymbol(), " (", liqSymbol, ")");
        symbol = string.concat("hsp", _peg(), "(", liqSymbol, ")");
    }

    /// @notice Collateral stability pool name (e.g., "Harbor SP: haETH").
    function stabilityPoolCollateralName() public view returns (string memory name) {
        (name, ) = _stabilityPoolStrings(Liquidation.Collateral);
    }

    /// @notice Collateral stability pool symbol (e.g., "sp(haETH)").
    function stabilityPoolCollateralSymbol() public view returns (string memory symbol) {
        (, symbol) = _stabilityPoolStrings(Liquidation.Collateral);
    }

    /// @notice Leveraged stability pool name (e.g., "Harbor SP: hsFXUSD-ETH").
    function stabilityPoolLeveragedName() public view returns (string memory name) {
        (name, ) = _stabilityPoolStrings(Liquidation.Leveraged);
    }

    /// @notice Leveraged stability pool symbol (e.g., "sp(hsFXUSD-ETH)").
    function stabilityPoolLeveragedSymbol() public view returns (string memory symbol) {
        (, symbol) = _stabilityPoolStrings(Liquidation.Leveraged);
    }
}
