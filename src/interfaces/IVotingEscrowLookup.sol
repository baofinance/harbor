// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";

interface IVotingEscrowLookup {
    /// @notice Finds the largest `epoch` belongs to `[startEpoch, endEpoch]` and
    /// `ve.point_history(epoch) <= timestamp`.
    ///
    /// TODO: put this as a check?
    /// Caller should make sure the `ve.point_history(startEpoch) <= timestamp`.
    ///
    /// @param timestamp The timestamp to search.
    /// @param startEpoch The number of start epoch, inclusive.
    /// @param endEpoch The number of end epoch, inclusive.
    /// @return epoch_ The largest `epoch` that `ve.point_history(epoch) <= timestamp`.
    /// @return point The value of `ve.point_history(epoch)`.
    function findSupplyPoint(
        uint256 timestamp,
        uint256 startEpoch,
        uint256 endEpoch
    ) external view returns (uint256 epoch_, IVotingEscrow.Point memory point);

    /// @dev Find the largest `epoch` belongs to `[startEpoch, endEpoch]` and
    /// `ve.user_point_history(account, epoch) <= timestamp`.
    ///
    /// TODO: put this as a check?
    /// Caller should make sure the `ve.user_point_history(account, startEpoch) <= timestamp`.
    ///
    /// @param account The address of user to search.
    /// @param timestamp The timestamp to search.
    /// @param startEpoch The number of start epoch, inclusive.
    /// @param endEpoch The number of end epoch, inclusive.
    /// @return epoch_ The largest `epoch` that `ve.user_point_history(account, epoch) <= timestamp`.
    /// @return point The value of `ve.user_point_history(account, epoch)`.
    function findUserPoint(
        address account,
        uint256 timestamp,
        uint256 startEpoch,
        uint256 endEpoch
    ) external view returns (uint256 epoch_, IVotingEscrow.Point memory point);
}
