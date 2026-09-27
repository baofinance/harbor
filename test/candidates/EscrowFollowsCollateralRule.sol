// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {MinterEscrowFollowsCollateral} from "@harbor-test/candidates/MinterEscrowFollowsCollateral.sol";
import {MarketRule} from "@harbor-test/harness/MarketRule.sol";

/// @notice The escrow candidate: its minter and the label its files carry. It keeps this tree's manager, since it
///         changes nothing about how a rebalance is sized.
///
/// The markets install a rule's minter before founding, because the escrow per leveraged token is written by
/// the first mint into an empty supply - a rule installed afterwards would inherit a figure the rule it replaced
/// had chosen.
contract EscrowFollowsCollateralRule is MarketRule {
    function label() public pure override returns (string memory) {
        return "_followsCollateral";
    }

    function buildMinter(
        address wrappedCollateralToken,
        address peggedToken,
        address leveragedToken
    ) public override returns (address) {
        return address(new MinterEscrowFollowsCollateral(wrappedCollateralToken, peggedToken, leveragedToken));
    }
}
