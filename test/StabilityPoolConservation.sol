// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";

import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";

/// @notice The StabilityPool's fixture-agnostic conservation checks and the raw accumulations under them, shared by
/// every test that drives the pool through stateful sequences: the stateful invariant (StabilityPoolInvariant), the
/// deterministic ledger-gap scenarios (StabilityPoolLedgerGap), and the envelope-fit fuzz (StabilityPoolEnvelope).
/// Everything reads only public pool/reward state (balanceOf, totalSupply, claimed, claimable, rewardData, token
/// balances) and takes the ghost accounting the caller tracks as parameters, so it works against any fixture - a
/// hand-rolled mock or the real deployForPeg protocol.
///
/// The accumulations (`_sumBalances`, `_ledgerGap`, `_creditedTotals`) are exposed so a caller with its own bespoke
/// assertion (a specific bound, a discriminating value, a CSV row) can build on the same computation the derived-bound
/// asserts use, rather than re-deriving it. The white-box divisor check needs the mock's internal accessor and lives
/// in the `MockStabilityPoolConservation` sub-mixin below; the per-action probe checks (claimable monotonicity,
/// no-retroactive-reward) need handler instrumentation and stay with their owning test.
///
/// The tolerances are the pool's derived arithmetic: the loss over-application (up to `maxSupplyEver/1e18` asset wei,
/// the ceiling-division loss error) plus per-checkpoint and per-actor stored-balance flooring (<= 1 wei each), and for
/// rewards the pool-favoured under-credit the ceiling-division loss strands (`injected * (maxSupplyEver/1e18) / supply`
/// per distribution). `calls` is the count of checkpoint-inducing operations; each is bounded to floor at most 2
/// stored balances. The per-token checks are split into their own frames to stay under the EVM stack limit.
abstract contract StabilityPoolConservation is BaoTest {
    /// @notice The ghost accounting a caller accumulates over its sequence, packed to keep the checks under the stack
    /// limit. `injected[t]` is aligned with `tokens[t]`.
    struct SpConservationGhosts {
        address[] tokens;
        uint256[] injected;
        uint256 maxSupplyEver;
        uint256 calls;
        uint256 minSupply;
    }

    // ─── raw accumulations (shared by the asserts below and by callers with bespoke assertions) ───

    /// @notice Sum of the actors' product-rebased balances.
    function _sumBalances(address pool, address[] memory actors) internal view returns (uint256 sum) {
        for (uint256 a = 0; a < actors.length; a++) {
            sum += IERC20(pool).balanceOf(actors[a]);
        }
    }

    /// @notice The signed ledger gap: totalSupply - Sum(balanceOf). Positive = users under-credited (loss
    /// over-applied); negative = over-credited (claimable can exceed tokens held).
    function _ledgerGap(address pool, address[] memory actors) internal view returns (int256) {
        return int256(IERC20(pool).totalSupply()) - int256(_sumBalances(pool, actors));
    }

    /// @notice Per token, the total credited: claimed + claimable + the distributor's queued remainder + the
    /// undistributed stream tail. What must never exceed the injected amount.
    function _creditedTotals(
        address pool,
        address[] memory actors,
        address[] memory tokens
    ) internal view returns (uint256[] memory total) {
        (uint256[] memory sumClaimed, uint256[] memory sumClaimable) = _sumClaimedClaimable(pool, actors, tokens);
        total = new uint256[](tokens.length);
        for (uint256 t = 0; t < tokens.length; t++) {
            (, uint256 finishAt, uint256 rate, uint256 queued) = IMultipleRewardDistributor(pool).rewardData(tokens[t]);
            uint256 undistributed = finishAt > block.timestamp ? rate * (finishAt - block.timestamp) : 0;
            total[t] = sumClaimed[t] + sumClaimable[t] + queued + undistributed;
        }
    }

    // ─── derived-bound asserts ───

    /// @notice The actors' product-rebased balances sum to the recorded total supply, within the loss over-application
    /// and per-store flooring. Symmetric: the sum can sit either side as the loss-error queue fills and drains.
    function _assertPoolConserved(
        address pool,
        address[] memory actors,
        uint256 maxSupplyEver,
        uint256 calls
    ) internal view {
        uint256 tolerance = maxSupplyEver / 1 ether + 2 * calls + actors.length;
        assertApprox(
            _sumBalances(pool, actors),
            IERC20(pool).totalSupply(),
            tolerance,
            "sum of actor balances vs totalSupply"
        );
    }

    /// @notice Every reward token conserves one-directionally: claimed + claimable + the distributor's queued remainder
    /// + the undistributed stream tail may never EXCEED what was injected (a real over-credit), and may fall short only
    /// by the pool-favoured under-credit the loss accounting strands.
    function _assertRewardConserved(
        address pool,
        address[] memory actors,
        SpConservationGhosts memory g
    ) internal view {
        (uint256[] memory sumClaimed, uint256[] memory sumClaimable) = _sumClaimedClaimable(pool, actors, g.tokens);
        for (uint256 t = 0; t < g.tokens.length; t++) {
            _assertTokenConserved(pool, g, t, sumClaimed[t], sumClaimable[t], actors.length);
        }
    }

    /// @notice Solvency: the pool holds enough asset to honour every withdrawal (asset balance >= supply), and enough
    /// of each reward token to honour its obligations within the stranded-slice allowance (the mirror of the reward
    /// under-credit: at dust scale the LAST claimer can fall a few wei short).
    function _assertSpSolvent(address pool, address[] memory actors, SpConservationGhosts memory g) internal view {
        assertGe(
            IERC20(IStabilityPool(pool).ASSET_TOKEN()).balanceOf(pool),
            IERC20(pool).totalSupply(),
            "asset balance below total supply"
        );
        (, uint256[] memory claimable) = _sumClaimedClaimable(pool, actors, g.tokens);
        for (uint256 t = 0; t < g.tokens.length; t++) {
            _assertTokenSolvent(pool, g, t, claimable[t]);
        }
    }

    /// @dev One reward token's conservation, in its own frame.
    function _assertTokenConserved(
        address pool,
        SpConservationGhosts memory g,
        uint256 t,
        uint256 sumClaimed,
        uint256 sumClaimable,
        uint256 actorCount
    ) private view {
        uint256[] memory partsVec = new uint256[](4);
        partsVec[0] = sumClaimed;
        partsVec[1] = sumClaimable;
        {
            (, uint256 finishAt, uint256 rate, uint256 queued) = IMultipleRewardDistributor(pool).rewardData(
                g.tokens[t]
            );
            partsVec[2] = queued;
            partsVec[3] = finishAt > block.timestamp ? rate * (finishAt - block.timestamp) : 0;
        }
        uint256 maxDust = _strandedRewardBound(g, t) + 2 * g.calls + 2 * actorCount + 2;
        assertConserved(
            partsVec,
            g.injected[t],
            maxDust,
            string.concat("reward conservation: ", vm.toString(g.tokens[t]))
        );
    }

    /// @dev One reward token's solvency, in its own frame. `baseObligation` is the actors' summed claimable.
    function _assertTokenSolvent(
        address pool,
        SpConservationGhosts memory g,
        uint256 t,
        uint256 baseObligation
    ) private view {
        (, uint256 finishAt, uint256 rate, uint256 queued) = IMultipleRewardDistributor(pool).rewardData(g.tokens[t]);
        uint256 obligation = baseObligation +
            queued +
            (finishAt > block.timestamp ? rate * (finishAt - block.timestamp) : 0);
        uint256 overCredit = _strandedRewardBound(g, t);
        assertGe(
            IERC20(g.tokens[t]).balanceOf(pool) + overCredit,
            obligation,
            string.concat("reward balance below obligations: ", vm.toString(g.tokens[t]))
        );
    }

    /// @dev The reward slice the loss ceiling-division error can strand per token: injected scaled by the outstanding
    /// loss over-application (maxSupplyEver/1e18, a rounding guard, and 2 per checkpoint call) over the min supply. The
    /// pool-favoured under-credit floor for conservation, and the mirror allowance for reward solvency.
    function _strandedRewardBound(SpConservationGhosts memory g, uint256 t) private pure returns (uint256) {
        return Math.mulDiv(g.injected[t], g.maxSupplyEver / 1 ether + 1 + 2 * g.calls, g.minSupply);
    }

    /// @dev Sum each actor's claimed and claimable across `tokens`, split out to keep the checks under the stack limit.
    function _sumClaimedClaimable(
        address pool,
        address[] memory actors,
        address[] memory tokens
    ) private view returns (uint256[] memory sumClaimed, uint256[] memory sumClaimable) {
        sumClaimed = new uint256[](tokens.length);
        sumClaimable = new uint256[](tokens.length);
        for (uint256 a = 0; a < actors.length; a++) {
            uint256[] memory claimedVector = IClaimReward(pool).claimed(actors[a], tokens);
            uint256[] memory claimableVector = IClaimReward(pool).claimable(actors[a], tokens);
            for (uint256 t = 0; t < tokens.length; t++) {
                sumClaimed[t] += claimedVector[t];
                sumClaimable[t] += claimableVector[t];
            }
        }
    }
}

/// @notice The minimal white-box accessor a mock StabilityPool exposes for the divisor check - referenced by interface
/// so the shared helper never imports the test contract that defines the mock.
interface IStabilityPoolRewardDivisor {
    function __rewardDivisor() external view returns (uint256); // solhint-disable-line func-name-mixedcase
}

/// @notice Adds the white-box divisor check for mock-based tests (StabilityPoolInvariant, StabilityPoolLedgerGap). The
/// real deployForPeg protocol has no such accessor, so real-SP tests inherit `StabilityPoolConservation` directly and
/// rely on the black-box `_assertRewardConserved`/`_assertSpSolvent` for the same guarantee's observable consequence.
abstract contract MockStabilityPoolConservation is StabilityPoolConservation {
    /// @notice The reward divisor (`_getTotalPoolShare().totalShare`) must never sit below Sum(balanceOf): a divisor
    /// below the summed balances credits `reward * Sum(balanceOf) / divisor > reward` - an over-credit.
    function _assertDivisorGeSumBalance(address pool, address[] memory actors) internal view {
        assertGe(
            IStabilityPoolRewardDivisor(pool).__rewardDivisor(),
            _sumBalances(pool, actors),
            "reward divisor below Sum(balanceOf): rewards would over-credit"
        );
    }
}
