// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

interface ILiquidator {
    /**********
     * Events *
     **********/

    /**********
     * Errors *
     **********/

    /// @dev Thrown the cannot liquidate.
    error CannotLiquidate();

    error NeedsRole(bytes32 role, address roleHolder);

    /*************************
     * Public View Functions *
     *************************/

    /// @notice Return the address of base token.
    function collateralToken() external view returns (address);

    /// @notice Return the address of underlying token of this contract.
    function assetToken() external view returns (address);

    /****************************
     * Public Mutator Functions *
     ****************************/

    /// @notice Liquidate asset.
    /// This function transfers a given amount of assets to the receiver.
    /// In return it is assumed the receiver will transfer a suitable amount of reward tokens via the 'accumulateReward function below.
    /// @param receiver The contract that receives the liquidation reward.
    function liquidate(address receiver) external;
}
