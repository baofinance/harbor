// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

// solhint-disable-next-line contract-name-capwords
interface IStabilityPoolManager_v2 is IStabilityPoolManager {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error InvalidHarvestRatioSum(uint256 bountyRatio, uint256 cutRatio);

    /// @notice Emitted when an auto-compounder is registered or unregistered for a stability pool.
    /// @param stabilityPool The stability pool address.
    /// @param autoCompounder The auto-compounder address (address(0) = unregistered).
    event AutoCompounderSet(address indexed stabilityPool, address indexed autoCompounder);

    /// @notice Emitted when compound() on a registered auto-compounder fails during harvest or
    ///         rebalance. The failure is non-fatal — harvest/rebalance still completes — but
    ///         rewards remain unclaimed until the next successful compound().
    /// @param autoCompounder The auto-compounder whose compound() call reverted.
    /// @param reason Raw revert bytes (empty if the revert carried no data).
    event CompoundFailed(address indexed autoCompounder, bytes reason);

    /*//////////////////////////////////////////////////////////////
                         PUBLIC READ FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    // solhint-disable-next-line func-name-mixedcase
    function MINTER() external view returns (address);

    /// @notice Register or unregister an auto-compounder for a stability pool.
    /// @dev Only one auto-compounder per stability pool. Pass address(0) to unregister.
    ///      The stability pool must be one of the two registered pools.
    /// @param stabilityPool The stability pool address.
    /// @param autoCompounder_ The auto-compounder address, or address(0) to remove.
    function setAutoCompounder(address stabilityPool, address autoCompounder_) external;

    /// @notice Get the auto-compounder registered for a stability pool.
    /// @param stabilityPool The stability pool address.
    /// @return The registered auto-compounder, or address(0) if none.
    function autoCompounder(address stabilityPool) external view returns (address);
}
