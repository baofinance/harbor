// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {ITokenHolder} from "@bao/interfaces/ITokenHolder.sol";

/// @title IGenesis
interface IGenesis is ITokenHolder {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/
    event GenesisBegins();
    event GenesisEnds();
    event Deposit(address indexed caller, address indexed receiver, uint256 collateralIn);
    event Withdraw(address indexed caller, address indexed receiver, uint256 amount);
    event Claim(address indexed caller, address indexed receiver, uint256 peggedAmount, uint256 leveragedAmount);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Thrown when an attempt to withdraw both pegged and leveraged token.
    error GenesisIsNotEnded();

    /// @dev Thrown when the amount of collateral token is not enough.
    error InsufficientCollateral(address token);

    /// @dev Thrown when deposit after the genesis process has ended.
    error GenesisIsEnded();

    /*//////////////////////////////////////////////////////////////
                        PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice returns the minter contract
    // solhint-disable-next-line func-name-mixedcase
    function MINTER() external view returns (address);

    /// @notice returns the collateral token used by the minter
    // solhint-disable-next-line func-name-mixedcase
    function WRAPPED_COLLATERAL_TOKEN() external view returns (address token);

    /// @notice returns the pegged token used by the minter
    // solhint-disable-next-line func-name-mixedcase
    function PEGGED_TOKEN() external view returns (address token);

    /// @notice returns the leveraged token used by the minter
    // solhint-disable-next-line func-name-mixedcase
    function LEVERAGED_TOKEN() external view returns (address token);

    /// @notice returns the amount of collateral deposited by `depositor`
    function balanceOf(address depositor) external view returns (uint256 share);

    /// @notice returns the amount of tokens that could be minted for the `depositor`
    /// given the current price
    function claimable(address depositor) external view returns (uint256 peggedAmount, uint256 leveragedAmount);

    /// @notice returns whether the genesis phase has ended or not
    function genesisIsEnded() external view returns (bool ended);

    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit collateral token to this contract.
    /// @param collateralIn The amount of token to deposit.
    /// @param receiver The address of pool share receiver.
    function deposit(uint256 collateralIn, address receiver) external;

    /// @notice Withdraw some collateral already deposited in this contract before genesis has ended.
    /// @param amount The amount of collateral token being withdrawn to receiver. If the share is less then all of the share is transferred
    /// @param receiver The address of collateral token receiver.
    /// @return collateralOut The amount of collateral token received.
    function withdraw(uint256 amount, address receiver) external returns (uint256 collateralOut);

    /// @notice Withdraw pegged and leveraged tokens from this contract.
    /// @param receiver The address of token receiver.
    function claim(address receiver) external;

    /*//////////////////////////////////////////////////////////////
                      PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize minter with the collateral in this contract.
    function endGenesis() external;
}
