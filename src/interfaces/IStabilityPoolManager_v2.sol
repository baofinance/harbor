// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice The stability pool manager's ABI surface as of v2.
/// @dev A standalone copy of IStabilityPoolManager rather than an extension of it, because v2 REMOVES the
///      single-ratio harvest setters: the bounty and the cut are slices of the same harvest gross and what a pool is
///      streamed is the residual left of it, so a pair summing above 100% describes a split that does not exist.
///      Setting them one at a time can only reject such a pair after the fact; setting them together makes it
///      unrepresentable, and Solidity has no way to withdraw an inherited declaration.
// solhint-disable-next-line contract-name-capwords
interface IStabilityPoolManager_v2 {
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
    /// @dev Thrown when the harvest bounty and cut ratios together are > 1, leaving no gross to split
    error InvalidHarvestRatioSum(uint256 bountyRatio, uint256 cutRatio);
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
    // solhint-disable-next-line func-name-mixedcase
    function MINTER() external view returns (address);
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
    /// @notice Updates the collateral ratio threshold below which rebalances may happen
    /// This form the target collateral ration when a rebalance is performed
    /// @param newRatio The new collateral ratio threshold, must be >= 1
    function updateRebalanceThreshold(uint256 newRatio) external;
    /// @notice Updates the cut receiver to the given (non-zero) address
    /// @param feeReceiver_ The new cut receiver (the harvest fee destination)
    function updateFeeReceiver(address feeReceiver_) external;

    /// @notice Set the harvest bounty and cut ratios - the pair they are validated as.
    /// @dev The only way to set either: what a stability pool is streamed is the residual the two leave of the
    ///      harvest gross, so the pair is the unit of meaning. Writing both together also means any valid pair is
    ///      reachable in one call from any stored pair, including one written before the two were validated together.
    /// @param harvestBountyRatio_ The share of the harvest gross paid to whoever calls harvest.
    /// @param harvestCutRatio_ The share of the harvest gross paid to the cut receiver. The two must sum within 100%;
    ///        what is left of the gross is what is streamed to the stability pools.
    function updateHarvestRatios(uint256 harvestBountyRatio_, uint256 harvestCutRatio_) external;

    /// @notice Set the harvest ratio pair while upgrading a proxy that was configured before the two were validated
    ///         as a pair, so that the ratios the market is upgraded onto are its configured ones.
    /// @dev Runs as the `upgradeToAndCall` data, so the migration and the upgrade are one transaction: a proxy whose
    ///      stored pair sums above 100% has no harvest until the pair is valid. Runs once per proxy, owner only.
    /// @param harvestBountyRatio_ The configured harvest bounty ratio (see `updateHarvestRatios`).
    /// @param harvestCutRatio_ The configured harvest cut ratio (see `updateHarvestRatios`).
    function initializeV2(uint256 harvestBountyRatio_, uint256 harvestCutRatio_) external;
}
