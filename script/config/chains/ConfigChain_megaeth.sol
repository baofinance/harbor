// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {WellKnownAddress} from "@bao-script/deployment/FactoryDeployer.sol";

/// @notice MegaETH chain addresses and configuration.
/// @dev Chain ID: 4326 (MegaETH mainnet)
abstract contract ConfigChain_megaeth {
    /// @dev Lombard BTC on MegaETH
    function BTC() public pure virtual returns (address) {
        return 0xB0F70C0bD6FD87dbEb7C10dC692a2a6106817072;
    }

    /// @dev wstETH on MegaETH
    function wstETH() public pure virtual returns (address) {
        return 0x601aC63637933D88285A025C685AC4e9a92a98dA;
    }

    /// @dev USDMY (Malaysian ringgit stablecoin) on MegaETH
    function USDMY() public pure virtual returns (address) {
        return 0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890;
    }

    function chainId() public pure virtual returns (uint256) {
        return 4326;
    }

    function chainName() public pure virtual returns (string memory) {
        return "megaeth";
    }

    function getWellKnownAddresses() public view virtual returns (WellKnownAddress[] memory addrs) {
        addrs = new WellKnownAddress[](3);
        addrs[0] = WellKnownAddress({addr: BTC(), label: "BTC"});
        addrs[1] = WellKnownAddress({addr: wstETH(), label: "wstETH"});
        addrs[2] = WellKnownAddress({addr: USDMY(), label: "USDMY"});
    }
}
