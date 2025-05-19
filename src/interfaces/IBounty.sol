// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @author rootminus0x1
interface IBounty {
    error BountyRatioTooLarge(uint256 bountyRatio, uint256 max);

    /// @notice Sets the bounty token and amounts configuration
    /// Either 'bountyAmount' or 'bountyRatio' which ever is the greater, or lesser, depending on 'useHighest'
    function setBounty(uint256 bountyAmount_, uint256 bountyRatio_, bool useHigher_) external;

    /// @notice Returns the bounty amounts configuration
    function bounty() external view returns (uint256 amount, uint256 ratio, bool useLower);

    /// @notice Returns the bounty amount for a given value
    function calcBounty(uint256 value) external pure returns (uint256 bounty_);
}
