// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {MinterLeverageCap} from "@harbor-test/candidates/MinterLeverageCap.sol";
import {StabilityPoolManagerLeverageCap} from "@harbor-test/candidates/StabilityPoolManagerLeverageCap.sol";
import {MarketRule} from "@harbor-test/harness/MarketRule.sol";

/// @notice The leverage-cap rule, whole: its minter, its manager, and the label its files carry.
///
/// The minter refuses every leveraged issuance below `K/(K-1)`; the manager gives the leveraged leg no headroom
/// there, so a rebalance runs on the collateral leg alone rather than reverting. Installed together or not at
/// all - see `MarketRule` for why that is an object and not two overrides.
contract LeverageCapRule is MarketRule {
    /// @dev The most leverage the rule will sell. `K = 20` puts the floor at `K/(K-1)` = 1.0526, where the
    /// deployed cap was measured to engage.
    uint256 public constant MAX_LEVERAGE_RATIO = 20 ether;

    function label() public pure virtual override returns (string memory) {
        return "_leverageCap";
    }

    function buildMinter(
        address wrappedCollateralToken,
        address peggedToken,
        address leveragedToken
    ) public override returns (address) {
        return address(new MinterLeverageCap(wrappedCollateralToken, peggedToken, leveragedToken, MAX_LEVERAGE_RATIO));
    }

    function buildManager(
        address minter,
        address collateralPool,
        address leveragedPool
    ) public virtual override returns (address) {
        return address(new StabilityPoolManagerLeverageCap(minter, collateralPool, leveragedPool));
    }
}
