// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ITokenHolder} from "@bao/TokenHolder.sol";

import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMultipleRewardAccumulator_v3} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {DecrementalFloatingPoint} from "@harbor/math/DecrementalFloatingPoint.sol";

import {TestStabilityPoolSetUp, MockStabilityPool} from "@harbor-test/StabilityPool.t.sol";
import {MockStabilityPoolConservation} from "@harbor-test/StabilityPoolConservation.sol";

/// @notice Stateful fuzz handler for the StabilityPool. Each external function is one bounded
/// action the invariant fuzzer can sequence: deposit / windowed and immediate (fee) withdrawal /
/// share transfer / reward claim / liquidation / reward deposit / time warp / checkpoint. Every
/// action bounds its inputs so it cannot revert (fail-on-revert is enabled in the test contract),
/// records the ghost accounting the invariants check against, and runs the claimable-monotonicity
/// probe across all actors.
contract StabilityPoolInvariantHandler is Test {
    using DecrementalFloatingPoint for uint128;

    address public immutable POOL;
    address public immutable ASSET_TOKEN;
    address public immutable LIQUIDATION_TOKEN;
    address public immutable REBALANCER;
    address public immutable REWARD_DEPOSITOR;
    uint256 public immutable PRICE;
    uint256 public immutable MIN_TOTAL_ASSET_SUPPLY;

    address[] internal _actors;
    address[] internal _rewardTokens;

    // ─── ghost accounting read by the invariants ───
    /// @notice Total of each reward token ever injected into the pool (depositReward amounts +
    /// liquidation `returned`), i.e. the "whole" that claimed+claimable+queued+undistributed
    /// must conserve.
    mapping(address => uint256) public injected;
    /// @notice Highest totalSupply seen — bounds the outstanding `lastAssetLossError`
    /// over-application (< supply/1e18 asset wei at any instant).
    uint256 public maxSupplyEver;
    /// @notice Number of state-changing handler actions — bounds the per-checkpoint 1-wei floor
    /// events accumulated by the derived dust tolerances.
    uint256 public calls;
    /// @notice Times an actor's claimable dropped by more than the 2-wei two-floor-composition
    /// allowance without that actor claiming. Must stay 0.
    uint256 public monotoneViolations;
    /// @notice Times a deposit by a never-staked receiver changed that receiver's claimable.
    /// Must stay 0 — capital deposited after a stream must not capture pre-deposit rewards.
    uint256 public retroactiveViolations;
    /// @notice True once an account has ever received pool shares. `balanceOf == 0` is NOT
    /// freshness: a stored dust share can floor to a zero balance yet still accrue, so the
    /// exact-equality retroactivity probe only applies to accounts that never held shares.
    mapping(address => bool) public everHeldShares;

    mapping(address => mapping(address => uint256)) internal _lastClaimable; // actor => token => amount

    constructor(
        address pool,
        address rebalancer,
        address rewardDepositor,
        uint256 price,
        address[] memory actors_,
        address[] memory rewardTokens_
    ) {
        POOL = pool;
        ASSET_TOKEN = IStabilityPool(pool).ASSET_TOKEN();
        LIQUIDATION_TOKEN = IStabilityPool(pool).LIQUIDATION_TOKEN();
        REBALANCER = rebalancer;
        REWARD_DEPOSITOR = rewardDepositor;
        PRICE = price;
        MIN_TOTAL_ASSET_SUPPLY = IStabilityPool(pool).MIN_DEPOSIT();
        _actors = actors_;
        _rewardTokens = rewardTokens_;
    }

    function actorCount() external view returns (uint256 count) {
        return _actors.length;
    }

    function actorAt(uint256 index) external view returns (address actor) {
        return _actors[index];
    }

    function rewardTokenCount() external view returns (uint256 count) {
        return _rewardTokens.length;
    }

    function rewardTokenAt(uint256 index) external view returns (address token) {
        return _rewardTokens[index];
    }

    // ─── actions ───

    /// @notice Deposit pegged tokens for an actor-chosen receiver. A receiver whose balance was
    /// zero must see claimable per token EXACTLY unchanged by the deposit (no retroactive reward):
    /// the pre-deposit checkpoint flushes pending at zero shares for them, the fresh snapshot is
    /// taken at the current integral, and the temporal pending restarts at elapsed 0.
    function deposit(uint256 actorSeed, uint256 receiverSeed, uint256 amount) external {
        address actor = _actors[actorSeed % _actors.length];
        address receiver = _actors[receiverSeed % _actors.length];

        // The floor is on the resulting total supply, so only an under-filling first deposit reverts.
        uint256 supply = IERC20(POOL).totalSupply();
        uint256 lower = 1;
        if (supply < MIN_TOTAL_ASSET_SUPPLY) {
            lower = MIN_TOTAL_ASSET_SUPPLY - supply;
        }
        amount = bound(amount, lower, 1_000_000 ether);

        bool freshReceiver = !everHeldShares[receiver];
        uint256[] memory claimableBefore = IClaimReward(POOL).claimable(receiver, _rewardTokens);

        deal(ASSET_TOKEN, actor, amount);
        vm.startPrank(actor);
        IERC20(ASSET_TOKEN).approve(POOL, amount);
        IStabilityPool(POOL).deposit(amount, receiver, 0);
        vm.stopPrank();
        everHeldShares[receiver] = true;

        if (freshReceiver) {
            uint256[] memory claimableAfter = IClaimReward(POOL).claimable(receiver, _rewardTokens);
            for (uint256 i = 0; i < claimableAfter.length; i++) {
                if (claimableAfter[i] != claimableBefore[i]) {
                    retroactiveViolations++;
                }
            }
        }
        _afterAction(address(0));
    }

    /// @notice Withdraw inside a requested window (no fee): request, warp to the window start,
    /// withdraw. Amount is capped at min(balance, supply - MIN_TOTAL_ASSET_SUPPLY) so the
    /// supply-floor trim branch and WithdrawZeroAmount are unreachable.
    function withdrawWindowed(uint256 actorSeed, uint256 amount) external {
        address actor = _actors[actorSeed % _actors.length];
        uint256 cap = _withdrawCap(actor);
        if (cap == 0) {
            return;
        }
        amount = bound(amount, 1, cap);

        vm.startPrank(actor);
        IStabilityPool(POOL).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool(POOL).getWithdrawalRequest(actor);
        vm.warp(start);
        vm.startPrank(actor);
        IStabilityPool(POOL).withdraw(amount, actor, 0);
        vm.stopPrank();
        _afterAction(address(0));
    }

    /// @notice Withdraw with no request: the early-withdrawal fee applies and is transferred to
    /// the fee address in asset tokens, reducing user balance and total supply by the same total.
    function withdrawImmediate(uint256 actorSeed, uint256 amount) external {
        address actor = _actors[actorSeed % _actors.length];
        uint256 cap = _withdrawCap(actor);
        if (cap == 0) {
            return;
        }
        amount = bound(amount, 1, cap);

        vm.startPrank(actor);
        IStabilityPool(POOL).withdraw(amount, actor, 0);
        vm.stopPrank();
        _afterAction(address(0));
    }

    /// @notice ERC20-transfer pool shares between two distinct actors; both are checkpointed by
    /// the pool, accrued rewards stay with the sender.
    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actors[fromSeed % _actors.length];
        uint256 toIndex = toSeed % _actors.length;
        if (_actors[toIndex] == from) {
            toIndex = (toIndex + 1) % _actors.length;
        }
        address to = _actors[toIndex];
        uint256 balance = IERC20(POOL).balanceOf(from);
        if (balance == 0) {
            return;
        }
        amount = bound(amount, 1, balance);

        vm.startPrank(from);
        IERC20(POOL).transfer(to, amount);
        vm.stopPrank();
        everHeldShares[to] = true;
        _afterAction(address(0));
    }

    /// @notice Claim each reward token for an actor — the only action allowed to reduce that
    /// actor's claimable. Claims are capped at the pool's token balance: checkpointed pending can
    /// exceed the balance by the bounded over-credit (see invariant_sp_solvent), in which case a
    /// plain claim() genuinely reverts ERC20InsufficientBalance — real behaviour the solvency
    /// invariant documents, but this handler must never revert.
    function claimRewards(uint256 actorSeed) external {
        address actor = _actors[actorSeed % _actors.length];
        vm.startPrank(actor);
        for (uint256 t = 0; t < _rewardTokens.length; t++) {
            address token = _rewardTokens[t];
            IClaimReward(POOL).claim(token, IERC20(token).balanceOf(POOL));
        }
        vm.stopPrank();
        _afterAction(actor);
    }

    /// @notice Liquidate: sweep `loss` asset tokens out, return `loss/price` liquidation tokens in,
    /// notify. Loss is capped at supply - MIN_TOTAL_ASSET_SUPPLY so _notifyLoss never clamps
    /// (keeping the sweep and the supply reduction 1:1 — the solvency invariant relies on this).
    /// Skipped once the supply product's exponent reaches 6: two below _MAX_EXPONENT_DIFFERENCE
    /// (8), past which claimable views truncate old snapshots by design.
    function liquidate(uint256 lossSeed) external {
        uint256 supply = IERC20(POOL).totalSupply();
        if (supply <= MIN_TOTAL_ASSET_SUPPLY) {
            return;
        }
        if (MockStabilityPool(POOL).__totalSupply().product.exponent() >= 6) {
            return;
        }
        uint256 loss = bound(lossSeed, 1, supply - MIN_TOTAL_ASSET_SUPPLY);
        uint256 returned = (loss * 1 ether) / PRICE;

        vm.startPrank(REBALANCER);
        ITokenHolder(POOL).sweep(ASSET_TOKEN, loss, REBALANCER);
        if (returned > 0) {
            deal(LIQUIDATION_TOKEN, REBALANCER, returned);
            IERC20(LIQUIDATION_TOKEN).transfer(POOL, returned);
        }
        IStabilityPool(POOL).notifyLiquidation(loss, returned);
        vm.stopPrank();

        injected[LIQUIDATION_TOKEN] += returned;
        _afterAction(address(0));
    }

    /// @notice Stream a reward deposit into the pool. Skipped while nobody is staked: with zero
    /// shares a stream would tick with no accruer (zero-staker reward behaviour is out of this
    /// harness's scope — the StabilityPoolManager only harvests with stakers present).
    function depositRewardToken(uint256 tokenSeed, uint256 amount) external {
        if (IERC20(POOL).totalSupply() == 0) {
            return;
        }
        address token = _rewardTokens[tokenSeed % _rewardTokens.length];
        amount = bound(amount, 1, 1_000_000 ether);

        deal(token, REWARD_DEPOSITOR, amount);
        vm.startPrank(REWARD_DEPOSITOR);
        IERC20(token).approve(POOL, amount);
        IMultipleRewardDistributor(POOL).depositReward(token, amount);
        vm.stopPrank();

        injected[token] += amount;
        _afterAction(address(0));
    }

    /// @notice Let streaming time pass (1 hour to 2 weeks — spans within-period and past-finish).
    function warpTime(uint256 delta) external {
        delta = bound(delta, 1 hours, 2 weeks);
        vm.warp(block.timestamp + delta);
        _afterAction(address(0));
    }

    /// @notice Checkpoint an actor — flushes pending stream into the integral and rolls the
    /// actor's stored balance through the current product.
    function checkpointActor(uint256 actorSeed) external {
        address actor = _actors[actorSeed % _actors.length];
        IMultipleRewardAccumulator_v3(POOL).checkpoint(actor);
        _afterAction(address(0));
    }

    // ─── probes ───

    /// @dev The largest withdrawal the pool accepts without reverting — the actor's whole balance. The POOL caps the
    /// outflow at the headroom above the floor itself (StabilityPool_v3._capToFloor), so the handler must NOT
    /// pre-enforce the floor: requesting up to the full balance is what drives the pool's own clamp, the path a
    /// floor-respecting cap could never reach. The only revert to dodge is WithdrawZeroAmount, when there is no
    /// headroom at all to clamp into; the fee cannot zero a non-zero clamped outflow (it is a fraction of it).
    function _withdrawCap(address actor) internal view returns (uint256 cap) {
        if (IERC20(POOL).totalSupply() <= MIN_TOTAL_ASSET_SUPPLY) {
            return 0; // no headroom: the pool would clamp the outflow to 0 and revert
        }
        cap = IERC20(POOL).balanceOf(actor);
    }

    /// @dev Runs after every state-changing action: update the call/supply ghosts and check that
    /// no actor's claimable dropped by more than 2 wei — the composition of the two floors taken
    /// when another account's checkpoint flushes the temporal pending into the integral (the view
    /// floors amount*shares/totalShares once; the flush floors the integral delta and then the
    /// user share) — unless the actor itself claimed in this action.
    function _afterAction(address claimer) internal {
        calls++;
        uint256 supply = IERC20(POOL).totalSupply();
        if (supply > maxSupplyEver) {
            maxSupplyEver = supply;
        }
        for (uint256 a = 0; a < _actors.length; a++) {
            address actor = _actors[a];
            uint256[] memory current = IClaimReward(POOL).claimable(actor, _rewardTokens);
            for (uint256 t = 0; t < _rewardTokens.length; t++) {
                address token = _rewardTokens[t];
                if (actor != claimer && current[t] + 2 < _lastClaimable[actor][token]) {
                    monotoneViolations++;
                }
                _lastClaimable[actor][token] = current[t];
            }
        }
    }
}

/// @notice Stateful invariants for StabilityPool_v3: properties that must hold across arbitrary
/// SEQUENCES of deposit / withdraw / transfer / claim / liquidation / reward-stream / warp actions
/// (the stateless single-operation space is covered by the Minter fee-range fuzzers). Tolerances
/// are derived from the pool's arithmetic, not guessed: 1 wei per truncating division, plus the
/// bounded loss over-application error.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail_on_revert = true
contract StabilityPoolInvariantTest is TestStabilityPoolSetUp, MockStabilityPoolConservation {
    StabilityPoolInvariantHandler internal handler;

    function setUp() public override {
        super.setUp();

        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        address[] memory actors = new address[](4);
        actors[0] = user1;
        actors[1] = user2;
        actors[2] = makeAddr("user3");
        actors[3] = makeAddr("user4");

        address[] memory rewardTokens = new address[](2);
        rewardTokens[0] = wrappedCollateralToken;
        rewardTokens[1] = steam;

        handler = new StabilityPoolInvariantHandler(
            stabilityPoolCollateral,
            rebalancer,
            rewardDepositor,
            price,
            actors,
            rewardTokens
        );

        // The fixture forks mainnet; random fuzzed senders would each trigger an RPC account fetch
        // (and rate-limit 429s). The handler start-pranks the real actor for every call, so the
        // outer sender is irrelevant — pin it to one address.
        targetSender(makeAddr("invariantSender"));
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = StabilityPoolInvariantHandler.deposit.selector;
        selectors[1] = StabilityPoolInvariantHandler.withdrawWindowed.selector;
        selectors[2] = StabilityPoolInvariantHandler.withdrawImmediate.selector;
        selectors[3] = StabilityPoolInvariantHandler.transferShares.selector;
        selectors[4] = StabilityPoolInvariantHandler.claimRewards.selector;
        selectors[5] = StabilityPoolInvariantHandler.liquidate.selector;
        selectors[6] = StabilityPoolInvariantHandler.depositRewardToken.selector;
        selectors[7] = StabilityPoolInvariantHandler.warpTime.selector;
        selectors[8] = StabilityPoolInvariantHandler.checkpointActor.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice Conservation of pool shares: the actors' rebased balances must sum to the recorded
    /// total supply. Symmetric tolerance, derived: (a) the outstanding `lastAssetLossError`
    /// over-application — user products are reduced as if the loss were up to 1 wei-per-unit
    /// larger, i.e. at most maxSupplyEver/1e18 asset wei pending, released back when a later loss
    /// is absorbed by the error queue (so the sum can sit either side of the supply); (b) at most
    /// 1 wei of compounded-balance flooring per actor per checkpoint, at most 2 checkpoints per
    /// handler call.
    function invariant_pool_conserved() public view {
        _assertPoolConserved(stabilityPoolCollateral, _actorsArray(), handler.maxSupplyEver(), handler.calls());
    }

    /// @notice Conservation of every reward token, one-directional: on-chain claimed + claimable (which already
    /// includes each actor's share of the temporal pending) + the distributor's queued remainder (LinearReward
    /// keeps its rate-truncation queued, never leaked) + the undistributed stream tail must never EXCEED what was
    /// injected -- an overshoot is a real over-credit, never tolerated as dust -- and may fall short only by the
    /// pool-favoured under-credit. The reward divisor (_getTotalPoolShare) rounds the pool's share aggregate UP,
    /// so it is always >= Sum(balanceOf) and each distribution of A credits at most A; the parts can never
    /// over-run injected. The permitted shortfall is the pool-favoured under-credit the loss accounting strands:
    /// the divisor tracks Sum(balanceOf), which the ceiling-division loss leaves below the exact supply by up to
    /// maxSupplyEver/1e18, so each distribution of A mis-credits at most A*(maxSupplyEver/1e18)/S (S never drops
    /// below MIN_TOTAL_ASSET_SUPPLY) -- bounded by injected*(maxSupplyEver/1e18 + 1)/MIN over the run -- plus a few
    /// wei of stored-balance and temporal-pending flooring per checkpoint and per actor.
    function invariant_reward_conserved() public view {
        _assertRewardConserved(stabilityPoolCollateral, _actorsArray(), _ghosts());
    }

    /// @notice An actor's claimable never decreases (beyond the 2-wei two-floor composition)
    /// except through their own claim. The probe runs inside the handler after every action;
    /// this asserts it never fired.
    function invariant_claimable_monotone() public view {
        assertEq(handler.monotoneViolations(), 0, "claimable dropped without the actor claiming");
    }

    /// @notice The reward divisor (`_getTotalPoolShare().totalShare`) must never sit below Sum(balanceOf). Every
    /// reward accumulate divides by it while crediting each user by `balanceOf`, so a divisor below the summed
    /// balances credits `reward * Sum(balanceOf) / divisor > reward` — an over-credit. The divisor tracks
    /// Sum(balanceOf) through a product-decaying aggregate; this pins that it is always pool-favoured (>=).
    function invariant_rewardDivisor_ge_sumBalance() public view {
        _assertDivisorGeSumBalance(stabilityPoolCollateral, _actorsArray());
    }

    /// @notice The reward divisor is either exactly 0 — an empty pool, where `_accumulateReward`'s `totalShare == 0`
    /// guard queues the reward instead of dividing — or at/above the pool floor `MIN_TOTAL_ASSET_SUPPLY` (less the
    /// slack by which Sum(balanceOf) trails supply). It never sits strictly between. This is the reward-integral cap's
    /// soundness precondition: `_depositRewardCap` sizes the cap assuming the worst-case divisor is `_minTotalShare()`,
    /// because a deposited reward streams and is accumulated LATER against a divisor that may by then have fallen to
    /// the floor — while `_accumulateReward` divides by the LIVE divisor. A divisor below the floor still passes the
    /// zero-guard and inflates `toAdd` past the bound the cap was sized for. The same `S >= MIN` denominator underpins
    /// the tolerances in `invariant_reward_conserved` and `invariant_sp_solvent`.
    function invariant_rewardDivisor_ge_minTotalShare() public view {
        _assertDivisorFloor(stabilityPoolCollateral, _actorsArray(), handler.maxSupplyEver(), handler.calls());
    }

    /// @notice Capital deposited by a zero-balance receiver captures none of the rewards streamed
    /// before the deposit: claimable is exactly unchanged by the deposit itself.
    function invariant_no_retroactive_reward() public view {
        assertEq(handler.retroactiveViolations(), 0, "deposit changed a fresh receiver's claimable");
    }

    /// @notice Solvency: the pool always holds enough asset tokens to honour every withdrawal
    /// (deposits, withdrawals+fees and sweep+loss all move balance and supply 1:1 — the handler
    /// keeps losses below the clamp), and enough of each reward token to honour every obligation
    /// within a derived allowance: when a loss is absorbed by the lastAssetLossError queue the
    /// supply drops with NO product change, so product-decayed user weights sum to supply + ε
    /// (ε ≤ maxSupplyEver/1e18 + 2·calls — the loss error bounded by the supply AT that loss,
    /// plus 1 wei of stored-balance flooring per user checkpoint; see invariant_reward_conserved)
    /// and a distribution of A over-credits claimable by A·ε/S with S ≥ MIN_TOTAL_ASSET_SUPPLY —
    /// i.e. obligations may exceed the balance by at most injected·ε_max/MIN (the
    /// mirror image of the stranded slice in invariant_reward_conserved; at this dust scale the
    /// LAST claimer's claim can revert for want of a few wei).
    function invariant_sp_solvent() public view {
        _assertSpSolvent(stabilityPoolCollateral, _actorsArray(), _ghosts());
    }

    /// @dev The handler's reward-token list as a memory array, for the vector claim views.
    function _rewardTokensArray() internal view returns (address[] memory tokens) {
        uint256 tokenTotal = handler.rewardTokenCount();
        tokens = new address[](tokenTotal);
        for (uint256 t = 0; t < tokenTotal; t++) {
            tokens[t] = handler.rewardTokenAt(t);
        }
    }

    function _actorsArray() internal view returns (address[] memory actors) {
        uint256 count = handler.actorCount();
        actors = new address[](count);
        for (uint256 a = 0; a < count; a++) {
            actors[a] = handler.actorAt(a);
        }
    }

    function _ghosts() internal view returns (SpConservationGhosts memory g) {
        g.tokens = _rewardTokensArray();
        g.injected = new uint256[](g.tokens.length);
        for (uint256 t = 0; t < g.tokens.length; t++) {
            g.injected[t] = handler.injected(g.tokens[t]);
        }
        g.maxSupplyEver = handler.maxSupplyEver();
        g.calls = handler.calls();
        g.minSupply = handler.MIN_TOTAL_ASSET_SUPPLY();
    }
}
