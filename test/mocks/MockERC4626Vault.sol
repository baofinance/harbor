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
///
///      Optionally implements the `IAutoCompounder` introspection surface (`PEGGED_TOKEN()` and
///      `MINTER()`) so tests can register a mock as an AC via `HarborYield.addAutoCompounderVault`.
///      Configure via `configureAsAutoCompounder` after construction; both fields default to
///      `address(0)`, i.e. "not an AC" (the getters return zero, which triggers `WrongPegToken`
///      at registration — correct behaviour for a non-AC vault).
contract MockERC4626Vault is ERC4626 {
    address public _pegged;
    address public _minter;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC4626(asset_) ERC20(name_, symbol_) {}

    /// @dev Drop extra underlying into the vault, simulating yield accrual.
    function addYield(uint256 amount) external {
        MockERC20(asset()).mint(address(this), amount);
    }

    /// @notice Set the values returned by `PEGGED_TOKEN()` and `MINTER()`, so this mock can
    ///         stand in as an AutoCompounder in HarborYield tests.
    function configureAsAutoCompounder(address pegged_, address minter_) external {
        _pegged = pegged_;
        _minter = minter_;
    }

    // solhint-disable func-name-mixedcase
    /// @notice `IAutoCompounder.PEGGED_TOKEN()` getter for test registration as an AC.
    function PEGGED_TOKEN() external view returns (address) {
        return _pegged;
    }

    /// @notice `IAutoCompounder.MINTER()` getter for test registration as an AC.
    function MINTER() external view returns (address) {
        return _minter;
    }
    // solhint-enable func-name-mixedcase
}
