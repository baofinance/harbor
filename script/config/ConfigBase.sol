// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

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
abstract contract Config_MinterMarket {}

/// @notice Base contract for price market configurations.
/// @dev Provides type safety for price market config parameters.
abstract contract Config_PriceMarket {}

/// @notice Library for computing minter market salt from configuration.
/// @dev Used by deployment scripts to generate salt for minter market configs.
library MinterMarketConfigLib {
    /// @notice Computes the salt for a minter market config.
    /// @param config The minter market config contract.
    /// @return The salt in "peg::collateral" format (e.g., "BTC::stETH").
    function salt(Config_MinterMarket config) internal view returns (string memory) {
        IMarketConfig market = IMarketConfig(address(config));
        return string.concat(market.peg(), "::", market.collateral());
    }

    /// @notice Predicts the price oracle address for a minter market config.
    /// @param config The minter market config contract.
    /// @param systemSalt System salt prefix.
    /// @param baoFactory BaoFactory address for prediction.
    /// @return The predicted price oracle address.
    function priceOracle(
        Config_MinterMarket config,
        string memory systemSalt,
        address baoFactory
    ) internal view returns (address) {
        IMarketConfig market = IMarketConfig(address(config));
        string memory key = string.concat(
            market.peg(),
            "::",
            market.collateral(),
            "::wrappedPriceAggregator"
        );
        bytes32 saltHash = keccak256(abi.encodePacked(systemSalt, "::", key));
        return IBaoFactory(baoFactory).predictAddress(saltHash);
    }
}

/// @notice Library for computing price market salt from configuration.
/// @dev Used by deployment scripts to generate salt for price market configs.
library PriceMarketConfigLib {
    /// @notice Computes the salt for a price market config.
    /// @param config The price market config contract.
    /// @return The salt in "peg::collateral" format (e.g., "BTC::stETH").
    function salt(Config_PriceMarket config) internal view returns (string memory) {
        IMarketConfig market = IMarketConfig(address(config));
        return string.concat(market.peg(), "::", market.collateral());
    }
}
