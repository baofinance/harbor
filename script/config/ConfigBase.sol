// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {SaltString} from "@bao-script/deployment/SaltString.sol";

/// @notice Base contract for all Harbor configuration contracts.
/// @dev Config contracts provide keys via methods, not string parsing.
abstract contract ConfigBase {
    /// @notice Get the key for this config.
    /// @return The key string.
    function key() public view virtual returns (string memory);
}

/// @notice Interface for market configuration components.
/// @dev Market configs should provide peg and collateral identifiers.
interface IMarketConfig {
    function peg() external view returns (string memory);
    function collateral() external view returns (string memory);
}

/// @notice Base contract for minter market configurations.
/// @dev Provides type safety for minter market config parameters.
///      Concrete configs must provide peg() and collateral() methods via inherited components.
///      This contract doesn't declare the methods to avoid diamond inheritance conflicts.
///      Concrete configs implement IHarborConfig — see script/config/IHarborConfig.sol.
abstract contract Config_MinterMarket {
    // Methods provided by ConfigPeg_* and ConfigCollateral_* components via inheritance
}

/// @notice Base contract for price market configurations.
/// @dev Provides type safety for price market config parameters.
abstract contract Config_PriceMarket {}

/// @notice A market's identity: the pair of names every key and address for that market derives from.
/// @dev The deploy layer keys everything off this pair. It exists as a named type because the identity has
///      two sources — a `Config_MinterMarket` where this repo configured the market, and the bare names
///      where it did not (fork verification against a live market, hand-written Safe batches). Both produce
///      the same `Market`, so the resolvers need only one primitive form.
struct Market {
    string peg;
    string collateral;
}

/// @notice Library for computing minter market identifiers from configuration.
/// @dev Used by deployment scripts for salt, token names/symbols, and oracle keys.
library MinterMarketConfigLib {
    /// @notice The market identity a config describes.
    function market(Config_MinterMarket config) internal view returns (Market memory) {
        return Market({peg: peg(config), collateral: collateral(config)});
    }

    /// @notice Get the peg identifier from a market config.
    /// @param config The minter market config contract.
    /// @return The peg identifier (e.g., "BTC", "ETH").
    function peg(Config_MinterMarket config) internal view returns (string memory) {
        return IMarketConfig(address(config)).peg();
    }

    /// @notice Get the collateral identifier from a market config.
    /// @param config The minter market config contract.
    /// @return The collateral identifier (e.g., "fxUSD", "stETH").
    function collateral(Config_MinterMarket config) internal view returns (string memory) {
        return IMarketConfig(address(config)).collateral();
    }

    /// @notice Computes the salt for a minter market config.
    /// @param config The minter market config contract.
    /// @return The salt in "peg::collateral" format (e.g., "BTC::stETH").
    function salt(Config_MinterMarket config) internal view returns (string memory) {
        return SaltString.key(peg(config), collateral(config));
    }

    /// @notice Computes the price oracle key for a minter market config.
    /// @dev The price oracle uses a reversed key format: collateral::peg (not peg::collateral).
    /// @param config The minter market config contract.
    /// @return The key in "collateral::peg::wrappedPriceAggregator" format (e.g., "fxUSD::BTC::wrappedPriceAggregator").
    function priceOracleKey(Config_MinterMarket config) internal view returns (string memory) {
        return SaltString.key(collateral(config), peg(config), "wrappedPriceAggregator");
    }
}
