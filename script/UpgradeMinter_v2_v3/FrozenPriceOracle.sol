// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

/// @title FrozenPriceOracle
/// @notice One oracle reading held still: answers `latestAnswer` with the four values it was constructed with, and
///         nothing else. A market's batch points its minter at one while the owner's fee-free operations run, so they
///         are priced at the reading the batch was built from - the capture block's, the last before the pause that
///         froze the market - and points it at its oracle proxy again after, in the same transaction. It is never a
///         minter's oracle outside that transaction.
/// @dev No owner and no setter: what it answers is fixed when it is made, so the batch that reads it cannot be given
///      another reading. It implements only what the minter reads.
contract FrozenPriceOracle is IWrappedPriceOracle {
    uint256 private immutable _MIN_PRICE;
    uint256 private immutable _MAX_PRICE;
    uint256 private immutable _MIN_RATE;
    uint256 private immutable _MAX_RATE;

    /// @param minPrice The low edge of the collateral's price band, in pegged units, 18 decimals.
    /// @param maxPrice The high edge of the collateral's price band.
    /// @param minRate The low edge of the wrapped-to-underlying rate band, 18 decimals.
    /// @param maxRate The high edge of the wrapped-to-underlying rate band.
    constructor(uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) {
        _MIN_PRICE = minPrice;
        _MAX_PRICE = maxPrice;
        _MIN_RATE = minRate;
        _MAX_RATE = maxRate;
    }

    /// @inheritdoc IWrappedPriceOracle
    function latestAnswer()
        external
        view
        returns (uint256 minUnderlyingPrice, uint256 maxUnderlyingPrice, uint256 minWrappedRate, uint256 maxWrappedRate)
    {
        return (_MIN_PRICE, _MAX_PRICE, _MIN_RATE, _MAX_RATE);
    }
}
