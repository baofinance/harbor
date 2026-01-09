// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_Protocol, WellKnownAddress} from "./Config_Protocol.sol";

/// @notice Mainnet chain addresses and configuration.
/// @dev Inherits protocol addresses from Config_Protocol (same across all networks).
abstract contract Config_Chain_Mainnet is Config_Protocol {
    // Collateral tokens - names match actual token symbols
    function fxUSD() public pure virtual returns (address) {
        return 0x085780639CC2cACd35E474e71f4d000e2405d8f6;
    }

    function fxSAVE() public pure virtual returns (address) {
        return 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39;
    }

    function stETH() public pure virtual returns (address) {
        return 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    }

    function wstETH() public pure virtual returns (address) {
        return 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    }

    function WBTC() public pure virtual returns (address) {
        return 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    }

    // Chain metadata
    function chainId() public pure virtual returns (uint256) {
        return 1;
    }

    function chainName() public pure virtual returns (string memory) {
        return "mainnet";
    }

    /// @notice Return all well-known addresses (protocol + chain-specific).
    /// @dev Combines protocol addresses with mainnet-specific collateral tokens.
    function getWellKnownAddresses() public pure virtual override returns (WellKnownAddress[] memory addrs) {
        WellKnownAddress[] memory protocolAddrs = Config_Protocol.getWellKnownAddresses();
        uint256 chainCount = 5; // fxUSD, fxSAVE, stETH, wstETH, WBTC
        addrs = new WellKnownAddress[](protocolAddrs.length + chainCount);
        
        // Copy protocol addresses
        for (uint256 i = 0; i < protocolAddrs.length; i++) {
            addrs[i] = protocolAddrs[i];
        }
        
        // Add chain-specific addresses
        uint256 idx = protocolAddrs.length;
        addrs[idx++] = WellKnownAddress({addr: fxUSD(), label: "fxUSD"});
        addrs[idx++] = WellKnownAddress({addr: fxSAVE(), label: "fxSAVE"});
        addrs[idx++] = WellKnownAddress({addr: stETH(), label: "stETH"});
        addrs[idx++] = WellKnownAddress({addr: wstETH(), label: "wstETH"});
        addrs[idx++] = WellKnownAddress({addr: WBTC(), label: "WBTC"});
    }
}
