// SPDX-License-Identifier: MIT
// coding standards by https://www.rareskills.io/post/solidity-style-guide
// and https://docs.soliditylang.org/en/latest/style-guide.html
pragma solidity 0.8.30;

import {BaoOwnableRoles} from "@bao/BaoOwnableRoles.sol";

contract MockMinter is BaoOwnableRoles /*, IMinter */ {
    ////////////////
    // Immutables //
    ////////////////

    // these variables are set in the constructor, not the initializer, to improve contract size and gas usage
    // to change them the contract must be upgraded
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable WRAPPED_COLLATERAL_TOKEN; // this is the wrapped token
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable PEGGED_TOKEN;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable LEVERAGED_TOKEN;
    // the type of burn signature for burning pegged tokens

    constructor(address _wrappedCollateralToken, address _peggedToken, address _leveragedToken) {
        require(_wrappedCollateralToken != address(0), "MockMinter: zero wrapped collateral");
        require(_peggedToken != address(0), "MockMinter: zero pegged token");
        require(_leveragedToken != address(0), "MockMinter: zero leveraged token");
        WRAPPED_COLLATERAL_TOKEN = _wrappedCollateralToken;
        PEGGED_TOKEN = _peggedToken;
        LEVERAGED_TOKEN = _leveragedToken;
    }
}
