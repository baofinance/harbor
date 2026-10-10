// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigBase} from "@harbor-script/config/ConfigBase.sol";
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

    /// @notice About a dollar's worth of the pegged token: the smallest amount given up for good. It is each stability
    ///         pool's supply floor (`MIN_TOTAL_ASSET_SUPPLY`), and the dead-share seed of each downstream vault, which
    ///         passes into a stability pool and so must clear that floor.
    /// @dev The floor is fixed in the pool's bytecode and also sets its ceiling, `MIN_TOTAL_ASSET_SUPPLY * 1e18`: the most
    ///      whole tokens a pool can hold is this value in wei. So it must be at least the number of whole tokens a pool
    ///      will ever hold, and otherwise small, since nobody gets it back. See doc/stability-pool-min-total-asset-supply.md.
    function aboutADollar() public view virtual returns (uint256);

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
