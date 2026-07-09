// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {SaltString} from "@bao-script/deployment/SaltString.sol";
import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";

import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {ConfigCollateral_fxUSD_mainnet} from "@harbor-script/config/collaterals/ConfigCollateral_fxUSD_mainnet.sol";
import {ConfigMarket_ETH_fxUSD_mainnet} from "@harbor-script/config/markets/ConfigMarket_ETH_fxUSD_mainnet.sol";
import {ConfigPeg_ETH} from "@harbor-script/config/pegs/ConfigPeg_ETH.sol";
import {StabilityPoolConservation} from "@harbor-test/StabilityPoolConservation.sol";
import {HarborTestSetup} from "@harbor-test/HarborTestSetup.sol";

/// @notice A named market's supported operating envelope, in the units a director thinks in: dollars and counts. The
/// harness translates these to what the protocol needs (a pegged token count and the oracle's 1e18-scaled price/rate),
/// so nothing here is mechanical. USD values are 1e18-scaled ($1 == 1e18); the wrap rate is a 1e18-scaled ratio
/// (1e18 == 1x). The peg $ price is a swept axis, not a fixed reference: the system's goal is to cope with many pegs
/// (micro-peg through BTC-scale), so the pool token count and the oracle price both scale with the swept peg. The
/// nominal peg pins the deterministic corner tests; the collateral USD range and the wrap-rate range sweep likewise.
struct Envelope {
    string name;
    uint256 maxPoolValueUSD; // pool size cap in $  (the totalSupply limit)
    uint256 maxPoolUsers; // depositor cap; poolValue/users = average deposit; 1 user = the whole pool in one deposit
    uint256 pegPriceUSD; // nominal pegged token $ price -> poolPegged = maxPoolValueUSD / pegPriceUSD, oracle price
    uint256 minPegPriceUSD; // swept peg $ price range: every fuzz walk prices its point against a peg drawn from
    uint256 maxPegPriceUSD; // this range, so each market axis is exercised under cheap and expensive pegs alike
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
            pegPriceUSD: 1 ether, // $1 nominal
            minPegPriceUSD: 1e-6 ether, // micro-peg through BTC-scale: the multi-peg goal, made a tested axis
            maxPegPriceUSD: 1e6 ether,
            minCollateralUSD: 1e-6 ether,
            maxCollateralUSD: 1e6 ether,
            minWrapRate: 0.001 ether,
            maxWrapRate: 1000 ether
        });
    }
}

/// @notice ETH::fxUSD market with the StabilityPoolManager's harvest cut and harvest/rebalance bounties zeroed, so all
/// yield and rewards flow to depositors - the envelope's conservation and read-back assertions then measure the pool
/// mechanics alone, not perturbed by a keeper bounty or a protocol cut. A test-only variant of the production market,
/// changed through the deployment config (the config-axis approach) rather than an imperative setter in setUp.
contract ConfigMarket_ETH_fxUSD_zeroFeesAndBounties is ConfigMarket_ETH_fxUSD_mainnet {
    function harvestCutRatio() public pure override returns (uint256) {
        return 0;
    }

    function harvestBountyRatio() public pure override returns (uint256) {
        return 0;
    }

    function rebalanceBountyRatio() public pure override returns (uint256) {
        return 0;
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

    /// @dev A short filesystem-safe market identifier, so each market's stress sweep writes its own constraints CSV
    /// (tmp/sp-constraints-<slug>.csv); separate files keep parallel test contracts from racing on one file.
    function _marketSlug() internal pure virtual returns (string memory);

    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }

    /// @dev The envelope's own config: the production ETH peg plus a zeroed-fee variant of the ETH::fxUSD market, so the
    /// pool mechanics are measured without the StabilityPoolManager's harvest cut or bounties skimming value from
    /// depositors. Overriding this (rather than editing the production config) keeps the whole config test-owned; a
    /// derived market that sweeps a config axis (Batch 2) overrides it to build its own config.
    function createETHMintersConfig()
        internal
        virtual
        override
        returns (ConfigPeg peg, Config_MinterMarket[] memory markets)
    {
        peg = new ConfigPeg_ETH();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_zeroFeesAndBounties();
    }

    function setUp() public virtual {
        // ── stand up the real protocol via the production deploy scripts (RebalanceFairness model) ──
        // _ensureBaoFactory gives the full deploy capability in-EVM and registers this test as the factory operator;
        // the only mainnet state the deploy needs is the collateral pair, so mock those two tokens and run with no fork.
        _ensureBaoFactory();

        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        // mock the collateral pair at the config's own addresses so the deploy wires to local mocks, not mainnet
        address underlyingToken = ConfigCollateral_fxUSD_mainnet(address(mktConfigs[0])).collateralToken();
        address wrappedToken = ConfigCollateral_fxUSD_mainnet(address(mktConfigs[0])).wrappedCollateralToken();
        vm.etch(underlyingToken, address(new MockERC20("fxUSD", "fxUSD", 18)).code); // decimals is immutable -> in code
        vm.etch(wrappedToken, address(new MockERC20("fxSAVE", "fxSAVE", 18)).code);
        Config_MinterMarket[] memory toDeploy = new Config_MinterMarket[](1);
        toDeploy[0] = mktConfigs[0]; // the fxUSD market
        deployHarborForPeg("envelope_test", peg, mktConfigs, "mainnet", true, toDeploy);

        minter = _predictAddress(SaltString.key("ETH", "fxUSD", "minter"));
        stabilityPool = _predictAddress(SaltString.key("ETH", "fxUSD", "stabilityPoolCollateral"));
        stabilityPoolManager = _predictAddress(SaltString.key("ETH", "fxUSD", "stabilityPoolManager"));
        pegged = _predictAddress(SaltString.key("ETH", "pegged"));
        leveraged = _predictAddress(SaltString.key("ETH", "fxUSD", "leveraged"));
        wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();

        // The price oracle is a separately-deployed dependency (harbor-price-aggregators): the deploy wires the minter
        // to its predicted CREATE3 address while that address is still codeless, exactly as production does. So etch the
        // settable mock AFTER the deploy - at the same _wrappedPriceOracleAddress the deploy used - which exercises the
        // deploy's codeless reference and puts the mock in place before the first read (the seed mint). etch copies code
        // not storage, so the answer is set per envelope point via mockOracle.setLatestAnswer.
        address priceOracle = _wrappedPriceOracleAddress(MinterMarketConfigLib.priceOracleKey(mktConfigs[0]));
        vm.etch(priceOracle, address(new MockWrappedPriceOracle()).code);
        mockOracle = MockWrappedPriceOracle(priceOracle);

        address spOwner = IBaoOwnable(stabilityPool).owner();
        uint256 rebalancerRole = IStabilityPool(stabilityPool).REBALANCER_ROLE();
        vm.startPrank(spOwner);
        IBaoRoles(stabilityPool).grantRoles(address(this), rebalancerRole); // to arrange prior losses
        vm.stopPrank();

        background = makeAddr("background");
        _createUsers(MAX_FUZZ_USERS);

        // a nominal envelope point (geometric-mean centre of the log-range) so the seed mint has a price to work from
        _setEnvelopePoint(_nominalCollateralUSD(), _nominalWrapRate(), buildEnvelope().pegPriceUSD);
        _seedPool(); // a permanent MIN_DEPOSIT seed so every actor can fully exit later

        // the owner drives the free-mints directly (onlyOwnerOrRoles), so it must never be granted ZERO_FEE_ROLE
        assertFalse(
            IBaoRoles(minter).hasAnyRole(IBaoOwnable(minter).owner(), IMinter(minter).ZERO_FEE_ROLE()),
            "owner must not hold ZERO_FEE_ROLE"
        );

        // start this market's constraints file fresh; the stress-sweep probes append one row per fuzz run
        vm.writeFile(_constraintsFile(), "market,action,w,price,rate,outcome,detail\n");
    }

    // ─── derivations: USD (director-facing) → protocol (token count + 1e18 oracle values) ───

    function _poolPeggedFor(uint256 poolValueUSD, uint256 pegPriceUSD) internal pure returns (uint256) {
        return (poolValueUSD * 1e18) / pegPriceUSD;
    }

    /// @dev The peg $ price is an explicit argument at every point: the system copes with many pegs, so each caller
    /// states the peg its point is priced against and the oracle price scales with it.
    function _setEnvelopePoint(uint256 collateralUSD, uint256 wrapRate, uint256 pegPriceUSD) internal {
        currentPrice = (collateralUSD * 1e18) / pegPriceUSD; // underlying collateral in pegged
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

    function _arrange(uint256 collateralUSD, uint256 wrapRate, uint256 pegPriceUSD, StartState memory s) internal {
        _setEnvelopePoint(collateralUSD, wrapRate, pegPriceUSD);

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
        uint256 pegSeed,
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
        uint256 pegPriceUSD = _logScale(pegSeed, e.minPegPriceUSD, e.maxPegPriceUSD);

        uint256 poolPegged = _poolPeggedFor(bound(poolSeed, e.maxPoolValueUSD / 1e5, e.maxPoolValueUSD), pegPriceUSD);
        if (poolPegged < n * minDeposit) {
            poolPegged = n * minDeposit; // every equal share must clear MIN_DEPOSIT
        }

        StartState memory s = StartState({
            existingDeposits: bound(existingSeed, 0, poolPegged),
            priorLossFraction: bound(lossSeed, 0, 1e18) // up to a FULL drain of the pool's headroom to its floor
        });
        _arrange(collateralUSD, wrapRate, pegPriceUSD, s);

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
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD);

        _arrange(
            e.minCollateralUSD,
            e.minWrapRate,
            e.pegPriceUSD,
            StartState({existingDeposits: 0, priorLossFraction: 0.5e18})
        );

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

    /// @notice The depositor-count corner: the declared business cap (maxPoolUsers, 10,000) of SEPARATE accounts each
    /// deposit an equal share of the whole envelope pool, then one rebalance returns the whole-pool collateral reward
    /// split across ALL of them. The books hold at the full crowd: the supply records every deposit exactly, and the
    /// reward conserves and stays solvent summed over every holder (per-holder flooring accumulates once per account,
    /// so the crowd is what stresses it). The fuzz walk caps its actors at MAX_FUZZ_USERS for feasibility; this pins
    /// the declared cap itself. Grown at the envelope's own (min) wrap rate - the rate the corner rebalance uses.
    function test_envelope_maxUsers_holds() public {
        Envelope memory e = buildEnvelope();
        uint256 n = e.maxPoolUsers;
        _setEnvelopePoint(_nominalCollateralUSD(), e.minWrapRate, e.pegPriceUSD);
        uint256 share = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD) / n; // $10B / 10,000 holders = $1M each
        _mintPeggedAtLeast(share * n);
        _mintLeveragedBuffer(share * n);

        uint256 supplyBefore = IERC20(stabilityPool).totalSupply();
        address[] memory crowd = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            address holder = makeAddr(string.concat("crowd", vm.toString(i)));
            crowd[i] = holder;
            IERC20(pegged).transfer(holder, share);
            vm.startPrank(holder);
            IERC20(pegged).approve(stabilityPool, share);
            IStabilityPool(stabilityPool).deposit(share, holder, 0);
            vm.stopPrank();
        }
        assertEq(
            IERC20(stabilityPool).totalSupply(),
            supplyBefore + share * n,
            "all 10,000 deposits recorded exactly"
        );

        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD); // cheap corner: CR below threshold
        assertTrue(
            IStabilityPoolManager(stabilityPoolManager).rebalanceable(),
            "the cheap-wrapped corner drives the collateral ratio below the rebalance threshold"
        );
        uint256 injected = _rebalance();
        assertGt(injected, 0, "rebalance delivered the whole-pool reward across the crowd");

        // conservation and solvency summed over EVERY holder (the crowd + the seed and background actors)
        address[] memory actors = new address[](n + 2);
        actors[0] = address(this);
        actors[1] = background;
        for (uint256 i = 0; i < n; i++) {
            actors[i + 2] = crowd[i];
        }
        SpConservationGhosts memory g = _rewardGhosts(injected, share * n, n + 2);
        _assertRewardConserved(stabilityPool, actors, g);
        _assertSpSolvent(stabilityPool, actors, g);
    }

    // ─── scatter-gun stress sweep: push each permissionless action PAST the envelope to LOCATE the constraint ───
    // Each fuzz run appends one row to tmp/sp-constraints-<slug>.csv (via try/catch, so a red run still emits the
    // grid). Within the envelope (w <= the envelope pool) the action MUST hold - a break there is a finding and the
    // test fails. Past the envelope the located limit is only recorded - the constraints table is the deliverable.

    function _constraintsFile() internal pure returns (string memory) {
        return string.concat("tmp/sp-constraints-", _marketSlug(), ".csv");
    }

    function _record(string memory action, uint256 w, string memory outcome, string memory detail) internal {
        vm.writeLine(
            _constraintsFile(),
            string.concat(
                _marketSlug(),
                ",",
                action,
                ",",
                vm.toString(w),
                ",",
                vm.toString(currentPrice),
                ",",
                vm.toString(currentRate),
                ",",
                outcome,
                ",",
                detail
            )
        );
    }

    function _revertReason(bytes memory err) internal pure returns (string memory) {
        if (err.length < 4) {
            return err.length == 0 ? "revert(no-data)" : vm.toString(err);
        }
        bytes4 sel;
        assembly {
            sel := mload(add(err, 0x20))
        }
        bytes memory data = new bytes(err.length - 4); // the arguments, after the 4-byte selector
        for (uint256 i = 0; i < data.length; i++) {
            data[i] = err[i + 4];
        }
        if (sel == 0x08c379a0 && data.length >= 64) {
            return abi.decode(data, (string)); // Error(string)
        }
        if (sel == 0x6dfcc650 && data.length == 64) {
            // OZ SafeCast SafeCastOverflowedUintDowncast(uint8 bits, uint256 value): the field-width overflow
            (uint256 bits, ) = abi.decode(data, (uint256, uint256));
            return string.concat("SafeCast-overflow-uint", vm.toString(bits));
        }
        if (sel == 0xe450d38c) {
            // OZ ERC20InsufficientBalance(address, uint256 balance, uint256 needed): a token-balance shortfall, not a
            // field-width limit (e.g. the minter cannot return more wrapped collateral than it holds)
            return "ERC20-insufficient-balance";
        }
        if (sel == 0xbbefdf6a) {
            // NoHarvestable(): the yield rounded to zero at this point - nothing to harvest, not a field-width limit
            return "no-harvestable";
        }
        return vm.toString(err); // other custom error / Panic: raw hex (selector + args)
    }

    /// @notice Deposit sweep: a fresh user deposits a swept amount into the StabilityPool at a swept oracle point,
    /// pushing PAST the envelope pool into the `TokenBalance.amount` width regime (uint128 in v3, ~3.4e38 - widened
    /// from v2's uint104 by Batch L). Whenever the deposit SUCCEEDS it must read back exactly (balance == amount, supply
    /// moved by the amount) - asserted at every size, since a silent truncation is a bug regardless of the envelope.
    /// Only a clean revert (the width) is a located limit, and only past the envelope. Funds via `deal` so the pool's
    /// own deposit width is isolated from the minter's mint reach (the mint sweep is a separate probe).
    function testFuzz_deposit_sweep(uint256 collateralSeed, uint256 rateSeed, uint256 pegSeed, uint256 wSeed) public {
        Envelope memory e = buildEnvelope();
        uint256 pegPriceUSD = _logScale(pegSeed, e.minPegPriceUSD, e.maxPegPriceUSD);
        _setEnvelopePoint(
            bound(collateralSeed, e.minCollateralUSD, e.maxCollateralUSD),
            bound(rateSeed, e.minWrapRate, e.maxWrapRate),
            pegPriceUSD
        );
        uint256 envelopePool = _poolPeggedFor(e.maxPoolValueUSD, pegPriceUSD); // the $ cap in the swept peg's tokens
        // log-scale over the full PHYSICAL input range [MIN_DEPOSIT, uint256 max]: the fuzzer locates the field break
        // within it, rather than a range sized to the field under test. _logScale samples every order of magnitude
        // equally, so the boundary (many orders below the max) is actually reached.
        uint256 w = _logScale(wSeed, IStabilityPool(stabilityPool).MIN_DEPOSIT(), type(uint256).max);

        address user = users[0];
        deal(pegged, user, w);
        uint256 supplyBefore = IERC20(stabilityPool).totalSupply();
        vm.startPrank(user);
        try IStabilityPool(stabilityPool).deposit(w, user, 0) {
            vm.stopPrank();
            bool exact = IERC20(stabilityPool).balanceOf(user) == w &&
                IERC20(stabilityPool).totalSupply() == supplyBefore + w;
            _record("deposit", w, exact ? "held" : "broke", exact ? "" : "readback-mismatch");
            // a deposit that SUCCEEDS must read back exactly - a silent truncation is a bug at ANY size, in or out of
            // the envelope, so assert unconditionally. Only a clean revert (below) is a located limit.
            assertTrue(exact, string.concat("deposit succeeded but did not read back exactly @ w=", vm.toString(w)));
        } catch (bytes memory err) {
            vm.stopPrank();
            string memory reason = _revertReason(err);
            _record("deposit", w, "broke", reason);
            // a clean revert is the located limit only PAST the envelope; within it the action must hold
            if (w <= envelopePool) {
                assertTrue(false, string.concat("within-envelope deposit reverted @ w=", vm.toString(w), ": ", reason));
            }
        }
    }

    /// @notice Withdraw sweep: a fresh user deposits a swept amount then fully exits inside the no-fee window. Whenever
    /// the round-trip SUCCEEDS it must return EXACTLY the deposit and clear the position - asserted at every size, since
    /// a silent wrong value is a bug regardless of the envelope. Only a clean revert (the deposit hitting the uint128
    /// width) is a located limit, and only past the envelope. The multi-step exit runs in an external self-call unit.
    function testFuzz_withdraw_sweep(uint256 collateralSeed, uint256 rateSeed, uint256 pegSeed, uint256 wSeed) public {
        Envelope memory e = buildEnvelope();
        uint256 pegPriceUSD = _logScale(pegSeed, e.minPegPriceUSD, e.maxPegPriceUSD);
        _setEnvelopePoint(
            bound(collateralSeed, e.minCollateralUSD, e.maxCollateralUSD),
            bound(rateSeed, e.minWrapRate, e.maxWrapRate),
            pegPriceUSD
        );
        uint256 envelopePool = _poolPeggedFor(e.maxPoolValueUSD, pegPriceUSD);
        // log-scale over the full physical input range - see testFuzz_deposit_sweep
        uint256 w = _logScale(wSeed, IStabilityPool(stabilityPool).MIN_DEPOSIT(), type(uint256).max);

        try this.depositThenWithdrawProbe(w, users[0]) returns (uint256 returned, uint256 residual) {
            bool exact = returned == w && residual == 0;
            _record("withdraw", w, exact ? "held" : "broke", exact ? "" : "roundtrip-mismatch");
            // a deposit+withdraw that SUCCEEDS must round-trip EXACTLY - a silent wrong value is a bug at any size, so
            // assert unconditionally. Only a clean revert (below) is a located limit.
            assertTrue(
                exact,
                string.concat(
                    "deposit/withdraw round-trip not exact @ w=",
                    vm.toString(w),
                    " returned=",
                    vm.toString(returned)
                )
            );
        } catch (bytes memory err) {
            string memory reason = _revertReason(err);
            _record("withdraw", w, "broke", reason);
            // a clean revert (e.g. the deposit hits the width) is the located limit only past the envelope
            if (w <= envelopePool) {
                assertTrue(
                    false,
                    string.concat("within-envelope deposit/withdraw reverted @ w=", vm.toString(w), ": ", reason)
                );
            }
        }
    }

    /// @dev External so the try/catch above treats the whole deposit->request->withdraw round-trip as one unit; it
    /// reverts (caught above, = a located limit) only if a STEP reverts. Returns the round-trip result so the caller
    /// asserts correctness unconditionally - a silent wrong value must fail everywhere, not just be caught here.
    function depositThenWithdrawProbe(uint256 w, address user) external returns (uint256 returned, uint256 residual) {
        deal(pegged, user, w);
        vm.startPrank(user);
        IStabilityPool(stabilityPool).deposit(w, user, 0);
        IStabilityPool(stabilityPool).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool(stabilityPool).getWithdrawalRequest(user);
        vm.warp(uint256(start) + 1);
        vm.startPrank(user);
        IStabilityPool(stabilityPool).withdraw(type(uint256).max, user, 0);
        vm.stopPrank();
        returned = IERC20(pegged).balanceOf(user);
        residual = IERC20(stabilityPool).balanceOf(user);
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
        _setEnvelopePoint(_nominalCollateralUSD(), _nominalWrapRate(), buildEnvelope().pegPriceUSD);
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD);
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
        _setEnvelopePoint(_nominalCollateralUSD(), _nominalWrapRate(), buildEnvelope().pegPriceUSD);
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD);
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
        _setEnvelopePoint(_nominalCollateralUSD(), e.minWrapRate, e.pegPriceUSD);
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD);
        _growPool(poolPegged, MAX_FUZZ_USERS);
        _mintLeveragedBuffer(poolPegged);

        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD); // cheapest wrapped: CR below threshold + max reward
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
        _setEnvelopePoint(_nominalCollateralUSD(), e.minWrapRate, e.pegPriceUSD);
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD);
        _growPool(poolPegged, 1); // the whole pool in ONE holder (users[0]); the MIN_DEPOSIT seed is the only other
        _mintLeveragedBuffer(poolPegged);

        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD); // cheapest wrapped: CR below threshold + max reward count
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
        assertGe(
            whaleClaimable,
            injected / 2,
            "the whole-pool reward concentrated in the whale's single pending field"
        );
    }

    // ─── scatter-gun reward sweeps: drive the keeper external functions PAST the envelope to LOCATE the reward field
    // that binds first. Named for the EXTERNAL FUNCTION exercised, not the internal field: the reward path is a
    // hierarchy of widths (LinearReward `rate` uint80, `queued` uint96; the accumulator `pending`/`claimed` uint128,
    // `integral` uint192), and which one binds depends on the function - a one-shot liquidation reward and a streamed
    // harvest stress different fields - so the sweep uncovers it rather than presuming a target. Correctness oracle on
    // a SUCCESS: the SAME shared conservation + solvency the `*_holds` guardrails use, asserted UNCONDITIONALLY (a
    // silent over-credit or insolvency is a bug at any size). Only a clean revert past the envelope is a located limit.

    /// @notice Rebalance reward sweep: grow a pool - a single whale holding a swept size from MIN_DEPOSIT up to the
    /// supply field's own uint128 width - so the reward limit is located GIVEN that (2a) deposit limit AND the whole
    /// reward concentrates in ONE `pending` field (the worst case). Then drop the wrapped collateral to the envelope
    /// corner (CR below the rebalance threshold; the whole-pool collateral is liquidated back to the pool as the
    /// reward, count = poolValue / wrappedUSD, which scales with the swept pool) and rebalance - the fuzzer finds where
    /// a reward field overflows. Grow at the envelope's own (min) wrap rate, the rate the corner rebalance uses, so the
    /// minter holds exactly the wrapped count it must return (a grow/rebalance rate mismatch would strand it). The grow
    /// and rebalance each run in their own external unit so a caught revert is attributable. Correctness on a hold: the
    /// shared conservation + solvency, asserted unconditionally.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_rebalance_sweep(uint256 poolSeed) public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(_nominalCollateralUSD(), e.minWrapRate, e.pegPriceUSD);

        // pool swept big, up to the supply field's own width; grown in its own unit so exceeding that field (the 2a
        // deposit/supply limit, cross-confirmed here) is recorded and stops this run rather than masking a reward find.
        uint256 poolPegged = _logScale(poolSeed, IStabilityPool(stabilityPool).MIN_DEPOSIT(), type(uint128).max);
        try this.growProbe(poolPegged) {
            // pool grew - proceed to stress the reward path
        } catch (bytes memory err) {
            _record("rebalance", poolPegged, "broke", string.concat("grow: ", _revertReason(err)));
            return;
        }

        // drop to the envelope corner: CR below the rebalance threshold (rebalanceable at any pool size, since CR is a
        // ratio) and the cheapest wrapped, maximising the reward count the whale's single pending field must hold
        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD);

        try this.rebalanceOnlyProbe() returns (uint256 injected) {
            vm.warp(block.timestamp + 8 days); // whole stream distributable
            SpConservationGhosts memory g = _rewardGhosts(injected, poolPegged, MAX_FUZZ_USERS + 2);
            // a rebalance that SUCCEEDS must conserve and stay solvent, and the whole reward must remain claimable by
            // the whale - a uint128 pending truncation would collapse that credit. All asserted unconditionally: a
            // silent wrong value is a bug at any size; only a clean revert (below) is a located limit.
            _assertRewardConserved(stabilityPool, _allActors(), g);
            _assertSpSolvent(stabilityPool, _allActors(), g);
            address[] memory rewardTokens = new address[](1);
            rewardTokens[0] = wrappedCollateral;
            assertGe(
                IClaimReward(stabilityPool).claimable(users[0], rewardTokens)[0],
                injected / 2,
                "whole-pool reward concentrated in the whale's single pending field"
            );
            _record("rebalance", poolPegged, "held", string.concat("injected=", vm.toString(injected)));
        } catch (bytes memory err) {
            _record("rebalance", poolPegged, "broke", _revertReason(err));
        }
    }

    /// @dev External so a pool that exceeds the supply field reverts as one attributable unit. Grows the whole pool
    /// into a single whale (users[0]) at the current healthy price - concentrating the later reward in ONE pending
    /// field - and mints the leveraged buffer so the pool can be driven below the rebalance threshold.
    function growProbe(uint256 poolPegged) external {
        _growPool(poolPegged, 1);
        _mintLeveragedBuffer(poolPegged);
    }

    /// @dev External so the try/catch treats the rebalance as one located-limit unit (it reverts only if a STEP
    /// reverts). The swept cheap point is already set by the caller; this asserts the pool is rebalanceable there and
    /// rebalances, returning the reward delivered to the pool.
    function rebalanceOnlyProbe() external returns (uint256 injected) {
        require(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "swept point not rebalanceable");
        injected = _rebalance();
    }

    /// @notice Harvest reward sweep: grow a pool so the minter holds a large wrapped-collateral balance, then accrue
    /// yield (a wrap-rate bump) and harvest it - the STREAMED reward path (StabilityPoolManager.harvest -> depositReward
    /// -> LinearReward `rate` uint80 / `queued` uint96), distinct from the rebalance path's one-shot accumulator
    /// integral. Grow at the cheapest wrap rate so the minter's wrapped holdings (and thus the harvested count) are
    /// largest; sweep the pool so that count crosses the streamed-field widths and the fuzzer locates where they
    /// overflow. Correctness on a hold: the shared conservation + solvency, asserted unconditionally.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_harvest_sweep(uint256 poolSeed) public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(_nominalCollateralUSD(), e.minWrapRate, e.pegPriceUSD);

        uint256 poolPegged = _logScale(poolSeed, IStabilityPool(stabilityPool).MIN_DEPOSIT(), type(uint128).max);
        try this.growProbe(poolPegged) {
            // pool grew - proceed to stress the streamed reward path
        } catch (bytes memory err) {
            _record("harvest", poolPegged, "broke", string.concat("grow: ", _revertReason(err)));
            return;
        }

        try this.harvestProbe() returns (uint256 injected) {
            vm.warp(block.timestamp + 8 days); // whole stream distributable
            SpConservationGhosts memory g = _rewardGhosts(injected, poolPegged, MAX_FUZZ_USERS + 2);
            // a harvest that SUCCEEDS must conserve and stay solvent - a silent over-credit or insolvency is a bug at
            // any size, so assert unconditionally. Only a clean revert (below) is a located limit.
            _assertRewardConserved(stabilityPool, _allActors(), g);
            _assertSpSolvent(stabilityPool, _allActors(), g);
            _record("harvest", poolPegged, "held", string.concat("injected=", vm.toString(injected)));
        } catch (bytes memory err) {
            _record("harvest", poolPegged, "broke", _revertReason(err));
        }
    }

    /// @dev External so the harvest runs as one attributable unit. Accrues yield (a wrap-rate bump) and harvests it to
    /// the pool, returning the reward delivered.
    function harvestProbe() external returns (uint256 injected) {
        injected = _harvest();
    }

    /// @notice Claim reward sweep: inject a whole-pool reward via a rebalance (accrued into the uint192 integral,
    /// claimable in uint256), then have the whale CLAIM - which checkpoints the account and writes its uint128
    /// `pending`. Sweep the pool so the accrued reward crosses uint128; the fuzzer locates where the pending write
    /// overflows. A silent truncation instead of a clean revert is caught too: the whale must receive essentially the
    /// whole reward, so a shrunk payout fails. Correctness on a hold: conservation + full payout, unconditional.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_claim_sweep(uint256 poolSeed) public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(_nominalCollateralUSD(), e.minWrapRate, e.pegPriceUSD);

        uint256 poolPegged = _logScale(poolSeed, IStabilityPool(stabilityPool).MIN_DEPOSIT(), type(uint128).max);
        try this.growProbe(poolPegged) {
            // pool grew - proceed to inject and claim
        } catch (bytes memory err) {
            _record("claim", poolPegged, "broke", string.concat("grow: ", _revertReason(err)));
            return;
        }
        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD); // corner: CR below threshold + max reward

        try this.rebalanceThenClaimProbe() returns (uint256 injected, uint256 claimedOut) {
            SpConservationGhosts memory g = _rewardGhosts(injected, poolPegged, MAX_FUZZ_USERS + 2);
            // the claim checkpoints the whale (writing its uint128 pending) then pays out. Conservation must hold and
            // the whale must receive essentially the whole reward - a silent pending truncation would shrink the
            // payout. Both asserted unconditionally; only a clean revert (below) is a located limit.
            _assertRewardConserved(stabilityPool, _allActors(), g);
            assertGe(claimedOut, injected / 2, "claim paid out the whole-pool reward from the whale's pending field");
            _record("claim", poolPegged, "held", string.concat("claimed=", vm.toString(claimedOut)));
        } catch (bytes memory err) {
            _record("claim", poolPegged, "broke", _revertReason(err));
        }
    }

    /// @dev External so the rebalance+claim runs as one attributable unit. Rebalances to inject a whole-pool reward,
    /// warps the stream complete, then the whale claims (checkpointing its uint128 pending). Returns the injected
    /// reward and the wrapped collateral the whale actually received.
    function rebalanceThenClaimProbe() external returns (uint256 injected, uint256 claimedOut) {
        require(IStabilityPoolManager(stabilityPoolManager).rebalanceable(), "swept point not rebalanceable");
        injected = _rebalance();
        vm.warp(block.timestamp + 8 days);
        uint256 whaleBefore = IERC20(wrappedCollateral).balanceOf(users[0]);
        vm.startPrank(users[0]);
        IClaimReward(stabilityPool).claim();
        vm.stopPrank();
        claimedOut = IERC20(wrappedCollateral).balanceOf(users[0]) - whaleBefore;
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

    /// @dev Log-uniform fuzz sample in [lo, hi]: pick an octave (bit-width) uniformly, then a value within it, so every
    /// order of magnitude is equally likely. A plain `bound` over a huge range samples almost only the top octave and
    /// never reaches a boundary many orders below the max - this is the "help" that lets the fuzzer locate one. The
    /// range passed in is the physical input range (MIN_DEPOSIT..uint256 max, 1 wei..a price), never sized to the field
    /// under test; the located limit is discovered, not encoded in the sweep bound.
    function _logScale(uint256 seed, uint256 lo, uint256 hi) internal pure returns (uint256 v) {
        if (lo < 1) {
            lo = 1;
        }
        if (hi <= lo) {
            return lo;
        }
        uint256 bits = bound(seed, Math.log2(lo), Math.log2(hi));
        uint256 octaveLo = uint256(1) << bits;
        uint256 octaveHi = bits >= 255 ? type(uint256).max : (uint256(2) << bits) - 1;
        // a decorrelated second draw for the mantissa within the octave, so within-octave resolution is not tied to the
        // octave choice; deterministic in `seed` for fuzz reproducibility
        v = bound(uint256(keccak256(abi.encode(seed, bits))), octaveLo, octaveHi);
        if (v < lo) {
            v = lo;
        }
        if (v > hi) {
            v = hi;
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

    function _marketSlug() internal pure override returns (string memory) {
        return "ethFxUSD";
    }
}
