// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {console2} from "forge-std/console2.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {DecrementalFloatingPoint_v2} from "@harbor/math/DecrementalFloatingPoint_v2.sol";

import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {IMultipleRewardDistributor_v3} from "@harbor/interfaces/IMultipleRewardDistributor_v3.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {MarketActions} from "@harbor-test/harness/MarketActions.sol";
import {StabilityPoolActions} from "@harbor-test/harness/StabilityPoolActions.sol";
import {MarketAddresses} from "@harbor-test/harness/MarketAddresses.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";
import {ConfigCollateral_fxUSD_mainnet} from "@harbor-script/config/collaterals/ConfigCollateral_fxUSD_mainnet.sol";
import {ConfigMarket_ETH_fxUSD_mainnet} from "@harbor-script/config/markets/ConfigMarket_ETH_fxUSD_mainnet.sol";
import {ConfigMarket_ETH_fxUSD_zeroFeesAndBounties} from "@harbor-test/config/ConfigMarket_ETH_fxUSD_zeroFeesAndBounties.sol";
import {ConfigPeg_ETH} from "@harbor-script/config/pegs/ConfigPeg_ETH.sol";
import {StabilityPoolConservation} from "@harbor-test/StabilityPoolConservation.sol";
import {RevertReason} from "@harbor-test/RevertReason.sol";

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
    uint256 maxPoolUsers; // declared depositor cap, not enumerated: holders are mapping entries (see the crowd test)
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
            name: "10B, 1e3, 1e3, 1e2",
            maxPoolValueUSD: 1e10 ether, // $10B
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

    /// @dev A per-peg-MIN market: the ethFxUSD envelope re-centred on `nominalPeg` with a modest ~3x band (the
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

/// @notice Envelope-fit harness: stands up the REAL protocol (Minter + StabilityPool + StabilityPoolManager) via the
/// production `deployForPeg` scripts, arranges a starting state, then drives user/keeper actions against it and reads
/// every result back for correctness — the minter-test discipline that surfaces truncation and rounding. Green means
/// the protocol HOLDS the whole envelope; a revert or a mismatched read-back at an envelope-reachable point is the
/// where-it-breaks finding, to be fixed (SafeCast / widen) or the documented envelope narrowed — never asserted as
/// intended behaviour. Each derived contract is one named, documented market; `buildEnvelope()` is the seam.
///
/// The suite drives deposit, withdraw, harvest, and rebalance against the arranged state — each a fuzz walk plus a
/// deterministic corner, including the reward-field corner that the harvest and rebalance rewards reach.
abstract contract StabilityPoolEnvelopeBase is BaoTest, StabilityPoolConservation, RevertReason {
    /// @dev The deploy run that stands the market up, held rather than inherited (see `HarborDeployRun`).
    HarborDeployRun internal deployRun;

    // capped so the fuzz stays feasible; the many-holder case is the deterministic crowd test below rather than
    // every fuzz run.
    uint256 internal constant MAX_FUZZ_USERS = 8;

    /// @dev The separate holders the many-holder corner deposits for. Above the two the reward integral can tell
    ///      apart, the count exercises nothing new (see `test_envelope_crowdOfHolders_holds`); a hundred keeps the
    ///      per-holder flooring a visible part of the conservation bound without the minutes the declared cap cost.
    uint256 internal constant CROWD_SIZE = 100;

    /// @dev The collateral ratio a market stands up at: Genesis' equal halves of pegged and leveraged put it at 2, and
    /// the pegged tranche that follows brings it to 1.5 - mid-band on the fee schedules, and a leveraged buffer able
    /// to absorb a third of the collateral's value before the pegged is touched.
    uint256 internal constant DEPLOY_COLLATERAL_RATIO = 1.5 ether;

    address internal minter;
    address internal stabilityPool; // the collateral-side StabilityPool
    address internal stabilityPoolLeveraged; // the leveraged-side StabilityPool (harvest splits across both)
    address internal stabilityPoolManager;
    address internal pegged;
    address internal leveraged;
    address internal wrappedCollateral;

    MockWrappedPriceOracle internal mockOracle;
    /// @dev What the envelope does to its market - see `MarketActions`. Made once the minter and its mock oracle exist,
    ///      before the snapshot the tests rewind to, so a rewind keeps it.
    MarketActions internal marketActions;
    /// @dev Liquidates the pool as this contract, which holds its rebalancer role to arrange prior losses. Made beside
    ///      `marketActions`, before the snapshot, for the same reason.
    StabilityPoolActions internal poolActions;
    uint256 internal currentPrice; // 1e18-scaled, set by _setEnvelopePoint
    uint256 internal currentRate;

    address[] internal users; // MAX_FUZZ_USERS deposit actors
    address internal background; // holds the arranged pre-existing deposit

    /// @dev The deployment with its actors in place and no capital yet, so a test can fund its market under
    ///      its own conditions rather than under the nominal ones `setUp` uses. Set once, never changed.
    uint256 internal preFundingState;

    function buildEnvelope() internal pure virtual returns (Envelope memory);

    /// @dev A short filesystem-safe market identifier, so each market's stress sweep writes its own constraints CSV
    /// (tmp/sp-constraints-<slug>.csv); separate files keep parallel test contracts from racing on one file.
    function _marketSlug() internal pure virtual returns (string memory);

    /// @dev The envelope's own config: the production ETH peg plus a zeroed-fee variant of the ETH::fxUSD market, so the
    /// pool mechanics are measured without the StabilityPoolManager's harvest cut or bounties skimming value from
    /// depositors. Overriding this (rather than editing the production config) keeps the whole config test-owned; a
    /// derived market that sweeps a config axis (Batch 2) overrides it to build its own config.
    function createETHMintersConfig() internal virtual returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_zeroFeesAndBounties();
    }

    function setUp() public virtual {
        // ── stand up the real protocol via the production deploy scripts (RebalanceFairness model) ──
        // The run registers itself as the factory operator and deploys on its own account, as the production
        // multisig; the only mainnet state the deploy needs is the collateral pair, so mock those two tokens and run
        // with no fork.
        deployRun = new HarborDeployRun(
            HARBOR_MULTISIG,
            HARBOR_MULTISIG,
            "envelope_test",
            "mainnet",
            HarborDeployRun.Cut.Whole
        );
        deployRun.ensureFactory();

        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        // mock the collateral pair at the config's own addresses so the deploy wires to local mocks, not mainnet
        address underlyingToken = ConfigCollateral_fxUSD_mainnet(address(mktConfigs[0])).collateralToken();
        address wrappedToken = ConfigCollateral_fxUSD_mainnet(address(mktConfigs[0])).wrappedCollateralToken();
        vm.etch(underlyingToken, address(new MockERC20("fxUSD", "fxUSD", 18)).code); // decimals is immutable -> in code
        vm.etch(wrappedToken, address(new MockERC20("fxSAVE", "fxSAVE", 18)).code);
        Config_MinterMarket[] memory toDeploy = new Config_MinterMarket[](1);
        toDeploy[0] = mktConfigs[0]; // the fxUSD market
        deployRun.deploy(peg, mktConfigs, true, toDeploy);

        MarketAddresses memory addresses = deployRun.marketAddresses(mktConfigs[0]);
        minter = addresses.minter;
        stabilityPool = addresses.collateralPool;
        stabilityPoolLeveraged = addresses.leveragedPool;
        stabilityPoolManager = addresses.manager;
        pegged = addresses.pegged;
        leveraged = addresses.leveraged;
        wrappedCollateral = addresses.wrappedCollateral;

        // The price oracle is a separately-deployed dependency (harbor-price-aggregators): the deploy wires the minter
        // to its predicted CREATE3 address while that address is still codeless, exactly as production does. So the run
        // installs the settable mock there AFTER the deploy, which exercises the deploy's codeless reference and puts the
        // mock in place before the first read (the seed mint). The answer is set per envelope point via
        // mockOracle.setLatestAnswer.
        mockOracle = MockWrappedPriceOracle(deployRun.installMockPriceOracle(mktConfigs[0]));
        marketActions = new MarketActions(minter);

        address stabilityPoolOwner = IBaoOwnable(stabilityPool).owner();
        uint256 rebalancerRole = IStabilityPool_v3(stabilityPool).REBALANCER_ROLE();
        vm.startPrank(stabilityPoolOwner);
        IBaoRoles(stabilityPool).grantRoles(address(this), rebalancerRole); // to arrange prior losses
        vm.stopPrank();
        poolActions = new StabilityPoolActions(stabilityPool, address(this));

        background = makeAddr("background");
        _createUsers(MAX_FUZZ_USERS);

        // Taken before ANY capital exists, so a test whose point is not the nominal one can rewind to here and
        // fund its market under its own conditions instead. See `_seedMarketAt`.
        preFundingState = vm.snapshotState();

        // a nominal envelope point (geometric-mean centre of the log-range) so the seed mint has a price to work from
        _setEnvelopePoint(_nominalCollateralUSD(), _nominalWrapRate(), buildEnvelope().pegPriceUSD);
        _seedMarket(); // the market's deploy-time capital structure, at nominal conditions
        _seedPool(); // a permanent seed at the supply floor so every actor can fully exit later

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

    /// @notice The peg and market configs paired in the deploy must AGREE on aboutADollar, the StabilityPool's floor.
    /// The stability pool deploy reads it from the MARKET config, so an override placed only on the peg is silently ignored and the
    /// deployed floor is not the intended one - which is exactly how the floorHuge variant deployed the base 2e14
    /// rather than its intended 1e24 (the override was on the peg alone). Asserting the two sources cannot diverge
    /// catches an override on the wrong config object, deploy-free and mock-free.
    function test_configIntegrity_aboutADollarPegMatchesMarket() public {
        (ConfigPeg peg, Config_MinterMarket[] memory markets) = createETHMintersConfig();
        for (uint256 i = 0; i < markets.length; i++) {
            assertEq(
                IHarborConfig(address(markets[i])).aboutADollar(),
                peg.aboutADollar(),
                "market aboutADollar diverges from the peg's - an override lands on a config the stability pool deploy ignores"
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
            IStabilityPool_v3(stabilityPool).MIN_TOTAL_ASSET_SUPPLY(),
            cfg.aboutADollar(),
            "deployed supply floor is not the configured one"
        );
        assertEq(
            IStabilityPool_v3(stabilityPool).MAX_TOTAL_ASSET_SUPPLY(),
            _expectedMaxTotalAssetSupply(cfg.aboutADollar()),
            "deployed supply ceiling is not MIN * FACTOR_PRECISION (saturated at the supply field)"
        );
        (uint256 startDelay, uint256 endWindow) = IStabilityPool_v3(stabilityPool).getWithdrawalWindow();
        assertEq(startDelay, cfg.stabilityPoolWithdrawalDelay(), "deployed withdrawal delay is not the configured one");
        assertEq(
            endWindow,
            cfg.stabilityPoolWithdrawalPeriod(),
            "deployed withdrawal window is not the configured one"
        );
        assertEq(
            IStabilityPool_v3(stabilityPool).getEarlyWithdrawalFee(),
            cfg.stabilityPoolEarlyWithdrawalFeeRatio(),
            "deployed early-withdrawal fee is not the configured one"
        );
    }

    /// @dev The ceiling the constructor derives: `MIN * FACTOR_PRECISION`, saturated at the uint128 supply field above
    /// which a larger ceiling is unreachable anyway.
    function _expectedMaxTotalAssetSupply(uint256 minTotalAssetSupply) internal pure returns (uint256) {
        return
            minTotalAssetSupply > type(uint128).max / DecrementalFloatingPoint_v2.FACTOR_PRECISION
                ? type(uint128).max
                : minTotalAssetSupply * DecrementalFloatingPoint_v2.FACTOR_PRECISION;
    }

    /// @notice The wrap rate is a SCALE axis, not a health one: the collateral ratio is computed from the RECORDED
    ///         backing, so moving the rate across its whole declared range does not move it. What a fallen rate
    ///         changes is whether the record is still covered by the holding - and the market halts until the rate
    ///         recovers or an owner says the shortfall is real. Recognition is the only thing that moves the ratio,
    ///         and only ever down.
    ///
    /// @dev Four parts, because each is a separate thing that could break and the first three look alike from
    /// outside. A reader who only checks that the ratio moved eventually cannot tell a market that held its ratio
    /// through a rate fall from one that never noticed the fall at all - part (b) is what separates them.
    function test_envelopePointAtCollateralRatio_holdsTheRatioAcrossTheRateRange() public {
        Envelope memory e = buildEnvelope();
        assertTrue(
            _seedMarketAt(_nominalCollateralUSD(), _nominalWrapRate(), e.pegPriceUSD),
            "a market stands up at the nominal point"
        );
        uint256 ratioAtNominal = IMinter(minter).collateralRatio();

        // (a) the rate falls to the bottom of the declared range and the ratio does not move: the backing is a
        // record, and nothing has yet decided the shortfall is real
        mockOracle.setLatestAnswer(currentPrice, e.minWrapRate);
        assertEq(
            IMinter(minter).collateralRatio(),
            ratioAtNominal,
            "a fallen rate does not move a ratio measured against the record"
        );

        // (b) but the market is HALTED, not merely unchanged - which is what makes (a) a decision deferred rather
        // than a fall gone unnoticed
        uint256 recorded = IMinter(minter).collateralTokenBalance();
        uint256 held = _heldAsCollateralAtRate(e.minWrapRate);
        address halted = makeAddr("haltedMinter");
        deal(wrappedCollateral, halted, 1 ether);
        vm.startPrank(halted);
        IERC20(wrappedCollateral).approve(minter, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.UnrecognisedImpairment.selector, recorded, held));
        IMinter(minter).mintPeggedToken(1 ether, halted, 0);
        vm.stopPrank();

        // (c) recognising is what moves it, and it moves by the factor the rate fell
        vm.startPrank(IBaoOwnable(minter).owner());
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();
        uint256 ratioRecognised = IMinter(minter).collateralRatio();
        // Exactly, not approximately. The write-down sets the record to what the holding converts to, and the same
        // holding is being converted at both rates - so the ratio carries the rate's own factor and the floors on
        // either side land on the same wei. An approximate assertion here would admit a write-down that was merely
        // close to the rate it claims to follow.
        assertEq(
            ratioRecognised,
            Math.mulDiv(ratioAtNominal, e.minWrapRate, _nominalWrapRate()),
            "recognition writes the ratio down by the factor the rate fell"
        );

        // (d) and the rate returning does NOT restore it: a recognised loss is a decision, not a reading
        mockOracle.setLatestAnswer(currentPrice, e.maxWrapRate);
        assertEq(
            IMinter(minter).collateralRatio(),
            ratioRecognised,
            "a risen rate does not undo a recognised impairment"
        );
    }

    /// @dev What the holding converts to at `rate`, computed from the balance rather than read from the minter, so the
    /// expected revert arguments are an independent statement of the figure the guard compares.
    function _heldAsCollateralAtRate(uint256 rate) internal view returns (uint256) {
        return Math.mulDiv(IERC20(wrappedCollateral).balanceOf(minter), rate, 1 ether);
    }

    /// @dev A collateral ratio deep enough below the rebalance threshold to make the rebalance return a large
    /// reward, while still leaving the pegged covered. Read from the manager rather than restated, so a market that
    /// configures its threshold differently gets a point that is actually below its own.
    ///
    /// Placed a tenth of the way from parity to the threshold: as deep as the shortfall can be driven while the
    /// collateral still covers the pegged claim, which is what keeps the leveraged buffer mintable and the reward
    /// large.
    function _belowRebalanceThreshold() internal view returns (uint256) {
        uint256 threshold = IStabilityPoolManager_v2(stabilityPoolManager).rebalanceThreshold();
        assertGt(threshold, 1 ether, "a threshold at or below parity leaves no covered ratio to rebalance from");
        return 1 ether + (threshold - 1 ether) / 10;
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

    /// @dev Establish the market AT this point: set the conditions FIRST, then fund the deploy-time capital
    /// structure under them. The order is the whole of it.
    ///
    /// The envelope's question is whether the protocol works across a declared range of conditions, and that
    /// means a market that LIVES at each point - not one market funded at nominal and then dragged across
    /// them. Funding first and moving after leaves the record stating a collateral value the holding no
    /// longer converts to, which is an impairment: real, but a different axis from the one these tests
    /// sweep, and one the guard reverts every trade through. Seeding at the point leaves nothing overstated
    /// and keeps the rate what it is meant to be here - a SCALE axis, widening the numbers running through
    /// the protocol without also deciding how healthy the market is.
    ///
    /// Recognising instead would make the arithmetic agree while leaving the wrong market underneath: the
    /// backing written down but the supplies still those minted at nominal, so a more leveraged market than
    /// any that could exist at this point.
    ///
    /// It REWINDS rather than topping up, because `setUp` has already funded a market at nominal and there is
    /// no way to unfund one. The snapshot is taken after the actors exist and before any capital does, so
    /// what comes back is the same deployment with no market in it yet.
    ///
    /// Returns whether a market's genesis could be minted at all. Where the collateral is worth less than a wei of
    /// pegged per unit, no amount of it mints anything and the first tranche divides by the floored price - the same
    /// located limit a later mint reaches, met earlier because the genesis is the first thing to need a price. It is
    /// OBSERVED through a probe rather than pre-checked, so the boundary is discovered each run. Only the funding
    /// is probed: the rewind and the oracle write happen here, where no revert can roll them back.
    function _seedMarketAt(uint256 collateralUSD, uint256 wrapRate, uint256 pegPriceUSD) internal returns (bool) {
        vm.revertToState(preFundingState);
        _setEnvelopePoint(collateralUSD, wrapRate, pegPriceUSD);

        try this.seedFundingProbe() {
            return true;
        } catch (bytes memory err) {
            // Tolerate ONLY the price underflow. Anything else - a seed assertion, a guard - is a real failure and
            // must propagate UNCHANGED rather than being reported as a point where markets cannot exist.
            if (!_isPanic(err, PANIC_DIVIDE_BY_ZERO)) {
                assembly {
                    revert(add(err, 0x20), mload(err))
                }
            }
            return false;
        }
    }

    /// @dev The deploy-time capital structure, external so `_seedMarketAt` can observe the one limit a market's
    /// genesis can reach. Nothing else may call it: the point must already be set.
    function seedFundingProbe() external {
        _seedMarket();
        _seedPool();
    }

    /// @dev Put the market at `targetCollateralRatio` at the given wrap rate, deriving the collateral price that
    /// achieves it.
    ///
    /// The price and the rate are not independent axes. A rate below the one the record was written at leaves the
    /// record above the holding, which halts the market until it is recognised - and recognised, the backing is the
    /// holding, so the collateral value is the holding times the WRAPPED price: the collateral price and the rate
    /// multiplied together. Sweeping the two separately therefore conflates two different questions: how healthy the
    /// market is, and how large the numbers running through it are. This takes the collateral ratio as the axis and
    /// derives the price from it, so the rate is free to widen the wrapped amounts across the whole declared range
    /// without also deciding whether the market is solvent. A test that means the rate as pure scale mints its
    /// market's genesis at that rate first (`_seedMarketAt`), so there is nothing to recognise.
    ///
    /// The derivation itself is `MarketActions.setCollateralRatioByWrapRate`, shared with any suite that needs to
    /// reach the impaired branch; this wrapper keeps the envelope's own `currentPrice` / `currentRate` in step with it
    /// and declares the peg price the feasibility check is expressed against.
    /// @param targetCollateralRatio The collateral ratio the market should sit at, 1e18-scaled.
    /// @param wrapRate The wrapped-to-underlying rate, used directly as the oracle rate.
    /// @param pegPriceUSD The peg's $ price, which the derived collateral price is expressed against.
    function _setEnvelopePointAtCollateralRatio(
        uint256 targetCollateralRatio,
        uint256 wrapRate,
        uint256 pegPriceUSD
    ) internal {
        currentRate = wrapRate;
        currentPrice = marketActions.setCollateralRatioByWrapRate(targetCollateralRatio, wrapRate);

        // The envelope declares a collateral-price range independently of its rate range, so not every pairing of
        // ratio and rate is expressible: holding a ratio while the rate falls demands a price rise of the same factor.
        // Say so rather than leaving the market at a price the suite never claimed to cover.
        uint256 impliedCollateralUSD = Math.mulDiv(currentPrice, pegPriceUSD, 1 ether);
        Envelope memory e = buildEnvelope();
        assertGe(impliedCollateralUSD, e.minCollateralUSD, "the ratio needs a collateral price below the envelope");
        assertLe(impliedCollateralUSD, e.maxCollateralUSD, "the ratio needs a collateral price above the envelope");
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
        (minted, ) = marketActions.mint(collateral, 0, address(this));
    }

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        IStabilityPool_v3(stabilityPool).deposit(amount, who, 0);
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
        IStabilityPool_v3(stabilityPool).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPool).getWithdrawalRequest(who);
        vm.warp(uint256(start) + 1);
        vm.startPrank(who);
        IStabilityPool_v3(stabilityPool).withdraw(type(uint256).max, who, 0);
        vm.stopPrank();
    }

    /// @dev Stand the market up the way a real one is: Genesis splits its collateral in half, minting pegged with
    /// one half and leveraged with the other, which leaves the pegged claim on half the collateral value - a
    /// collateral ratio of 2. A further pegged tranche of the same size then brings it to 1.5, mid-band on the fee
    /// schedules.
    ///
    /// This is deployment-time state, and it must be complete before anything ADVERSE happens - which the point of a
    /// market's genesis is not, however extreme (see `_seedMarketAt`). Leveraged is the junior claim that absorbs an
    /// impairment, so a market that stands up without one is underwater on the first adverse move, and leveraged cannot
    /// be added afterwards: minting it requires a residual to sell, and an impaired market has none. The buffer has
    /// to exist before conditions change, exactly as in production.
    function _seedMarket() internal {
        // Three equal tranches of collateral: pegged and leveraged at genesis, then pegged again.
        // Value 3X against a pegged claim of 2X is a collateral ratio of 1.5.
        uint256 tranche = _collateralFor(IStabilityPool_v3(stabilityPool).MIN_TOTAL_ASSET_SUPPLY()) + 1 ether;
        marketActions.mint(tranche, tranche, address(this)); // Genesis' half-and-half: ratio 2
        marketActions.mint(tranche, 0, address(this)); // the pegged tranche that takes it to 1.5

        // What the flooring costs the reported ratio. The ratio is `backing x price / claim`, so a wei lost from
        // either side moves it by the ratio's own size over that side - and BOTH sides are counted in units the
        // tranches are not. The tranches are paid in WRAPPED collateral and recorded as underlying, one floor per
        // mint; they are claimed in pegged, one floor per pegged mint. So:
        //   - three tranches of backing, each short by at most a wei of underlying: 3 x ratio / backing
        //   - two pegged mints, each minting at most a wei short:                   2 x ratio / claim
        //   - the ratio's own floor:                                                1
        // The backing term is the one that bites, and it is the wrap rate that decides how hard: a tranche of
        // wrapped collateral records `tranche x rate` of underlying, so at the bottom of the rate range the same
        // wei of flooring is a far larger share of a far smaller backing. Sizing this off the claim alone reads
        // as a tight bound at nominal and silently becomes one three decades too tight at the rate floor.
        uint256 peggedClaim = IMinter(minter).peggedTokenBalance();
        uint256 backing = IMinter(minter).collateralTokenBalance();
        uint256 flooring = Math.mulDiv(3, DEPLOY_COLLATERAL_RATIO, backing, Math.Rounding.Ceil) +
            Math.mulDiv(2, DEPLOY_COLLATERAL_RATIO, peggedClaim, Math.Rounding.Ceil) +
            1;
        assertApproxEqAbs(
            IMinter(minter).collateralRatio(),
            DEPLOY_COLLATERAL_RATIO,
            flooring,
            "the market stands up over-collateralised, at genesis proportions plus one pegged tranche"
        );
    }

    function _seedPool() internal {
        // The pegged to deposit was already minted by `_seedMarket`; this establishes only the pool's own floor.
        uint256 minTotalAssetSupply = IStabilityPool_v3(stabilityPool).MIN_TOTAL_ASSET_SUPPLY();
        IERC20(pegged).approve(stabilityPool, type(uint256).max);
        IStabilityPool_v3(stabilityPool).deposit(minTotalAssetSupply, address(this), 0);
    }

    // ─── arrange: bring the real system to a StartState the action acts against ───

    function _arrange(uint256 collateralUSD, uint256 wrapRate, uint256 pegPriceUSD, StartState memory s) internal {
        _setEnvelopePoint(collateralUSD, wrapRate, pegPriceUSD);

        if (s.existingDeposits > 0) {
            _mintPeggedAtLeast(s.existingDeposits);
            IERC20(pegged).transfer(background, s.existingDeposits);
            vm.startPrank(background);
            IERC20(pegged).approve(stabilityPool, type(uint256).max);
            IStabilityPool_v3(stabilityPool).deposit(s.existingDeposits, background, 0);
            vm.stopPrank();
        }

        if (s.priorLossFraction > 0) {
            uint256 minTotalAssetSupply = IStabilityPool_v3(stabilityPool).MIN_TOTAL_ASSET_SUPPLY();
            uint256 held = IERC20(pegged).balanceOf(stabilityPool);
            uint256 headroom = held > minTotalAssetSupply ? held - minTotalAssetSupply : 0;
            uint256 loss = (headroom * s.priorLossFraction) / 1e18;
            if (loss > 0) {
                // a loss alone - no proceeds - decays the compounding product the envelope measures against
                poolActions.liquidate(wrappedCollateral, loss, 0);
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
        uint256 minTotalAssetSupply = IStabilityPool_v3(stabilityPool).MIN_TOTAL_ASSET_SUPPLY();

        uint256 n = bound(nSeed, 1, _min(e.maxPoolUsers, MAX_FUZZ_USERS));
        uint256 collateralUSD = bound(collateralSeed, e.minCollateralUSD, e.maxCollateralUSD);
        uint256 wrapRate = bound(rateSeed, e.minWrapRate, e.maxWrapRate);
        uint256 pegPriceUSD = _logScale(pegSeed, e.minPegPriceUSD, e.maxPegPriceUSD);

        uint256 poolPegged = _poolPeggedFor(bound(poolSeed, e.maxPoolValueUSD / 1e5, e.maxPoolValueUSD), pegPriceUSD);
        if (poolPegged < n * minTotalAssetSupply) {
            poolPegged = n * minTotalAssetSupply; // every equal share must clear the supply floor
        }
        // Peak supply during the walk is the pre-existing deposit (<= poolPegged) plus one equal share (<= poolPegged)
        // on top of the baseline, so bound the pool at half the remaining headroom to keep that peak within the supply
        // cap. For a peg far below MIN this binds (the nominal pool for the $ value exceeds MAX_TOTAL_ASSET_SUPPLY);
        // MIN * FACTOR_PRECISION / 2 dwarfs n * minTotalAssetSupply, so it never conflicts with the floor above.
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
        // Fund the market AT this point rather than moving a nominal one to it, so the rate is the scale axis
        // it is meant to be here and nothing is left overstated. Set the oracle point HERE too (the probe sets
        // it again inside `_arrange`, but that inner write rolls back on a probe revert): the recorded row
        // below must log the point that produced the failure, not the prior one.
        //
        // The genesis is itself priced, so the cheap-collateral corner reverts here rather than at the mint
        // below - the same located limit, one step earlier. Record it under its own name: at this point there is
        // no market to deposit into, which is a stronger statement than a pool that cannot be grown.
        if (!_seedMarketAt(collateralUSD, wrapRate, pegPriceUSD)) {
            _record("depositWithdraw", poolPegged, "broke", "found: divide-by-zero");
            return;
        }

        try this.depositWithdrawSetupProbe(collateralUSD, wrapRate, pegPriceUSD, s, poolPegged, shares, n) {
            // setup held - exercise the behaviour below
        } catch (bytes memory err) {
            // Tolerate ONLY the expected economic limit: when the collateral is worth < 1 wei of pegged per unit the
            // mint cannot back the pool and `_collateralFor` divides by zero. Any OTHER revert is an unexpected failure
            // and must propagate UNCHANGED - a broad catch here would be a fuzz-level fail_on_revert=false, silently
            // recording a real bug as a located limit.
            if (!_isPanic(err, PANIC_DIVIDE_BY_ZERO)) {
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

        // Mint the market's genesis at the cheap corner rather than dragging a nominal one down to it: the cheapness
        // is a condition this market is meant to live under, not a loss it has suffered, and the two are different
        // markets. See `_seedMarketAt`.
        assertTrue(
            _seedMarketAt(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD),
            "a market stands up at the envelope's cheapest collateral"
        );

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
        IStabilityPool_v3(stabilityPool).deposit(amount, user, 0);
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
            IStabilityPool_v3(stabilityPool).deposit(half, user, 0);
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
        IStabilityPool_v3(stabilityPool).deposit(amount, user, 0);
        vm.stopPrank();
    }

    /// @notice The depositor-count corner: a crowd of SEPARATE accounts each deposit an equal share of the whole
    /// envelope pool, then one rebalance returns the whole-pool collateral reward split across ALL of them. The books
    /// hold across the crowd: the supply records every deposit exactly, and the reward conserves and stays solvent
    /// summed over every holder (per-holder flooring accumulates once per account, so the crowd is what stresses it).
    /// The fuzz walk caps its actors at MAX_FUZZ_USERS for feasibility; this is the many-holder case. Grown at the
    /// envelope's own (min) wrap rate - the rate the corner rebalance uses.
    ///
    /// The envelope declares a cap of `maxPoolUsers` holders, and this does NOT enumerate it. A holder is a mapping
    /// entry, in the pool and in every reward base it inherits, and no loop anywhere in that code is over holders
    /// (they are over the reward tokens and the compounding exponent ladder), so every operation costs the same
    /// whatever the count and the ten-thousandth deposit runs the code the third did. What does grow with the count
    /// is the per-holder flooring, linearly, and the conservation bound (`n + 2` actors) grows with it - so a crowd
    /// of `CROWD_SIZE` exercises exactly what the declared cap would. Enumerating the cap cost minutes per leaf, and
    /// the leaf's other tests - under two seconds on their own - took hundreds more in its company.
    function test_envelope_crowdOfHolders_holds() public {
        Envelope memory e = buildEnvelope();
        uint256 n = CROWD_SIZE;
        _setEnvelopePointAtCollateralRatio(DEPLOY_COLLATERAL_RATIO, e.minWrapRate, e.pegPriceUSD);
        uint256 share = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD) / n; // the whole envelope pool, split
        _mintLeveragedBuffer(share * n);
        _mintPeggedAtLeast(share * n);

        uint256 supplyBefore = IERC20(stabilityPool).totalSupply();
        address[] memory crowd = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            address holder = makeAddr(string.concat("crowd", vm.toString(i)));
            crowd[i] = holder;
            IERC20(pegged).transfer(holder, share);
            vm.startPrank(holder);
            IERC20(pegged).approve(stabilityPool, share);
            IStabilityPool_v3(stabilityPool).deposit(share, holder, 0);
            vm.stopPrank();
        }
        assertEq(IERC20(stabilityPool).totalSupply(), supplyBefore + share * n, "every deposit recorded exactly");

        _setEnvelopePointAtCollateralRatio(_belowRebalanceThreshold(), e.minWrapRate, e.pegPriceUSD);
        assertTrue(
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(),
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
        StabilityPoolConservationGhosts memory g = _rewardGhosts(injected, share * n, n + 2);
        _assertRewardConserved(stabilityPool, actors, g);
        _assertStabilityPoolSolvent(stabilityPool, actors, g);
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

    /// @notice Deposit sweep: a fresh user deposits a swept amount into the StabilityPool at a swept oracle point,
    /// pushing PAST the envelope pool into the `TokenBalance.amount` width regime (uint128 in v3, ~3.4e38 - widened
    /// from v2's uint104). Whenever the deposit SUCCEEDS it must read back exactly (balance == amount, supply
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
        // log-scale over the full PHYSICAL input range [MIN_TOTAL_ASSET_SUPPLY, uint256 max]: the fuzzer locates the field break
        // within it, rather than a range sized to the field under test. _logScale samples every order of magnitude
        // equally, so the boundary (many orders below the max) is actually reached.
        uint256 w = _logScale(wSeed, IStabilityPool_v3(stabilityPool).MIN_TOTAL_ASSET_SUPPLY(), type(uint256).max);

        address user = users[0];
        deal(pegged, user, w);
        uint256 supplyBefore = IERC20(stabilityPool).totalSupply();
        vm.startPrank(user);
        try IStabilityPool_v3(stabilityPool).deposit(w, user, 0) {
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
        uint256 w = _logScale(wSeed, IStabilityPool_v3(stabilityPool).MIN_TOTAL_ASSET_SUPPLY(), type(uint256).max);

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
        IStabilityPool_v3(stabilityPool).deposit(w, user, 0);
        IStabilityPool_v3(stabilityPool).requestWithdrawal();
        vm.stopPrank();
        (uint64 start, ) = IStabilityPool_v3(stabilityPool).getWithdrawalRequest(user);
        vm.warp(uint256(start) + 1);
        vm.startPrank(user);
        IStabilityPool_v3(stabilityPool).withdraw(type(uint256).max, user, 0);
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
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(keeper, 0);
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
    ) internal view returns (StabilityPoolConservationGhosts memory g) {
        g.tokens = new address[](1);
        g.tokens[0] = wrappedCollateral;
        g.injected = new uint256[](1);
        g.injected[0] = injected;
        g.maxSupplyEver = maxSupplyEver;
        g.calls = calls;
        g.minSupply = IStabilityPool_v3(stabilityPool).MIN_TOTAL_ASSET_SUPPLY();
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
            IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio() -
            IStabilityPoolManager_v2(stabilityPoolManager).harvestCutRatio();
        if (residualRatio > 0) {
            assertGt(injected, 0, "harvest delivered the pools' residual share");
        } else {
            // bounty + cut consume the whole harvest; both pool shares floor and the sub-wei remainder is never swept
            // (it stays in the minter as harvestable), so the pools receive NOTHING - no dust transfer
            assertEq(injected, 0, "no dust reaches the pools when bounty + cut consume the harvest");
        }

        vm.warp(block.timestamp + 8 days); // whole stream distributable

        StabilityPoolConservationGhosts memory g = _rewardGhosts(injected, poolPegged, MAX_FUZZ_USERS + 2);
        _assertRewardConserved(stabilityPool, _allActors(), g);
        _assertStabilityPoolSolvent(stabilityPool, _allActors(), g);
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
        assertTrue(
            _seedMarketAt(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD),
            "a market stands up at the envelope's cheapest collateral"
        );
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD);
        _growPool(poolPegged, MAX_FUZZ_USERS);
        currentRate = e.maxWrapRate; // one un-harvested step: the wrapped collateral appreciates from min to MAX rate
        mockOracle.setLatestAnswer(currentPrice, currentRate);

        uint256 residualRatio = 1e18 -
            IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio() -
            IStabilityPoolManager_v2(stabilityPoolManager).harvestCutRatio();
        uint256 harvestableBefore = IMinter(minter).harvestable();
        uint256 rewardBefore = IERC20(wrappedCollateral).balanceOf(stabilityPool);

        address keeper = makeAddr("harvestKeeper");
        vm.startPrank(keeper);
        uint256 swept = IStabilityPoolManager_v2(stabilityPoolManager).harvest(keeper, 0); // MUST NOT revert - defers at the corner
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
        assertTrue(
            _seedMarketAt(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD),
            "a market stands up at the envelope's cheapest collateral"
        );
        _growPool(_poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD), MAX_FUZZ_USERS);
        currentRate = e.maxWrapRate; // the largest single-step yield the envelope declares - far exceeds one period
        mockOracle.setLatestAnswer(currentPrice, currentRate);

        address token = wrappedCollateral;
        uint256 period = IMultipleRewardDistributor_v3(stabilityPool).REWARD_PERIOD_LENGTH();
        uint256 capacityFresh = IMultipleRewardDistributor_v3(stabilityPool).maxDepositReward(token);
        address keeper = makeAddr("harvestRecoveryKeeper");

        uint256 residualRatio = 1e18 -
            IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio() -
            IStabilityPoolManager_v2(stabilityPoolManager).harvestCutRatio();
        uint256 harvestable0 = IMinter(minter).harvestable();
        // Only markets whose single-step corner yield EXCEEDS one period's capacity form a deferred backlog; where the
        // capacity already dwarfs the yield (huge MIN) or the config sends no residual to the pools (full bounty + cut),
        // there is nothing to defer and no recovery question to probe.
        if (residualRatio == 0 || harvestable0 == 0 || capacityFresh == 0 || harvestable0 <= capacityFresh) {
            return;
        }

        uint256 pool0 = IERC20(token).balanceOf(stabilityPool);
        vm.startPrank(keeper);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(keeper, 0);
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
            uint256 swept = IStabilityPoolManager_v2(stabilityPoolManager).harvest(keeper, 0);
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
        uint256 skimRatio = IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio() +
            IStabilityPoolManager_v2(stabilityPoolManager).harvestCutRatio();
        uint256 residualRatio = 1e18 - skimRatio;
        // needs a real skim AND a residual to the pools; the zero-fee and full-cut markets have nothing to prove here
        if (skimRatio == 0 || residualRatio == 0) {
            return;
        }
        Envelope memory e = buildEnvelope();
        assertTrue(
            _seedMarketAt(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD),
            "a market stands up at the envelope's cheapest collateral"
        );
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
        uint256 leveragedPoolBefore = IERC20(token).balanceOf(stabilityPoolLeveraged);
        vm.startPrank(keeper);
        uint256 swept = IStabilityPoolManager_v2(stabilityPoolManager).harvest(keeper, 0);
        vm.stopPrank();
        uint256 distributed = (IERC20(token).balanceOf(stabilityPool) - poolCollBefore) +
            (IERC20(token).balanceOf(stabilityPoolLeveraged) - leveragedPoolBefore);
        uint256 skim = swept - distributed; // the bounty + cut that left the minter

        // the skim is the ratio slice of what was DISTRIBUTED, not of the whole (mostly-deferred) harvestable
        uint256 expectedSkim = Math.mulDiv(distributed, skimRatio, residualRatio);
        // skim on the whole backlog, orders of magnitude higher
        uint256 backlogProportionalSkim = Math.mulDiv(harvestable0, skimRatio, 1e18);
        // the skim rounds through `processed = mulDiv(distributed, 1e18, residualRatio)` then a ratio floor, so it can
        // differ from the direct `mulDiv(distributed, skimRatio, residualRatio)` by at most 1 wei; the band admits the
        // capped skim and rejects the backlog-proportional value it is many orders of magnitude away from
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
        IStabilityPool_v3(pool).deposit(amount, who, 0);
        vm.stopPrank();
    }

    /// @notice Both pools take their FLOORED share - neither absorbs the split remainder. With both pools holding pegged
    /// in an uneven ratio (so the residual split leaves a 1-wei remainder), each pool receives EXACTLY
    /// floor(residual * itsHoldings / total) and the remainder stays in the minter, rather than one pool being handed it
    /// as a systematic advantage.
    function test_harvest_bothPoolsFloored() public {
        uint256 bountyRatio = IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio();
        uint256 cutRatio = IStabilityPoolManager_v2(stabilityPoolManager).harvestCutRatio();
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
        // loses 0 or 1 wei). The manager splits the new yield by holdings gross, flooring BOTH shares; that holdings-
        // split remainder stays un-owed harvestable, handed to neither pool. (Within the streamed gross, each pool then
        // takes its OWN floored net, so its per-part net-flooring remainder also stays unharvested - see below.)
        uint256 residualRatio = 1e18 - bountyRatio - cutRatio;
        uint256 grossCollateral;
        uint256 grossLeveraged;
        uint256 harvestableAmount;
        for (uint256 i = 0; i < 8; i++) {
            currentRate = (currentRate * 1001) / 1000;
            mockOracle.setLatestAnswer(currentPrice, currentRate);
            harvestableAmount = IMinter(minter).harvestable();
            uint256 totalHold = IERC20(pegged).balanceOf(stabilityPool) +
                IERC20(pegged).balanceOf(stabilityPoolLeveraged);
            grossCollateral = Math.mulDiv(harvestableAmount, IERC20(pegged).balanceOf(stabilityPool), totalHold);
            grossLeveraged = Math.mulDiv(
                harvestableAmount,
                IERC20(pegged).balanceOf(stabilityPoolLeveraged),
                totalHold
            );
            if (grossCollateral + grossLeveraged < harvestableAmount) {
                break; // the gross split leaves an un-owed remainder - the discriminating case
            }
        }
        require(grossCollateral + grossLeveraged < harvestableAmount, "fixture must produce a split remainder");
        // Each pool gets its OWN floored net floor(grossShare * residualRatio) - neither absorbs the per-part flooring
        // residual. The holdings-split remainder is separate: it was never owed, so it stays in the minter (asserted
        // below), alongside each pool's own net-flooring remainder.
        uint256 expectedLeveraged = Math.mulDiv(grossLeveraged, residualRatio, 1e18);
        uint256 expectedCollateral = Math.mulDiv(grossCollateral, residualRatio, 1e18);

        uint256 collateralPoolBefore = IERC20(wrappedCollateral).balanceOf(stabilityPool);
        uint256 leveragedPoolBefore = IERC20(wrappedCollateral).balanceOf(stabilityPoolLeveraged);
        address keeper = makeAddr("harvestKeeper");
        vm.startPrank(keeper);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(keeper, 0);
        vm.stopPrank();

        assertEq(
            IERC20(wrappedCollateral).balanceOf(stabilityPool) - collateralPoolBefore,
            expectedCollateral,
            "collateral pool got exactly the net of its floored gross share, not a conserving complement"
        );
        assertEq(
            IERC20(wrappedCollateral).balanceOf(stabilityPoolLeveraged) - leveragedPoolBefore,
            expectedLeveraged,
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
        uint256 bountyRatio = IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio();
        uint256 cutRatio = IStabilityPoolManager_v2(stabilityPoolManager).harvestCutRatio();
        if (1e18 - bountyRatio - cutRatio == 0) {
            return; // a full-cut config sends nothing to the pools, so no backlog forms to leak
        }
        // Corner: cheapest collateral + the max single-step wrap-rate jump -> the collateral pool's residual share
        // far exceeds one period's stream capacity, so the harvest defers a backlog rather than depositing it all.
        Envelope memory e = buildEnvelope();
        assertTrue(
            _seedMarketAt(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD),
            "a market stands up at the envelope's cheapest collateral"
        );
        _growPool(_poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD), MAX_FUZZ_USERS); // collateral pool only

        // Mint the late entrant's pegged NOW (its collateral folds into the corner yield) but hold it in-wallet, so the
        // leveraged pool is still empty at harvest #1 and takes no share of the backlog it will later skim.
        address lateEntrant = makeAddr("lateEntrant");
        uint256 leveragedPoolHeadroom = IStabilityPool_v3(stabilityPoolLeveraged).MAX_TOTAL_ASSET_SUPPLY() -
            IERC20(stabilityPoolLeveraged).totalSupply();
        uint256 leveragedPoolHold = _min(IERC20(pegged).balanceOf(stabilityPool), leveragedPoolHeadroom); // ~ the collateral pool's holding
        _mintPeggedAtLeast(leveragedPoolHold);
        IERC20(pegged).transfer(lateEntrant, leveragedPoolHold);

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
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(keeper, 0);
        vm.stopPrank();
        uint256 backlog = IMinter(minter).harvestable();
        assertGt(backlog, 0, "harvest #1 deferred a backlog owed to the collateral pool");

        // The leveraged pool enters AFTER the backlog accrued.
        vm.startPrank(lateEntrant);
        IERC20(pegged).approve(stabilityPoolLeveraged, leveragedPoolHold);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(leveragedPoolHold, lateEntrant, 0);
        vm.stopPrank();

        // Free the stream capacity, accrue NO fresh yield: the next harvest works the PURE backlog.
        vm.warp(block.timestamp + IMultipleRewardDistributor_v3(stabilityPool).REWARD_PERIOD_LENGTH() + 1);
        assertEq(IMinter(minter).harvestable(), backlog, "no fresh yield: harvestable is exactly the deferred backlog");

        // The leveraged pool's re-split share of the backlog clears the sub-period dust floor, so a zero receipt is the
        // fairness property under test, not the dust rule zeroing a tiny share.
        uint256 residualBacklog = backlog - (backlog * bountyRatio) / 1e18 - (backlog * cutRatio) / 1e18;
        uint256 total = IERC20(pegged).balanceOf(stabilityPool) + IERC20(pegged).balanceOf(stabilityPoolLeveraged);
        uint256 leveragedPoolUncapped = (residualBacklog * IERC20(pegged).balanceOf(stabilityPoolLeveraged)) / total;
        assertGt(
            leveragedPoolUncapped,
            IMultipleRewardDistributor_v3(stabilityPoolLeveraged).REWARD_PERIOD_LENGTH(),
            "the leveraged pool's re-split share clears the dust floor (so a zero receipt is fairness, not dust)"
        );

        // Harvest #2 on the pure backlog: measure what the late-entrant leveraged pool receives.
        uint256 leveragedPoolBefore = IERC20(token).balanceOf(stabilityPoolLeveraged);
        vm.startPrank(keeper);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(keeper, 0);
        vm.stopPrank();
        uint256 leveragedPoolGot = IERC20(token).balanceOf(stabilityPoolLeveraged) - leveragedPoolBefore;

        assertEq(
            leveragedPoolGot,
            0,
            "the deferred backlog is not re-split to a pool that held nothing when it accrued"
        );
    }

    /// @notice A pool's deferred harvest backlog drains to THAT pool across periods, never to the co-pool. At the
    /// corner the collateral pool's residual share exceeds one period's capacity, so a backlog defers while only the
    /// collateral pool holds. The leveraged pool then enters and, over several draining harvests of the PURE backlog
    /// (no fresh yield), receives none of it - the whole backlog is owed to the collateral pool and streams only there.
    function test_harvest_owedDrainsToOwningPoolAcrossPeriods() public {
        uint256 bountyRatio = IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio();
        uint256 cutRatio = IStabilityPoolManager_v2(stabilityPoolManager).harvestCutRatio();
        if (1e18 - bountyRatio - cutRatio == 0) {
            return; // full cut: nothing streams to the pools, so no backlog forms
        }
        Envelope memory e = buildEnvelope();
        assertTrue(
            _seedMarketAt(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD),
            "a market stands up at the envelope's cheapest collateral"
        );
        _growPool(_poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD), MAX_FUZZ_USERS); // collateral pool only

        address lateEntrant = makeAddr("lateEntrantDrain");
        uint256 leveragedPoolHeadroom = IStabilityPool_v3(stabilityPoolLeveraged).MAX_TOTAL_ASSET_SUPPLY() -
            IERC20(stabilityPoolLeveraged).totalSupply();
        uint256 leveragedPoolHold = _min(IERC20(pegged).balanceOf(stabilityPool), leveragedPoolHeadroom);
        _mintPeggedAtLeast(leveragedPoolHold);
        IERC20(pegged).transfer(lateEntrant, leveragedPoolHold);

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
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(keeper, 0);
        vm.stopPrank();
        assertGt(IMinter(minter).harvestable(), 0, "harvest #1 deferred a backlog owed to the collateral pool");

        // the leveraged pool enters AFTER the backlog accrued
        vm.startPrank(lateEntrant);
        IERC20(pegged).approve(stabilityPoolLeveraged, leveragedPoolHold);
        IStabilityPool_v3(stabilityPoolLeveraged).deposit(leveragedPoolHold, lateEntrant, 0);
        vm.stopPrank();

        // drain the PURE backlog (no fresh yield) over several periods: it is owed to the collateral pool, so it
        // streams only there and the late-entrant leveraged pool receives none of it on ANY of these harvests.
        uint256 period = IMultipleRewardDistributor_v3(stabilityPool).REWARD_PERIOD_LENGTH();
        for (uint256 i = 0; i < 3; i++) {
            vm.warp(block.timestamp + period + 1);
            uint256 collateralPoolBefore = IERC20(token).balanceOf(stabilityPool);
            uint256 leveragedPoolBefore = IERC20(token).balanceOf(stabilityPoolLeveraged);
            vm.startPrank(keeper);
            IStabilityPoolManager_v2(stabilityPoolManager).harvest(keeper, 0);
            vm.stopPrank();
            assertEq(
                IERC20(token).balanceOf(stabilityPoolLeveraged) - leveragedPoolBefore,
                0,
                "the leveraged pool receives none of the collateral pool's backlog on any draining harvest"
            );
            assertGt(
                IERC20(token).balanceOf(stabilityPool) - collateralPoolBefore,
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
        uint256 bountyRatio = IStabilityPoolManager_v2(stabilityPoolManager).harvestBountyRatio();
        uint256 cutRatio = IStabilityPoolManager_v2(stabilityPoolManager).harvestCutRatio();
        uint256 residualRatio = 1e18 - bountyRatio - cutRatio;
        // the skim's bands below are derived for these
        assertLt(bountyRatio, uint256(1e18) / 3, "fixture: the bounty ratio is under a third");
        assertTrue(
            residualRatio == 0 || residualRatio > 0.5e18,
            "fixture: the residual ratio is nothing or over a half"
        );

        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(_nominalCollateralUSD(), _nominalWrapRate(), e.pegPriceUSD);
        _growPool(_poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD), MAX_FUZZ_USERS);
        _depositPeggedTo(stabilityPoolLeveraged, background, _poolPeggedFor(e.maxPoolValueUSD / 2, e.pegPriceUSD));

        address keeper = makeAddr("skimKeeper");

        // (a) a normal harvest: accrue a little yield, then check the skim matches the harvestable decrease
        currentRate = (currentRate * 1001) / 1000;
        mockOracle.setLatestAnswer(currentPrice, currentRate);
        _assertSkimMatchesHarvestableDrop(keeper, bountyRatio, residualRatio, false);

        // (b) a deferred corner harvest: the same invariant must hold when the pools cap and the excess defers
        _setEnvelopePoint(e.minCollateralUSD, e.minWrapRate, e.pegPriceUSD);
        currentRate = e.maxWrapRate;
        mockOracle.setLatestAnswer(currentPrice, currentRate);
        _assertSkimMatchesHarvestableDrop(keeper, bountyRatio, residualRatio, true);
    }

    /// @dev Harvest once (as `keeper`) and assert the keeper bounty and the pools' net receipt are the bounty/residual
    /// ratio slices of the harvestable decrease, to the floors' wei. The decrease is the sweep `drop = B + C + N`, each
    /// part a floor of its own base on the gross G, so for a part P of ratio p, `P - drop * p = (the other parts'
    /// flooring) * p - (P's flooring) * (1 - p)`. At a normal harvest four parts floor (the bounty, the cut, the two
    /// pools' nets): the bounty lands in [floor(drop * b), floor(drop * b) + 1] and the nets in [floor(drop * r),
    /// floor(drop * r) + 2]. Where the pools cap, each net IS its cap and the gross is floored back up from it, so the
    /// nets sit up to a wei above their share of the gross: the nets' band is unchanged and the bounty's widens by a wei
    /// below. (For a bounty ratio under 1/3, and a residual over 1/2 or none - with none the nets are nothing, and do not
    /// floor.) Single external call under the prank (the harvest); balances read outside it.
    function _assertSkimMatchesHarvestableDrop(
        address keeper,
        uint256 bountyRatio,
        uint256 residualRatio,
        bool poolsCap
    ) internal {
        address token = wrappedCollateral;
        uint256 harvestableBefore = IMinter(minter).harvestable();
        uint256 keeperBefore = IERC20(token).balanceOf(keeper);
        uint256 poolsBefore = IERC20(token).balanceOf(stabilityPool) + IERC20(token).balanceOf(stabilityPoolLeveraged);
        vm.startPrank(keeper);
        IStabilityPoolManager_v2(stabilityPoolManager).harvest(keeper, 0);
        vm.stopPrank();
        uint256 drop = harvestableBefore - IMinter(minter).harvestable();
        uint256 bounty = IERC20(token).balanceOf(keeper) - keeperBefore;
        uint256 netToPools = (IERC20(token).balanceOf(stabilityPool) +
            IERC20(token).balanceOf(stabilityPoolLeveraged)) - poolsBefore;
        uint256 flooredBounty = Math.mulDiv(drop, bountyRatio, 1e18);
        assertGe(
            bounty,
            poolsCap && flooredBounty > 0 ? flooredBounty - 1 : flooredBounty,
            "bounty == bountyRatio x harvestable decrease, to the floors' wei below"
        );
        assertLe(bounty, flooredBounty + 1, "bounty == bountyRatio x harvestable decrease, to a wei above");
        uint256 flooredNet = Math.mulDiv(drop, residualRatio, 1e18);
        assertGe(netToPools, flooredNet, "net to pools == residualRatio x harvestable decrease, never below");
        assertLe(netToPools, flooredNet + 2, "net to pools == residualRatio x harvestable decrease, to two wei above");
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
        address stabilityPoolOwner = IBaoOwnable(stabilityPool).owner();
        uint256 depositorRole = IMultipleRewardDistributor_v3(stabilityPool).REWARD_DEPOSITOR_ROLE();
        vm.startPrank(stabilityPoolOwner);
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
        uint256 floor = IStabilityPool_v3(stabilityPool).MIN_TOTAL_ASSET_SUPPLY();
        // the first cap is the floor's: the pool is seeded with exactly the floor
        assertEq(IERC20(stabilityPool).totalSupply(), floor, "fixture: the supply is exactly the floor");
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
    /// rebalance threshold. Minted BEFORE the pegged it buffers: the minter sells no leverage below its floor, and the
    /// pool's pegged, minted first at par against collateral worth exactly that pegged, would bring the market down to
    /// the peg, where a leveraged mint reverts.
    function _mintLeveragedBuffer(uint256 peggedBacked) internal {
        uint256 collateral = _collateralFor(peggedBacked) / 2;
        marketActions.mint(0, collateral, address(this));
    }

    /// @dev Lower the collateral price to put the collateral ratio inside the window a rebalance is offered in, halfway
    /// across it: from the minter's floor to the rebalance threshold where the threshold is above the floor - the
    /// one-step rebalance by both legs - and from the peg to the threshold where it is not. Placed by price rather than
    /// stepped down to, because the window is as narrow as the threshold is low, and fixed steps can jump it; and
    /// bounded by the minter's own floor, so it moves with the leverage cap that sets it.
    function _dropPriceBelowRebalanceThreshold() internal {
        uint256 threshold = IStabilityPoolManager_v2(stabilityPoolManager).rebalanceThreshold();
        uint256 floor = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();
        uint256 bottom = threshold > floor ? floor : 1 ether;
        currentPrice = marketActions.setCollateralRatioByPrice(bottom + (threshold - bottom) / 2);
        assertTrue(
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(),
            "could not drive the collateral ratio below the rebalance threshold"
        );
    }

    /// @dev A keeper rebalances: the Minter liquidates pool pegged and returns collateral to the StabilityPool as the
    /// liquidation reward. Returns the reward delivered to the collateral pool.
    function _rebalance() internal returns (uint256 injectedToPool) {
        uint256 rewardBefore = IERC20(wrappedCollateral).balanceOf(stabilityPool);
        address keeper = makeAddr("keeper");
        vm.startPrank(keeper);
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(keeper, 0);
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
        _mintLeveragedBuffer(poolPegged);
        _growPool(poolPegged, MAX_FUZZ_USERS);

        _dropPriceBelowRebalanceThreshold();
        uint256 injected = _rebalance();
        assertGt(injected, 0, "rebalance delivered a collateral reward to the pool");

        StabilityPoolConservationGhosts memory g = _rewardGhosts(injected, poolPegged, MAX_FUZZ_USERS + 2);
        _assertRewardConserved(stabilityPool, _allActors(), g);
        _assertStabilityPoolSolvent(stabilityPool, _allActors(), g);
    }

    /// @notice A pool whose share of a rebalance exceeds its solvency headroom gives up all it can, and the co-pool takes
    /// the shortfall WITHIN the same rebalance - so a single rebalance restores the collateral ratio to the threshold
    /// instead of the co-pool recovering it across several later calls. The co-pool must have the headroom to absorb
    /// the shortfall. From inside the band the first step takes both pools' pegged by the collateral route, pro rata:
    /// a small collateral pool beside a large leveraged pool floors there, and the leveraged pool covers its shortfall
    /// and then carries the step above the floor alone.
    function test_rebalance_flooredPoolShortfallPickedUpInCall() public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePoint(_nominalCollateralUSD(), _nominalWrapRate(), e.pegPriceUSD);

        // A small collateral pool (floors early) beside a large leveraged pool with ample headroom to absorb the
        // shortfall; the two together hold nearly all the pegged there is.
        uint256 minSupply = IStabilityPool_v3(stabilityPool).MIN_TOTAL_ASSET_SUPPLY();
        uint256 leveragedPoolHeadroom = IStabilityPool_v3(stabilityPoolLeveraged).MAX_TOTAL_ASSET_SUPPLY() -
            IERC20(stabilityPoolLeveraged).totalSupply();
        uint256 leveragedPoolHold = _min(minSupply * 1_000_000, leveragedPoolHeadroom / 2);
        _mintLeveragedBuffer(leveragedPoolHold); // start the CR healthy so it can be dropped
        _growPool(minSupply * 10, 1); // small collateral pool, beside the seed's floor deposit
        _depositPeggedTo(stabilityPoolLeveraged, background, leveragedPoolHold);

        // Start where the first step - the collateral route to the floor, or to the threshold if that is lower - takes
        // 95% of what the pools hold: past the collateral pool's headroom, which is 10/11 of what it holds, and well
        // inside the leveraged pool's. At par that step takes `a` of the claim and `a` of the value, reaching
        // `firstTarget` when `a = n·(firstTarget − start)/(firstTarget − 1)`.
        uint256 firstTarget = Math.min(
            IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO(),
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceThreshold()
        );
        uint256 held = IERC20(pegged).balanceOf(stabilityPool) + IERC20(pegged).balanceOf(stabilityPoolLeveraged);
        uint256 start = firstTarget -
            Math.mulDiv(firstTarget - 1 ether, 95 * held, 100 * IMinter(minter).peggedTokenBalance());
        _setEnvelopePointAtCollateralRatio(start, _nominalWrapRate(), e.pegPriceUSD);
        assertTrue(
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(),
            "the market starts between the peg and the first target"
        );

        address keeper = makeAddr("rebalanceKeeper");
        vm.startPrank(keeper);
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(keeper, 0);
        vm.stopPrank();

        assertEq(
            IERC20(stabilityPool).totalSupply(),
            minSupply,
            "the small collateral pool gave up all it could - its share exceeded its headroom"
        );
        assertFalse(
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(),
            "the leveraged pool took the shortfall, so one rebalance restores the collateral ratio to the threshold"
        );
    }

    /// @notice A corner rebalance does not overflow the reward integral. The rebalance liquidation reward is
    /// distributed immediately through `_accumulateReward`, not streamed under the harvest path's `maxDepositReward`;
    /// what bounds it is the manager, which scales each leg down so its proceeds stay within the pool's
    /// `maxLiquidationReward` before it sweeps. A rebalance is time-critical and must execute: at the cheapest wrapped
    /// collateral (which maximises the collateral `returned`, the worst case for the integral) the rebalance delivers
    /// its reward without reverting.
    function test_rebalance_cornerLiquidationDoesNotOverflowIntegral() public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePointAtCollateralRatio(DEPLOY_COLLATERAL_RATIO, e.minWrapRate, e.pegPriceUSD);
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD);
        _mintLeveragedBuffer(poolPegged);
        _growPool(poolPegged, MAX_FUZZ_USERS);
        _setEnvelopePointAtCollateralRatio(_belowRebalanceThreshold(), e.minWrapRate, e.pegPriceUSD); // max returned
        if (!IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable()) {
            return; // this market's corner does not drop the CR below the threshold
        }

        uint256 capIntegral = IMultipleRewardDistributor_v3(stabilityPool).maxDepositReward(wrappedCollateral);
        uint256 injected = _rebalance();

        assertGt(injected, 0, "the corner rebalance executes and delivers a reward - no reward-integral overflow");
        console2.log("corner rebalance injected         =", injected);
        console2.log("corner rebalance maxDepositReward =", capIntegral);
    }

    // ─── deterministic reward-field corner (the fuzz reaches this < 1/256 runs; never leave it to the fuzzer) ───

    /// @notice An impairment deeper than the leveraged buffer can absorb, and the recovery out of it. The oracles floor
    ///         the reported rate today, so the market halts before it can get this far and the path has never been
    ///         exercised; the planned widening of those bounds turns it from a halt into a state the protocol has
    ///         to carry. Leveraged is wiped and the pegged depegs, and no rebalance can help: below the peg a
    ///         redemption takes its share of the backing with it, so the rebalance reverts by name and the pool
    ///         keeps its pegged. Once the collateral recovers past the rebalance threshold the market has to come back
    ///         with it.
    function test_deepImpairment_wipesLeveragedThenRecovers() public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePointAtCollateralRatio(DEPLOY_COLLATERAL_RATIO, e.minWrapRate, e.pegPriceUSD);
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD);
        _mintLeveragedBuffer(poolPegged);
        _growPool(poolPegged, MAX_FUZZ_USERS);

        assertGt(IMinter(minter).leveragedTokenPrice(), 0, "leveraged carries value while the market is covered");
        assertEq(IMinter(minter).peggedTokenPrice(), 1 ether, "and the pegged is at par");

        // past the buffer: the collateral no longer covers the pegged claim at all
        _setEnvelopePointAtCollateralRatio(0.7 ether, e.minWrapRate, e.pegPriceUSD);

        assertEq(IMinter(minter).leveragedTokenPrice(), 0, "leveraged is the junior claim and is wiped out first");
        assertLt(IMinter(minter).peggedTokenPrice(), 1 ether, "the pegged depegs once leveraged can absorb no more");
        assertEq(IMinter(minter).harvestable(), 0, "a shortfall is not a surplus");

        // both directions that would take value out of a market that cannot cover its pegged revert
        (, , , uint256 peggedMinted, , ) = IMinter(minter).mintPeggedTokenDryRun(1 ether);
        assertEq(peggedMinted, 0, "pegged minting reverts while the pegged is uncovered");
        (, , , uint256 leveragedCollateralOut, , ) = IMinter(minter).redeemLeveragedTokenDryRun(1 ether);
        assertEq(leveragedCollateralOut, 0, "leveraged redemption reverts while it stands behind an uncovered pegged");

        // below the peg there is nothing a rebalance can repair: it reverts by name, and the pool keeps its pegged
        // for when the price brings the market back above the peg
        uint256 depeggedRatio = IMinter(minter).collateralRatio();
        uint256 poolPeggedHeld = IERC20(pegged).balanceOf(stabilityPool);
        address keeper = makeAddr("keeper");
        assertFalse(
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(),
            "a wiped-out market is not offered one"
        );
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPoolManager_v2.CollateralRatioNotAbovePeg.selector, depeggedRatio)
        );
        IStabilityPoolManager_v2(stabilityPoolManager).rebalance(keeper, 0);
        assertEq(IERC20(pegged).balanceOf(stabilityPool), poolPeggedHeld, "the pool keeps its pegged");

        // the collateral recovers past the rebalance threshold, and the market has to come back with it
        uint256 recovered = IStabilityPoolManager_v2(stabilityPoolManager).rebalanceThreshold() + 0.01 ether;
        _setEnvelopePointAtCollateralRatio(recovered, e.minWrapRate, e.pegPriceUSD);

        assertFalse(
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(),
            "above the threshold there is nothing left to rebalance"
        );
        assertEq(IMinter(minter).peggedTokenPrice(), 1 ether, "the pegged is covered again, so it is back at par");
        assertGt(IMinter(minter).leveragedTokenPrice(), 0, "and leveraged carries the recovery, being the residual");

        // Pegged minting has its OWN bound, the terminal disallow band of the fee schedule, and it sits above the
        // rebalance threshold - a market can be past rebalancing and still too thinly covered to mint more pegged.
        // Read the bound rather than assume the two coincide: a market may set them independently, and one here does.
        uint256 mintBound = IMinter_v3(minter).config().mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[0];
        if (recovered <= mintBound) {
            (, , , uint256 mintedBelowTheBound, , ) = IMinter(minter).mintPeggedTokenDryRun(1 ether);
            assertEq(
                mintedBelowTheBound,
                0,
                "clearing the rebalance threshold does not by itself re-open pegged minting"
            );
        }

        _setEnvelopePointAtCollateralRatio(mintBound + 0.01 ether, e.minWrapRate, e.pegPriceUSD);
        (, , , uint256 peggedMintedAfter, , ) = IMinter(minter).mintPeggedTokenDryRun(1 ether);
        assertGt(peggedMintedAfter, 0, "past its own bound, pegged minting is permitted again");
    }

    /// @notice The reward-field corner: the full pool ($maxPoolValueUSD) liquidated in one rebalance at the CHEAPEST
    /// wrapped collateral (minCollateral x minRate) - the point that maximises the reward token count the pool's uint128
    /// `pending` field must hold, `poolValueUSD / wrappedUSD`. Grown at a healthy nominal price so minting works, then
    /// moved to the corner (which drops the collateral ratio below the rebalance threshold AND maximises the returned
    /// collateral). Green = the reward field holds the whole-pool reward at the corner; a SafeCast revert here is the
    /// documented envelope exceeding the field, to be fixed or narrowed.
    function test_envelope_corner_rebalance_holds() public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePointAtCollateralRatio(DEPLOY_COLLATERAL_RATIO, e.minWrapRate, e.pegPriceUSD);
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD);
        _mintLeveragedBuffer(poolPegged);
        _growPool(poolPegged, MAX_FUZZ_USERS);

        _setEnvelopePointAtCollateralRatio(_belowRebalanceThreshold(), e.minWrapRate, e.pegPriceUSD); // max reward
        assertTrue(
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(),
            "the cheap-wrapped corner drives the collateral ratio below the rebalance threshold"
        );

        uint256 injected = _rebalance();
        assertGt(injected, 0, "rebalance delivered the whole-pool collateral reward at the corner");

        StabilityPoolConservationGhosts memory g = _rewardGhosts(injected, poolPegged, MAX_FUZZ_USERS + 2);
        _assertRewardConserved(stabilityPool, _allActors(), g);
        _assertStabilityPoolSolvent(stabilityPool, _allActors(), g);
    }

    // ─── the reward-field worst case: the whole-pool reward concentrated in one holder's pending field ───

    /// @notice The reward field's worst case - the whole pool concentrated on ONE holder. A single whale deposits the
    /// entire pool (the permanent seed at the supply floor is the only other holder), the wrapped collateral sits at its
    /// cheapest, and one full rebalance returns the whole-pool collateral reward - so the ENTIRE reward accrues to a
    /// SINGLE holder's uint128 `pending` field, the maximum any one reward-accrual field must hold (poolValueUSD /
    /// wrappedUSD). The field holds the concentrated reward and the whale reads it back; conservation and solvency hold
    /// across every holder. A revert or a collapsed read-back at a market-reachable corner is the located field limit -
    /// resolved by widening the field or narrowing the documented market, never asserted as intended.
    function test_envelope_peakPendingRewards_holds() public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePointAtCollateralRatio(DEPLOY_COLLATERAL_RATIO, e.minWrapRate, e.pegPriceUSD);
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD);
        _mintLeveragedBuffer(poolPegged);
        _growPool(poolPegged, 1); // the whole pool in ONE holder (users[0]); the floor seed is the only other

        _setEnvelopePointAtCollateralRatio(_belowRebalanceThreshold(), e.minWrapRate, e.pegPriceUSD); // max reward count
        assertTrue(
            IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(),
            "the cheap-wrapped corner drives the collateral ratio below the rebalance threshold"
        );

        uint256 injected = _rebalance();
        assertGt(injected, 0, "rebalance delivered the whole-pool collateral reward at the corner");

        // conservation and solvency across every holder - the SAME shared checks the invariant proves
        StabilityPoolConservationGhosts memory g = _rewardGhosts(injected, poolPegged, MAX_FUZZ_USERS + 2);
        _assertRewardConserved(stabilityPool, _allActors(), g);
        _assertStabilityPoolSolvent(stabilityPool, _allActors(), g);

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
        _setEnvelopePointAtCollateralRatio(DEPLOY_COLLATERAL_RATIO, e.minWrapRate, e.pegPriceUSD);
        uint256 poolPegged = _poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD);
        _mintLeveragedBuffer(poolPegged);
        _growPool(poolPegged, 1); // the whole pool in ONE holder (users[0]); the floor seed is the only other

        _setEnvelopePointAtCollateralRatio(_belowRebalanceThreshold(), e.minWrapRate, e.pegPriceUSD); // max reward count
        if (!IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable()) {
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

    /// @notice Rebalance reward sweep: grow a pool - a single whale holding a swept size from MIN_TOTAL_ASSET_SUPPLY up to the
    /// supply field's own uint128 width - so the reward limit is located GIVEN that (2a) deposit limit AND the whole
    /// reward concentrates in ONE `pending` field (the worst case). Then drop the wrapped collateral to the envelope
    /// corner (CR below the rebalance threshold; the whole-pool collateral is liquidated back to the pool as the
    /// reward, count = poolValue / wrappedUSD, which scales with the swept pool) and rebalance - the fuzzer finds where
    /// a reward field overflows. Grow at the envelope's own (min) wrap rate, the rate the corner rebalance uses, so the
    /// minter holds exactly the wrapped count it must return (a grow/rebalance rate mismatch would strand it). The grow
    /// and rebalance each run in their own external unit so a caught revert is attributable. Correctness on a hold: the
    /// shared conservation + solvency, asserted unconditionally.
    function testFuzz_rebalance_sweep(uint256 poolSeed) public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePointAtCollateralRatio(DEPLOY_COLLATERAL_RATIO, e.minWrapRate, e.pegPriceUSD);
        uint256 envelopePool = _capToSupplyHeadroom(_poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD));

        // pool swept big, up to the supply field's own width; grown in its own unit so exceeding that field (the 2a
        // deposit/supply limit, cross-confirmed here) is recorded and stops this run rather than masking a reward find.
        uint256 poolPegged = _logScale(
            poolSeed,
            IStabilityPool_v3(stabilityPool).MIN_TOTAL_ASSET_SUPPLY(),
            type(uint128).max
        );
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
        _setEnvelopePointAtCollateralRatio(_belowRebalanceThreshold(), e.minWrapRate, e.pegPriceUSD);

        try this.rebalanceOnlyProbe() returns (uint256 injected) {
            vm.warp(block.timestamp + 8 days); // whole stream distributable
            StabilityPoolConservationGhosts memory g = _rewardGhosts(injected, poolPegged, MAX_FUZZ_USERS + 2);
            // a rebalance that SUCCEEDS must conserve and stay solvent, and the whole reward must remain claimable by
            // the whale - a uint128 pending truncation would collapse that credit. All asserted unconditionally: a
            // silent wrong value is a bug at any size; only a clean revert (below) is a located limit.
            _assertRewardConserved(stabilityPool, _allActors(), g);
            _assertStabilityPoolSolvent(stabilityPool, _allActors(), g);
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

    /// @dev External so a pool that exceeds the supply field reverts as one attributable unit. Mints the leveraged
    /// buffer so the pool can be driven below the rebalance threshold, then grows the whole pool into a single whale
    /// (users[0]) at the current healthy price - concentrating the later reward in ONE pending field.
    function growProbe(uint256 poolPegged) external {
        _mintLeveragedBuffer(poolPegged);
        _growPool(poolPegged, 1);
    }

    /// @dev External so the try/catch treats the rebalance as one located-limit unit (it reverts only if a STEP
    /// reverts). The swept cheap point is already set by the caller; this asserts the pool is rebalanceable there and
    /// rebalances, returning the reward delivered to the pool.
    function rebalanceOnlyProbe() external returns (uint256 injected) {
        require(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "swept point not rebalanceable");
        injected = _rebalance();
    }

    /// @notice Harvest reward sweep: grow a pool so the minter holds a large wrapped-collateral balance, then accrue
    /// yield (a wrap-rate bump) and harvest it - the STREAMED reward path (StabilityPoolManager.harvest -> depositReward
    /// -> LinearReward `rate` uint80 / `queued` uint96), distinct from the rebalance path's one-shot accumulator
    /// integral. Grow at the cheapest wrap rate so the minter's wrapped holdings (and thus the harvested count) are
    /// largest; sweep the pool so that count crosses the streamed-field widths and the fuzzer locates where they
    /// overflow. Correctness on a hold: the shared conservation + solvency, asserted unconditionally.
    function testFuzz_harvest_sweep(uint256 poolSeed) public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePointAtCollateralRatio(DEPLOY_COLLATERAL_RATIO, e.minWrapRate, e.pegPriceUSD);

        uint256 envelopePool = _capToSupplyHeadroom(_poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD));
        uint256 poolPegged = _logScale(
            poolSeed,
            IStabilityPool_v3(stabilityPool).MIN_TOTAL_ASSET_SUPPLY(),
            type(uint128).max
        );
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
            StabilityPoolConservationGhosts memory g = _rewardGhosts(injected, poolPegged, MAX_FUZZ_USERS + 2);
            // a harvest that SUCCEEDS must conserve and stay solvent - a silent over-credit or insolvency is a bug at
            // any size, so assert unconditionally. Only a clean revert (below) is a located limit.
            _assertRewardConserved(stabilityPool, _allActors(), g);
            _assertStabilityPoolSolvent(stabilityPool, _allActors(), g);
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
    function testFuzz_claim_sweep(uint256 poolSeed) public {
        Envelope memory e = buildEnvelope();
        _setEnvelopePointAtCollateralRatio(DEPLOY_COLLATERAL_RATIO, e.minWrapRate, e.pegPriceUSD);

        uint256 envelopePool = _capToSupplyHeadroom(_poolPeggedFor(e.maxPoolValueUSD, e.pegPriceUSD));
        uint256 poolPegged = _logScale(
            poolSeed,
            IStabilityPool_v3(stabilityPool).MIN_TOTAL_ASSET_SUPPLY(),
            type(uint128).max
        );
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
        _setEnvelopePointAtCollateralRatio(_belowRebalanceThreshold(), e.minWrapRate, e.pegPriceUSD); // max reward

        try this.rebalanceThenClaimProbe() returns (uint256 injected, uint256 claimedOut) {
            StabilityPoolConservationGhosts memory g = _rewardGhosts(injected, poolPegged, MAX_FUZZ_USERS + 2);
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
        require(IStabilityPoolManager_v2(stabilityPoolManager).rebalanceable(), "swept point not rebalanceable");
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
    /// range passed in is the physical input range (MIN_TOTAL_ASSET_SUPPLY..uint256 max, 1 wei..a price), never sized to the field
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

/// @notice ETH peg with a huge supply floor (1e6 tokens = $1M at the nominal $1 peg): the floor interactions
/// (seed, full exits down to the floor, loss headroom above it) exercised at the opposite extreme. aboutADollar is
/// carried on BOTH this peg and its market (below) - the stability pool deploy reads the MARKET, and the config-integrity test
/// asserts the two agree so an override can never again land on a config object the deploy ignores.
contract ConfigPeg_ETH_floorHuge is ConfigPeg_ETH {
    function aboutADollar() public pure override returns (uint256) {
        return 1e24;
    }
}

/// @notice Early-withdrawal fee at the largest the pool accepts, one wei below 100%. Every probe exits INSIDE the
/// no-fee window, so green means the fee is never charged where it must not be - any accidental in-window fee charge
/// breaks a round-trip loudly at this tripwire value.
contract ConfigMarket_ETH_fxUSD_earlyWithdrawalFeeMax is ConfigMarket_ETH_fxUSD_zeroFeesAndBounties {
    function stabilityPoolEarlyWithdrawalFeeRatio() public pure override returns (uint256) {
        return 1 ether - 1;
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
/// the stability pool deploy actually reads (the peg-only override the prior variant used was silently ignored; the
/// config-integrity test now forbids that). A large floor keeps the ceiling MAX = MIN * FACTOR_PRECISION saturated at
/// the field width, so the reward-integral cap never binds here - the opposite corner from the reachable-cap markets.
contract ConfigMarket_ETH_fxUSD_floorHuge is ConfigMarket_ETH_fxUSD_zeroFeesAndBounties {
    function aboutADollar() public pure override returns (uint256) {
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

// An aboutADollar=1-wei envelope variant is intentionally ABSENT: MAX = MIN * FACTOR_PRECISION ties the supply ceiling to
// the floor, so a 1-wei MIN caps the whole pool at ~$1 and the base suite's realistic-pool tests (rebalance, harvest,
// max-users, the field-width corners) cannot run. A low-floor deploy variant that also runs those tests cannot exist;
// the MIN=1 cap/floor behaviour is instead pinned by the deterministic mock tests in StabilityPoolLedgerGap.

contract StabilityPoolEnvelope_ETH_fxUSD_floorHuge is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory) {
        return EnvelopeLib.ethFxUSD();
    }

    function _marketSlug() internal pure override returns (string memory) {
        return "ethFxUSD_floorHuge";
    }

    function createETHMintersConfig() internal override returns (ConfigPeg peg, Config_MinterMarket[] memory markets) {
        peg = new ConfigPeg_ETH_floorHuge();
        markets = new Config_MinterMarket[](1);
        markets[0] = new ConfigMarket_ETH_fxUSD_floorHuge();
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

// ─── Per-peg-MIN markets - the ETH::fxUSD deploy config priced at a range of peg SCALES, each with MIN sized ~$1
// at its nominal peg (MIN = 1e18 / pegDollars), so a CORRECTLY-DEPLOYED market at that scale is proved to hold a full
// $-range pool. This is the "diverse markets, each deployed for its peg" axis, distinct from ethFxUSD's frozen-MIN
// wide-peg drift. Real deployed scales mirror the MINs their peg configs (script/config/pegs) deploy; extreme scales
// are invented for future/hypothetical markets ───

contract ConfigPeg_ETH_min1e13 is ConfigPeg_ETH {
    function aboutADollar() public pure override returns (uint256) {
        return 1e13;
    }
}

contract ConfigMarket_ETH_fxUSD_min1e13 is ConfigMarket_ETH_fxUSD_zeroFeesAndBounties {
    function aboutADollar() public pure override returns (uint256) {
        return 1e13;
    }
}

/// @notice BTC-scale market: the deployed BTC peg's MIN (1e13, as ConfigPeg_BTC deploys it) priced at ~$1e5 (BTC). A correctly-deployed
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
    function aboutADollar() public pure override returns (uint256) {
        return 1e27;
    }
}

contract ConfigMarket_ETH_fxUSD_min1e27 is ConfigMarket_ETH_fxUSD_zeroFeesAndBounties {
    function aboutADollar() public pure override returns (uint256) {
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
    function aboutADollar() public pure override returns (uint256) {
        return 1e18;
    }
}

contract ConfigMarket_ETH_fxUSD_min1e18 is ConfigMarket_ETH_fxUSD_zeroFeesAndBounties {
    function aboutADollar() public pure override returns (uint256) {
        return 1e18;
    }
}

/// @notice EUR-scale market: the deployed EUR peg's MIN (1e18, as ConfigPeg_EUR deploys it) priced at ~$1 (a
/// fiat-parity peg).
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
    function aboutADollar() public pure override returns (uint256) {
        return 1e9;
    }
}

contract ConfigMarket_ETH_fxUSD_min1e9 is ConfigMarket_ETH_fxUSD_zeroFeesAndBounties {
    function aboutADollar() public pure override returns (uint256) {
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
