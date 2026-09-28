// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";

/// @notice Evaluate a candidate rule about the SAIL'S CLAIM by measuring the market once and rescaling,
/// instead of implementing the rule in a contract and installing it.
///
/// The conversion mints `anchorIn x anchorPrice x sailSupply / sailClaim`. The only term a claim rule
/// touches is the divisor, so a result measured at one claim can be converted to the result at another
/// by multiplying by the ratio of the claims. One transaction then yields a whole family of candidate
/// answers, at any number of parameter values, with no mock minter for any of them.
///
/// That matters for more than speed. Every rule implemented as a contract is a second implementation
/// that can be wrong on its own account, and one written for this work WAS - it priced the anchor at one
/// where it was not, and paid 111 sail per anchor against a cap of 100. A rescale has nothing to get
/// wrong: it is one multiply against a number the market itself produced.
///
/// ─────────────────────────────────────────────────────────────────────────────────────────────────────
/// WHEN THE RESCALE IS EXACT, AND WHEN IT IS A MODEL PRETENDING TO BE A MEASUREMENT
///
/// Exact if, and only if, the candidate rule leaves ALL of these untouched:
///
///   1. the ANCHOR's price - `min(1, collateralRatio)`, unchanged;
///   2. the sail SUPPLY at the moment of measurement;
///   3. the path the operation takes - which band it walks, what fee it pays, whether it refuses.
///
/// A rule that only puts a floor under the sail's claim satisfies all three, because the band walk is
/// indexed by the collateral ratio with the anchor taken at par and so cannot see a sail rule at all.
/// A reserve account backing the sail satisfies all three for the same reason - the claim becomes
/// `residual + reserve` and nothing else moves.
///
/// A rule that changes the ANCHOR's price does NOT, and the rescale silently becomes a model. The
/// shifted-knee proposal was exactly that: it moved the anchor's price, which moved what every band walk
/// did, which no amount of rescaling can reach. That is why it needed a real implementation, and why
/// measuring it by rescale would have reported a rule that does not exist.
///
/// So the two techniques divide the work rather than competing:
///
///   - RESCALE (this library) - cheap, exact for claim-only rules, sweeps many parameter values in one
///     pass. Use it to CHOOSE A SHAPE and a parameter.
///   - DIFFERENTIAL SURFACE SWEEP - install a real implementation and compare the whole external surface
///     under both rules, asserting it differs only where it must. Use it to VERIFY the chosen rule
///     reaches every path, including the fee-paying ones the external adjustments library reaches by
///     delegatecall. A rescale cannot do this at all, because it never installs anything.
///
/// One further limit: a rescale answers "what would ONE operation have returned", at the state actually
/// measured. It says nothing about how the market evolves under repeated operations, because the supply
/// moves. A trajectory needs the real rule installed.
library MinterClaimRescaleLib {
    /// @notice How a market's collateral divides, in the 1e36-scaled units the contract works in.
    /// @param collateralValueE36 What the collateral is worth, in pegged tokens.
    /// @param anchorClaimE36 What the anchor is owed at par - its count, valued at one each.
    /// @param residualE36 What is left for the sail, floored at zero where the anchor is not covered.
    struct Valuation {
        uint256 collateralValueE36;
        uint256 anchorClaimE36;
        uint256 residualE36;
    }

    /// @notice Read a market's own valuation, rather than reconstructing it from a test's assumptions.
    /// @dev Deliberately not `IMinter.leveragedTokenPrice()` times the supply: that has already been
    /// divided and floored, so multiplying back loses wei and the rescale below stops being exact.
    /// @param minter The market to read.
    /// @param priceOracle The oracle that market prices its collateral with.
    function valuationOf(address minter, address priceOracle) internal view returns (Valuation memory valuation) {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        valuation.collateralValueE36 = IMinter(minter).collateralTokenBalance() * price;
        valuation.anchorClaimE36 = IMinter(minter).peggedTokenBalance() * 1 ether;
        valuation.residualE36 = valuation.collateralValueE36 > valuation.anchorClaimE36
            ? valuation.collateralValueE36 - valuation.anchorClaimE36
            : 0;
    }

    /// @notice What the measured operation would have returned had the sail's claim been `candidateClaimE36`.
    /// @dev Exact under the three conditions in this library's notes, and a model outside them. The
    /// result goes as one over the claim, so this is a single multiply and not an approximation - but
    /// only where the numerator genuinely did not move.
    /// @param measuredOut What the operation actually returned.
    /// @param measuredClaimE36 The sail's claim at the moment it was measured, usually the raw residual.
    /// @param candidateClaimE36 The claim the candidate rule would have given.
    function rescaleToClaim(
        uint256 measuredOut,
        uint256 measuredClaimE36,
        uint256 candidateClaimE36
    ) internal pure returns (uint256) {
        // slither-disable-next-line incorrect-equality
        if (candidateClaimE36 == 0) {
            return 0; // no claim to buy into, so the operation cannot be priced at all
        }
        return Math.mulDiv(measuredOut, measuredClaimE36, candidateClaimE36);
    }

    /// @notice What a candidate rule hands to, or takes from, whatever funds it - as a signed share of
    ///         the collateral's value.
    /// @dev Positive where the candidate gives the sail MORE than the residual, so something must supply
    /// the difference; negative where it gives less, so the difference accrues. Whether the second pays
    /// for the first over a market's life is the question a floor has to answer, and it cannot be seen
    /// without the sign.
    /// @param candidateClaimE36 The claim the candidate rule gives the sail.
    /// @param residualE36 The claim with no rule at all.
    /// @param collateralValueE36 What the collateral is worth, which the flow is expressed against.
    function signedFlowShare(
        uint256 candidateClaimE36,
        uint256 residualE36,
        uint256 collateralValueE36
    ) internal pure returns (int256) {
        // slither-disable-next-line incorrect-equality
        if (collateralValueE36 == 0) {
            return 0;
        }
        if (candidateClaimE36 >= residualE36) {
            return int256(Math.mulDiv(candidateClaimE36 - residualE36, 1 ether, collateralValueE36));
        }
        return -int256(Math.mulDiv(residualE36 - candidateClaimE36, 1 ether, collateralValueE36));
    }
}
