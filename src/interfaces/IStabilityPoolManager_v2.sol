// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice The stability pool manager's ABI surface as of v2.
/// @dev A standalone copy of IStabilityPoolManager rather than an extension of it, because v2 REMOVES the one-value
///      setters: each action's payment terms - its bounty ratio, bounty ceiling and cut ratio - are set by one call,
///      `updateHarvestConfig` or `updateRebalanceConfig`. The bounty and the cut are slices of the same proceeds and
///      what a pool receives is the residual left of them, so a pair summing above 100% describes a split that does not
///      exist. Setting them one at a time can only reject such a pair after the fact; setting them together makes it
///      unrepresentable, and Solidity has no way to withdraw an inherited declaration.
// solhint-disable-next-line contract-name-capwords
interface IStabilityPoolManager_v2 {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event RebalanceThresholdUpdated(uint256 collateralRatio);
    /// @notice Emitted when a harvest's payment terms are set, by `updateHarvestConfig`.
    /// @param bountyRatio The share of the harvest gross paid to its caller.
    /// @param bountyCeiling The most a harvest pays its caller, in wrapped collateral; zero is no ceiling.
    /// @param cutRatio The share of the harvest gross paid to the cut receiver.
    event HarvestConfigUpdated(uint256 bountyRatio, uint256 bountyCeiling, uint256 cutRatio);
    /// @notice Emitted when a rebalance's payment terms are set, by `updateRebalanceConfig`.
    /// @param bountyRatio The share of each rebalance payment paid to its caller.
    /// @param bountyCeiling The most a rebalance pays its caller in all, measured in wrapped collateral; zero is no
    ///        ceiling.
    /// @param cutRatio The share of each rebalance payment paid to the cut receiver.
    event RebalanceConfigUpdated(uint256 bountyRatio, uint256 bountyCeiling, uint256 cutRatio);

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
    /// @dev Thrown when the harvest cut ratio is > 1
    error InvalidHarvestCutRatio(uint256 ratio);
    /// @dev Thrown when the harvest bounty and cut ratios together are > 1, leaving no gross to split
    error InvalidHarvestRatioSum(uint256 bountyRatio, uint256 cutRatio);
    /// @dev Thrown when the rebalance bounty ratio is > 1
    error InvalidRebalanceBountyRatio(uint256 ratio);
    /// @dev Thrown when the rebalance cut ratio is > 1
    error InvalidRebalanceCutRatio(uint256 ratio);
    /// @dev Thrown when the rebalance bounty and cut ratios together are > 1, leaving a pool nothing of its payment
    error InvalidRebalanceRatioSum(uint256 bountyRatio, uint256 cutRatio);
    /// @dev Thrown when the rebalance collateral ratio is invalid
    error InvalidRebalanceThreshold(uint256 ratio);

    /// @dev Thrown when a liquidation is attempted but the collateral ratio is not sufficiently low
    error CollateralRatioNotBelowRebalanceThreshold(uint256 currentCollateralRatio, uint256 rebalanceThreshold);

    /// @dev Thrown by `rebalance` when it takes no pegged from the pools: neither has a deposit - a supply of zero,
    ///      whatever pegged they hold - or neither can give any, or what they can give would be paid nothing, or the
    ///      minter has none of its own pegged outstanding to redeem.
    error NoTokensToLiquidate(address token);

    /// @dev Thrown by `rebalance` when the pegged it took from the pools is less than the caller's minimum.
    error InsufficientLiquidation(address token, uint256 peggedTokensToLiquidate, uint256 minLiquidated);

    /*//////////////////////////////////////////////////////////////
                         PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    // solhint-disable-next-line func-name-mixedcase
    function MINTER() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function WRAPPED_COLLATERAL_TOKEN() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function PEGGED_TOKEN() external view returns (address);
    // solhint-disable-next-line func-name-mixedcase
    function LEVERAGED_TOKEN() external view returns (address);
    function stabilityPools() external view returns (address[] memory);
    function hasStabilityPool(address stabilityPool) external view returns (bool);
    function harvestable() external view returns (uint256);
    /// @notice Whether a rebalance has pegged to take and backing to pay for it: the collateral ratio is below the
    ///         rebalance threshold, the minter is not halted by an unrecognised impairment (`IMinter_v3.impairment`),
    ///         during which `rebalance` reverts, the minter has backing on record and pegged of its own outstanding,
    ///         and a pool has deposits above its floor to give.
    /// @dev It does not ask how much. Where all the pools can give is too little to be paid a wei, it is true and
    ///      `rebalance` reverts `NoTokensToLiquidate`.
    function rebalanceable() external view returns (bool);
    function harvestBountyRatio() external view returns (uint256 harvestBountyRatio_);
    function harvestCutRatio() external view returns (uint256 harvestCutRatio_);
    function rebalanceBountyRatio() external view returns (uint256 rebalanceBountyRatio_);
    /// @notice The share of each rebalance payment - each pool's proceeds of each step - paid to the cut receiver, in
    ///         the payment's token. Not bounded by `rebalanceBountyCeiling`, which bounds the bounty alone.
    function rebalanceCutRatio() external view returns (uint256);
    /// @notice The most a harvest pays its caller, in wrapped collateral: the bounty ratio's slice of the gross up to
    ///         this, the rest of the slice going to the cut receiver. Zero is no ceiling.
    function harvestBountyCeiling() external view returns (uint256);
    /// @notice The most a rebalance pays its caller in all, measured in wrapped collateral - a payment in leveraged
    ///         tokens counted as the collateral those tokens were minted for. Shared between the two pools by what
    ///         each has had deposited - its supply - when the rebalance starts, each pool's legs drawing on its share;
    ///         what a leg does not pay the caller stays with the pool. Zero is no ceiling.
    function rebalanceBountyCeiling() external view returns (uint256);
    /// @notice Returns the collateral ratio at which rebalancing should occur
    /// @return The rebalance collateral ratio
    function rebalanceThreshold() external view returns (uint256);
    /// @notice Returns the cut receiver - who receives the harvest cut, the rebalance cut and the no-pool catch-all
    function feeReceiver() external view returns (address);

    /*//////////////////////////////////////////////////////////////
                        PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Lift the collateral ratio to the rebalance threshold with the stability pools' pegged, in up to two
    ///         steps, and pay the pools for what they give - less `bountyReceiver`'s bounty ratio of every payment,
    ///         within `rebalanceBountyCeiling`, and the cut receiver's cut ratio of it.
    ///         Where the minter sells leverage, one step by both legs: the collateral pool's pegged redeemed for
    ///         collateral, the leveraged pool's converted into leveraged tokens. Where it sells none - below its
    ///         floor, `IMinter_v3.MINIMUM_COLLATERAL_RATIO` - first both pools' pegged by the collateral route, pro
    ///         rata to their supplies, to the floor or the threshold if that is lower, all paid in collateral; then,
    ///         from the floor, the step by both legs. Each pool gives up no more than its headroom
    ///         (`IStabilityPool_v3.maxAssetLoss`), so small pools may lift the ratio only part of the way.
    ///         A leg of the redemption that would be paid nothing is not taken. In the step by both legs each pool's
    ///         pegged is its own leg: a pool whose leg would be paid nothing is left out as a pool at its floor is,
    ///         and the legs are sized again without it, so the other pool's leg covers the distance where it can.
    ///         Where neither leg would be paid anything, neither is taken. By the collateral route the two pools'
    ///         pegged is one leg, taken whole or not at all.
    ///         Where the backing is worth no more than the pegged the minter has minted - a ratio at or below the peg -
    ///         the first step lifts nothing: a pegged token redeems for its share of the backing and takes that share
    ///         with it. The step takes all the pegged the minter has minted that the pools can give, and pays each
    ///         pool its pegged's share of the backing in collateral.
    /// @dev Reverts `CollateralRatioNotBelowRebalanceThreshold` at or above the threshold, `NoTokensToLiquidate` when
    ///      it takes no pegged, and `InsufficientLiquidation` when both steps together take less than
    ///      `minPeggedLiquidated`. The minter's own errors are passed up unchanged, among them
    ///      `IMinter_v3.UnrecognisedImpairment`: while the minter's record of its backing overstates what it holds,
    ///      every redemption a rebalance makes is an update the minter reverts until the rate recovers or the
    ///      impairment is recognised. A rebalance that makes no redemption, as no leg would be paid anything, reverts
    ///      `NoTokensToLiquidate` whether or not the record is overstated: with both edges of the wrap rate at zero
    ///      no collateral leg is paid anything.
    /// @return liquidatedPegged The pegged taken from the pools, both steps together.
    function rebalance(address bountyReceiver, uint256 minPeggedLiquidated) external returns (uint256 liquidatedPegged);

    /// @notice Harvests tokens to stability pools and returns the total amount harvested. New yield is split between the
    ///         pools by their supplies - what has been deposited, never the pegged they hold - and goes to the treasury
    ///         when neither has a deposit. `bountyReceiver` is paid the bounty ratio's slice of the gross up to
    ///         `harvestBountyCeiling`, the rest of the slice going to the cut receiver; `minBounty` is judged on what
    ///         is paid.
    function harvest(address bountyReceiver, uint256 minBounty) external returns (uint256 harvestedAmount);

    /*//////////////////////////////////////////////////////////////
                      PROTECTED UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Updates the collateral ratio threshold below which rebalances may happen
    /// This form the target collateral ration when a rebalance is performed
    /// @param newRatio The new collateral ratio threshold, must be > 1
    function updateRebalanceThreshold(uint256 newRatio) external;
    /// @notice Updates the cut receiver to the given (non-zero) address
    /// @param feeReceiver_ The new cut receiver (the harvest fee destination)
    function updateFeeReceiver(address feeReceiver_) external;

    /// @notice Set a harvest's payment terms: the bounty ratio, the bounty ceiling and the cut ratio.
    /// @dev The only way to set any of them: what a stability pool is streamed is the residual the two ratios leave of
    ///      the harvest gross, so the terms are the unit of meaning. Writing them whole also means any valid pair of
    ///      ratios is reachable in one call from any stored pair, including one written before the two were validated
    ///      together.
    /// @param bountyRatio The share of the harvest gross paid to whoever calls harvest.
    /// @param bountyCeiling The most a harvest pays its caller, in wrapped collateral; zero is no ceiling.
    /// @param cutRatio The share of the harvest gross paid to the cut receiver. The two ratios must sum within 100%;
    ///        what is left of the gross is what is streamed to the stability pools.
    function updateHarvestConfig(uint256 bountyRatio, uint256 bountyCeiling, uint256 cutRatio) external;

    /// @notice Set a rebalance's payment terms: the bounty ratio, the bounty ceiling and the cut ratio.
    /// @dev The only way to set any of them, for the reason `updateHarvestConfig` gives: what a pool is paid is what
    ///      the bounty and the cut leave of its proceeds.
    /// @param bountyRatio The share of each rebalance payment paid to whoever calls rebalance.
    /// @param bountyCeiling The most a rebalance pays its caller in all, in wrapped collateral - a leveraged payment
    ///        counted as the collateral its tokens were minted for; zero is no ceiling.
    /// @param cutRatio The share of each rebalance payment paid to the cut receiver. The two ratios must sum within
    ///        100%; what is left of each payment is the pool's.
    function updateRebalanceConfig(uint256 bountyRatio, uint256 bountyCeiling, uint256 cutRatio) external;
}
