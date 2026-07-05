// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {SaltString} from "@bao-script/deployment/SaltString.sol";
import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/// @notice How `maxPoolPegged` is split across the depositors — concentration is a stress axis, not a detail: the
/// reward `pending` field holds a SINGLE user's share, so a whale owning ~all of the pool makes an entire rebalance
/// reward land in one `pending`, which a spread of equal users never reveals.
enum DepositShape {
    Equal,
    WhaleAndDust
}

/// @notice A named market's supported operating envelope: the market conditions (pool size, price/rate range, harvest
/// size, loss depth) plus the participant mix (users that build the pool, keepers that execute harvests/rebalances).
/// Values are 1e18-scaled where they are prices/rates. Produced by `buildEnvelope()` so a derived contract can take one
/// from `EnvelopeLib`, override it, or start from another and tweak a single field.
struct Envelope {
    string name;
    // market axes
    uint256 maxPoolPegged; // pool token-count cap, wei
    uint256 price; // nominal operating collateral price (pegged per collateral), 1e18-scaled
    uint256 rate; // nominal operating wrap rate, 1e18-scaled
    uint256 minPrice; // sweep bounds ...
    uint256 maxPrice;
    uint256 minRate;
    uint256 maxRate;
    uint256 maxHarvestPegged; // largest single harvest, pegged value (50% of pool)
    uint256 maxLossDepth; // sequential liquidations (drives the DecrementalFloatingPoint product/exponent)
    // participant axes
    uint256 userCount; // depositors that build the StabilityPool supply
    DepositShape depositShape;
    uint256 keeperCount; // executors of harvests / rebalances
}

/// @notice The catalog of named markets. Real (ETH/fxUSD, BTC, ...) and made-up markets are entries here; a derived
/// test contract selects one in `buildEnvelope()`, optionally tweaking one field off another entry.
library EnvelopeLib {
    /// @dev ETH::fxUSD at its mainnet-nominal price/rate (ETH ~ $4000, no accrued yield). The price/rate sweep bounds
    /// span the minter's supported extremes; the pool size here is a validation scale (the $1B binding-corner envelope
    /// lands in a later batch).
    function ethFxUSD() internal pure returns (Envelope memory e) {
        e = Envelope({
            name: "ETH/fxUSD",
            maxPoolPegged: 1_000 ether, // 1000 haETH
            price: 1 ether / 4000, // ETH per fxUSD (4000 fxUSD per ETH)
            rate: 1 ether, // 1 fxSAVE = 1 fxUSD
            minPrice: 1 ether / 1e8,
            maxPrice: 1 ether * 1e8,
            minRate: 1 ether / 1e5,
            maxRate: 1 ether * 1e5,
            maxHarvestPegged: 500 ether, // 50% of the pool
            maxLossDepth: 8,
            userCount: 3,
            depositShape: DepositShape.Equal,
            keeperCount: 1
        });
    }
}

/// @notice Envelope-fit harness: stands up the REAL protocol (Minter + StabilityPool + StabilityPoolManager) via the
/// production `deployForPeg` scripts, then exercises the happy paths — deposit, withdraw, harvest, rebalance — with real
/// users and keepers and reads the results back for correctness. Green means the protocol HOLDS the whole envelope; a
/// revert at an envelope-reachable corner is the where-it-breaks finding, to be fixed (widen/batch) or the envelope
/// narrowed — never asserted as intended. Each derived contract is one named, documented market; `buildEnvelope()` is
/// the seam that lets it take an `EnvelopeLib` entry, override it, or tweak one field off another.
///
/// This batch (foundation) proves the system stands up and a deposit/withdraw round-trip reads back exactly; harvest,
/// rebalance, the binding corner, the price/rate sweep, and the market catalog land in later batches.
abstract contract StabilityPoolEnvelopeBase is BaoTest, Deploy_ETH_Minter {
    address internal minter;
    address internal stabilityPool; // the collateral-side StabilityPool
    address internal stabilityPoolManager;
    address internal pegged;
    address internal leveraged;
    address internal wrappedCollateral;

    MockWrappedPriceOracle internal mockOracle;

    address[] internal users; // build the pool
    address[] internal keepers; // execute harvests / rebalances (roles granted in the harvest/rebalance batch)

    /// @dev The market this harness exercises. Derived contracts override to select / tweak an envelope.
    function buildEnvelope() internal pure virtual returns (Envelope memory);

    function _shouldPersistState() internal pure override returns (bool) {
        return false;
    }

    function setUp() public virtual {
        Envelope memory e = buildEnvelope();

        // ── stand up the real protocol via the production deploy scripts (RebalanceFairness model) ──
        address factory = _ensureBaoFactory();
        vm.selectFork(vm.createSelectFork(vm.rpcUrl("mainnet"), 24699497)); // pinned for caching; real fxSAVE/fxUSD exist
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

        // ── install the movable oracle so price/rate are set freely (the deploy points it at a not-yet-deployed addr) ──
        mockOracle = new MockWrappedPriceOracle();
        mockOracle.setLatestAnswer(e.price, e.rate);

        // ── configure the minter: movable oracle + fee-free minting for this test contract ──
        address minterOwner = IBaoOwnable(minter).owner();
        uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
        vm.startPrank(minterOwner);
        IMinter(minter).updatePriceOracle(address(mockOracle));
        IBaoRoles(minter).grantRoles(address(this), zeroFeeRole);
        vm.stopPrank();

        // ── bounties/cuts to zero so the full reward reaches the pool (maximum field stress) ──
        address spmOwner = IBaoOwnable(stabilityPoolManager).owner();
        vm.startPrank(spmOwner);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestCutRatio(0);
        IStabilityPoolManager(stabilityPoolManager).updateHarvestBountyRatio(0);
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceBountyRatio(0);
        vm.stopPrank();

        _createUsers(e.userCount);
        _createKeepers(e.keeperCount);
        _seedPool(); // a permanent MIN_DEPOSIT seed so every user can fully exit later
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

    function _createKeepers(uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            keepers.push(makeAddr(string.concat("keeper", vm.toString(i))));
        }
    }

    // ─── exercise primitives (drive the real protocol) ───

    function _setPriceRate(uint256 price, uint256 rate) internal {
        mockOracle.setLatestAnswer(price, rate);
    }

    /// @dev Mint `pegged` to `to`, backed by real collateral at the current price (so the Minter holds backing to
    /// redeem in a rebalance). Returns the amount actually minted.
    function _mintPeggedTo(address to, uint256 collateralAmount) internal returns (uint256 peggedMinted) {
        deal(wrappedCollateral, address(this), collateralAmount);
        IERC20(wrappedCollateral).approve(minter, collateralAmount);
        peggedMinted = IMinter(minter).freeMintPeggedToken(collateralAmount, to);
    }

    /// @dev Mint leveraged tokens to `to` — the collateral buffer that keeps the collateral ratio healthy.
    function _mintLeveragedTo(address to, uint256 collateralAmount) internal returns (uint256 leveragedMinted) {
        deal(wrappedCollateral, address(this), collateralAmount);
        IERC20(wrappedCollateral).approve(minter, collateralAmount);
        leveragedMinted = IMinter(minter).freeMintLeveragedToken(collateralAmount, to);
    }

    /// @dev The collateral needed to mint `peggedAmount` at the current envelope price (peggedMinted = collateral *
    /// price / 1e18), rounded up so the mint reaches at least the target.
    function _collateralFor(uint256 peggedAmount) internal pure returns (uint256) {
        Envelope memory e = buildEnvelope();
        return (peggedAmount * 1 ether + e.price - 1) / e.price;
    }

    function _deposit(address who, uint256 amount) internal {
        vm.startPrank(who);
        IStabilityPool(stabilityPool).deposit(amount, who, 0);
        vm.stopPrank();
    }

    /// @dev Full exit inside the no-fee withdrawal window (request → warp into the window → withdraw everything).
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

    /// @dev Distribute `total` pegged across `users` per `shape`, returning each user's share (Σ shares == total).
    function _split(uint256 total, DepositShape shape) internal view returns (uint256[] memory shares) {
        uint256 n = users.length;
        shares = new uint256[](n);
        if (shape == DepositShape.WhaleAndDust) {
            shares[0] = total - (n - 1); // the whale takes all but 1 wei per other user
            for (uint256 i = 1; i < n; i++) {
                shares[i] = 1;
            }
        } else {
            uint256 each = total / n;
            shares[0] = each + (total - each * n); // first absorbs the remainder
            for (uint256 i = 1; i < n; i++) {
                shares[i] = each;
            }
        }
    }

    /// @dev Mint the pool's pegged (plus a leveraged buffer for a healthy collateral ratio) and hand each user its
    /// share. Returns the actual per-user shares.
    function _fundUsersToPool(uint256 poolPegged, DepositShape shape) internal returns (uint256[] memory shares) {
        uint256 minted = _mintPeggedTo(address(this), _collateralFor(poolPegged));
        _mintLeveragedTo(address(this), _collateralFor(poolPegged) / 2); // buffer → collateral ratio ~1.5

        shares = _split(minted, shape);
        for (uint256 i = 0; i < users.length; i++) {
            IERC20(pegged).transfer(users[i], shares[i]);
        }
    }

    function _seedPool() internal {
        uint256 minDeposit = IStabilityPool(stabilityPool).MIN_DEPOSIT();
        _mintPeggedTo(address(this), _collateralFor(minDeposit) + 1 ether);
        IERC20(pegged).approve(stabilityPool, type(uint256).max);
        IStabilityPool(stabilityPool).deposit(minDeposit, address(this), 0);
    }

    function _sum(uint256[] memory xs) internal pure returns (uint256 total) {
        for (uint256 i = 0; i < xs.length; i++) {
            total += xs[i];
        }
    }

    // ─── walk tests (run for every derived market) ───

    /// @notice Deposit happy path: users build the StabilityPool supply, and the supply counter and each user's
    /// balance read back EXACTLY (fresh pool, no loss → balance == deposited); then every user exits inside the no-fee
    /// window and gets its whole deposit back, leaving the supply at the seed. Green = the deposit/withdraw accounting
    /// holds across this market's participant mix.
    function test_envelope_depositWithdraw_holds() public {
        Envelope memory e = buildEnvelope();
        uint256[] memory shares = _fundUsersToPool(e.maxPoolPegged, e.depositShape);

        uint256 supplySeed = IERC20(stabilityPool).totalSupply();
        for (uint256 i = 0; i < users.length; i++) {
            _deposit(users[i], shares[i]);
            assertEq(IERC20(stabilityPool).balanceOf(users[i]), shares[i], "fresh deposit: balance == deposited");
        }
        assertEq(IERC20(stabilityPool).totalSupply(), supplySeed + _sum(shares), "totalSupply == seed + deposits");

        for (uint256 i = 0; i < users.length; i++) {
            uint256 walletBefore = IERC20(pegged).balanceOf(users[i]);
            _withdrawAll(users[i]);
            assertEq(IERC20(pegged).balanceOf(users[i]) - walletBefore, shares[i], "withdraw returns the full deposit");
            assertEq(IERC20(stabilityPool).balanceOf(users[i]), 0, "position cleared");
        }
        assertEq(IERC20(stabilityPool).totalSupply(), supplySeed, "supply back to the seed after all exits");
    }
}

/// @notice ETH::fxUSD market — the seed envelope. Other markets (USD/BTC inverse, made-up, the deliberately-extreme
/// minter-full) are added as sibling contracts in a later batch.
contract StabilityPoolEnvelope_ETH_fxUSD is StabilityPoolEnvelopeBase {
    function buildEnvelope() internal pure override returns (Envelope memory) {
        return EnvelopeLib.ethFxUSD();
    }
}
