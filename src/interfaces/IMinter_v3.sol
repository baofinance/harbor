// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

/// @notice Minter v3 extensions: fee-capped minting and absolute-amount fee queries in pegged space.
// solhint-disable-next-line contract-name-capwords
interface IMinter_v3 {
    /// @notice Mint pegged tokens with a fee cap. Stops minting when cumulative fee would exceed maxFeeRatio.
    /// Returns (0, 0) gracefully if the fee exceeds the cap from the start (does not revert).
    /// @param collateralIn The amount of wrapped collateral to post. Use type(uint256).max for all.
    /// @param receiver The address to receive minted pegged tokens.
    /// @param minPeggedOut Minimum acceptable pegged output. 0 means no check.
    /// @param maxFeeRatio Maximum overall fee ratio (18 decimals). e.g. 0.05 ether = 5%.
    /// @return peggedOut The amount of pegged tokens minted.
    /// @return collateralUsed The amount of wrapped collateral actually consumed (collateral added + fee).
    function mintPeggedToken(
        uint256 collateralIn,
        address receiver,
        uint256 minPeggedOut,
        uint256 maxFeeRatio
    ) external returns (uint256 peggedOut, uint256 collateralUsed);

    /// @notice Dry run of a capped mint: computes outcome if total fee is capped at maxFeeRatio.
    /// @param collateralIn The proposed amount of wrapped collateral.
    /// @param maxFeeRatio The maximum overall fee ratio (18 decimals). e.g. 0.05 ether = 5%.
    function mintPeggedTokenDryRun(
        uint256 collateralIn,
        uint256 maxFeeRatio
    )
        external
        view
        returns (
            int256 incentiveRatio,
            uint256 fee,
            uint256 collateralTaken,
            uint256 peggedMinted,
            uint256 price,
            uint256 rate
        );

    /// @notice Returns the absolute mint fee and uncapped redeem bonus for a given pegged amount, both
    /// expressed in pegged token units at current oracle prices.
    ///
    /// Intended for contract-to-contract callers (e.g. SP_v3 withdrawal fee, HY mechanism C) that need
    /// the fee as an amount (not a ratio) for a specific withdrawal size. Does NOT handle
    /// type(uint256).max as "all tokens" — callers must supply the actual amount.
    ///
    /// @param peggedIn The pegged token amount being evaluated (in pegged base units, 1e18-scaled).
    /// @return mintFee The absolute mint fee in pegged units that the Minter would charge for minting
    ///         the collateral-equivalent of `peggedIn`. Floored at zero. Used by SP_v3 as one component
    ///         of the CR-based withdrawal fee.
    /// @return peggedNotMinted The portion of `peggedIn` that falls in the disallow band (unmintable).
    ///         Zero when CR is high enough that the full amount is mintable.
    /// @return mintMaxFeeRatio The highest configured fee ratio across all non-disallow mint bands
    ///         (1e18-scaled). Used by callers to cap or scale the fee.
    /// @return redeemPeggedUncappedBonus The absolute uncapped redeem bonus in pegged units that the
    ///         system would pay from the reserve pool for redeeming `peggedIn` at the current CR. The
    ///         reserve pool is treated as unlimited (theoretical, not capped by actual balance). Floored
    ///         at zero — positive only when CR is stressed enough to offer a redemption discount.
    function peggedIncentivesByPegged(
        uint256 peggedIn
    )
        external
        view
        returns (uint256 mintFee, uint256 peggedNotMinted, uint256 mintMaxFeeRatio, uint256 redeemPeggedUncappedBonus);

    /// @notice Dry run of `freeRedeemPeggedToken`: the wrapped collateral and leveraged tokens a zero-fee pegged
    ///         redeem would yield for the given pegged split, priced against current oracle state - without moving
    ///         tokens or writing state. Intended for contract-to-contract callers (the StabilityPoolManager's
    ///         rebalance) that must know the redeemed proceeds before acting, e.g. to bound a pool's liquidation
    ///         reward to what its reward accounting can absorb.
    /// @param peggedForCollateral The pegged amount redeemed for wrapped collateral.
    /// @param peggedForLeveraged The pegged amount redeemed for leveraged tokens.
    /// @return wrappedCollateralOut The wrapped collateral that `peggedForCollateral` would return.
    /// @return leveragedOut The leveraged tokens that `peggedForLeveraged` would return.
    function freeRedeemDryRun(
        uint256 peggedForCollateral,
        uint256 peggedForLeveraged
    ) external view returns (uint256 wrappedCollateralOut, uint256 leveragedOut);
}
