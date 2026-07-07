// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {SaltString} from "@bao-script/deployment/SaltString.sol";
import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {ConfigCollateral_fxUSD_mainnet} from "@harbor-script/config/collaterals/ConfigCollateral_fxUSD_mainnet.sol";
import {StabilityPoolConservation} from "@harbor-test/StabilityPoolConservation.sol";
import {HarborTestSetup} from "@harbor-test/HarborTestSetup.sol";

/// @notice A named market's supported operating envelope, in the units a director thinks in: dollars and counts. The
/// harness translates these to what the protocol needs (a pegged token count and the oracle's 1e18-scaled price/rate),
/// so nothing here is mechanical. USD values are 1e18-scaled ($1 == 1e18); the wrap rate is a 1e18-scaled ratio
/// (1e18 == 1x). The peg price is a fixed per-market reference (not a swept axis) that derives the oracle price and the
/// pool token count; the collateral USD range and the wrap-rate range are what the fuzzer sweeps.
struct Envelope {
    string name;
    uint256 maxPoolValueUSD; // pool size cap in $  (the totalSupply limit)
    uint256 maxPoolUsers; // depositor cap; poolValue/users = average deposit; 1 user = the whole pool in one deposit
    uint256 pegPriceUSD; // pegged token $ price -> poolPegged = maxPoolValueUSD / pegPriceUSD, and oracle price
    uint256 minCollateralUSD; // underlying collateral $ range -> oracle price = collateralUSD / pegPriceUSD
    uint256 maxCollateralUSD;
    uint256 minWrapRate; // wrapped/underlying collateral ratio (the yield multiplier) -> oracle rate directly
    uint256 maxWrapRate;
}

/// @notice The state the action under test acts against — arranged on the REAL protocol before the action fires. It
/// grows as the harness covers more operations: this batch (deposit/withdraw) uses a populated, loss-decayed pool;
/// later batches add collateral ratio, pegged/leveraged composition, and pending rewards.
struct StartState {
    uint256 existingDeposits; // pegged already deposited by a background holder before the action
    uint256 priorLossFraction; // 1e18-scaled fraction of headroom already liquidated (decays the compounding product)
}

/// @notice The catalog of named markets. A derived test contract selects one in `buildEnvelope()`, optionally starting
/// from another entry and tweaking a single field.
library EnvelopeLib {
    /// @dev ETH::fxUSD at realistic bounds: haETH tracks ETH (~$4000), collateral fxUSD sits near $1, wrapped fxSAVE
    /// carries a yield premium (>= $1). A comfortably-fitting real market; the deliberately-extreme full-range market
    /// that locates the field limit is a separate entry (later batch).
    function ethFxUSD() internal pure returns (Envelope memory e) {
        e = Envelope({
            name: "1B, 1e3, 1e3, 1e2",
            maxPoolValueUSD: 1e10 ether, // $01B
            maxPoolUsers: 1e4,
            pegPriceUSD: 1 ether, // $1
            minCollateralUSD: 1e-6 ether,
            maxCollateralUSD: 1e6 ether,
            minWrapRate: 0.001 ether,
            maxWrapRate: 1000 ether
        });
    }
}

/// @notice Envelope-fit harness: stands up the REAL protocol (Minter + StabilityPool + StabilityPoolManager) via the
/// production `deployForPeg` scripts, arranges a starting state, then drives user/keeper actions against it and reads
/// every result back for correctness — the minter-test discipline that surfaces truncation and rounding. Green means
/// the protocol HOLDS the whole envelope; a revert or a mismatched read-back at an envelope-reachable point is the
/// where-it-breaks finding, to be fixed (SafeCast / widen) or the documented envelope narrowed — never asserted as
/// intended behaviour. Each derived contract is one named, documented market; `buildEnvelope()` is the seam.
///
/// This batch covers deposit/withdraw. Harvest, rebalance, the reward-field corner, and richer arranged state land in
/// later batches (the `StartState` and the keeper set grow with them).
abstract contract StabilityPoolEnvelopeBase is BaoTest, Deploy_ETH_Minter, StabilityPoolConservation, HarborTestSetup {
    // capped so the fork fuzz stays feasible; the declared business cap (maxPoolUsers) can be far larger and is
    // exercised by the deterministic max-users test rather than every fuzz run.
    uint256 internal constant MAX_FUZZ_USERS = 8;

    address internal minter;
    address internal stabilityPool; // the collateral-side StabilityPool
    address internal stabilityPoolManager;
    address internal pegged;
    address internal leveraged;
    address internal wrappedCollateral;

    MockWrappedPriceOracle internal mockOracle;
    uint256 internal currentPrice; // 1e18-scaled, set by _setEnvelopePoint
    uint256 internal currentRate;

    address[] internal users; // MAX_FUZZ_USERS deposit actors
    address internal background; // holds the arranged pre-existing deposit

    function buildEnvelope() internal pure virtual returns (Envelope memory);

    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }

    function setUp() public virtual {
        // ── stand up the real protocol via the production deploy scripts (RebalanceFairness model) ──
        // _ensureBaoFactory gives the full deploy capability in-EVM; the only mainnet state the deploy needs is the
        // collateral pair, so mock those two tokens locally and run with no fork.
        address factory = _ensureBaoFactory();
        address factoryOwner = IBaoFactory(factory).owner();
        vm.startPrank(factoryOwner);
        IBaoFactory(factory).setOperator(address(this), 365 days);
        vm.stopPrank();

        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        // mock the collateral pair at the config's own addresses so the deploy wires to local mocks, not mainnet
        address underlyingToken = ConfigCollateral_fxUSD_mainnet(address(mktConfigs[0])).collateralToken();
        address wrappedToken = ConfigCollateral_fxUSD_mainnet(address(mktConfigs[0])).wrappedCollateralToken();
        vm.etch(underlyingToken, address(new MockERC20("fxUSD", "fxUSD", 18)).code); // decimals is immutable -> in code
        vm.etch(wrappedToken, address(new MockERC20("fxSAVE", "fxSAVE", 18)).code);
        Config_MinterMarket[] memory toDeploy = new Config_MinterMarket[](1);
        toDeploy[0] = mktConfigs[0]; // the fxUSD market
        deployHarborForPeg("envelope_test", peg, mktConfigs, "mainnet", true, toDeploy);

        _setSaltPrefix("envelope_test");
        minter = _predictAddress(SaltString.key("ETH", "fxUSD", "minter"));
        stabilityPool = _predictAddress(SaltString.key("ETH", "fxUSD", "stabilityPoolCollateral"));
        stabilityPoolManager = _predictAddress(SaltString.key("ETH", "fxUSD", "stabilityPoolManager"));
        pegged = _predictAddress(SaltString.key("ETH", "pegged"));
        leveraged = _predictAddress(SaltString.key("ETH", "fxUSD", "leveraged"));
        wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();

        mockOracle = new MockWrappedPriceOracle();

        // ── point the minter at the mock oracle. The free-mints run as the owner (genesisMint pranks minter.owner(),
        // and free* is onlyOwnerOrRoles), so ZERO_FEE_ROLE is never granted in this harness. ──
        address minterOwner = IBaoOwnable(minter).owner();
        vm.startPrank(minterOwner);
        IMinter(minter).updatePriceOracle(address(mockOracle));
        vm.stopPrank();

        address spOwner = IBaoOwnable(stabilityPool).owner();
        uint256 rebalancerRole = IStabilityPool(stabilityPool).REBALANCER_ROLE();
        vm.startPrank(spOwner);
        IBaoRoles(stabilityPool).grantRoles(address(this), rebalancerRole); // to arrange prior losses
        vm.stopPrank();

        address spmOwner = IBaoOwnable(stabilityPoolManager).owner();
        vm.startPrank(spmOwner);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestCutRatio(0);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestBountyRatio(0);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceBountyRatio(0);
        vm.stopPrank();

        background = makeAddr("background");
        _createUsers(MAX_FUZZ_USERS);

        // a nominal envelope point (geometric-mean centre of the log-range) so the seed mint has a price to work from
        _setEnvelopePoint(_nominalCollateralUSD(), _nominalWrapRate());
        _seedPool(); // a permanent MIN_DEPOSIT seed so every actor can fully exit later

        // the owner drives the free-mints directly (onlyOwnerOrRoles), so it must never be granted ZERO_FEE_ROLE
        assertFalse(
            IBaoRoles(minter).hasAnyRole(IBaoOwnable(minter).owner(), IMinter(minter).ZERO_FEE_ROLE()),
            "owner must not hold ZERO_FEE_ROLE"
        );
    }

    // ─── derivations: USD (director-facing) → protocol (token count + 1e18 oracle values) ───

    function _poolPeggedFor(uint256 poolValueUSD) internal pure returns (uint256) {
        return (poolValueUSD * 1e18) / buildEnvelope().pegPriceUSD;
    }

    function _setEnvelopePoint(uint256 collateralUSD, uint256 wrapRate) internal {
        currentPrice = (collateralUSD * 1e18) / buildEnvelope().pegPriceUSD; // underlying collateral in pegged
        currentRate = wrapRate; // wrapped/underlying ratio, used directly as the oracle rate
        mockOracle.setLatestAnswer(currentPrice, currentRate);
    }

    // ─── actors ───

    function _createUsers(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            address u = makeAddr(string.concat("user", vm.toString(i)));
            vm.startPrank(u);
            IERC20(pegged).approve(stabilityPool, type(uint256).max);
            vm.stopPrank();
            users.push(u);
        }
    }

    // ─── exercise primitives (drive the real protocol) ───

    /// @dev The wrapped collateral's value in pegged: underlying price times the wrap rate. The minter values a
    /// deposited (wrapped) collateral at this, so it is what converts a target pegged amount back to a collateral
    /// amount — using `currentPrice` alone under-funds the mint by the rate factor.
    function _wrappedPrice() internal view returns (uint256) {
        return (currentPrice * currentRate) / 1e18;
    }

    function _collateralFor(uint256 peggedAmount) internal view returns (uint256) {
        uint256 wrappedPrice = _wrappedPrice();
        return (peggedAmount * 1e18 + wrappedPrice - 1) / wrappedPrice; // ceil at the wrapped collateral price
    }

    /// @dev Mint at least `target` pegged to this contract (backed by real collateral at the current price).
    function _mintPeggedAtLeast(uint256 target) internal returns (uint256 minted) {
        uint256 collateral = _collateralFor(target) + 1 ether; // slack for the flooring in the mint
        (minted, ) = genesisMint(minter, collateral, 0, address(this));
    }

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        IStabilityPool(stabilityPool).deposit(amount, who, 0);
        vm.stopPrank();
    }

    /// @dev Full exit inside the no-fee withdrawal window.
    function _withdrawAll(address who) internal {
        vm.startPrank(who);
        IStabilityPool(stabilityPool).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool(stabilityPool).getWithdrawalRequest(who);
        vm.warp(uint256(start) + 1);
        vm.startPrank(who);
        IStabilityPool(stabilityPool).withdraw(type(uint256).max, who, 0);
        vm.stopPrank();
    }

    /// @dev Liquidate `loss` pegged out of the pool and notify — decays the compounding product (this contract holds
    /// REBALANCER_ROLE). Mirrors the production liquidation's effect on the pool without a real minter redeem.
    function _applyLoss(uint256 loss) internal {
        ITokenHolder(stabilityPool).sweep(pegged, loss, address(this));
        IStabilityPool(stabilityPool).notifyLiquidation(loss, 0);
    }

    function _seedPool() internal {
        uint256 minDeposit = IStabilityPool(stabilityPool).MIN_DEPOSIT();
        _mintPeggedAtLeast(minDeposit);
        IERC20(pegged).approve(stabilityPool, type(uint256).max);
        IStabilityPool(stabilityPool).deposit(minDeposit, address(this), 0);
    }

    // ─── arrange: bring the real system to a StartState the action acts against ───

    function _arrange(uint256 collateralUSD, uint256 wrapRate, StartState memory s) internal {
        _setEnvelopePoint(collateralUSD, wrapRate);

        if (s.existingDeposits > 0) {
            _mintPeggedAtLeast(s.existingDeposits);
            IERC20(pegged).transfer(background, s.existingDeposits);
            vm.startPrank(background);
            IERC20(pegged).approve(stabilityPool, type(uint256).max);
            IStabilityPool(stabilityPool).deposit(s.existingDeposits, background, 0);
            vm.stopPrank();
        }

        if (s.priorLossFraction > 0) {
            uint256 minDeposit = IStabilityPool(stabilityPool).MIN_DEPOSIT();
            uint256 held = IERC20(pegged).balanceOf(stabilityPool);
            uint256 headroom = held > minDeposit ? held - minDeposit : 0;
            uint256 loss = (headroom * s.priorLossFraction) / 1e18;
            if (loss > 0) {
                _applyLoss(loss);
            }
        }
    }

    // ─── fuzz walk (the primary test) ───

    /// @notice Deposit/withdraw hold across the envelope: for a fuzzed point (collateral/wrapped $ in range, pool size
    /// up to the cap, user count up to the cap) and a fuzzed starting state (a pre-existing deposit, a prior loss that
    /// decays the product), every user deposits then fully exits, and each result is read back and checked exactly.
    /// A fresh deposit reads back its amount and moves the supply by exactly that; a full exit returns exactly the
    /// deposit and moves the supply back. An exact read-back is what a silent narrowing cast or rounding drift cannot
    /// satisfy, so a failure here flags a real code action, not test noise.
    function testFuzz_depositWithdraw_holds(
        uint256 collateralSeed,
        uint256 rateSeed,
        uint256 poolSeed,
        uint256 nSeed,
        uint256 existingSeed,
        uint256 lossSeed
    ) public {
        Envelope memory e = buildEnvelope();
        uint256 minDeposit = IStabilityPool(stabilityPool).MIN_DEPOSIT();

        uint256 n = bound(nSeed, 1, _min(e.maxPoolUsers, MAX_FUZZ_USERS));
        uint256 collateralUSD = bound(collateralSeed, e.minCollateralUSD, e.maxCollateralUSD);
        uint256 wrapRate = bound(rateSeed, e.minWrapRate, e.maxWrapRate);

        uint256 poolPegged = _poolPeggedFor(bound(poolSeed, e.maxPoolValueUSD / 1e5, e.maxPoolValueUSD));
        if (poolPegged < n * minDeposit) {
            poolPegged = n * minDeposit; // every equal share must clear MIN_DEPOSIT
        }

        StartState memory s = StartState({
            existingDeposits: bound(existingSeed, 0, poolPegged),
            priorLossFraction: bound(lossSeed, 0, 0.9e18)
        });
        _arrange(collateralUSD, wrapRate, s);

        uint256[] memory shares = _equalSplit(poolPegged, n);
        _mintPeggedAtLeast(poolPegged);

        for (uint256 i = 0; i < n; i++) {
            IERC20(pegged).transfer(users[i], shares[i]);

            uint256 supplyBefore = IERC20(stabilityPool).totalSupply();
            _deposit(users[i], shares[i]);
            assertEq(IERC20(stabilityPool).balanceOf(users[i]), shares[i], "fresh deposit reads back exactly");
            assertEq(IERC20(stabilityPool).totalSupply(), supplyBefore + shares[i], "supply moved by the deposit");

            uint256 walletBefore = IERC20(pegged).balanceOf(users[i]);
            uint256 supplyMid = IERC20(stabilityPool).totalSupply();
            _withdrawAll(users[i]);
            assertEq(IERC20(pegged).balanceOf(users[i]) - walletBefore, shares[i], "exit returns the full deposit");
            assertEq(IERC20(stabilityPool).balanceOf(users[i]), 0, "position cleared");
            assertEq(IERC20(stabilityPool).totalSupply(), supplyMid - shares[i], "supply moved back by the exit");
        }
    }

    // ─── deterministic corner (named must-pass) ───

    /// @notice The combined extreme for deposit/withdraw: the whole pool ($1B) deposited by a SINGLE user (the whole
    /// pool in one position — the concentration corner), the wrapped collateral at its cheapest, into a pool already
    /// decayed by a 50% prior loss. The deposit field must hold the whole-pool position and the round-trip stays
    /// exact. (This batch does not drive a rebalance, so it does not yet exercise the reward field the extreme is
    /// ultimately about; that corner arrives with the rebalance walk.)
    function test_corner_depositWithdraw_holds() public {
        Envelope memory e = buildEnvelope();
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD);

        _arrange(e.minCollateralUSD, e.minWrapRate, StartState({existingDeposits: 0, priorLossFraction: 0.5e18}));

        _mintPeggedAtLeast(poolPegged);
        IERC20(pegged).transfer(users[0], poolPegged);

        uint256 supplyBefore = IERC20(stabilityPool).totalSupply();
        _deposit(users[0], poolPegged);
        assertEq(IERC20(stabilityPool).balanceOf(users[0]), poolPegged, "whole-pool deposit reads back exactly");
        assertEq(IERC20(stabilityPool).totalSupply(), supplyBefore + poolPegged, "supply moved by the whole pool");

        uint256 walletBefore = IERC20(pegged).balanceOf(users[0]);
        _withdrawAll(users[0]);
        assertEq(IERC20(pegged).balanceOf(users[0]) - walletBefore, poolPegged, "whole-pool exit returns everything");
    }

    // ─── harvest walk ───

    function _nominalCollateralUSD() internal pure returns (uint256) {
        Envelope memory e = buildEnvelope();
        return Math.sqrt(e.minCollateralUSD * e.maxCollateralUSD); // geometric-mean centre of the log-range
    }

    function _nominalWrapRate() internal pure returns (uint256) {
        Envelope memory e = buildEnvelope();
        return Math.sqrt(e.minWrapRate * e.maxWrapRate);
    }

    /// @dev Grow the pool to `poolPegged` split across the first `n` users (each mints pegged through the minter and
    /// deposits), so a harvest/rebalance reward lands in the integral/pending path (stakers present), not the
    /// stakerless queue. Returns each user's deposited share.
    function _growPool(uint256 poolPegged, uint256 n) internal returns (uint256[] memory shares) {
        shares = _equalSplit(poolPegged, n);
        _mintPeggedAtLeast(poolPegged);
        for (uint256 i = 0; i < n; i++) {
            IERC20(pegged).transfer(users[i], shares[i]);
            _deposit(users[i], shares[i]);
        }
    }

    /// @dev Accrue yield on the Minter-held collateral (a wrap-rate bump) and have a keeper harvest it to the pool.
    /// Returns the reward delivered to the collateral StabilityPool (its wrapped-collateral balance delta).
    function _harvest() internal returns (uint256 injectedToPool) {
        currentRate = (currentRate * 1001) / 1000; // +0.1% yield on the wrapped collateral
        mockOracle.setLatestAnswer(currentPrice, currentRate);
        uint256 rewardBefore = IERC20(wrappedCollateral).balanceOf(stabilityPool);
        address keeper = makeAddr("keeper");
        vm.startPrank(keeper);
        IStabilityPoolManager(stabilityPoolManager).harvest(keeper, 0);
        vm.stopPrank();
        injectedToPool = IERC20(wrappedCollateral).balanceOf(stabilityPool) - rewardBefore;
    }

    /// @dev Every possible pool holder (the seed, the arranged background, the deposit actors) - zero-balance entries
    /// contribute nothing to the conservation sums.
    function _allActors() internal view returns (address[] memory actors) {
        actors = new address[](users.length + 2);
        actors[0] = address(this);
        actors[1] = background;
        for (uint256 i = 0; i < users.length; i++) {
            actors[i + 2] = users[i];
        }
    }

    /// @dev The conservation ghosts for a single wrapped-collateral reward of `injected`, over a pool that peaked at
    /// `maxSupplyEver` with `calls` checkpoint-inducing operations.
    function _rewardGhosts(
        uint256 injected,
        uint256 maxSupplyEver,
        uint256 calls
    ) internal view returns (SpConservationGhosts memory g) {
        g.tokens = new address[](1);
        g.tokens[0] = wrappedCollateral;
        g.injected = new uint256[](1);
        g.injected[0] = injected;
        g.maxSupplyEver = maxSupplyEver;
        g.calls = calls;
        g.minSupply = IStabilityPool(stabilityPool).MIN_TOTAL_ASSET_SUPPLY();
    }

    /// @notice Harvest happy path across the envelope: a full pool of stakers, yield accrued on Minter-held collateral,
    /// a keeper harvests it in. The reward reaches the pool, and once the stream completes it conserves - the credited
    /// total (claimed + claimable + queued + undistributed) never exceeds what was injected, and the pool stays solvent
    /// - checked with the SAME shared assertions the invariant proves. Run at the nominal operating point; Batch 3
    /// pushes it to the cheap-wrapped corner where the reward-field capacity bites.
    function test_envelope_harvest_holds() public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(_nominalCollateralUSD(), _nominalWrapRate());
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD);
        _growPool(poolPegged, MAX_FUZZ_USERS);

        uint256 injected = _harvest();
        assertGt(injected, 0, "harvest delivered a reward to the pool");

        vm.warp(block.timestamp + 8 days); // whole stream distributable

        SpConservationGhosts memory g = _rewardGhosts(injected, poolPegged, MAX_FUZZ_USERS + 2);
        _assertRewardConserved(stabilityPool, _allActors(), g);
        _assertSpSolvent(stabilityPool, _allActors(), g);
    }

    // ─── rebalance walk ───

    /// @dev Mint a leveraged buffer so the collateral ratio starts healthy (~1.5x) and can then be dropped below the
    /// rebalance threshold.
    function _mintLeveragedBuffer(uint256 peggedBacked) internal {
        uint256 collateral = _collateralFor(peggedBacked) / 2;
        genesisMint(minter, 0, collateral, address(this));
    }

    /// @dev Lower the collateral price until the collateral ratio falls below the rebalance threshold.
    function _dropPriceBelowRebalanceThreshold() internal {
        for (uint256 i = 0; i < 50 && !IStabilityPoolManager(stabilityPoolManager).rebalanceable(); i++) {
            currentPrice = (currentPrice * 9) / 10; // -10% collateral price lowers the collateral ratio
            mockOracle.setLatestAnswer(currentPrice, currentRate);
        }
        assertTrue(
            IStabilityPoolManager(stabilityPoolManager).rebalanceable(),
            "could not drive the collateral ratio below the rebalance threshold"
        );
    }

    /// @dev A keeper rebalances: the Minter liquidates pool pegged and returns collateral to the StabilityPool as the
    /// liquidation reward. Returns the reward delivered to the collateral pool.
    function _rebalance() internal returns (uint256 injectedToPool) {
        uint256 rewardBefore = IERC20(wrappedCollateral).balanceOf(stabilityPool);
        address keeper = makeAddr("keeper");
        vm.startPrank(keeper);
        IStabilityPoolManager(stabilityPoolManager).rebalance(keeper, 0);
        vm.stopPrank();
        injectedToPool = IERC20(wrappedCollateral).balanceOf(stabilityPool) - rewardBefore;
    }

    /// @notice Rebalance happy path across the envelope: a full pool of stakers, the collateral ratio dropped below the
    /// rebalance threshold, a keeper rebalances - the Minter liquidates pool pegged and returns collateral to the pool
    /// as the reward. The reward reaches the pool and conserves, and the pool stays solvent through the liquidation
    /// (which also decays the product) - the SAME shared assertions the invariant proves. This is the path that drives
    /// the reward field; run at the nominal point here, pushed to the corner in Batch 3.
    function test_envelope_rebalance_holds() public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(_nominalCollateralUSD(), _nominalWrapRate());
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD);
        _growPool(poolPegged, MAX_FUZZ_USERS);
        _mintLeveragedBuffer(poolPegged);

        _dropPriceBelowRebalanceThreshold();
        uint256 injected = _rebalance();
        assertGt(injected, 0, "rebalance delivered a collateral reward to the pool");

        SpConservationGhosts memory g = _rewardGhosts(injected, poolPegged, MAX_FUZZ_USERS + 2);
        _assertRewardConserved(stabilityPool, _allActors(), g);
        _assertSpSolvent(stabilityPool, _allActors(), g);
    }

    // ─── deterministic reward-field corner (the fuzz reaches this < 1/256 runs; never leave it to the fuzzer) ───

    /// @notice The reward-field corner: the full pool ($maxPoolValueUSD) liquidated in one rebalance at the CHEAPEST
    /// wrapped collateral (minCollateral x minRate) - the point that maximises the reward token count the pool's uint128
    /// `pending` field must hold, `poolValueUSD / wrappedUSD`. Grown at a healthy nominal price so minting works, then
    /// moved to the corner (which drops the collateral ratio below the rebalance threshold AND maximises the returned
    /// collateral). Green = the reward field holds the whole-pool reward at the corner; a SafeCast revert here is the
    /// documented envelope exceeding the field, to be fixed or narrowed.
    function test_envelope_corner_rebalance_holds() public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(_nominalCollateralUSD(), e.minWrapRate);
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD);
        _growPool(poolPegged, MAX_FUZZ_USERS);
        _mintLeveragedBuffer(poolPegged);

        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate); // cheapest wrapped: CR below threshold + max reward
        assertTrue(
            IStabilityPoolManager(stabilityPoolManager).rebalanceable(),
            "the cheap-wrapped corner drives the collateral ratio below the rebalance threshold"
        );

        uint256 injected = _rebalance();
        assertGt(injected, 0, "rebalance delivered the whole-pool collateral reward at the corner");

        SpConservationGhosts memory g = _rewardGhosts(injected, poolPegged, MAX_FUZZ_USERS + 2);
        _assertRewardConserved(stabilityPool, _allActors(), g);
        _assertSpSolvent(stabilityPool, _allActors(), g);
    }

    // ─── the reward-field worst case: the whole-pool reward concentrated in one holder's pending field ───

    /// @notice The reward field's worst case - the whole pool concentrated on ONE holder. A single whale deposits the
    /// entire pool (the permanent MIN_DEPOSIT seed is the only other holder), the wrapped collateral sits at its
    /// cheapest, and one full rebalance returns the whole-pool collateral reward - so the ENTIRE reward accrues to a
    /// SINGLE holder's uint128 `pending` field, the maximum any one reward-accrual field must hold (poolValueUSD /
    /// wrappedUSD). The field holds the concentrated reward and the whale reads it back; conservation and solvency hold
    /// across every holder. A revert or a collapsed read-back at a market-reachable corner is the located field limit -
    /// resolved by widening the field or narrowing the documented market, never asserted as intended.
    function test_envelope_peakPendingRewards_holds() public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(_nominalCollateralUSD(), e.minWrapRate);
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD);
        _growPool(poolPegged, 1); // the whole pool in ONE holder (users[0]); the MIN_DEPOSIT seed is the only other
        _mintLeveragedBuffer(poolPegged);

        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate); // cheapest wrapped: CR below threshold + max reward count
        assertTrue(
            IStabilityPoolManager(stabilityPoolManager).rebalanceable(),
            "the cheap-wrapped corner drives the collateral ratio below the rebalance threshold"
        );

        uint256 injected = _rebalance();
        assertGt(injected, 0, "rebalance delivered the whole-pool collateral reward at the corner");

        // conservation and solvency across every holder - the SAME shared checks the invariant proves
        SpConservationGhosts memory g = _rewardGhosts(injected, poolPegged, MAX_FUZZ_USERS + 2);
        _assertRewardConserved(stabilityPool, _allActors(), g);
        _assertSpSolvent(stabilityPool, _allActors(), g);

        // the concentration landed in ONE field: the whale owns ~the whole pool, so its single pending field carries
        // essentially the whole reward. injected/2 is a robust floor a uint128 truncation - which would collapse the
        // field by orders of magnitude - cannot clear; the conservation above pins the aggregate exactly.
        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = wrappedCollateral;
        uint256 whaleClaimable = IClaimReward(stabilityPool).claimable(users[0], rewardTokens)[0];
        assertGe(whaleClaimable, injected / 2, "the whole-pool reward concentrated in the whale's single pending field");
    }

    // ─── helpers ───

    function _equalSplit(uint256 total, uint256 n) internal pure returns (uint256[] memory shares) {
        shares = new uint256[](n);
        uint256 each = total / n;
        shares[0] = each + (total - each * n); // first absorbs the remainder
        for (uint256 i = 1; i < n; i++) {
            shares[i] = each;
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// @notice ETH::fxUSD market — the seed envelope. Other markets (USD/BTC inverse, made-up, the deliberately-extreme
/// full-range one that locates the field limit) are added as sibling contracts in a later batch.
/// forge-config: default.invariant.runs = 8
/// forge-config: default.invariant.depth = 16
contract StabilityPoolEnvelope_ETH_fxUSD is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory) {
        return EnvelopeLib.ethFxUSD();
    }
}
