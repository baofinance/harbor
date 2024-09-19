// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ReentrancyGuardTransientUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { BaoAccessControl } from "src/common/BaoAccessControl.sol";
import { Token } from "src/common/Token.sol";

abstract contract TokenOwner is BaoAccessControl, ReentrancyGuardTransientUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice function to transfer owned owned balance of a token
    /// This allows. for example dust resulting from rounding errors, etc.
    /// in case tokens are transferred to this contract by mistake, they can be recovered
    function sweep(
        address token,
        address receiver,
        uint256 amount
    ) public virtual nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        Token.ensureNonZeroAddress(receiver);
        amount = Token.allOf(address(this), token, amount);
        if (amount > 0) {
            // TODO: do all ERC20 tokens support increase allowance?
            // wake-disable-next-line reentrancy
            IERC20(token).safeIncreaseAllowance(address(this), amount);
            IERC20(token).safeTransferFrom(address(this), receiver, amount);
        }
    }
}
