// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IReservePool {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when the market request bonus.
    /// @param minter The address of minter contract.
    /// @param token The address of the token requested.
    /// @param receiver The address of token receiver.
    /// @param amountRequested The amount used to compute bonus.
    /// @param amountSent The amount of bonus token.
    event RequestBonus(
        address indexed minter,
        address indexed token,
        address indexed receiver,
        uint256 amountRequested,
        uint256 amountSent
    );

    /*//////////////////////////////////////////////////////////////
                        PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice returns the role for contracts who can call `requestBonus`
    // solhint-disable-next-line func-name-mixedcase
    function REQUESTER_ROLE() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                      PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Request bonus token from Reserve Pool.
    /// @param token The address of token to request.
    /// @param receiver The address recipient for the bonus token.
    /// @param amountRequested The original amount of token used.
    /// @param amountSent The amount of bonus token sent.
    function requestBonus(
        address token,
        address receiver,
        uint256 amountRequested
    ) external returns (uint256 amountSent);
}
