// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IStabilityPoolManager {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event RebalanceBountyUpdated(uint256 rebalanceBountyRatio);
    event HarvestBountyUpdated(uint256 harvestBountyRatio);
    // event LiquidationPerformed(address indexed stabilityPool, uint256 amount);
    // event HarvestPerformed(uint256 harvestedAmount, uint256 bounty);
    event RebalanceCollateralRatioUpdated(uint256 collateralRatio);

    /// @notice Emitted when liquidation happens.
    /// @param liquidated The amount of asset liquidated.
    /// @param forWrappedCollateral The resulting collateral.
    /// @param forLeveraged The resulting leveraged tokens.
    event Rebalanced(uint256 liquidated, uint256 forWrappedCollateral, uint256 forLeveraged);
    event Harvested(uint256 amount);

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
    error InvalidRebalanceCollateralRatio(uint256 ratio);

    /// @dev Thrown when a liquidation is attempted but the collateral ratio is not sufficiently low
    error CollateralRatioTooHigh(uint256 currentCollateralRatio, uint256 rebalanceCollateralRatio);

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
    function harvestBountyRatio() external view returns (uint256 harvestRatio);
    function rebalanceBountyRatio() external view returns (uint256 rebalanceRatio);
    function rebalanceCollateralRatio() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function rebalance(address bountyReceiver, uint256 minPeggedLiquidated) external returns (uint256 liquidatedPegged);

    function harvest(address bountyReceiver, uint256 minBounty) external returns (uint256 harvestedAmount);

    /*//////////////////////////////////////////////////////////////
                      PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    function setRebalanceBountyRatio(uint256 rebalanceRatio) external;
    function setHarvestBountyRatio(uint256 harvestRatio) external;
    function setRebalanceCollateralRatio(uint256 newRatio) external;
}
