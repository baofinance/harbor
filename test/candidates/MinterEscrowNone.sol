// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Minter_v3} from "@harbor/minter/Minter_v3.sol";

/// @notice The CURRENT code with the escrow rule removed: no escrow, so the leveraged token's claim is the
/// residual alone.
///
/// **This is not `main`, and a measurement of it must never be reported as one.** It is the current
/// contract with one rule switched off, which makes it a control for the question "what does the escrow
/// do?" - the same valuation, the same impairment guard, the same pro-rata write-down, differing in the
/// escrow and nothing else, so a difference between it and a candidate is attributable to the escrow.
///
/// What `main` actually does is a separate question and is only answerable from the DEPLOYED CONTRACTS.
/// Main differs from this in more than the escrow - the par valuation below the peg, the impairment guard
/// and the pro-rata write-down all arrived after it - so this cannot stand in for it however close the two
/// may turn out to be. `deployments/mainnet/harbor_v1.state.json` carries the implementation addresses;
/// a proxy pointed at those, on a pinned fork, is the only thing entitled to be labelled `main`.
///
/// IT WAS BUILT AS A HYPOTHESIS - that this rule and the deployed code would produce the same graph, and so
/// that the escrow was the whole of what changed for a rebalance. **The hypothesis is FALSE, and measuring
/// the deployed contracts is what showed it.**
///
///   - This rule rebalances at 150 of 800 collateral ratios, none of them below one. Below the peg the
///     residual is gone, so the claim is nothing, `leverageRatio` reports `type(uint256).max` - the encoding
///     for a claim of zero - and the market is not rebalanceable at all.
///   - The deployed contracts rebalance at 649 of 800, from every ratio down to 0.002, and report
///     `leverageRatio` of exactly 20 at the same points.
///
/// Twenty is a CAP, and it is the second difference. The escrow did not merely close a pole; it REPLACED a
/// leverage-ratio cap that bounded issuance where the claim had vanished. Take the escrow away without
/// restoring that cap and the result is neither system: a claim of zero with nothing bounding it, so no
/// conversion can be made at all.
///
/// So this contract models NOTHING THAT HAS EVER RUN. Its value is as a boundary case - it shows what the
/// escrow alone contributes by removing it and leaving nothing in its place - and it must never be read as
/// `main`. What `main` does is measured directly, by the `Deployed` leaf of each graph suite - a
/// `DeployedMarket`, the deployed proxies on a pinned fork - which is the only thing entitled to that label.
///
/// It is also the BASE of `MinterLeverageCap`, which keeps these four overrides, supplies the fifth part of the
/// escrow seam (`_escrowedPerPegged`), and adds the refusal that puts a bound back where the escrow was.
///
/// What this should show is the pole: with no escrow the leveraged claim is the residual, which vanishes at
/// a collateral ratio of one, so the conversion rate diverges there and the leveraged price reads zero
/// below it. That is the behaviour the escrow was introduced to remove, and measuring it is the only way to
/// say what the removal cost.
///
/// Overrides all four parts of the escrow rule, because a rule that changes the derivation without changing
/// the movements would leave collateral moved into an escrow that reports as nothing - the records would
/// drift from the holding and the guard would halt the market.
contract MinterEscrowNone is Minter_v3 {
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address collateralToken_,
        address peggedToken_,
        address leveragedToken_
    ) Minter_v3(collateralToken_, peggedToken_, leveragedToken_) {}

    function _escrow(MinterStorage storage) internal view virtual override returns (uint256) {
        return 0;
    }

    function _escrowTakenByAMint(
        MinterStorage storage,
        uint256,
        uint256,
        uint256
    ) internal virtual override returns (uint256) {
        return 0;
    }

    function _escrowReleasedByARedeem(
        MinterStorage storage,
        uint256,
        uint256,
        uint256
    ) internal view virtual override returns (uint256) {
        return 0;
    }

    function _conversionEscrowMove(
        MinterStorage storage,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256
    ) internal virtual override returns (uint256) {
        return 0;
    }
}
