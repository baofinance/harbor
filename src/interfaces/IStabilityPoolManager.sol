// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IStabilityPoolManager {
    // Events
    event StabilityPoolAdded(address indexed stabilityPool);
    event StabilityPoolRemoved(address indexed stabilityPool);
    event BountyUpdated(address token, uint256 rebalanceAamount, uint256 harvestRratio);
    event LiquidationPerformed(address indexed stabilityPool, uint256 amount);
    event HarvestPerformed(uint256 harvestedAmount, uint256 bounty);

    // Errors
    error InvalidStabilityPool(address pool);
    error InsufficientBounty(address token, uint256 given, uint256 expected);
    error NoStabilityPools();
    error NoHarvestable();
    error InsufficientLiquidation(uint256 actual, uint256 expected);

    // View functions
    function stabilityPools() external view returns (address[] memory);
    function hasStabilityPool(address stabilityPool) external view returns (bool);
    function harvestable() external view returns (uint256);
    function rebalanceable() external view returns (bool);
    function bounty() external view returns (address token, uint256 bountyAmount, uint256 HarvestRatio);

    // Mutator functions
    // function addStabilityPool(address stabilityPool) external;
    // function removeStabilityPool(address stabilityPool) external;
    function setRebalanceBounty(uint256 rebalanceAmount, uint256 harvestRatio) external;
    function rebalance(address bountyReceiver, uint256 minLiquidation) external returns (uint256 totalLiquidated);
    function harvest(address bountyReceiver, uint256 minBounty) external returns (uint256 harvestedAmount);
}
