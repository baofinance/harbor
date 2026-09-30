// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice The addresses of one market - everything a test needs to reach it - as the run that built it reports them.
/// @dev At file level, so a deploy run and the market harness name the same type. It is not called `Market` because
///      that is HarborDeployer's name for a peg and collateral pair.
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
