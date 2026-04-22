// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";

interface IStabilityPoolManager_v2 is IStabilityPoolManager {
    /// @notice Emitted when an auto-compounder is registered or unregistered for a stability pool.
    /// @param sp The stability pool address.
    /// @param ac The auto-compounder address (address(0) = unregistered).
    event AutoCompounderSet(address indexed sp, address indexed ac);

    /// @notice Register or unregister an auto-compounder for a stability pool.
    /// @dev Only one auto-compounder per stability pool. Pass address(0) to unregister.
    ///      The stability pool must be one of the two registered pools.
    /// @param sp The stability pool address.
    /// @param ac The auto-compounder address, or address(0) to remove.
    function setAutoCompounder(address sp, address ac) external;

    /// @notice Get the auto-compounder registered for a stability pool.
    /// @param sp The stability pool address.
    /// @return The registered auto-compounder, or address(0) if none.
    function autoCompounder(address sp) external view returns (address);
}
