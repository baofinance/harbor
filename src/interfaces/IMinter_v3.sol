// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

/// @notice Minter v3 extensions: fee-capped minting.
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
}
