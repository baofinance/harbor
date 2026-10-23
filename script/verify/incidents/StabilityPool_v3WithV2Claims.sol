// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {StabilityPool_v3} from "@harbor/minter/StabilityPool_v3.sol";

/// @notice StabilityPool_v3 with StabilityPool_v2's account-taking claim forms put back, so a transaction written
///         against v2 - such as the 2026-10-16 exploits, which call them - can be replayed against v3's accounting.
///         For replays only: v3 dropped these forms on purpose. Each one reads or pays through v3's own reward
///         ledger, so what it reports or pays is what v3 holds for the account.
///
///         v3 has no reward receiver: it pays an account's rewards to the account. v2 paid to the receiver an account
///         had chosen, or to the `receiver` argument; paying anyone other than the account is not implemented here,
///         and reverts.
contract StabilityPool_v3WithV2Claims is StabilityPool_v3 {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address minter_,
        uint256 withdrawalStartDelay_,
        uint256 withdrawalEndWindow_,
        uint256 minTotalAssetSupply,
        string memory name_,
        string memory symbol_
    ) StabilityPool_v3(minter_, withdrawalStartDelay_, withdrawalEndWindow_, minTotalAssetSupply, name_, symbol_) {}

    /// @notice v2's `claimable(account, token)`: what `account` could claim of `token` now.
    function claimable(address account, address token) external view returns (uint256) {
        return _claimable(account, token, true);
    }

    /// @notice v2's `claim(account)`: pays `account` everything it is owed in every active reward token, whoever
    ///         calls.
    function claim(address account) external nonReentrant {
        _claimEveryToken(account);
    }

    /// @notice v2's `claim(account, receiver)`: as `claim(account)`, refusing as v2 did to pay another account's
    ///         rewards to a chosen receiver. A receiver other than the account itself is not implemented.
    function claim(address account, address receiver) external nonReentrant {
        if (account != _msgSender() && receiver != address(0)) {
            revert IMultipleRewardAccumulator.ClaimOthersRewardToAnother();
        }
        if (receiver != address(0) && receiver != account) {
            revert("StabilityPool_v3WithV2Claims: paying a receiver other than the account is not implemented");
        }
        _claimEveryToken(account);
    }

    function _claimEveryToken(address account) private {
        _checkpoint(account);
        address[] memory tokens = activeRewardTokens();
        for (uint256 i = 0; i < tokens.length; ++i) {
            _claimOneToken(account, tokens[i], type(uint256).max); // wake-disable-line unchecked-return-value
        }
    }
}
