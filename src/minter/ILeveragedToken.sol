// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IOwnableRoles } from "@bao/interfaces/IOwnableRoles.sol";
import { IMintable } from "@bao/interfaces/IMintable.sol";
import { IBurnable } from "@bao/interfaces/IBurnable.sol";
import { IBurnableFrom } from "@bao/interfaces/IBurnableFrom.sol";

/// @title Bao Minter Leveraged Token
/// @notice A simple ERC20 token used as the leveraged token for a Bao Minter
/// @author rootminus0x1
interface ILeveragedToken is
    IERC20,
    IERC20Metadata,
    IERC20Errors,
    IERC20Permit,
    IOwnableRoles,
    IERC165,
    IMintable,
    IBurnable,
    IBurnableFrom
{
    /// @notice returns the role for contracts who can mint this contract
    function MINTER_ROLE() external returns (uint256);
}
