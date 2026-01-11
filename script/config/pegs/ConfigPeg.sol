// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigBase} from "../ConfigBase.sol";
import {LibString} from "@solady/utils/LibString.sol";

/// @notice Base contract for peg configurations.
/// @dev Provides common functionality for all peg configs.
abstract contract ConfigPeg is ConfigBase {
    using LibString for string;

    /// @notice Get the key for this peg (uses peg identifier).
    function key() public view override returns (string memory) {
        return peg();
    }

    /// @notice Get the peg identifier.
    /// @dev Must be implemented by concrete peg configs.
    function peg() public view virtual returns (string memory);

    /// @notice Minimum single deposit amount.
    function minDeposit() public view virtual returns (uint256);

    /// @notice Minimum total supply required in system.
    function minTotalSupply() public view virtual returns (uint256);

    /// @notice Burn signature for pegged token.
    function peggedBurnSignature() public pure virtual returns (string memory) {
        return "burn(uint256)";
    }

    /// @notice Pegged token name.
    /// @return "Harbor anchored {PEG}" (e.g., "Harbor anchored ETH")
    function name() public view returns (string memory) {
        return string.concat("Harbor anchored ", peg());
    }

    /// @notice Pegged token symbol.
    /// @return "ha{PEG}" (e.g., "haETH")
    function symbol() public view returns (string memory) {
        return string.concat("ha", peg().upper());
    }
}
