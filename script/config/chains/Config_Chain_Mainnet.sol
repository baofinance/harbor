// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_Protocol} from "./Config_Protocol.sol";

/// @notice Mainnet chain addresses and configuration.
/// @dev Inherits protocol addresses from Config_Protocol (same across all networks).
abstract contract Config_Chain_Mainnet is Config_Protocol {
    // Collateral tokens - names match actual token symbols
    address internal constant fxUSD = 0x085780639CC2cACd35E474e71f4d000e2405d8f6;
    address internal constant fxSAVE = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;
    address internal constant stETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;

    // Chain metadata
    uint256 internal constant CHAIN_ID = 1;
    string internal constant CHAIN_NAME = "mainnet";
}
