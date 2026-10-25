// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Every address of one market, as `HarborDeployer.marketAddresses` resolves it: the contracts the deploy puts
///         at predicted addresses, the wrapped collateral its config names, and the oracle its minter reads. Each
///         contract's deploy takes its addresses from here, by name, so the market's contracts name the same tokens and
///         each other.
/// @dev At file level, so the deploy and the test harness name the same type. It is not called `Market` because that
///      is HarborDeployer's name for a peg and collateral pair.
struct MarketAddresses {
    address minter;
    address collateralPool;
    address leveragedPool;
    address manager;
    address pegged;
    address leveraged;
    address wrappedCollateral;
    address oracle;
}
