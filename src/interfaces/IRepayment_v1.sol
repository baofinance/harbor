// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title IRepayment_v1
/// @notice Repays a fixed list of debts, all in one token, from whatever is paid into the contract: at every moment
///         every account can claim the same fraction of its debt as every other, and the whole of it once the total
///         debt has been paid in. The contract is a fee receiver: the fees of the markets flow to it until the debts
///         are covered, after which the owner sweeps the surplus.
///
///         It is also a token that cannot be transferred: each account's balance is what it is still owed, minted at
///         deployment and burned as it is claimed, so the debt shows in the account's wallet until it is repaid.
// solhint-disable-next-line contract-name-capwords
interface IRepayment_v1 is IERC20Metadata {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted once per account when the debts are recorded, with the `Transfer` that mints them.
    /// @param account The account owed.
    /// @param debt What it is owed, in the debt token.
    event DebtRecorded(address indexed account, uint256 debt);

    /// @notice Emitted by a claim, with the `Transfer` that burns what it paid.
    /// @param account The account whose debt is repaid.
    /// @param receiver The account paid.
    /// @param amount The debt token paid.
    event Claimed(address indexed account, address indexed receiver, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice The accounts and the debts recorded must pair up.
    error AccountsAndDebtsDifferentSizes(uint256 accountsLength, uint256 debtsLength);

    /// @notice An account owed nothing is not recorded.
    error ZeroDebt(address account);

    /// @notice An account is recorded once.
    error DuplicateAccount(address account);

    /// @notice The caller is not among the accounts owed.
    error NoDebt(address account);

    /// @notice The caller has already claimed everything paid in so far entitles it to.
    error NothingToClaim(address account);

    /// @notice The debt token can be swept only once the total debt has been paid in, and only beyond it.
    error DebtsNotCovered(uint256 received, uint256 totalDebt);

    /// @notice A sweep of the debt token may take only the surplus over the debts.
    error SweepExceedsSurplus(uint256 amount, uint256 surplus);

    /// @notice The debt stays with the account that is owed: the token is not transferred or approved.
    error NotTransferable();

    /*//////////////////////////////////////////////////////////////
                           PUBLIC VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice The token the debts are in and are repaid in.
    // solhint-disable-next-line func-name-mixedcase
    function TOKEN() external view returns (address);

    /// @notice What `account` is owed in all. Its balance is what it is still owed.
    function debt(address account) external view returns (uint256);

    /// @notice What `account` has claimed so far.
    function claimed(address account) external view returns (uint256);

    /// @notice What `account` can claim now: its debt times the fraction of the total debt paid in so far (capped at
    ///         the whole), less what it has claimed.
    function claimable(address account) external view returns (uint256);

    /// @notice Everything paid into the contract so far: its balance of the debt token plus what has been claimed.
    function received() external view returns (uint256);

    /// @notice The sum of the debts. The total supply is what is still outstanding.
    function totalDebt() external view returns (uint256);

    /// @notice The sum of the claims so far.
    function totalClaimed() external view returns (uint256);

    /*//////////////////////////////////////////////////////////////
                          PUBLIC UPDATE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pay the caller what it can claim, burning as much of its balance.
    /// @dev Reverts `NoDebt` for an account not owed, `NothingToClaim` when nothing new has been paid in.
    /// @return amount The debt token paid.
    function claim() external returns (uint256 amount);

    /// @notice Pay `receiver` what the caller can claim; the claim is recorded against the caller, whose balance burns.
    /// @return amount The debt token paid.
    function claim(address receiver) external returns (uint256 amount);
}
