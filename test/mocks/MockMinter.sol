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

    /// @notice Configurable pegged-token price. Defaults to 1 ether (pegged 1:1).
    ///         Tests can lower this to simulate a haXXX depeg.
    uint256 private _peggedTokenPrice = 1 ether;

    constructor(address _wrappedCollateralToken, address _peggedToken, address _leveragedToken) {
        require(_wrappedCollateralToken != address(0), "MockMinter: zero wrapped collateral");
        require(_peggedToken != address(0), "MockMinter: zero pegged token");
        require(_leveragedToken != address(0), "MockMinter: zero leveraged token");
        WRAPPED_COLLATERAL_TOKEN = _wrappedCollateralToken;
        PEGGED_TOKEN = _peggedToken;
        LEVERAGED_TOKEN = _leveragedToken;
    }

    /// @notice Return the current pegged-token price (18 decimals). Matches `IMinter.peggedTokenPrice`.
    function peggedTokenPrice() external view returns (uint256) {
        return _peggedTokenPrice;
    }

    /// @notice Configure the pegged-token price for test scenarios.
    function setPeggedTokenPrice(uint256 price) external {
        _peggedTokenPrice = price;
    }

    /// @notice Dry-run mint returning price and rate used by HarborYield._computeDistributeMinOut.
    ///         Returns price = _peggedTokenPrice, rate = 1e18. Other fields are zeroed.
    function mintPeggedTokenDryRun(
        uint256 /* collateralIn */,
        uint256 /* maxFeeRatio */
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 fee,
            uint256 collateralTaken,
            uint256 peggedMinted,
            uint256 price,
            uint256 rate
        )
    {
        incentiveRatio = 0;
        fee = 0;
        collateralTaken = 0;
        peggedMinted = 0;
        price = _peggedTokenPrice;
        rate = 1 ether;
    }
}
