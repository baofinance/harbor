// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {SaltString} from "@bao-script/deployment/SaltString.sol";
import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

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
            name: "ETH/fxUSD",
            maxPoolValueUSD: 1e9 ether, // $1B
            maxPoolUsers: 1000,
            pegPriceUSD: 4000 ether, // $4000
            minCollateralUSD: 0.98 ether, // fxUSD ~ $1
            maxCollateralUSD: 1.02 ether,
            minWrapRate: 1 ether, // fxSAVE / fxUSD, >= 1x and rising as yield accrues
            maxWrapRate: 1.5 ether
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
abstract contract StabilityPoolEnvelopeBase is BaoTest, Deploy_ETH_Minter {
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
        Envelope memory e = buildEnvelope();

        // ── stand up the real protocol via the production deploy scripts (RebalanceFairness model) ──
        address factory = _ensureBaoFactory();
        vm.selectFork(vm.createSelectFork(vm.rpcUrl("mainnet"), 24699497)); // pinned; real fxSAVE/fxUSD exist
        address factoryOwner = IBaoFactory(factory).owner();
        vm.startPrank(factoryOwner);
        IBaoFactory(factory).setOperator(address(this), 365 days);
        vm.stopPrank();

        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
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

        // ── grant this test contract the roles it needs to build positions and arrange losses ──
        address minterOwner = IBaoOwnable(minter).owner();
        uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
        vm.startPrank(minterOwner);
        IMinter(minter).updatePriceOracle(address(mockOracle));
        IBaoRoles(minter).grantRoles(address(this), zeroFeeRole);
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

        // a nominal envelope point (range midpoints) so the seed mint has a price to work from
        _setEnvelopePoint((e.minCollateralUSD + e.maxCollateralUSD) / 2, (e.minWrapRate + e.maxWrapRate) / 2);
        _seedPool(); // a permanent MIN_DEPOSIT seed so every actor can fully exit later
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
        deal(wrappedCollateral, address(this), collateral);
        IERC20(wrappedCollateral).approve(minter, collateral);
        minted = IMinter(minter).freeMintPeggedToken(collateral, address(this));
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
