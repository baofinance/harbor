// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

/// @notice The one-shot migration of a pool from StabilityPool_v2 to StabilityPool_v3: its reward streams and each
///         holder's reward record copied into v3's widened storage, its ledger gap written, the rewards named taken
///         back from the accounts that may claim them and paid to the owner, and the pool then running
///         StabilityPool_v3.
interface IStabilityPool_v3_Upgrader {
    /// @notice A reward taken back as the pool is migrated: `amount` of `token` from what `account` may claim.
    struct Deduction {
        address account;
        address token;
        uint256 amount;
    }

    /// @notice `amount` of `token` is more than `account` may claim, `claimable`, so nothing was taken.
    error DeductionExceedsReward(address account, address token, uint256 amount, uint256 claimable);

    /// @notice `amount` of `token` was taken from what `account` may claim and paid to the owner.
    event RewardDeducted(address indexed account, address indexed token, uint256 amount);

    /// @notice Widen-copy the reward streams and per-holder reward snapshots, write the reward-divisor gap, take each
    ///         deduction from what its account may claim and pay it to the owner, then upgrade the proxy to
    ///         StabilityPool_v3.
    /// @param rewardDivisorGap The gap to seed: `supply - Sum(balanceOf)`, computed off-chain from the complete frozen
    ///        holder list under realistic bounds so the v3 divisor (`supply - gap`) tracks Sum(balanceOf) from the
    ///        first block. `0` when supply already equals the summed balances.
    /// @param holders The complete frozen holder list (the same one the gap is computed from) whose per-token reward
    ///        snapshots must be widen-copied into the v3 mapping. MUST be complete: a holder omitted here reads an empty
    ///        v3 snapshot after the upgrade - losing their pending/claimed and over-crediting future accrual from
    ///        integral 0. Runs in one transaction, so the list must fit the block gas limit.
    /// @param deductions The rewards taken back, each from a holder the list names. Each account is settled first by
    ///        `stabilityPoolV3`'s own checkpoint, so what accrued since its last checkpoint counts; a deduction above
    ///        what the account may then claim reverts `DeductionExceedsReward`. The tokens leave the pool for the
    ///        owner in the same call. Empty for a pool with nothing to take back.
    /// @param stabilityPoolV3 The real StabilityPool_v3 implementation to reinstate once migrated.
    function migrateAndUpgrade(
        int256 rewardDivisorGap,
        address[] calldata holders,
        Deduction[] calldata deductions,
        address stabilityPoolV3
    ) external;
}
