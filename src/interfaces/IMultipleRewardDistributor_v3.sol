// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";

// solhint-disable-next-line contract-name-capwords
interface IMultipleRewardDistributor_v3 is IMultipleRewardDistributor {
    /// @notice The maximum reward a single `depositReward(token, amount)` can accept without the linear stream's rate
    /// field overflowing. A conservative, `increase`-decoupled bound: `cap - committed`, where
    /// `cap = rateMax * REWARD_PERIOD_LENGTH` and `committed = queued + rate * REWARD_PERIOD_LENGTH` (the `rate * period`
    /// term upper-bounds any restream carry, since an active period's re-fold window is at most one period). Returns
    /// `type(uint256).max` in immediate-distribution mode (period 0), where there is no stream to overflow. A caller can
    /// deposit any amount up to this value in one call; larger deposits must be split across calls.
    /// @param token The reward token.
    /// @return maxAmount The largest amount a single `depositReward` can accept without reverting on the rate field.
    function maxDepositReward(address token) external view returns (uint256 maxAmount);
}
