// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

interface IStabilityPoolManager {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event RebalanceBountyUpdated(uint256 rebalanceBountyRatio);
    event HarvestBountyUpdated(uint256 harvestBountyRatio);
    event HarvestCutUpdated(uint256 harvestCutRatio);
    event RebalanceThresholdUpdated(uint256 collateralRatio);

    /// @notice Emitted when liquidation happens.
    /// @param liquidated The amount of asset liquidated.
    /// @param forWrappedCollateral The resulting collateral.
    /// @param forLeveraged The resulting leveraged tokens.
    event Rebalanced(uint256 liquidated, uint256 forWrappedCollateral, uint256 forLeveraged);
    /// @notice Emitted when harvest happens.
    event Harvested(uint256 amount);
    /// @notice Emitted when the cut receiver is updated.
    /// @param oldFeeReceiver The previous cut receiver.
    /// @param newFeeReceiver The new (current) cut receiver.
    event UpdateFeeReceiver(address indexed oldFeeReceiver, address indexed newFeeReceiver);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error InvalidStabilityPool(address pool);
    error InsufficientBounty(address token, uint256 given, uint256 minExpected);
    // @dev Thrown when there are no harvestable tokens
    error NoHarvestable();
    /// @dev Thrown when the harvest bounty ratio is > 1
    error InvalidHarvestBountyRatio(uint256 ratio);
    /// @dev Thrown when the rebalance bounty ratio is > 1
    error InvalidRebalanceBountyRatio(uint256 ratio);
    /// @dev Thrown when the rebalance collateral ratio is invalid
    error InvalidRebalanceThreshold(uint256 ratio);

    /// @dev Thrown when a liquidation is attempted but the collateral ratio is not sufficiently low
    error CollateralRatioNotBelowRebalanceThreshold(uint256 currentCollateralRatio, uint256 rebalanceThreshold);

    /// @dev Thrown when the amount requested to be liquidated isn't met
    error NoTokensToLiquidate(address token);

    /// @dev raised when there are no tokens to liquidate
    error InsufficientLiquidation(address token, uint256 peggedTokensToLiquidate, uint256 minLiquidated);

    // @dev Thrown when initiaising with an invalid liquidation token
    error InvalidLiquidationToken(address token);

    /*//////////////////////////////////////////////////////////////
                         PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function stabilityPools() external view returns (address[] memory);
    function hasStabilityPool(address stabilityPool) external view returns (bool);
    function harvestable() external view returns (uint256);
    function rebalanceable() external view returns (bool);
    function harvestBountyRatio() external view returns (uint256 harvestBountyRatio_);
    function harvestCutRatio() external view returns (uint256 harvestCutRatio_);
    function rebalanceBountyRatio() external view returns (uint256 rebalanceBountyRatio_);
    /// @notice Returns the collateral ratio at which rebalancing should occur
    /// @return The rebalance collateral ratio
    function rebalanceThreshold() external view returns (uint256);
    /// @notice Returns the cut receiver - who receives the harvest cut and the no-pool catch-all
    function feeReceiver() external view returns (address);

    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function rebalance(address bountyReceiver, uint256 minPeggedLiquidated) external returns (uint256 liquidatedPegged);

    /// @notice Harvests tokens to stability pools and returns the total amount harvested
    function harvest(address bountyReceiver, uint256 minBounty) external returns (uint256 harvestedAmount);

    /*//////////////////////////////////////////////////////////////
                      PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function updateRebalanceBountyRatio(uint256 rebalanceRatio) external;
    function updateHarvestBountyRatio(uint256 harvestRatio) external;
    /// @notice Updates the collateral ratio threshold below which rebalances may happen
    /// This form the target collateral ration when a rebalance is performed
    /// @param newRatio The new collateral ratio threshold, must be >= 1
    function updateRebalanceThreshold(uint256 newRatio) external;
    /// @notice Updates the cut receiver to the given (non-zero) address
    /// @param feeReceiver_ The new cut receiver (the harvest fee destination)
    function updateFeeReceiver(address feeReceiver_) external;
    /// @notice update the ratio sent to the feeReceiver, if any
    function updateHarvestCutRatio(uint256 harvestCutRatio_) external;
}
