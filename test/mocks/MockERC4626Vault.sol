// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

/// @title MockERC4626Vault
/// @notice Minimal ERC4626 vault for tests. Wraps an underlying MockERC20 and exposes an
///         `addYield` hook that mints extra underlying into the vault, simulating yield accrual.
/// @dev Used by HarborYield_v1 unit tests and anywhere else an ERC4626 stand-in is needed without
///      pulling in the full Minter/SP/AC deployment.
contract MockERC4626Vault is ERC4626 {
    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC4626(asset_) ERC20(name_, symbol_) {}

    /// @dev Drop extra underlying into the vault, simulating yield accrual.
    function addYield(uint256 amount) external {
        MockERC20(asset()).mint(address(this), amount);
    }
}
