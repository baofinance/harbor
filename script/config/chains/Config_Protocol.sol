// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Protocol addresses that are the same across all networks.
abstract contract Config_Protocol {
    string private systemSaltValue;

    constructor(string memory systemSaltString) {
        systemSaltValue = systemSaltString;
    }

    function systemSalt() public view virtual returns (string memory) {
        return systemSaltValue;
    }

    function treasury() public pure virtual returns (address) {
        return 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
    }

    function owner() public pure virtual returns (address) {
        return 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
    }

    function baoFactory() public pure virtual returns (address) {
        return 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
    }
}
