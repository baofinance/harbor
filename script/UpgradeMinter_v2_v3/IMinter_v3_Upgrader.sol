// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice The one-shot upgrade of a minter that records backing but holds no wrapped collateral - a retired market's
///         rounding dust - to Minter_v3: the record is set to what nothing held is worth, zero, and the minter then runs
///         Minter_v3.
interface IMinter_v3_Upgrader {
    /// @notice The minter holds `held` of `wrappedCollateral`, so the backing it records is not dust to zero.
    error MinterHoldsWrappedCollateral(address wrappedCollateral, uint256 held);

    /// @notice The minter's recorded backing, `backing`, was set to zero: it held no wrapped collateral.
    event BackingZeroed(uint256 backing);

    /// @notice Set the recorded backing to zero, then upgrade to `minterV3`, running `upgradeCall` there. Refuses unless
    ///         the minter holds none of the wrapped collateral `minterV3` is built for.
    function zeroBackingAndUpgrade(address minterV3, bytes calldata upgradeCall) external;
}
