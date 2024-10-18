// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title Bao Minter Leveraged Token
/// @notice A simple (ERC20) token used as the leveraged token for a Bao Minter
/// @author rootminus0x1

interface ILeveragedToken {
    /// @notice returns the role for contracts who can mint this contract
    // solhint-disable-next-line func-name-mixedcase
    function MINTER_ROLE() external view returns (uint256);
}
