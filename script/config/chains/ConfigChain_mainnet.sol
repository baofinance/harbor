// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {WellKnownAddress} from "@bao-script/deployment/FactoryDeployer.sol";

/// @notice Mainnet chain addresses and configuration.
/// @dev Only provides chain-specific addresses; protocol-level addresses live in deployers.
abstract contract ConfigChain_mainnet {
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

    function PAXG() public pure virtual returns (address) {
        return 0x45804880De22913dAFE09f4980848ECE6EcbAf78;
    }

    function tBTC() public pure virtual returns (address) {
        return 0x18084fbA666a33d37592fA2633fD49a74DD93a88;
    }

    // Chain metadata
    function chainId() public pure virtual returns (uint256) {
        return 1;
    }

    function chainName() public pure virtual returns (string memory) {
        return "mainnet";
    }

    /// @notice Return all well-known addresses (protocol + chain-specific).
    /// @dev Protocol addresses (treasury, baoFactory) are provided by FactoryDeployer.
    function getWellKnownAddresses() public view virtual returns (WellKnownAddress[] memory addrs) {
        addrs = new WellKnownAddress[](7);
        addrs[0] = WellKnownAddress({addr: fxUSD(), label: "fxUSD"});
        addrs[1] = WellKnownAddress({addr: fxSAVE(), label: "fxSAVE"});
        addrs[2] = WellKnownAddress({addr: stETH(), label: "stETH"});
        addrs[3] = WellKnownAddress({addr: wstETH(), label: "wstETH"});
        addrs[4] = WellKnownAddress({addr: WBTC(), label: "WBTC"});
        addrs[5] = WellKnownAddress({addr: PAXG(), label: "PAXG"});
        addrs[6] = WellKnownAddress({addr: tBTC(), label: "tBTC"});
    }
}
