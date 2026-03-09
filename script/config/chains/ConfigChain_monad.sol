// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {WellKnownAddress} from "@bao-script/deployment/FactoryDeployer.sol";

/// @notice Monad chain addresses and configuration.
/// @dev Chain ID: 143 (Monad mainnet)
abstract contract ConfigChain_monad {
    /// @dev wstETH on Monad
    function wstETH() public pure virtual returns (address) {
        return 0x10Aeaf63194db8d453d4D85a06E5eFE1dd0b5417;
    }

    /// @dev sUSDe on Monad – no liquidity as of yet; replace when deployed / liquid
    function sUSDe() public pure virtual returns (address) {
        return 0x0000000000000000000000000000000000000002;
    }

    function chainId() public pure virtual returns (uint256) {
        return 143;
    }

    function chainName() public pure virtual returns (string memory) {
        return "monad";
    }

    function getWellKnownAddresses() public view virtual returns (WellKnownAddress[] memory addrs) {
        addrs = new WellKnownAddress[](2);
        addrs[0] = WellKnownAddress({addr: wstETH(), label: "wstETH"});
        addrs[1] = WellKnownAddress({addr: sUSDe(), label: "sUSDe"});
    }
}
