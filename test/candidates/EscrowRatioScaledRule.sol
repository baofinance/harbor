// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {MinterEscrowRatioScaled} from "@harbor-test/candidates/MinterEscrowRatioScaled.sol";
import {MarketRule} from "@harbor-test/harness/MarketRule.sol";

/// @notice The escrow candidate at a chosen escrow ratio - the product dial - with the label that names the ratio.
///         This tree's manager, as for the candidate itself.
contract EscrowRatioScaledRule is MarketRule {
    /// @dev The share of a founding deposit the escrow takes, 1e18-scaled; the candidate's own is 0.1.
    uint256 public immutable ESCROW_RATIO;
    string private _label;

    constructor(uint256 escrowRatio, string memory label_) {
        ESCROW_RATIO = escrowRatio;
        _label = label_;
    }

    function label() public view override returns (string memory) {
        return _label;
    }

    function buildMinter(
        address wrappedCollateralToken,
        address peggedToken,
        address leveragedToken
    ) public override returns (address) {
        return address(new MinterEscrowRatioScaled(wrappedCollateralToken, peggedToken, leveragedToken, ESCROW_RATIO));
    }
}
