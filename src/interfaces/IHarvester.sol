// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @author rootminus0x1
interface IHarvester {
    error InsufficientBounty(address token, uint256 bountyAmount, uint256 minBountyAmlount);

    function MINTER() external view returns (address);
    function BOUNTY_TOKEN() external view returns (address);
    function HARVEST_RECEIVER() external view returns (address);

    /// @notice Harvests accrued value for a bounty
    function harvest(address bountyReceiver, uint256 minBountyAmount) external;
}
