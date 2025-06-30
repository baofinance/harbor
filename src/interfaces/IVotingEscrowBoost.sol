// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

interface IVotingEscrowBoost {
    /// @notice Returns the adjusted balance of a user at the current epoch.
    /// @param account The address of the user.
    /// @return The adjusted balance of the user.
    // solhint-disable-next-line func-name-mixedcase
    function adjusted_balance_of(address account) external view returns (uint256);
}
