// SPDX-License-Identifier: MIT

pragma solidity 0.8.26;

interface ILiquidator {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @dev Thrown the cannot liquidate.
    error CannotLiquidate();

    error NeedsRole(address roleHolder, uint256 role);

    /*//////////////////////////////////////////////////////////////
                         PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Return the address of underlying rebalance pool.
    function rebalancePool() external view returns (address);

    /// @notice Returns the reward for calling liquidate successfully
    function reward() external view returns (address token, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Liquidate asset.
    /// This function transfers a given amount of assets to the receiver.
    /// In return it is assumed the receiver will transfer a suitable amount of reward tokens via the 'accumulateReward function below.
    /// @param minLiquidation The minimum amount of liquidated asset (get this from the reservePool)
    /// @param rewardReceiver The contract that receives the liquidation reward.
    /// @return liquidated The amount actually liquidated
    function liquidate(address rewardReceiver, uint256 minLiquidation) external returns (uint256 liquidated);
}
