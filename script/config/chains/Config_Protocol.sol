// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice Protocol addresses that are the same across all networks.
abstract contract Config_Protocol {
    address internal constant TREASURY = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
    address internal constant OWNER = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
    address internal constant BAO_FACTORY = 0x9bABfC1A1952a6ed2caC1922BFfE80c0506364a2;
}
