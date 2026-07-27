// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {SaltString} from "@bao-script/deployment/SaltString.sol";
import {BaoTest} from "@bao-test/BaoTest.sol";
import {console2} from "forge-std/console2.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {ITokenHolder} from "@bao/TokenHolder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {DecrementalFloatingPoint_v2} from "@harbor/math/DecrementalFloatingPoint_v2.sol";

import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IMultipleRewardDistributor_v3} from "@harbor/interfaces/IMultipleRewardDistributor_v3.sol";
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
/// (a hyperinflation-devalued unit at $1e-12 through a risen-BTC or index token at $1e12), so the pool token count and
/// the oracle price both scale with the swept peg. The cross-asset RATIO the oracle expresses (e.g. BTC priced in yen,
/// ~1.5e7) is the collateral $ over the peg $ and is already covered by those two ranges; the peg axis instead stresses
/// the absolute token count and oracle-price magnitude. The nominal peg pins the deterministic corner tests; the
/// collateral USD range and the wrap-rate range sweep likewise.
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

/// @notice The state the action under test acts against — arranged on the REAL protocol before the action fires: a
/// populated pool (background deposits) already decayed by a prior loss (the compounding product moved off 1x). The
/// reward-bearing operations (harvest, rebalance) are driven as actions against this state, not pre-arranged here.
struct StartState {
    uint256 existingDeposits; // pegged already deposited by a background holder before the action
    uint256 priorLossFraction; // 1e18-scaled fraction of headroom already liquidated (decays the compounding product)
}

/// @notice The catalog of named markets. A derived test contract selects one in `buildEnvelope()`, optionally starting
/// from another entry and tweaking a single field.
library EnvelopeLib {
    /// @dev ETH::fxUSD anchored on a real market - collateral fxUSD near $1, wrapped fxSAVE at a yield premium (>= $1) -
    /// but with the peg $ price swept as a deliberately wide axis ($1e-12 hyperinflation floor to $1e12 appreciation
    /// ceiling), far beyond haETH's real ~$4000, to exercise the many-pegs goal. The expensive-peg corner where the
    /// collateral can no longer back a mint is pinned by `test_corner_expensivePeg_mintCannotBackPool`; the field-width
    /// limits by the `test_widthCorner_*` tests and the config-corner sibling markets.
    function ethFxUSD() internal pure returns (Envelope memory e) {
        e = Envelope({
            name: "1B, 1e3, 1e3, 1e2",
            maxPoolValueUSD: 1e10 ether, // $01B
            maxPoolUsers: 1e4,
            pegPriceUSD: 1 ether, // $1 nominal
            minPegPriceUSD: 1e-12 ether, // hyperinflation floor (a devalued unit worth <$1e-6) ...
            maxPegPriceUSD: 1e12 ether, // ... through appreciation ceiling (a token worth >$1e6, e.g. a risen BTC)
            minCollateralUSD: 1e-6 ether,
            maxCollateralUSD: 1e6 ether,
            minWrapRate: 0.001 ether,
            maxWrapRate: 1000 ether
        });
    }

    /// @dev A per-peg-MIN market (D2): the ethFxUSD envelope re-centred on `nominalPeg` with a modest ~3x band (the
    /// pegged token's realistic volatility), for a market CORRECTLY DEPLOYED at that scale - its MIN sized ~$1 at
    /// `nominalPeg` by the config (MIN = 1e18 / pegDollars). Distinct from ethFxUSD's frozen-MIN wide-peg DRIFT: here
    /// MIN tracks the peg, so the supply cap MAX = MIN * FACTOR_PRECISION stays ~$1e18 at every scale, and the market
    /// is proved to hold a full $-range pool where it is actually deployed.
    function atPegScale(uint256 nominalPeg, string memory name_) internal pure returns (Envelope memory e) {
        e = ethFxUSD();
        e.name = name_;
        e.pegPriceUSD = nominalPeg;
        e.minPegPriceUSD = nominalPeg / 3;
        e.maxPegPriceUSD = nominalPeg * 3;
    }
}

/// @notice ETH::fxUSD market with the StabilityPoolManager's harvest cut and harvest/rebalance bounties zeroed, so all
/// yield and rewards flow to depositors - the envelope's conservation and read-back assertions then measure the pool
/// mechanics alone, not perturbed by a keeper bounty or a protocol cut. A test-only variant of the production market,
/// changed through the deployment config (the config-axis approach) rather than an imperative setter in setUp.
contract ConfigMarket_ETH_fxUSD_zeroFeesAndBounties is ConfigMarket_ETH_fxUSD_mainnet {
    function harvestCutRatio() public pure virtual override returns (uint256) {
        return 0;
    }

    function harvestBountyRatio() public pure virtual override returns (uint256) {
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
/// The suite drives deposit, withdraw, harvest, and rebalance against the arranged state — each a fuzz walk plus a
/// deterministic corner, including the reward-field corner that the harvest and rebalance rewards reach.
abstract contract StabilityPoolEnvelopeBase is BaoTest, Deploy_ETH_Minter, StabilityPoolConservation, HarborTestSetup {
    // capped so the fork fuzz stays feasible; the declared business cap (maxPoolUsers) can be far larger and is
    // exercised by the deterministic max-users test rather than every fuzz run.
    uint256 internal constant MAX_FUZZ_USERS = 8;

    address internal minter;
    address internal stabilityPool; // the collateral-side StabilityPool
    address internal stabilityPoolLeveraged; // the leveraged-side StabilityPool (harvest splits across both)
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
        stabilityPoolLeveraged = _predictAddress(SaltString.key("ETH", "fxUSD", "stabilityPoolLeveraged"));
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

        // start this market's constraints file fresh; the stress-sweep probes append one row per fuzz run. Opt-in
        // (SP_CONSTRAINTS=true), so a plain run neither writes the file nor needs results/ to exist.
        if (_constraintsEnabled()) {
            vm.writeFile(_constraintsFile(), "market,action,w,price,rate,outcome,detail\n");
        }
    }

    // ─── config integrity (layer 1: config sources must agree; no deploy, no mocks) ───

    /// @notice The peg and market configs paired in the deploy must AGREE on minTotalSupply, the StabilityPool's floor.
    /// The SP deploy reads it from the MARKET config, so an override placed only on the peg is silently ignored and the
    /// deployed floor is not the intended one - which is exactly how the minDepositHuge variant deployed the base 2e14
    /// rather than its intended 1e24 (the override was on the peg alone). Asserting the two sources cannot diverge
    /// catches an override on the wrong config object, deploy-free and mock-free.
    function test_configIntegrity_minTotalSupplyPegMatchesMarket() public {
        (ConfigPeg peg, Config_MinterMarket[] memory markets) = createETHMintersConfig();
        for (uint256 i = 0; i < markets.length; i++) {
            assertEq(
                IHarborConfig(address(markets[i])).minTotalSupply(),
                peg.minTotalSupply(),
                "market minTotalSupply diverges from the peg's - an override lands on a config the SP deploy ignores"
            );
        }
    }

    /// @notice Config integrity, layer 2: every config-derived value baked into the DEPLOYED pool must equal what the
    /// config it was deployed from says. Layer 1 catches an override on the wrong config OBJECT; this catches the
    /// deploy reading the wrong config GETTER (delay and period transposed, a fee wired from the wrong ratio) - a class
    /// no amount of config-vs-config comparison can see. It reads the REAL deployed pool: mocked DEPENDENCIES (the
    /// etched oracle) are irrelevant here because these values are the pool's own immutables, taken from config at
    /// construction. (A mock SUT would be out of scope - it bypasses config by design - but this pool is the real one.)
    function test_configIntegrity_deployedPoolMatchesItsConfig() public {
        (, Config_MinterMarket[] memory markets) = createETHMintersConfig();
        IHarborConfig cfg = IHarborConfig(address(markets[0]));

        assertEq(
            IStabilityPool(stabilityPool).MIN_TOTAL_ASSET_SUPPLY(),
            cfg.minTotalSupply(),
            "deployed supply floor is not the configured one"
        );
        assertEq(
            IStabilityPool_v3(stabilityPool).MAX_TOTAL_ASSET_SUPPLY(),
            _expectedMaxTotalAssetSupply(cfg.minTotalSupply()),
            "deployed supply ceiling is not MIN * FACTOR_PRECISION (saturated at the supply field)"
        );
        (uint256 startDelay, uint256 endWindow) = IStabilityPool(stabilityPool).getWithdrawalWindow();
        assertEq(startDelay, cfg.stabilityPoolWithdrawalDelay(), "deployed withdrawal delay is not the configured one");
        assertEq(
            endWindow,
            cfg.stabilityPoolWithdrawalPeriod(),
            "deployed withdrawal window is not the configured one"
        );
        assertEq(
            IStabilityPool(stabilityPool).getEarlyWithdrawalFee(),
            cfg.stabilityPoolEarlyWithdrawalFeeRatio(),
            "deployed early-withdrawal fee is not the configured one"
        );
    }

    /// @dev The ceiling the constructor derives: `MIN * FACTOR_PRECISION`, saturated at the uint128 supply field above
    /// which a larger ceiling is unreachable anyway.
    function _expectedMaxTotalAssetSupply(uint256 minTotalSupply) internal pure returns (uint256) {
        return
            minTotalSupply > type(uint128).max / DecrementalFloatingPoint_v2.FACTOR_PRECISION
                ? type(uint128).max
                : minTotalSupply * DecrementalFloatingPoint_v2.FACTOR_PRECISION;
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

    /// @dev Mint at least `target` pegged to this contract (backed by real collateral at the current price). At an
    /// extreme peg/collateral/rate the wrapped price floors to zero and `_collateralFor` divides by it - the market
    /// cannot back a mint. Callers reach this through an external probe and OBSERVE the revert (a located economic
    /// limit), rather than pre-checking for it - so the boundary is discovered each run and cannot go stale.
    function _mintPeggedAtLeast(uint256 target) internal returns (uint256 minted) {
        uint256 collateral = _collateralFor(target) + 1 ether; // slack for the flooring in the mint
        (minted, ) = genesisMint(minter, collateral, 0, address(this));
    }

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        IStabilityPool(stabilityPool).deposit(amount, who, 0);
        vm.stopPrank();
    }

    /// @dev Cap a within-envelope deposit ceiling at the pool's remaining headroom under the supply cap. For a peg far
    /// below the pool's fixed MIN, the economic $ ceiling converts to a nominal token count above
    /// MAX_TOTAL_ASSET_SUPPLY; past that cap a deposit reverts DepositAmountExceedsMaximum - a located limit, not an
    /// in-envelope failure. So the effective within-envelope ceiling is the smaller of the economic ceiling and the
    /// current headroom.
    function _capToSupplyHeadroom(uint256 economicCeiling) internal view returns (uint256) {
        uint256 headroom = IStabilityPool_v3(stabilityPool).MAX_TOTAL_ASSET_SUPPLY() -
            IERC20(stabilityPool).totalSupply();
        return economicCeiling > headroom ? headroom : economicCeiling;
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
        // Peak supply during the walk is the pre-existing deposit (<= poolPegged) plus one equal share (<= poolPegged)
        // on top of the baseline, so bound the pool at half the remaining headroom to keep that peak within the supply
        // cap. For a peg far below MIN this binds (the nominal pool for the $ value exceeds MAX_TOTAL_ASSET_SUPPLY);
        // MIN * FACTOR_PRECISION / 2 dwarfs n * minDeposit, so it never conflicts with the floor above.
        uint256 halfHeadroom = (IStabilityPool_v3(stabilityPool).MAX_TOTAL_ASSET_SUPPLY() -
            IERC20(stabilityPool).totalSupply()) / 2;
        if (poolPegged > halfHeadroom) {
            poolPegged = halfHeadroom;
        }

        StartState memory s = StartState({
            existingDeposits: bound(existingSeed, 0, poolPegged),
            priorLossFraction: bound(lossSeed, 0, 1e18) // up to a FULL drain of the pool's headroom to its floor
        });
        uint256[] memory shares = _equalSplit(poolPegged, n);

        // Mint-backed setup (arrange + mint the pool + distribute) is the ONLY part that can revert at an economic
        // limit: when the collateral is worth < 1 wei of pegged per unit the wrapped price floors to zero and
        // `_collateralFor` divides by it. Observe it through an external probe - a revert is a located limit that is
        // recorded and ends the run; a success proceeds to the read-backs. This discovers the boundary each run rather
        // than pre-judging it, so a later widening simply lets the same walk hold at a wider corner.
        // Set the oracle point HERE too (the probe sets it again inside `_arrange`, but that inner write rolls back on
        // a probe revert): the recorded row below must log the point that produced the failure, not the prior one.
        _setEnvelopePoint(collateralUSD, wrapRate, pegPriceUSD);

        try this.depositWithdrawSetupProbe(collateralUSD, wrapRate, pegPriceUSD, s, poolPegged, shares, n) {
            // setup held - exercise the behaviour below
        } catch (bytes memory err) {
            // Tolerate ONLY the expected economic limit: when the collateral is worth < 1 wei of pegged per unit the
            // mint cannot back the pool and `_collateralFor` divides by zero. Any OTHER revert is an unexpected failure
            // and must propagate UNCHANGED - a broad catch here would be a fuzz-level fail_on_revert=false, silently
            // recording a real bug as a located limit.
            if (keccak256(bytes(_revertReason(err))) != keccak256(bytes("divide-by-zero"))) {
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
            _record("depositWithdraw", poolPegged, "broke", "grow: divide-by-zero");
            return;
        }
        // Behaviour, with read-backs asserted UNCONDITIONALLY (never inside the try) so a silent ledger error fails
        // here rather than being caught and mislabelled a limit.
        for (uint256 i = 0; i < n; i++) {
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

    /// @dev The mint-backed setup for the deposit/withdraw walk, external so a revert at an economic limit (the mint
    /// cannot back the pool) is caught and recorded by the caller rather than failing the run. Mints the pool to this
    /// contract and distributes each user's share; the users deposit themselves in the behaviour loop above.
    function depositWithdrawSetupProbe(
        uint256 collateralUSD,
        uint256 wrapRate,
        uint256 pegPriceUSD,
        StartState memory s,
        uint256 poolPegged,
        uint256[] memory shares,
        uint256 n
    ) external {
        _arrange(collateralUSD, wrapRate, pegPriceUSD, s);
        _mintPeggedAtLeast(poolPegged);
        for (uint256 i = 0; i < n; i++) {
            IERC20(pegged).transfer(users[i], shares[i]);
        }
    }

    /// @notice The widened peg range makes the walk draw expensive-peg + cheap-collateral + low-rate points where the
    /// oracle price underflows to zero (the market cannot mint). At such a point the walk records the located limit and
    /// skips - it must NOT revert trying to mint/distribute a pool that cannot be backed. These seeds pin that corner:
    /// collateral at min, rate at min, peg at max, with a background deposit too so both mint paths are exercised.
    function test_depositWithdraw_atPriceUnderflow_skipsWithoutReverting() public {
        testFuzz_depositWithdraw_holds(0, 0, type(uint256).max, 0, 0, type(uint256).max, 0);
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

    /// @notice At an extreme-expensive peg paired with cheap collateral and a low wrap rate, the oracle price
    /// (collateral priced in pegged) rounds toward zero, so no finite collateral can back a mint: the mint-backed pool
    /// grow reverts (the divide in `_collateralFor`). This is the located economic limit the sweeps catch and record;
    /// pinned deterministically here. The setEnvelopePoint call is made BEFORE expectRevert so it does not steal it.
    function test_corner_expensivePeg_mintCannotBackPool() public {
        _setEnvelopePoint(1e-6 ether, 0.001 ether, 1e12 ether); // collateral $1e-6, rate 0.001x, peg $1e12
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x12)); // divide by zero: collateral cannot back pegged
        this.growProbe(1 ether);
    }

    /// @notice A divide-by-zero panic - the recorded reason when the mint cannot back a pool at a price-underflow
    /// limit - decodes to a readable constraints-CSV label rather than raw hex.
    function test_revertReason_decodesDivideByZeroPanic() public pure {
        assertEq(_revertReason(abi.encodeWithSignature("Panic(uint256)", 0x12)), "divide-by-zero");
    }

    // ─── deterministic width-boundary corners (the balance-field regression pins, on the REAL deployForPeg pool) ───
    // The fuzz sweeps cross these boundaries probabilistically; these pin the exact historical defect points every
    // run. The 104-bit measurement run (the field retyped to uint104) demonstrated the same assertions go red the
    // moment the field narrows - the regression these guard.

    /// @notice A deposit just past 2^104 is recorded exactly. This is the v2 defect point: the raw uint104 cast kept
    /// only the low bits, so the pool pulled the full amount but credited ~1e18 - silent loss of the entire 2^104
    /// part. The widened field must credit it in full.
    function test_widthCorner_depositPastUint104RecordedExactly() public {
        uint256 amount = 2 ** 104 + 1 ether;
        uint256 supplyBefore = IERC20(stabilityPool).totalSupply();
        // At a small-MIN market MAX = MIN * FACTOR_PRECISION sits below 2^104, so the supply cap binds before the
        // balance field width: this field-width regression is unreachable here (the cap reverts first), and is pinned
        // on the larger-MIN markets where the field IS reachable.
        if (supplyBefore + amount > IStabilityPool_v3(stabilityPool).MAX_TOTAL_ASSET_SUPPLY()) {
            vm.skip(true);
            return;
        }
        address user = users[0];
        deal(pegged, user, amount);
        vm.startPrank(user);
        IStabilityPool(stabilityPool).deposit(amount, user, 0);
        vm.stopPrank();
        assertEq(IERC20(stabilityPool).balanceOf(user), amount, "deposit past 2^104 credited exactly");
        assertEq(IERC20(stabilityPool).totalSupply(), supplyBefore + amount, "supply records the deposit exactly");
    }

    /// @notice Two deposits that each fit uint104 but whose SUM crosses 2^104 must both succeed - the availability
    /// half of the v2 width defect: no cast truncated, but the checked += on the uint104 total Panicked on the second
    /// deposit, bricking deposits for everyone once the pool was ~2e31 full.
    function test_widthCorner_supplyAccumulationCrossesUint104() public {
        uint256 half = 15e30; // 1.5e31: fits uint104 alone, crosses 2^104 (~2.03e31) combined
        uint256 supplyBefore = IERC20(stabilityPool).totalSupply();
        // unreachable where MAX = MIN * FACTOR_PRECISION is below 2^104 (small-MIN market): the cap binds first - the
        // regression is pinned on the larger-MIN markets. See test_widthCorner_depositPastUint104RecordedExactly.
        if (supplyBefore + 2 * half > IStabilityPool_v3(stabilityPool).MAX_TOTAL_ASSET_SUPPLY()) {
            vm.skip(true);
            return;
        }
        for (uint256 i = 0; i < 2; i++) {
            address user = users[i];
            deal(pegged, user, half);
            vm.startPrank(user);
            IStabilityPool(stabilityPool).deposit(half, user, 0);
            vm.stopPrank();
        }
        assertEq(IERC20(stabilityPool).totalSupply(), supplyBefore + 2 * half, "accumulated supply records exactly");
    }

    /// @notice Beyond the balance field there is no legal recording, so the deposit must REVERT cleanly - never
    /// truncate (2^128 is a multiple of 2^104, so the v2 raw cast truncated it away silently and the deposit
    /// SUCCEEDED crediting only the remainder). The supply total is written first, so the overflowing value the
    /// checked cast reports is the pre-existing supply plus the deposit.
    function test_widthCorner_depositBeyondUint128Reverts() public {
        uint256 amount = 2 ** 128 + 1 ether;
        address user = users[0];
        deal(pegged, user, amount);
        uint256 supplyBefore = IERC20(stabilityPool).totalSupply();
        vm.startPrank(user);
        vm.expectRevert(
            abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, supplyBefore + amount)
        );
        IStabilityPool(stabilityPool).deposit(amount, user, 0);
        vm.stopPrank();
    }

    /// @notice The depositor-count corner: the declared business cap (maxPoolUsers, 10,000) of SEPARATE accounts each
    /// deposit an equal share of the whole envelope pool, then one rebalance returns the whole-pool collateral reward
    /// split across ALL of them. The books hold at the full crowd: the supply records every deposit exactly, and the
    /// reward conserves and stays solvent summed over every holder (per-holder flooring accumulates once per account,
    /// so the crowd is what stresses it). The fuzz walk caps its actors at MAX_FUZZ_USERS for feasibility; this pins
    /// the declared cap itself. Grown at the envelope's own (min) wrap rate - the rate the corner rebalance uses.
    /// @notice The `_notInGasReport` suffix excludes this from the gas regression pass (bin/gas skips
    ///         `--no-match-test _notInGasReport`). It deposits for `maxPoolUsers` (10,000) holders, and
    ///         `--isolate` turns each deposit into its own transaction - ~220s, 99.7% of the suite's gas-mode
    ///         cost, against ~1ms for every other test here. It stays in the plain test and coverage passes,
    ///         where it verifies the many-holder path and contributes to line coverage; only the isolate-per-call
    ///         gas measurement, which the shorter tests already cover for the same functions, drops it.
    function test_envelope_maxUsers_holds_notInGasReport() public {
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
        assertEq(IERC20(stabilityPool).totalSupply(), supplyBefore + share * n, "all 10,000 deposits recorded exactly");

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
    // Each fuzz run appends one row to tmp/sp-constraints-<slug>.csv when SP_CONSTRAINTS=true (via try/catch, so a
    // red run still emits the grid). Within the envelope (w <= the envelope pool) the action MUST hold - a break there is a finding and the
    // test fails. Past the envelope the located limit is only recorded - the constraints table is the deliverable.

    /// @notice The constraints table is an opt-in diagnostic, off by default. It is a per-run fuzz scatter
    ///         (non-repeatable under a random seed), so it belongs in untracked tmp/ scratch, not the tracked
    ///         results/ deliverables - and emitting it on every run would fail wherever tmp/ is absent (e.g. a plain
    ///         `yarn test`, which does not create it). Set SP_CONSTRAINTS=true to generate it.
    function _constraintsEnabled() internal view returns (bool) {
        return vm.envOr("SP_CONSTRAINTS", false);
    }

    function _constraintsFile() internal pure returns (string memory) {
        return string.concat("tmp/sp-constraints-", _marketSlug(), ".csv");
    }

    function _record(string memory action, uint256 w, string memory outcome, string memory detail) internal {
        if (!_constraintsEnabled()) {
            return;
        }
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
        if (sel == 0x4e487b71 && data.length == 32) {
            // Panic(uint256): a Solidity runtime panic. 0x12 = divide/modulo by zero - the mint dividing by a wrapped
            // price that floored to zero, i.e. the collateral cannot back pegged (a price-underflow economic limit);
            // 0x11 = arithmetic over/underflow. Others reported by code.
            uint256 code = abi.decode(data, (uint256));
            if (code == 0x12) {
                return "divide-by-zero";
            }
            if (code == 0x11) {
                return "arithmetic-overflow";
            }
            return string.concat("panic-", vm.toString(code));
        }
        return vm.toString(err); // other custom error: raw hex (selector + args)
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
        uint256 envelopePool = _capToSupplyHeadroom(_poolPeggedFor(e.maxPoolValueUSD, pegPriceUSD)); // $ cap in tokens
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
        uint256 envelopePool = _capToSupplyHeadroom(_poolPeggedFor(e.maxPoolValueUSD, pegPriceUSD));
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
        // the pools' DIRECT share of a harvest is what remains after the keeper bounty and the protocol cut (the cut
        // returns to the pools later through the FeeReceiver split - a separate flow). Under the production config
        // (1% bounty + 99% cut) that residual is ZERO, so assert against the deployed ratios, not a fixed premise.
        uint256 residualRatio = 1e18 -
            IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio() -
            IStabilityPoolManager(stabilityPoolManager).harvestCutRatio();
        if (residualRatio > 0) {
            assertGt(injected, 0, "harvest delivered the pools' residual share");
        } else {
            // bounty + cut consume the whole harvest; both pool shares floor and the sub-wei remainder is never swept
            // (it stays in the minter as harvestable), so the pools receive NOTHING - no dust transfer
            assertEq(injected, 0, "no dust reaches the pools when bounty + cut consume the harvest");
        }

        vm.warp(block.timestamp + 8 days); // whole stream distributable

        SpConservationGhosts memory g = _rewardGhosts(injected, poolPegged, MAX_FUZZ_USERS + 2);
        _assertRewardConserved(stabilityPool, _allActors(), g);
        _assertSpSolvent(stabilityPool, _allActors(), g);
    }

    /// @notice The harvest HOLDS at the envelope corner. At the envelope-MAX pool, cheapest collateral (largest
    /// wrapped-token holdings), and the MAX single-step wrap-rate jump - the largest single-step yield the envelope
    /// declares - the harvest does not revert on the reward stream. It deposits up to one period's capacity
    /// (`maxDepositReward`) and leaves the excess as harvestable in the minter, so only `swept` leaves the minter and
    /// the rest stays claimable by the next harvest. Under a config whose residual reaches the pools (zeroed cut) that
    /// residual share exceeds the per-period capacity at this corner, so the harvest defers the excess rather than
    /// failing all-or-nothing.
    function test_envelope_harvestCorner_holds() public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD);
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD);
        _growPool(poolPegged, MAX_FUZZ_USERS);
        currentRate = e.maxWrapRate; // one un-harvested step: the wrapped collateral appreciates from min to MAX rate
        mockOracle.setLatestAnswer(currentPrice, currentRate);

        uint256 residualRatio = 1e18 -
            IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio() -
            IStabilityPoolManager(stabilityPoolManager).harvestCutRatio();
        uint256 harvestableBefore = IMinter(minter).harvestable();
        uint256 rewardBefore = IERC20(wrappedCollateral).balanceOf(stabilityPool);

        address keeper = makeAddr("harvestKeeper");
        vm.startPrank(keeper);
        uint256 swept = IStabilityPoolManager(stabilityPoolManager).harvest(keeper, 0); // MUST NOT revert - defers at the corner
        vm.stopPrank();
        uint256 injected = IERC20(wrappedCollateral).balanceOf(stabilityPool) - rewardBefore;

        // only `swept` leaves the minter; the harvestable drops by exactly that and the unswept remainder stays
        assertLe(swept, harvestableBefore, "harvest swept no more than was harvestable");
        assertEq(
            IMinter(minter).harvestable(),
            harvestableBefore - swept,
            "the unswept remainder (deferred + flooring) stays as harvestable"
        );
        if (residualRatio > 0) {
            assertGt(injected, 0, "some reward reached the pool at the corner (capped, not reverted)");
        }
    }

    /// @notice The harvest RECOVERS a deferred backlog across reward periods (real cap, no mock). At the envelope corner
    /// a single max wrap-rate jump accrues far more collateral yield than one period's reward-stream capacity
    /// `maxDepositReward = _depositRewardCap - committed`, so the first harvest deposits exactly the capacity and defers
    /// the rest as harvestable. Recovery is by WAITING, not by frequency: within the same period the capacity is
    /// consumed (a second harvest adds nothing), but each elapsed period distributes the stream and frees the capacity,
    /// letting the keeper drain another ~capacity chunk - the backlog shrinks monotonically and nothing is lost
    /// (harvestable falls by exactly what each harvest sweeps). Uses the real `maxDepositReward`, so the same-period vs
    /// across-period asymmetry is exercised against the live `committed = queued + rate*period`, not a fixed stand-in.
    function test_envelope_harvestRecovery_realCapNoMock() public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD);
        _growPool(_poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD), MAX_FUZZ_USERS);
        currentRate = e.maxWrapRate; // the largest single-step yield the envelope declares - far exceeds one period
        mockOracle.setLatestAnswer(currentPrice, currentRate);

        address token = wrappedCollateral;
        uint256 period = IMultipleRewardDistributor_v3(stabilityPool).REWARD_PERIOD_LENGTH();
        uint256 capacityFresh = IMultipleRewardDistributor_v3(stabilityPool).maxDepositReward(token);
        address keeper = makeAddr("harvestRecoveryKeeper");

        uint256 residualRatio = 1e18 -
            IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio() -
            IStabilityPoolManager(stabilityPoolManager).harvestCutRatio();
        uint256 harvestable0 = IMinter(minter).harvestable();
        // Only markets whose single-step corner yield EXCEEDS one period's capacity form a deferred backlog; where the
        // capacity already dwarfs the yield (huge MIN) or the config sends no residual to the pools (full bounty + cut),
        // there is nothing to defer and no recovery question to probe.
        if (residualRatio == 0 || harvestable0 == 0 || capacityFresh == 0 || harvestable0 <= capacityFresh) {
            return;
        }

        uint256 pool0 = IERC20(token).balanceOf(stabilityPool);
        vm.startPrank(keeper);
        IStabilityPoolManager(stabilityPoolManager).harvest(keeper, 0);
        vm.stopPrank();
        uint256 injected1 = IERC20(token).balanceOf(stabilityPool) - pool0;
        uint256 backlog = IMinter(minter).harvestable();
        assertEq(injected1, capacityFresh, "harvest #1 deposits exactly one period's reward-stream capacity");
        assertGt(backlog, 0, "the excess beyond capacity is deferred as harvestable");

        // within the SAME period the capacity is consumed - harvesting more often cannot add to the pool
        assertEq(
            IMultipleRewardDistributor_v3(stabilityPool).maxDepositReward(token),
            0,
            "same period: the stream capacity is consumed, so a second harvest adds nothing (recovery is by waiting, not frequency)"
        );

        // RECOVERY across periods: each elapsed period distributes the stream, frees the capacity, and lets the keeper
        // drain another ~capacity chunk of the backlog - shrinking monotonically at ~capacity/period, nothing lost.
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + period + 1);
            assertGt(
                IMultipleRewardDistributor_v3(stabilityPool).maxDepositReward(token),
                0,
                "after a full period the distributed stream frees capacity for the next deposit"
            );
            vm.startPrank(keeper);
            uint256 swept = IStabilityPoolManager(stabilityPoolManager).harvest(keeper, 0);
            vm.stopPrank();
            assertGt(
                swept,
                0,
                "a harvest after the period drains another chunk of the backlog (recovery across periods)"
            );
            uint256 backlogNow = IMinter(minter).harvestable();
            assertEq(
                backlogNow,
                backlog - swept,
                "conservation: the backlog falls by exactly what the harvest swept - nothing lost"
            );
            assertLt(backlogNow, backlog, "the deferred backlog shrinks each period");
            backlog = backlogNow;
        }
    }

    /// @notice The harvest's SKIM (keeper bounty + protocol cut) is capped at the SAME rate as the pool deposit -
    /// proportional to what is actually distributed, never to the deferred backlog. At the corner one harvest can only
    /// deposit a period's `maxDepositReward` to the pools; the bounty and cut must scale to THAT, or a keeper/treasury
    /// would skim a fee on funds the pools never receive. Runs under `_testBounty` (the skim is all bounty) and
    /// `_testCut` (all cut), isolating each half of the shared cap. The band pins the skim to the pool-proportional
    /// amount and rejects a skim on the whole (mostly-deferred) harvestable, which is orders of magnitude larger.
    function test_envelope_harvestSkimCappedWithPoolDeposit() public {
        uint256 skimRatio = IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio() +
            IStabilityPoolManager(stabilityPoolManager).harvestCutRatio();
        uint256 residualRatio = 1e18 - skimRatio;
        // needs a real skim AND a residual to the pools; the zero-fee and full-cut markets have nothing to prove here
        if (skimRatio == 0 || residualRatio == 0) {
            return;
        }
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD);
        _growPool(_poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD), MAX_FUZZ_USERS);
        currentRate = e.maxWrapRate;
        mockOracle.setLatestAnswer(currentPrice, currentRate);

        address token = wrappedCollateral;
        uint256 capacityFresh = IMultipleRewardDistributor_v3(stabilityPool).maxDepositReward(token);
        uint256 harvestable0 = IMinter(minter).harvestable();
        if (capacityFresh == 0 || harvestable0 <= capacityFresh) {
            return; // no deferred backlog, so the pool deposit is not capped and there is nothing to prove
        }

        address keeper = makeAddr("harvestSkimKeeper");
        uint256 poolCollBefore = IERC20(token).balanceOf(stabilityPool);
        uint256 poolLevBefore = IERC20(token).balanceOf(stabilityPoolLeveraged);
        vm.startPrank(keeper);
        uint256 swept = IStabilityPoolManager(stabilityPoolManager).harvest(keeper, 0);
        vm.stopPrank();
        uint256 distributed = (IERC20(token).balanceOf(stabilityPool) - poolCollBefore) +
            (IERC20(token).balanceOf(stabilityPoolLeveraged) - poolLevBefore);
        uint256 skim = swept - distributed; // the bounty + cut that left the minter

        // the skim is the ratio slice of what was DISTRIBUTED, not of the whole (mostly-deferred) harvestable
        uint256 expectedSkim = Math.mulDiv(distributed, skimRatio, residualRatio);
        uint256 backlogProportionalSkim = Math.mulDiv(harvestable0, skimRatio, 1e18); // skim on the whole backlog, decades higher
        // the skim rounds through `processed = mulDiv(distributed, 1e18, residualRatio)` then a ratio floor, so it can
        // differ from the direct `mulDiv(distributed, skimRatio, residualRatio)` by at most 1 wei; the band admits the
        // capped skim and rejects the backlog-proportional value it is many decades away from
        assertDiscriminates(
            skim,
            expectedSkim,
            1,
            backlogProportionalSkim,
            "skim scales with the pool deposit, not the backlog"
        );
    }

    /// @dev Deposit `amount` pegged (minted fresh) into `pool` for `who` - used to give the leveraged-side pool its own
    /// holdings so the harvest split across both pools is exercised.
    function _depositPeggedTo(address pool, address who, uint256 amount) internal {
        _mintPeggedAtLeast(amount);
        IERC20(pegged).transfer(who, amount);
        vm.startPrank(who);
        IERC20(pegged).approve(pool, amount);
        IStabilityPool(pool).deposit(amount, who, 0);
        vm.stopPrank();
    }

    /// @notice Both pools take their FLOORED share - neither absorbs the split remainder. With both pools holding pegged
    /// in an uneven ratio (so the residual split leaves a 1-wei remainder), each pool receives EXACTLY
    /// floor(residual * itsHoldings / total) and the remainder stays in the minter, rather than one pool being handed it
    /// as a systematic advantage.
    function test_harvest_bothPoolsFloored() public {
        uint256 bountyRatio = IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio();
        uint256 cutRatio = IStabilityPoolManager(stabilityPoolManager).harvestCutRatio();
        if (1e18 - bountyRatio - cutRatio == 0) {
            return; // no residual to split under a full-cut config
        }
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(_nominalCollateralUSD(), _nominalWrapRate(), e.pegPriceUSD);
        // uneven holdings across the two pools so the residual split can leave a remainder
        uint256 base = _poolPeggedFor(e.maxPoolValueUSD / 1e4, e.pegPriceUSD);
        _growPool(base, MAX_FUZZ_USERS); // collateral pool (plus the setUp seed)
        _depositPeggedTo(stabilityPoolLeveraged, background, 2 * base); // leveraged pool holds ~twice as much

        // accrue yield until the GROSS split across the (uneven) holdings leaves an un-owed remainder (a 2-way floor
        // loses 0 or 1 wei). The manager splits the new yield by holdings gross, flooring BOTH shares, then streams
        // each pool net = gross * residualRatio; the remainder stays un-owed harvestable, handed to neither pool.
        uint256 residualRatio = 1e18 - bountyRatio - cutRatio;
        uint256 grossCol;
        uint256 grossLev;
        uint256 harvestableAmount;
        for (uint256 i = 0; i < 8; i++) {
            currentRate = (currentRate * 1001) / 1000;
            mockOracle.setLatestAnswer(currentPrice, currentRate);
            harvestableAmount = IMinter(minter).harvestable();
            uint256 totalHold = IERC20(pegged).balanceOf(stabilityPool) +
                IERC20(pegged).balanceOf(stabilityPoolLeveraged);
            grossCol = Math.mulDiv(harvestableAmount, IERC20(pegged).balanceOf(stabilityPool), totalHold);
            grossLev = Math.mulDiv(harvestableAmount, IERC20(pegged).balanceOf(stabilityPoolLeveraged), totalHold);
            if (grossCol + grossLev < harvestableAmount) {
                break; // the gross split leaves an un-owed remainder - the discriminating case
            }
        }
        require(grossCol + grossLev < harvestableAmount, "fixture must produce a split remainder");
        uint256 expectedCol = Math.mulDiv(grossCol, residualRatio, 1e18);
        uint256 expectedLev = Math.mulDiv(grossLev, residualRatio, 1e18);

        uint256 colBefore = IERC20(wrappedCollateral).balanceOf(stabilityPool);
        uint256 levBefore = IERC20(wrappedCollateral).balanceOf(stabilityPoolLeveraged);
        address keeper = makeAddr("harvestKeeper");
        vm.startPrank(keeper);
        IStabilityPoolManager(stabilityPoolManager).harvest(keeper, 0);
        vm.stopPrank();

        assertEq(
            IERC20(wrappedCollateral).balanceOf(stabilityPool) - colBefore,
            expectedCol,
            "collateral pool got exactly the net of its floored gross share"
        );
        assertEq(
            IERC20(wrappedCollateral).balanceOf(stabilityPoolLeveraged) - levBefore,
            expectedLev,
            "leveraged pool got exactly the net of its floored gross share, not the split remainder"
        );
        assertGt(IMinter(minter).harvestable(), 0, "the split remainder stays in the minter as harvestable");
    }

    /// @notice A harvest backlog deferred while a pool held nothing is NOT re-split to that pool when it later
    /// deposits. At the reward-field corner the collateral pool's residual share exceeds one period's stream capacity,
    /// so the first harvest deposits a period's capacity and defers the rest as a backlog left in the minter. That
    /// backlog accrued entirely while the leveraged pool was empty, so it is owed to the collateral pool alone. When
    /// the leveraged pool then enters and a keeper harvests the PURE backlog (no fresh yield), the backlog must still
    /// go to the collateral pool - a pool that held nothing when it accrued earns none of it.
    function test_harvest_deferredBacklogNotReSplitToLaterEntrant() public {
        uint256 bountyRatio = IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio();
        uint256 cutRatio = IStabilityPoolManager(stabilityPoolManager).harvestCutRatio();
        if (1e18 - bountyRatio - cutRatio == 0) {
            return; // a full-cut config sends nothing to the pools, so no backlog forms to leak
        }
        // Corner: cheapest collateral + the max single-step wrap-rate jump -> the collateral pool's residual share
        // far exceeds one period's stream capacity, so the harvest defers a backlog rather than depositing it all.
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD);
        _growPool(_poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD), MAX_FUZZ_USERS); // collateral pool only

        // Mint the late entrant's pegged NOW (its collateral folds into the corner yield) but hold it in-wallet, so the
        // leveraged pool is still empty at harvest #1 and takes no share of the backlog it will later skim.
        address lateEntrant = makeAddr("lateEntrant");
        uint256 levHeadroom = IStabilityPool_v3(stabilityPoolLeveraged).MAX_TOTAL_ASSET_SUPPLY() -
            IERC20(stabilityPoolLeveraged).totalSupply();
        uint256 levHold = _min(IERC20(pegged).balanceOf(stabilityPool), levHeadroom); // ~ the collateral pool's holding
        _mintPeggedAtLeast(levHold);
        IERC20(pegged).transfer(lateEntrant, levHold);

        currentRate = e.maxWrapRate; // one un-harvested min->max step: the largest yield the envelope declares
        mockOracle.setLatestAnswer(currentPrice, currentRate);

        address token = wrappedCollateral;
        uint256 capacityFresh = IMultipleRewardDistributor_v3(stabilityPool).maxDepositReward(token);
        uint256 harvestable0 = IMinter(minter).harvestable();
        if (capacityFresh == 0 || harvestable0 <= capacityFresh) {
            return; // this market's corner yield fits one period -> no backlog forms, nothing to prove
        }

        // Harvest #1: only the collateral pool holds, so it takes the whole residual (capped); the excess defers.
        address keeper = makeAddr("harvestKeeper");
        vm.startPrank(keeper);
        IStabilityPoolManager(stabilityPoolManager).harvest(keeper, 0);
        vm.stopPrank();
        uint256 backlog = IMinter(minter).harvestable();
        assertGt(backlog, 0, "harvest #1 deferred a backlog owed to the collateral pool");

        // The leveraged pool enters AFTER the backlog accrued.
        vm.startPrank(lateEntrant);
        IERC20(pegged).approve(stabilityPoolLeveraged, levHold);
        IStabilityPool(stabilityPoolLeveraged).deposit(levHold, lateEntrant, 0);
        vm.stopPrank();

        // Free the stream capacity, accrue NO fresh yield: the next harvest works the PURE backlog.
        vm.warp(block.timestamp + IMultipleRewardDistributor_v3(stabilityPool).REWARD_PERIOD_LENGTH() + 1);
        assertEq(IMinter(minter).harvestable(), backlog, "no fresh yield: harvestable is exactly the deferred backlog");

        // The leveraged pool's re-split share of the backlog clears the sub-period dust floor, so a zero receipt is the
        // fairness property under test, not the dust rule zeroing a tiny share.
        uint256 residualBacklog = backlog - (backlog * bountyRatio) / 1e18 - (backlog * cutRatio) / 1e18;
        uint256 total = IERC20(pegged).balanceOf(stabilityPool) + IERC20(pegged).balanceOf(stabilityPoolLeveraged);
        uint256 levUncapped = (residualBacklog * IERC20(pegged).balanceOf(stabilityPoolLeveraged)) / total;
        assertGt(
            levUncapped,
            IMultipleRewardDistributor_v3(stabilityPoolLeveraged).REWARD_PERIOD_LENGTH(),
            "the leveraged pool's re-split share clears the dust floor (so a zero receipt is fairness, not dust)"
        );

        // Harvest #2 on the pure backlog: measure what the late-entrant leveraged pool receives.
        uint256 levBefore = IERC20(token).balanceOf(stabilityPoolLeveraged);
        vm.startPrank(keeper);
        IStabilityPoolManager(stabilityPoolManager).harvest(keeper, 0);
        vm.stopPrank();
        uint256 levGot = IERC20(token).balanceOf(stabilityPoolLeveraged) - levBefore;

        assertEq(levGot, 0, "the deferred backlog is not re-split to a pool that held nothing when it accrued");
    }

    /// @notice A pool's deferred harvest backlog drains to THAT pool across periods, never to the co-pool. At the
    /// corner the collateral pool's residual share exceeds one period's capacity, so a backlog defers while only the
    /// collateral pool holds. The leveraged pool then enters and, over several draining harvests of the PURE backlog
    /// (no fresh yield), receives none of it - the whole backlog is owed to the collateral pool and streams only there.
    function test_harvest_owedDrainsToOwningPoolAcrossPeriods() public {
        uint256 bountyRatio = IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio();
        uint256 cutRatio = IStabilityPoolManager(stabilityPoolManager).harvestCutRatio();
        if (1e18 - bountyRatio - cutRatio == 0) {
            return; // full cut: nothing streams to the pools, so no backlog forms
        }
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD);
        _growPool(_poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD), MAX_FUZZ_USERS); // collateral pool only

        address lateEntrant = makeAddr("lateEntrantDrain");
        uint256 levHeadroom = IStabilityPool_v3(stabilityPoolLeveraged).MAX_TOTAL_ASSET_SUPPLY() -
            IERC20(stabilityPoolLeveraged).totalSupply();
        uint256 levHold = _min(IERC20(pegged).balanceOf(stabilityPool), levHeadroom);
        _mintPeggedAtLeast(levHold);
        IERC20(pegged).transfer(lateEntrant, levHold);

        currentRate = e.maxWrapRate;
        mockOracle.setLatestAnswer(currentPrice, currentRate);

        address token = wrappedCollateral;
        uint256 capacityFresh = IMultipleRewardDistributor_v3(stabilityPool).maxDepositReward(token);
        uint256 harvestable0 = IMinter(minter).harvestable();
        if (capacityFresh == 0 || harvestable0 <= capacityFresh) {
            return; // no backlog forms at this market's corner
        }

        address keeper = makeAddr("harvestKeeper");
        vm.startPrank(keeper);
        IStabilityPoolManager(stabilityPoolManager).harvest(keeper, 0);
        vm.stopPrank();
        assertGt(IMinter(minter).harvestable(), 0, "harvest #1 deferred a backlog owed to the collateral pool");

        // the leveraged pool enters AFTER the backlog accrued
        vm.startPrank(lateEntrant);
        IERC20(pegged).approve(stabilityPoolLeveraged, levHold);
        IStabilityPool(stabilityPoolLeveraged).deposit(levHold, lateEntrant, 0);
        vm.stopPrank();

        // drain the PURE backlog (no fresh yield) over several periods: it is owed to the collateral pool, so it
        // streams only there and the late-entrant leveraged pool receives none of it on ANY of these harvests.
        uint256 period = IMultipleRewardDistributor_v3(stabilityPool).REWARD_PERIOD_LENGTH();
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + period + 1);
            uint256 colBefore = IERC20(token).balanceOf(stabilityPool);
            uint256 levBefore = IERC20(token).balanceOf(stabilityPoolLeveraged);
            vm.startPrank(keeper);
            IStabilityPoolManager(stabilityPoolManager).harvest(keeper, 0);
            vm.stopPrank();
            assertEq(
                IERC20(token).balanceOf(stabilityPoolLeveraged) - levBefore,
                0,
                "the leveraged pool receives none of the collateral pool's backlog on any draining harvest"
            );
            assertGt(
                IERC20(token).balanceOf(stabilityPool) - colBefore,
                0,
                "the collateral pool's backlog drains to the collateral pool"
            );
        }
    }

    /// @notice Each harvest, the keeper bounty and the pools' net share are exactly their ratios of what left the
    /// minter: `bounty == bountyRatio × (harvestable decrease)` and `netToPools == residualRatio × (harvestable
    /// decrease)`. So a bounty receiver is never short-changed or over-paid relative to the harvestable consumed, and
    /// the cut (the remainder) is proportional too. Checked at a normal harvest AND at the deferred corner.
    function test_harvest_bountyMatchesHarvestableDecrease() public {
        uint256 bountyRatio = IStabilityPoolManager(stabilityPoolManager).harvestBountyRatio();
        uint256 cutRatio = IStabilityPoolManager(stabilityPoolManager).harvestCutRatio();
        uint256 residualRatio = 1e18 - bountyRatio - cutRatio;

        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(_nominalCollateralUSD(), _nominalWrapRate(), e.pegPriceUSD);
        _growPool(_poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD), MAX_FUZZ_USERS);
        _depositPeggedTo(stabilityPoolLeveraged, background, _poolPeggedFor(e.maxPoolValueUSD / 2, e.pegPriceUSD));

        address keeper = makeAddr("skimKeeper");

        // (a) a normal harvest: accrue a little yield, then check the skim matches the harvestable decrease
        currentRate = (currentRate * 1001) / 1000;
        mockOracle.setLatestAnswer(currentPrice, currentRate);
        _assertSkimMatchesHarvestableDrop(keeper, bountyRatio, residualRatio);

        // (b) a deferred corner harvest: the same invariant must hold when the pools cap and the excess defers
        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD);
        currentRate = e.maxWrapRate;
        mockOracle.setLatestAnswer(currentPrice, currentRate);
        _assertSkimMatchesHarvestableDrop(keeper, bountyRatio, residualRatio);
    }

    /// @dev Harvest once (as `keeper`) and assert the keeper bounty and the pools' net receipt are the bounty/residual
    /// ratio slices of the harvestable decrease. Tolerance ~8 wei: the swept total is the sum of up to five floored
    /// parts (bounty, cut, two pool nets, treasury), so it trails the exact gross by ≤ 5 wei, and the ratio check by
    /// ≤ that × the ratio + 1. Single external call under the prank (the harvest); balances read outside it.
    function _assertSkimMatchesHarvestableDrop(address keeper, uint256 bountyRatio, uint256 residualRatio) internal {
        address token = wrappedCollateral;
        uint256 harvestableBefore = IMinter(minter).harvestable();
        uint256 keeperBefore = IERC20(token).balanceOf(keeper);
        uint256 poolsBefore = IERC20(token).balanceOf(stabilityPool) + IERC20(token).balanceOf(stabilityPoolLeveraged);
        vm.startPrank(keeper);
        IStabilityPoolManager(stabilityPoolManager).harvest(keeper, 0);
        vm.stopPrank();
        uint256 drop = harvestableBefore - IMinter(minter).harvestable();
        uint256 bounty = IERC20(token).balanceOf(keeper) - keeperBefore;
        uint256 netToPools = (IERC20(token).balanceOf(stabilityPool) +
            IERC20(token).balanceOf(stabilityPoolLeveraged)) - poolsBefore;
        assertApproxEqAbs(
            bounty,
            Math.mulDiv(drop, bountyRatio, 1e18),
            8,
            "bounty == bountyRatio x harvestable decrease"
        );
        assertApproxEqAbs(
            netToPools,
            Math.mulDiv(drop, residualRatio, 1e18),
            8,
            "net to pools == residualRatio x harvestable decrease"
        );
    }

    /// @notice maxDepositReward is the conservative deposit capacity `cap - committed`, where `cap` is the smaller of
    /// the rate-field capacity (`uint128.max * REWARD_PERIOD_LENGTH`) and the reward-integral capacity (which keeps the
    /// accumulated per-share integral inside uint256). On the envelope pools the integral cap binds, so `cap` sits
    /// strictly below the field cap. A fresh stream offers the full `cap`; after a reward is streamed it drops by
    /// exactly `committed = queued + rate * period`. This is the value the harvest caps each pool's deposit against, so
    /// `depositReward` can overflow neither the rate field nor the reward integral. (The exact cap boundary - that a
    /// deposit of `cap` is the largest that keeps the integral safe - is pinned in the discrimination test.)
    function test_maxDepositReward_conservativeBound() public {
        uint256 period = IMultipleRewardDistributor_v3(stabilityPool).REWARD_PERIOD_LENGTH();
        uint256 fieldCap = uint256(type(uint128).max) * period;

        // A fresh stream (nothing queued or streaming) offers the full cap. On the envelope pools the reward-integral
        // cap binds strictly below the rate-field cap - a regression dropping the integral bound would return fieldCap.
        // `cap` is a constant here (the integral cap uses the immutable MIN_TOTAL_ASSET_SUPPLY, not live share), so it
        // is a valid reference for the post-stream assertion below.
        uint256 cap = IMultipleRewardDistributor_v3(stabilityPool).maxDepositReward(wrappedCollateral);
        assertLt(cap, fieldCap, "integral cap binds below the rate-field cap");
        assertGt(cap, 0, "cap is positive");

        // stream a reward, then the capacity drops by exactly committed = queued + rate * period
        address spOwner = IBaoOwnable(stabilityPool).owner();
        uint256 depositorRole = IMultipleRewardDistributor_v3(stabilityPool).REWARD_DEPOSITOR_ROLE();
        vm.startPrank(spOwner);
        IBaoRoles(stabilityPool).grantRoles(address(this), depositorRole);
        vm.stopPrank();
        uint256 reward = 1e24; // well within the cap, so depositReward streams it without overflowing
        deal(wrappedCollateral, address(this), reward);
        IERC20(wrappedCollateral).approve(stabilityPool, reward);
        IMultipleRewardDistributor_v3(stabilityPool).depositReward(wrappedCollateral, reward);

        (, , uint256 rate, uint256 queued) = IMultipleRewardDistributor_v3(stabilityPool).rewardData(wrappedCollateral);
        uint256 committed = queued + rate * period;
        assertEq(
            IMultipleRewardDistributor_v3(stabilityPool).maxDepositReward(wrappedCollateral),
            cap - committed,
            "streamed: capacity is cap minus the committed reward"
        );
    }

    /// @notice The reward-integral cap derives from the IMMUTABLE pool floor, never the live share. A deposited reward
    /// streams and is accumulated LATER (`_accumulateReward`) against the total share as it stands THEN - which may by
    /// then have fallen back to the floor - so sizing the cap off the live share would under-protect in exactly the
    /// case the cap exists for. Growing the live share orders of magnitude clear of the floor must therefore leave the
    /// cap untouched; an implementation reading the live share would scale it by that same factor. Deliberately
    /// formula-free: re-deriving `integralCap` here would copy `_REWARD_PRECISION`/`_INTEGRAL_HEADROOM` (both internal)
    /// and could only re-assert the implementation against itself.
    function test_maxDepositReward_capIndependentOfLiveShare() public {
        uint256 floor = IStabilityPool(stabilityPool).MIN_TOTAL_ASSET_SUPPLY();
        uint256 capBefore = IMultipleRewardDistributor_v3(stabilityPool).maxDepositReward(wrappedCollateral);
        assertGt(capBefore, 0, "precondition: a fresh stream offers a positive cap");

        // Grow the live share orders of magnitude clear of the floor, so a live-share cap would differ materially.
        _depositPeggedTo(stabilityPool, address(this), 1000 * floor);
        assertGt(
            IERC20(stabilityPool).totalSupply() / floor,
            100,
            "precondition: the live share sits orders of magnitude above the floor"
        );

        assertEq(
            IMultipleRewardDistributor_v3(stabilityPool).maxDepositReward(wrappedCollateral),
            capBefore,
            "the cap must derive from the immutable floor, not the live share"
        );
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

    /// @notice A pool sweep-capped at its MIN floor makes a single rebalance under-restore the collateral ratio, and
    /// the shortfall is recovered by the co-pool on a later rebalance. The pegged balance is the deficit ledger: a
    /// floored pool retains its pegged and drops to MIN, so the holdings-weighted split hands the co-pool a larger share
    /// on the next call until the CR is restored. The sequence converges to the threshold - the same end state a single
    /// uncapped liquidation targets. This characterises the CURRENT recovery-across-calls (unlike harvest, which leaks);
    /// the batch-3 in-call pickup makes a single rebalance suffice.
    function test_rebalance_flooredPoolShortfallRecoversAcrossCalls() public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(_nominalCollateralUSD(), _nominalWrapRate(), e.pegPriceUSD);

        // A small collateral pool (floors early) beside a large leveraged pool with ample headroom to absorb the
        // shortfall.
        uint256 minSupply = IStabilityPool(stabilityPool).MIN_TOTAL_ASSET_SUPPLY();
        _growPool(minSupply * 10, 1); // small collateral pool
        uint256 levHeadroom = IStabilityPool_v3(stabilityPoolLeveraged).MAX_TOTAL_ASSET_SUPPLY() -
            IERC20(stabilityPoolLeveraged).totalSupply();
        uint256 levHold = _min(minSupply * 1_000_000, levHeadroom / 2);
        _depositPeggedTo(stabilityPoolLeveraged, background, levHold);
        _mintLeveragedBuffer(levHold); // start the CR healthy so it can be dropped

        // Drop deep below the threshold so the required liquidation exceeds the small collateral pool's headroom and it
        // floors on the first rebalance.
        _dropPriceBelowRebalanceThreshold();
        for (uint256 i = 0; i < 6; i++) {
            currentPrice = (currentPrice * 6) / 10;
            mockOracle.setLatestAnswer(currentPrice, currentRate);
        }
        if (!IStabilityPoolManager(stabilityPoolManager).rebalanceable()) {
            return; // the drop over/under-shot for this market's config; the scenario is not set up
        }

        address keeper = makeAddr("rebalanceKeeper");
        uint256 calls;
        bool flooredAndUnderRestoredFirst;
        for (uint256 i = 0; i < 20 && IStabilityPoolManager(stabilityPoolManager).rebalanceable(); i++) {
            vm.startPrank(keeper);
            IStabilityPoolManager(stabilityPoolManager).rebalance(keeper, 0);
            vm.stopPrank();
            calls++;
            if (calls == 1) {
                flooredAndUnderRestoredFirst =
                    IERC20(stabilityPool).totalSupply() == minSupply &&
                    IStabilityPoolManager(stabilityPoolManager).rebalanceable();
            }
        }

        console2.log("R1 rebalance calls to converge =", calls);
        assertFalse(
            IStabilityPoolManager(stabilityPoolManager).rebalanceable(),
            "the rebalance sequence restores the collateral ratio to the threshold (deficit self-corrects)"
        );
        assertTrue(
            flooredAndUnderRestoredFirst,
            "the small pool floored and the first rebalance under-restored the collateral ratio"
        );
        assertGt(
            calls,
            1,
            "recovery takes more than one rebalance (the co-pool picks up the shortfall on a later call)"
        );
    }

    /// @notice A corner rebalance does not overflow the reward integral. The rebalance liquidation reward is
    /// distributed immediately through `_accumulateReward`, which - unlike the streamed harvest path's
    /// `maxDepositReward` - has NO upper cap, so it either executes or overflow-reverts. A rebalance is time-critical
    /// and must execute. At the cheapest wrapped collateral (which maximises the collateral `returned`, the worst case
    /// for the integral) the rebalance delivers its reward without reverting, and the margin to overflow (a single
    /// immediate accrual overflows only ~1e6x above the streamed integral-safe cap) is the room the batch-3 in-call
    /// shortfall-pickup must stay within.
    function test_rebalance_cornerLiquidationDoesNotOverflowIntegral() public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(_nominalCollateralUSD(), e.minWrapRate, e.pegPriceUSD);
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD);
        _growPool(poolPegged, MAX_FUZZ_USERS);
        _mintLeveragedBuffer(poolPegged);
        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD); // cheapest wrapped: CR below threshold + max returned
        if (!IStabilityPoolManager(stabilityPoolManager).rebalanceable()) {
            return; // this market's corner does not drop the CR below the threshold
        }

        uint256 capIntegral = IMultipleRewardDistributor_v3(stabilityPool).maxDepositReward(wrappedCollateral);
        uint256 injected = _rebalance();

        assertGt(injected, 0, "the corner rebalance executes and delivers a reward - no reward-integral overflow");
        console2.log("R2 corner injected         =", injected);
        console2.log("R2 corner maxDepositReward =", capIntegral);
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

    /// @notice The whale can actually CLAIM the concentrated reward - not just read it. `peakPendingRewards_holds` reads
    /// the uint256 `claimable` VIEW, which never overflows; a claim CHECKPOINTS `pending = claimable.toUint128()`, so a
    /// concentrated reward that exceeds the uint128 `pending` field reverts the claim - a DoS the view hides. Within the
    /// declared envelope (collateral >= $1e-6) the claim succeeds and returns ~the whole reward; the hyperinflated-
    /// collateral stretch pushes the reward token count `poolValueUSD / wrappedUSD` past uint128.max, and this locates
    /// whether `ClaimData.pending` genuinely overflows there.
    function test_envelope_peakPending_whaleCanClaim() public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(_nominalCollateralUSD(), e.minWrapRate, e.pegPriceUSD);
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD);
        _growPool(poolPegged, 1); // the whole pool in ONE holder (users[0]); the MIN_DEPOSIT seed is the only other
        _mintLeveragedBuffer(poolPegged);

        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD); // cheapest wrapped: max reward count
        if (!IStabilityPoolManager(stabilityPoolManager).rebalanceable()) {
            return; // this market's corner does not drive the collateral ratio below the rebalance threshold
        }
        uint256 injected = _rebalance();
        assertGt(injected, 0, "rebalance delivered the whole-pool collateral reward at the corner");

        address[] memory rewardTokens = new address[](1);
        rewardTokens[0] = wrappedCollateral;
        uint256 whaleClaimable = IClaimReward(stabilityPool).claimable(users[0], rewardTokens)[0];
        emit log_named_uint("whale claimable (view, uint256)", whaleClaimable);
        emit log_named_uint("uint128.max", type(uint128).max);

        // the claim STORES pending = claimable.toUint128(); if the concentrated reward exceeds uint128.max the claim
        // reverts (the field limit the view above cannot show)
        uint256 balBefore = IERC20(wrappedCollateral).balanceOf(users[0]);
        vm.startPrank(users[0]);
        IClaimReward(stabilityPool).claim();
        vm.stopPrank();
        uint256 claimed = IERC20(wrappedCollateral).balanceOf(users[0]) - balBefore;
        assertGe(claimed, whaleClaimable / 2, "the whale claimed ~the whole concentrated reward");
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
        uint256 envelopePool = _capToSupplyHeadroom(_poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD));

        // pool swept big, up to the supply field's own width; grown in its own unit so exceeding that field (the 2a
        // deposit/supply limit, cross-confirmed here) is recorded and stops this run rather than masking a reward find.
        uint256 poolPegged = _logScale(poolSeed, IStabilityPool(stabilityPool).MIN_DEPOSIT(), type(uint128).max);
        try this.growProbe(poolPegged) {
            // pool grew - proceed to stress the reward path
        } catch (bytes memory err) {
            string memory reason = _revertReason(err);
            _record("rebalance", poolPegged, "broke", string.concat("grow: ", reason));
            // within the declared envelope the pool MUST grow; a revert there is a real break, not a located limit
            if (poolPegged <= envelopePool) {
                assertTrue(
                    false,
                    string.concat("within-envelope grow reverted @ pool=", vm.toString(poolPegged), ": ", reason)
                );
            }
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
            string memory reason = _revertReason(err);
            _record("rebalance", poolPegged, "broke", reason);
            // within the declared envelope the rebalance MUST hold; a revert there is a real break, not a located limit
            if (poolPegged <= envelopePool) {
                assertTrue(
                    false,
                    string.concat("within-envelope rebalance reverted @ pool=", vm.toString(poolPegged), ": ", reason)
                );
            }
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

        uint256 envelopePool = _capToSupplyHeadroom(_poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD));
        uint256 poolPegged = _logScale(poolSeed, IStabilityPool(stabilityPool).MIN_DEPOSIT(), type(uint128).max);
        try this.growProbe(poolPegged) {
            // pool grew - proceed to stress the streamed reward path
        } catch (bytes memory err) {
            string memory reason = _revertReason(err);
            _record("harvest", poolPegged, "broke", string.concat("grow: ", reason));
            // within the declared envelope the pool MUST grow; a revert there is a real break, not a located limit
            if (poolPegged <= envelopePool) {
                assertTrue(
                    false,
                    string.concat("within-envelope grow reverted @ pool=", vm.toString(poolPegged), ": ", reason)
                );
            }
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
            string memory reason = _revertReason(err);
            _record("harvest", poolPegged, "broke", reason);
            // within the declared envelope the harvest MUST hold - EXCEPT NoHarvestable, the benign no-op where the
            // yield rounds to zero (e.g. the prod-fee market's pool share is zero), which is not a break. Any OTHER
            // within-envelope revert is a real break.
            if (poolPegged <= envelopePool && keccak256(bytes(reason)) != keccak256(bytes("no-harvestable"))) {
                assertTrue(
                    false,
                    string.concat("within-envelope harvest reverted @ pool=", vm.toString(poolPegged), ": ", reason)
                );
            }
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

        uint256 envelopePool = _capToSupplyHeadroom(_poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD));
        uint256 poolPegged = _logScale(poolSeed, IStabilityPool(stabilityPool).MIN_DEPOSIT(), type(uint128).max);
        try this.growProbe(poolPegged) {
            // pool grew - proceed to inject and claim
        } catch (bytes memory err) {
            string memory reason = _revertReason(err);
            _record("claim", poolPegged, "broke", string.concat("grow: ", reason));
            // within the declared envelope the pool MUST grow; a revert there is a real break, not a located limit
            if (poolPegged <= envelopePool) {
                assertTrue(
                    false,
                    string.concat("within-envelope grow reverted @ pool=", vm.toString(poolPegged), ": ", reason)
                );
            }
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
            string memory reason = _revertReason(err);
            _record("claim", poolPegged, "broke", reason);
            // within the declared envelope the claim MUST hold; a revert there is a real break, not a located limit
            if (poolPegged <= envelopePool) {
                assertTrue(
                    false,
                    string.concat("within-envelope claim reverted @ pool=", vm.toString(poolPegged), ": ", reason)
                );
            }
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

/// @notice ETH::fxUSD market — the seed envelope. The config-corner sibling markets below each stretch one deployment
/// parameter (production fees, a huge minimum-deposit floor, the maximum early-withdrawal fee, the tightest rebalance
/// threshold) off this baseline and re-run the whole suite against it.
contract StabilityPoolEnvelope_ETH_fxUSD is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory) {
        return EnvelopeLib.ethFxUSD();
    }

    function _marketSlug() internal pure override returns (string memory) {
        return "ethFxUSD";
    }
}

// ─── config-corner markets: each stretches ONE deployment-config param off the measurement baseline and re-runs the
// ENTIRE suite (every fuzz walk, sweep, and corner) against it; each writes its own tmp/sp-constraints-<slug>.csv so a
// break is attributed to the config that produced it ───

/// @notice ETH peg with a huge minimum-deposit floor (1e6 tokens = $1M at the nominal $1 peg): the floor interactions
/// (seed, full exits down to the floor, loss headroom above it) exercised at the opposite extreme. minTotalSupply is
/// carried on BOTH this peg and its market (below) - the SP deploy reads the MARKET, and the config-integrity test
/// asserts the two agree so an override can never again land on a config object the deploy ignores.
contract ConfigPeg_ETH_minDepositHuge is ConfigPeg_ETH {
    function minDeposit() public pure override returns (uint256) {
        return 1e24;
    }

    function minTotalSupply() public pure override returns (uint256) {
        return 1e24;
    }
}

/// @notice Early-withdrawal fee at the maximum the pool accepts (100%). Every probe exits INSIDE the no-fee window,
/// so green means the fee is never charged where it must not be - any accidental in-window fee charge breaks a
/// round-trip loudly at this tripwire value.
contract ConfigMarket_ETH_fxUSD_earlyWithdrawalFeeMax is ConfigMarket_ETH_fxUSD_zeroFeesAndBounties {
    function stabilityPoolEarlyWithdrawalFeeRatio() public pure override returns (uint256) {
        return 1 ether;
    }
}

/// @notice Rebalance threshold lowered to 1.05x (the tightest production volatility tier): rebalances arm much later,
/// so the corner rebalances fire from a far thinner collateral cushion.
contract ConfigMarket_ETH_fxUSD_rebalanceThreshold105 is ConfigMarket_ETH_fxUSD_zeroFeesAndBounties {
    function rebalanceThreshold() public pure override returns (uint256) {
        return 1.05e18;
    }
}

/// @notice Minimum-supply floor at the huge extreme (1e6 tokens = $1M), overridden on the MARKET config - the object
/// the SP deploy actually reads (the peg-only override the prior variant used was silently ignored; the
/// config-integrity test now forbids that). A large floor keeps the ceiling MAX = MIN * FACTOR_PRECISION saturated at
/// the field width, so the reward-integral cap never binds here - the opposite corner from the reachable-cap markets.
contract ConfigMarket_ETH_fxUSD_minDepositHuge is ConfigMarket_ETH_fxUSD_zeroFeesAndBounties {
    function minTotalSupply() public pure override returns (uint256) {
        return 1e24;
    }
}

/// @notice A realistic keeper bounty (1%) with no protocol cut, so a large harvest residual (99%) still reaches the
/// pools AND a real bounty flows - the only config that exercises the harvest's bounty path against a deferred pool
/// deposit. Zero-fee proves the pool mechanics and prodFees proves the shipped skims; this proves the bounty is capped
/// at the SAME rate as the pool deposit (never skimmed off the deferred backlog) and that recovery holds at any bounty.
contract ConfigMarket_ETH_fxUSD_testBounty is ConfigMarket_ETH_fxUSD_zeroFeesAndBounties {
    function harvestBountyRatio() public pure override returns (uint256) {
        return 1e16; // 1%
    }
}

/// @notice A realistic protocol cut (1%) with no keeper bounty, so a large harvest residual (99%) still reaches the
/// pools AND a real cut flows - the cut's counterpart to `_testBounty`. Proves the cut is capped at the SAME rate as
/// the pool deposit (never skimmed off the deferred backlog); the harvest's skim fix caps bounty and cut identically,
/// so this isolates the cut half of it.
contract ConfigMarket_ETH_fxUSD_testCut is ConfigMarket_ETH_fxUSD_zeroFeesAndBounties {
    function harvestCutRatio() public pure override returns (uint256) {
        return 1e16; // 1%
    }
}

/// @notice The PRODUCTION ETH::fxUSD market unmodified (1% keeper bounties, 99% harvest cut): the zeroed-fee baseline
/// proves the pool mechanics, this proves the SHIPPED config - the same envelope must hold with the production skims
/// in place (a harvest's direct pool share is zero here; the cut returns via the FeeReceiver split).
contract StabilityPoolEnvelope_ETH_fxUSD_prodFees is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory) {
        return EnvelopeLib.ethFxUSD();
    }

    function _marketSlug() internal pure override returns (string memory) {
        return "ethFxUSD_prodFees";
    }

    function createETHMintersConfig() internal override returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_mainnet();
    }
}

contract StabilityPoolEnvelope_ETH_fxUSD_testBounty is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory) {
        return EnvelopeLib.ethFxUSD();
    }

    function _marketSlug() internal pure override returns (string memory) {
        return "ethFxUSD_testBounty";
    }

    function createETHMintersConfig() internal override returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_testBounty();
    }
}

contract StabilityPoolEnvelope_ETH_fxUSD_testCut is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory) {
        return EnvelopeLib.ethFxUSD();
    }

    function _marketSlug() internal pure override returns (string memory) {
        return "ethFxUSD_testCut";
    }

    function createETHMintersConfig() internal override returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_testCut();
    }
}

// A minDeposit=1-wei envelope variant is intentionally ABSENT: MAX = MIN * FACTOR_PRECISION ties the supply ceiling to
// the floor, so a 1-wei MIN caps the whole pool at ~$1 and the base suite's realistic-pool tests (rebalance, harvest,
// max-users, the field-width corners) cannot run. A low-floor deploy variant that also runs those tests cannot exist;
// the MIN=1 cap/floor behaviour is instead pinned by the deterministic mock tests in StabilityPoolLedgerGap.

contract StabilityPoolEnvelope_ETH_fxUSD_minDepositHuge is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory) {
        return EnvelopeLib.ethFxUSD();
    }

    function _marketSlug() internal pure override returns (string memory) {
        return "ethFxUSD_minDepositHuge";
    }

    function createETHMintersConfig() internal override returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH_minDepositHuge();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_minDepositHuge();
    }
}

contract StabilityPoolEnvelope_ETH_fxUSD_feeMax is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory) {
        return EnvelopeLib.ethFxUSD();
    }

    function _marketSlug() internal pure override returns (string memory) {
        return "ethFxUSD_feeMax";
    }

    function createETHMintersConfig() internal override returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_earlyWithdrawalFeeMax();
    }
}

contract StabilityPoolEnvelope_ETH_fxUSD_rebalance105 is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory) {
        return EnvelopeLib.ethFxUSD();
    }

    function _marketSlug() internal pure override returns (string memory) {
        return "ethFxUSD_rebalance105";
    }

    function createETHMintersConfig() internal override returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_rebalanceThreshold105();
    }
}

// ─── D2: per-peg-MIN markets - the ETH::fxUSD deploy config priced at a range of peg SCALES, each with MIN sized ~$1
// at its nominal peg (MIN = 1e18 / pegDollars), so a CORRECTLY-DEPLOYED market at that scale is proved to hold a full
// $-range pool. This is the "diverse markets, each deployed for its peg" axis (A.6), distinct from ethFxUSD's
// frozen-MIN wide-peg drift. Real deployed scales mirror their A.6 MINs; extreme scales are invented for
// future/hypothetical markets ───

contract ConfigPeg_ETH_min1e13 is ConfigPeg_ETH {
    function minDeposit() public pure override returns (uint256) {
        return 1e13;
    }

    function minTotalSupply() public pure override returns (uint256) {
        return 1e13;
    }
}

contract ConfigMarket_ETH_fxUSD_min1e13 is ConfigMarket_ETH_fxUSD_zeroFeesAndBounties {
    function minTotalSupply() public pure override returns (uint256) {
        return 1e13;
    }
}

/// @notice BTC-scale market: the deployed BTC peg's MIN (1e13, per A.6) priced at ~$1e5 (BTC). A correctly-deployed
/// high-value-peg market must hold the same $-range pool as a $1 market.
contract StabilityPoolEnvelope_btcScale is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory) {
        return EnvelopeLib.atPegScale(1e5 ether, "btcScale");
    }

    function _marketSlug() internal pure override returns (string memory) {
        return "btcScale";
    }

    function createETHMintersConfig() internal override returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH_min1e13();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_min1e13();
    }
}

contract ConfigPeg_ETH_min1e27 is ConfigPeg_ETH {
    function minDeposit() public pure override returns (uint256) {
        return 1e27;
    }

    function minTotalSupply() public pure override returns (uint256) {
        return 1e27;
    }
}

contract ConfigMarket_ETH_fxUSD_min1e27 is ConfigMarket_ETH_fxUSD_zeroFeesAndBounties {
    function minTotalSupply() public pure override returns (uint256) {
        return 1e27;
    }
}

/// @notice Hyperinflation-scale market (invented): a peg devalued to ~$1e-9, deployed with a MIN of 1e27 (= ~$1 at
/// that peg). The token count for any real value is enormous, so MAX = MIN * FACTOR_PRECISION saturates at the uint128
/// supply field - the pool holds up to the field, and a correctly-deployed hyperinflated market still round-trips.
contract StabilityPoolEnvelope_hyperScale is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory) {
        return EnvelopeLib.atPegScale(1e-9 ether, "hyperScale");
    }

    function _marketSlug() internal pure override returns (string memory) {
        return "hyperScale";
    }

    function createETHMintersConfig() internal override returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH_min1e27();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_min1e27();
    }
}

/// @notice STRETCH beyond the declared envelope (invented): a hyperinflated PEG (~$1e-9) AND hyperinflated COLLATERAL
/// (~$1e-12) - a market whose collateral is itself a devaluing unit, not just the peg. The reward token count for any
/// real value is `poolValueUSD / wrappedUSD`, so a micro-priced collateral makes it enormous, pushing a single holder's
/// concentrated reward past the uint128 `ClaimData.pending` field. The current envelope stops the collateral axis at
/// $1e-6 (reward threshold ~$340B, unreachable); this drops it to $1e-12 (threshold ~$340K) to probe whether `pending`
/// genuinely overflows on a claim. Same MIN=1e27 config as hyperScale so MAX and maxDepositReward are large enough that
/// the reward is not capped below the field first.
contract StabilityPoolEnvelope_hyperCollateral is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory e) {
        e = EnvelopeLib.atPegScale(1e-9 ether, "hyperCollateral");
        // STRETCH: the WHOLE collateral range is hyperinflated (persistently < the declared $1e-6 floor), so the
        // nominal MINT price sqrt(min*max) is cheap and the minter holds an enormous collateral token count
        e.minCollateralUSD = 1e-12 ether;
        e.maxCollateralUSD = 1e-6 ether;
    }

    function _marketSlug() internal pure override returns (string memory) {
        return "hyperCollateral";
    }

    function createETHMintersConfig() internal override returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH_min1e27();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_min1e27();
    }
}

contract ConfigPeg_ETH_min1e18 is ConfigPeg_ETH {
    function minDeposit() public pure override returns (uint256) {
        return 1e18;
    }

    function minTotalSupply() public pure override returns (uint256) {
        return 1e18;
    }
}

contract ConfigMarket_ETH_fxUSD_min1e18 is ConfigMarket_ETH_fxUSD_zeroFeesAndBounties {
    function minTotalSupply() public pure override returns (uint256) {
        return 1e18;
    }
}

/// @notice EUR-scale market: the deployed EUR peg's MIN (1e18, per A.6) priced at ~$1 (a fiat-parity peg).
contract StabilityPoolEnvelope_eurScale is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory) {
        return EnvelopeLib.atPegScale(1 ether, "eurScale");
    }

    function _marketSlug() internal pure override returns (string memory) {
        return "eurScale";
    }

    function createETHMintersConfig() internal override returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH_min1e18();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_min1e18();
    }
}

/// @notice ETH-scale market: the DEFAULT config MIN (2e14) priced at its real ~$5000 peg - the correctly-deployed
/// haETH market itself (the config's MIN is sized for exactly this peg), so it inherits the base's default config.
contract StabilityPoolEnvelope_ethScale is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory) {
        return EnvelopeLib.atPegScale(5000 ether, "ethScale");
    }

    function _marketSlug() internal pure override returns (string memory) {
        return "ethScale";
    }
}

contract ConfigPeg_ETH_min1e9 is ConfigPeg_ETH {
    function minDeposit() public pure override returns (uint256) {
        return 1e9;
    }

    function minTotalSupply() public pure override returns (uint256) {
        return 1e9;
    }
}

contract ConfigMarket_ETH_fxUSD_min1e9 is ConfigMarket_ETH_fxUSD_zeroFeesAndBounties {
    function minTotalSupply() public pure override returns (uint256) {
        return 1e9;
    }
}

/// @notice Rich-scale market (invented): an appreciated / high-unit-value peg at ~$1e9, deployed with MIN 1e9 (= ~$1
/// there) - which sits at the dust-share precision floor, so this market also probes the low-MIN edge.
contract StabilityPoolEnvelope_richScale is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory) {
        return EnvelopeLib.atPegScale(1e9 ether, "richScale");
    }

    function _marketSlug() internal pure override returns (string memory) {
        return "richScale";
    }

    function createETHMintersConfig() internal override returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH_min1e9();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_min1e9();
    }
}
