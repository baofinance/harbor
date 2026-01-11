// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Well-known address entry for address-to-label mapping.
struct WellKnownAddress {
    address addr;
    string label;
}

/// @notice Protocol addresses that are the same across all networks.
abstract contract ConfigProtocol {
    string private _systemSaltValue;

    constructor() {}

    /// @notice Set the system salt - must be called before any deployment.
    /// @dev Called by scripts before startBroadcast().
    function _setSystemSalt(string memory systemSaltString) internal {
        _systemSaltValue = systemSaltString;
    }

    function systemSalt() public view virtual returns (string memory) {
        return _systemSaltValue;
    }

    function treasury() public pure virtual returns (address) {
        return 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
    }

    function owner() public pure virtual returns (address) {
        return 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
    }

    function baoFactory() public pure virtual returns (address) {
        // BaoFactory CREATE2/CREATE3 predicted address (same on all EVM chains)
        return 0xD696E56b3A054734d4C6DCBD32E11a278b0EC458;
    }

    /// @notice Return protocol-level well-known addresses.
    /// @dev Override in chain configs to add chain-specific addresses.
    function getWellKnownAddresses() public pure virtual returns (WellKnownAddress[] memory addrs) {
        addrs = new WellKnownAddress[](2);
        addrs[0] = WellKnownAddress({addr: treasury(), label: "treasury/owner"});
        addrs[1] = WellKnownAddress({addr: baoFactory(), label: "baoFactory"});
    }
}
