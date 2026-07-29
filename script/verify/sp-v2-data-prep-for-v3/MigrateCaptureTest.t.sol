// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {Deploy_BTC_Minter} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {Deploy_EUR_Minter} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {Deploy_GOLD_Minter} from "@harbor-script/src/Deploy_GOLD_Minter.sol";
import {Deploy_MCAP_Minter} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {Deploy_SILVER_Minter} from "@harbor-script/src/Deploy_SILVER_Minter.sol";

/// @title MigrateCaptureTest — Prong A of the force-migrate verification
/// @notice Captures all view-function results AND interaction outcomes for every stability
/// pool, writing them to JSON. Run once before the migrate script and once after, then diff:
/// the force-migrate only reshapes internal accumulator storage, so the diff MUST be empty.
///
/// This mirrors script/test/MainnetForkUpgradeTest.t.sol (the v1->v2 upgrade verifier) but:
///   - derives pools + minters from salt keys (no hardcoded addresses), and
///   - reads each pool's depositors from holders/<saltKey>.txt (capture-sp-holders output),
/// so the captured set is exactly the migrated set across all 22 pools.
///
/// Produces per-pool files in:
///   tmp/{VERSION}/pre/{saltKey}.json   -- state snapshot before any interactions
///   tmp/{VERSION}/post/{saltKey}.json  -- interaction results + state snapshot after
///
/// Run (against a local mainnet fork) with VERSION=before, then VERSION=after around the
/// Migrate_StabilityPool_v2_Data_mainnet run; pass the same START_TIMESTAMP to both.
contract MigrateCaptureTest is
    Test,
    Deploy_BTC_Minter,
    Deploy_ETH_Minter,
    Deploy_EUR_Minter,
    Deploy_GOLD_Minter,
    Deploy_MCAP_Minter,
    Deploy_SILVER_Minter
{
    using LibString for string;

    string internal constant HOLDERS_DIR = "tmp/sp-holders/";

    struct PoolConfig {
        address proxy;
        address minter;
        string label; // == saltKey, e.g. "ETH::fxUSD::stabilityPoolCollateral"
    }

    /// @dev Mutable JSON object key -- unique per pool per phase (e.g., "pre_0", "post_3")
    string private _jsonKey;

    PoolConfig[] pools;
    // proxy => depositors (read from holders/<saltKey>.txt)
    mapping(address => address[]) poolDepositors;

    address testUser;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("local"));
        _setSaltPrefix("harbor_v1");

        testUser = makeAddr("testUser");

        Config_MinterMarket[] memory markets;
        (, markets) = createBTCMintersConfig();
        _registerMarkets(markets);
        (, markets) = createETHMintersConfig();
        _registerMarkets(markets);
        (, markets) = createEURMintersConfig();
        _registerMarkets(markets);
        (, markets) = createGOLDMintersConfig();
        _registerMarkets(markets);
        (, markets) = createMCAPMintersConfig();
        _registerMarkets(markets);
        (, markets) = createSILVERMintersConfig();
        _registerMarkets(markets);
    }

    function _registerMarkets(Config_MinterMarket[] memory markets) internal {
        for (uint256 i = 0; i < markets.length; i++) {
            string memory marketKey = MinterMarketConfigLib.salt(markets[i]);
            _registerPool(marketKey, StabilityPoolType.Collateral);
            _registerPool(marketKey, StabilityPoolType.Leveraged);
        }
    }

    function _registerPool(string memory marketKey, StabilityPoolType poolType) internal {
        string memory saltKey = stabilityPoolKey(marketKey, poolType);
        address proxy = stabilityPoolAddress(marketKey, poolType);
        address minter = minterAddress(marketKey);
        pools.push(PoolConfig(proxy, minter, saltKey));

        address[] memory holders = _readHolders(saltKey);
        for (uint256 i = 0; i < holders.length; i++) {
            poolDepositors[proxy].push(holders[i]);
        }
    }

    // ========================================================================
    // HOLDER FILE READING
    // ========================================================================

    /// @dev Read a pool's holder list from HOLDERS_DIR/<saltKey>.txt; '#' lines are comments.
    function _readHolders(string memory saltKey) internal returns (address[] memory holders) {
        string memory path = string.concat(HOLDERS_DIR, saltKey, ".txt");
        if (!vm.isFile(path)) {
            return new address[](0);
        }
        uint256 count = 0;
        while (true) {
            string memory line = vm.readLine(path);
            if (bytes(line).length == 0) {
                break;
            }
            if (_isAddressLine(line)) {
                count++;
            }
        }
        vm.closeFile(path);

        holders = new address[](count);
        uint256 idx = 0;
        while (true) {
            string memory line = vm.readLine(path);
            if (bytes(line).length == 0) {
                break;
            }
            if (_isAddressLine(line)) {
                holders[idx] = vm.parseAddress(line);
                idx++;
            }
        }
        vm.closeFile(path);
    }

    function _isAddressLine(string memory line) internal pure returns (bool) {
        bytes memory b = bytes(line);
        if (b.length == 0) {
            return false;
        }
        if (b[0] == 0x23) {
            return false;
        }
        return true;
    }

    // ========================================================================
    // HELPERS (called many times across pools/phases)
    // ========================================================================

    /// @dev Serialize a uint256 as a decimal string.
    function _serializeUint(string memory key, uint256 value) internal {
        vm.serializeString(_jsonKey, key, vm.toString(value));
    }

    /// @dev Serialize totalAssetSupply + per-user assetBalanceOf. Called 2x per pool (pre/post deposit).
    function _serializeBalances(address proxy, address[] memory users, string memory prefix) internal {
        _serializeUint(string.concat(prefix, "_totalAssetSupply"), IStabilityPool(proxy).totalAssetSupply());
        for (uint256 i = 0; i < users.length; i++) {
            _serializeUint(
                string.concat(prefix, "_user_", vm.toString(i), "_assetBalance"),
                IStabilityPool(proxy).assetBalanceOf(users[i])
            );
        }
    }

    /// @dev Serialize per-user per-token claimable. Called 6x per pool (before/after reward, half/full claim).
    function _serializeClaimables(
        address proxy,
        address[] memory users,
        address[] memory tokens,
        string memory prefix
    ) internal {
        for (uint256 u = 0; u < users.length; u++) {
            for (uint256 t = 0; t < tokens.length; t++) {
                _serializeUint(
                    string.concat(prefix, "_user_", vm.toString(u), "_reward_", vm.toString(t), "_claimable"),
                    IMultipleRewardAccumulator(proxy).claimable(users[u], tokens[t])
                );
            }
        }
    }

    /// @dev Claim for each user via try/catch, recording success/failure and per-token balance deltas.
    /// Called 2x per pool (half/full period). Records deltas instead of absolute balances to avoid
    /// cross-pool contamination when the same user appears in multiple pools.
    function _claimAllWithDeltas(
        address proxy,
        address[] memory users,
        address[] memory tokens,
        string memory prefix
    ) internal {
        // Snapshot balances before claims
        uint256[] memory balancesBefore = new uint256[](users.length * tokens.length);
        for (uint256 u = 0; u < users.length; u++) {
            for (uint256 t = 0; t < tokens.length; t++) {
                balancesBefore[u * tokens.length + t] = IERC20(tokens[t]).balanceOf(users[u]);
            }
        }

        // Claim for each user
        for (uint256 i = 0; i < users.length; i++) {
            vm.prank(users[i]);
            // Use the no-arg claim() (selector 0x4e71d92d). vm.prank above makes msg.sender = users[i],
            // so this is a self-claim under both v2 and v3. The claim(address) overload exists on v2
            // but was removed in v3 — using it here makes the v3 capture's claims revert and surface
            // as spurious diffs.
            try IMultipleRewardAccumulator(proxy).claim() {
                vm.serializeString(_jsonKey, string.concat(prefix, "_user_", vm.toString(i), "_success"), "true");
            } catch {
                vm.serializeString(_jsonKey, string.concat(prefix, "_user_", vm.toString(i), "_success"), "false");
            }
        }

        // Record balance deltas
        for (uint256 u = 0; u < users.length; u++) {
            for (uint256 t = 0; t < tokens.length; t++) {
                _serializeUint(
                    string.concat(prefix, "_user_", vm.toString(u), "_reward_", vm.toString(t), "_delta"),
                    IERC20(tokens[t]).balanceOf(users[u]) - balancesBefore[u * tokens.length + t]
                );
            }
        }
    }

    /// @dev Serialize reward token data for one token. Called per-token per-pool per-phase.
    function _serializeRewardToken(address proxy, address token, string memory ri) internal {
        vm.serializeString(_jsonKey, string.concat(ri, "_token"), vm.toString(token));
        vm.serializeString(_jsonKey, string.concat(ri, "_isActive"), "true");

        {
            (uint256 lastUpdate, uint256 finishAt, uint256 rate, uint256 queued) = IMultipleRewardDistributor(proxy)
                .rewardData(token);
            _serializeUint(string.concat(ri, "_lastUpdate"), lastUpdate);
            _serializeUint(string.concat(ri, "_finishAt"), finishAt);
            _serializeUint(string.concat(ri, "_rate"), rate);
            _serializeUint(string.concat(ri, "_queued"), queued);
        }

        try IMultipleRewardDistributor(proxy).pendingRewards(token) returns (
            uint256 distributable,
            uint256 undistributed
        ) {
            vm.serializeString(_jsonKey, string.concat(ri, "_pendingRewards_ok"), "true");
            _serializeUint(string.concat(ri, "_pendingDistributable"), distributable);
            _serializeUint(string.concat(ri, "_pendingUndistributed"), undistributed);
        } catch {
            vm.serializeString(_jsonKey, string.concat(ri, "_pendingRewards_ok"), "false");
            _serializeUint(string.concat(ri, "_pendingDistributable"), 0);
            _serializeUint(string.concat(ri, "_pendingUndistributed"), 0);
        }
    }

    /// @dev Serialize per-user view data. Called per-user per-pool per-phase.
    function _serializeUser(address proxy, address user, address[] memory activeTokens, string memory ui) internal {
        vm.serializeString(_jsonKey, string.concat(ui, "_address"), vm.toString(user));
        _serializeUint(string.concat(ui, "_assetBalance"), IStabilityPool(proxy).assetBalanceOf(user));

        {
            (uint64 wStart, uint64 wEnd) = IStabilityPool(proxy).getWithdrawalRequest(user);
            _serializeUint(string.concat(ui, "_withdrawalStart"), uint256(wStart));
            _serializeUint(string.concat(ui, "_withdrawalEnd"), uint256(wEnd));
        }

        // rewardReceiver intentionally not captured: removed in v3 (so reading it reverts), and
        // unused on mainnet (no one called setRewardReceiver — value would always be 0x0).
        // The migration does not touch reward-receiver storage, so dropping it loses no signal.

        for (uint256 t = 0; t < activeTokens.length; t++) {
            string memory ut = string.concat(ui, "_reward_", vm.toString(t));
            _serializeUint(
                string.concat(ut, "_claimable"),
                IMultipleRewardAccumulator(proxy).claimable(user, activeTokens[t])
            );
            _serializeUint(
                string.concat(ut, "_claimed"),
                IMultipleRewardAccumulator(proxy).claimed(user, activeTokens[t])
            );
        }
    }

    /// @dev Serialize all view functions for a pool into the current JSON object.
    function _serializePoolState(address proxy, address[] memory depositors, string memory prefix) internal {
        vm.serializeString(_jsonKey, string.concat(prefix, "_owner"), vm.toString(IBaoOwnable(proxy).owner()));
        {
            IStabilityPool pool = IStabilityPool(proxy);
            _serializeUint(string.concat(prefix, "_totalAssetSupply"), pool.totalAssetSupply());
            _serializeUint(string.concat(prefix, "_lastAssetLossError"), pool.lastAssetLossError());
            _serializeUint(string.concat(prefix, "_earlyWithdrawalFee"), pool.getEarlyWithdrawalFee());
            vm.serializeString(_jsonKey, string.concat(prefix, "_feeAddress"), vm.toString(pool.getFeeAddress()));
            {
                (uint64 startDelay, uint64 endWindow) = pool.getWithdrawalWindow();
                _serializeUint(string.concat(prefix, "_withdrawalStartDelay"), uint256(startDelay));
                _serializeUint(string.concat(prefix, "_withdrawalEndWindow"), uint256(endWindow));
            }
            vm.serializeString(
                _jsonKey,
                string.concat(prefix, "_liquidationToken"),
                vm.toString(pool.LIQUIDATION_TOKEN())
            );
            _serializeUint(string.concat(prefix, "_minTotalAssetSupply"), pool.MIN_TOTAL_ASSET_SUPPLY());
            _serializeUint(string.concat(prefix, "_minDeposit"), pool.MIN_DEPOSIT());
            vm.serializeString(_jsonKey, string.concat(prefix, "_assetToken"), vm.toString(pool.ASSET_TOKEN()));
        }

        _serializeUint(
            string.concat(prefix, "_rewardPeriodLength"),
            uint256(IMultipleRewardDistributor(proxy).REWARD_PERIOD_LENGTH())
        );

        {
            address[] memory activeTokens = IMultipleRewardDistributor(proxy).activeRewardTokens();
            _serializeUint(string.concat(prefix, "_activeRewardTokenCount"), activeTokens.length);
            for (uint256 i = 0; i < activeTokens.length; i++) {
                _serializeRewardToken(proxy, activeTokens[i], string.concat(prefix, "_reward_", vm.toString(i)));
            }
        }

        {
            address[] memory historicalTokens = IMultipleRewardDistributor(proxy).historicalRewardTokens();
            _serializeUint(string.concat(prefix, "_historicalRewardTokenCount"), historicalTokens.length);
            for (uint256 i = 0; i < historicalTokens.length; i++) {
                vm.serializeString(
                    _jsonKey,
                    string.concat(prefix, "_historicalRewardToken_", vm.toString(i)),
                    vm.toString(historicalTokens[i])
                );
            }
        }

        {
            address[] memory activeTokens = IMultipleRewardDistributor(proxy).activeRewardTokens();
            _serializeUint(string.concat(prefix, "_depositorCount"), depositors.length);
            for (uint256 u = 0; u < depositors.length; u++) {
                _serializeUser(proxy, depositors[u], activeTokens, string.concat(prefix, "_user_", vm.toString(u)));
            }
        }
    }

    /// @dev Try all interactions on a pool with before/after snapshots. Called once per pool.
    function _doInteractions(address proxy, string memory prefix) internal {
        address[] memory depositors = poolDepositors[proxy];
        address[] memory allUsers = new address[](depositors.length + 1);
        for (uint256 i = 0; i < depositors.length; i++) {
            allUsers[i] = depositors[i];
        }
        allUsers[depositors.length] = testUser;

        address[] memory activeTokens = IMultipleRewardDistributor(proxy).activeRewardTokens();

        // 1. Pre-deposit balances
        _serializeBalances(proxy, allUsers, string.concat(prefix, "_preDeposit"));

        // 2. Deposit (new user)
        {
            address assetToken = IStabilityPool(proxy).ASSET_TOKEN();
            deal(assetToken, testUser, 100 ether);
            vm.startPrank(testUser);
            IERC20(assetToken).approve(proxy, type(uint256).max);
            try IStabilityPool(proxy).deposit(100 ether, testUser, 0) {
                vm.serializeString(_jsonKey, string.concat(prefix, "_deposit_success"), "true");
            } catch {
                vm.serializeString(_jsonKey, string.concat(prefix, "_deposit_success"), "false");
            }
            vm.stopPrank();
            _serializeUint(string.concat(prefix, "_deposit_amount"), 100 ether);
        }

        // 2b. Existing depositor deposit (exercises checkpoint with historical reward integral)
        if (depositors.length > 0) {
            address existingDepositor = depositors[0];
            address assetToken2 = IStabilityPool(proxy).ASSET_TOKEN();
            deal(assetToken2, existingDepositor, 100 ether);
            vm.startPrank(existingDepositor);
            IERC20(assetToken2).approve(proxy, type(uint256).max);
            try IStabilityPool(proxy).deposit(100 ether, existingDepositor, 0) {
                vm.serializeString(_jsonKey, string.concat(prefix, "_existingDepositorDeposit_success"), "true");
            } catch {
                vm.serializeString(_jsonKey, string.concat(prefix, "_existingDepositorDeposit_success"), "false");
            }
            vm.stopPrank();
            vm.serializeString(
                _jsonKey,
                string.concat(prefix, "_existingDepositorDeposit_user"),
                vm.toString(existingDepositor)
            );
        }

        // 3. Post-deposit balances
        _serializeBalances(proxy, allUsers, string.concat(prefix, "_postDeposit"));

        // 4. Pre-depositReward claimables
        _serializeClaimables(proxy, allUsers, activeTokens, string.concat(prefix, "_preReward"));

        // 5. Deposit reward (prank owner who already has depositor role)
        {
            address liquidationToken = IStabilityPool(proxy).LIQUIDATION_TOKEN();
            address owner = IBaoOwnable(proxy).owner();
            deal(liquidationToken, owner, 10 ether);
            vm.startPrank(owner);
            IERC20(liquidationToken).approve(proxy, type(uint256).max);
            try IMultipleRewardDistributor(proxy).depositReward(liquidationToken, 10 ether) {
                vm.serializeString(_jsonKey, string.concat(prefix, "_depositReward_success"), "true");
            } catch {
                vm.serializeString(_jsonKey, string.concat(prefix, "_depositReward_success"), "false");
            }
            vm.stopPrank();
            vm.serializeString(_jsonKey, string.concat(prefix, "_depositReward_token"), vm.toString(liquidationToken));
            _serializeUint(string.concat(prefix, "_depositReward_amount"), 10 ether);
        }

        // 6. Post-depositReward claimables
        _serializeClaimables(proxy, allUsers, activeTokens, string.concat(prefix, "_postReward"));

        // 7. Warp half period
        uint256 halfPeriod = uint256(IMultipleRewardDistributor(proxy).REWARD_PERIOD_LENGTH()) / 2;
        vm.warp(block.timestamp + halfPeriod);
        _serializeUint(string.concat(prefix, "_warp_half_seconds"), halfPeriod);

        // 8-10. Half-period: claimable before, claim all (with balance deltas), claimable after
        _serializeClaimables(proxy, allUsers, activeTokens, string.concat(prefix, "_half_preClaim"));
        _claimAllWithDeltas(proxy, allUsers, activeTokens, string.concat(prefix, "_half_claim"));
        _serializeClaimables(proxy, allUsers, activeTokens, string.concat(prefix, "_half_postClaim"));

        // 11. Warp remaining half period
        vm.warp(block.timestamp + halfPeriod);
        _serializeUint(string.concat(prefix, "_warp_total_seconds"), halfPeriod * 2);

        // 12-14. Full-period: claimable before, claim all (with balance deltas), claimable after
        _serializeClaimables(proxy, allUsers, activeTokens, string.concat(prefix, "_full_preClaim"));
        _claimAllWithDeltas(proxy, allUsers, activeTokens, string.concat(prefix, "_full_claim"));
        _serializeClaimables(proxy, allUsers, activeTokens, string.concat(prefix, "_full_postClaim"));

        // 15. Assert all claimable == 0 after full period
        {
            bool allZero = true;
            for (uint256 u = 0; u < allUsers.length && allZero; u++) {
                for (uint256 t = 0; t < activeTokens.length && allZero; t++) {
                    if (IMultipleRewardAccumulator(proxy).claimable(allUsers[u], activeTokens[t]) > 0) {
                        allZero = false;
                    }
                }
            }
            vm.serializeString(_jsonKey, string.concat(prefix, "_full_allClaimableZero"), allZero ? "true" : "false");
        }

        // 16. Withdraw for test user (request, warp into window, withdraw)
        vm.startPrank(testUser);
        try IStabilityPool(proxy).requestWithdrawal() {
            vm.serializeString(_jsonKey, string.concat(prefix, "_requestWithdrawal_success"), "true");
            vm.stopPrank();

            {
                (uint64 wStart, ) = IStabilityPool(proxy).getWithdrawalRequest(testUser);
                if (wStart > 0) {
                    vm.warp(uint256(wStart) + 1);
                }
            }

            uint256 withdrawAmount = IStabilityPool(proxy).assetBalanceOf(testUser) / 2;
            vm.prank(testUser);
            try IStabilityPool(proxy).withdraw(withdrawAmount, testUser, 0) {
                vm.serializeString(_jsonKey, string.concat(prefix, "_withdraw_success"), "true");
            } catch {
                vm.serializeString(_jsonKey, string.concat(prefix, "_withdraw_success"), "false");
            }
            _serializeUint(string.concat(prefix, "_withdraw_amount"), withdrawAmount);
        } catch {
            vm.stopPrank();
            vm.serializeString(_jsonKey, string.concat(prefix, "_requestWithdrawal_success"), "false");
            vm.serializeString(_jsonKey, string.concat(prefix, "_withdraw_success"), "false");
            _serializeUint(string.concat(prefix, "_withdraw_amount"), 0);
        }
    }

    // ========================================================================
    // TEST FUNCTION
    // ========================================================================

    /// @notice Capture all view results and interaction outcomes to JSON files.
    /// @dev Run with VERSION=before (pre-migrate) or VERSION=after (post-migrate).
    function test_captureState() public {
        string memory version = vm.envOr("VERSION", string("before"));
        string memory poolFilter = vm.envOr("POOL_FILTER", string(""));

        // Normalize timestamp so before/after runs start from the same point (the migrate run
        // advances block.timestamp, which would otherwise shift reward accrual).
        {
            uint256 startTimestamp = vm.envOr("START_TIMESTAMP", uint256(0));
            console.log("Current block:", block.number, "timestamp:", block.timestamp);
            if (startTimestamp > 0) {
                require(startTimestamp >= block.timestamp, "START_TIMESTAMP is in the past");
                vm.roll(block.number + 1);
                vm.warp(startTimestamp);
            }
            console.log("Normalized block:", block.number, "timestamp:", block.timestamp);
        }

        string memory preDir = string.concat("tmp/", version, "/pre");
        string memory postDir = string.concat("tmp/", version, "/post");
        vm.createDir(preDir, true);
        vm.createDir(postDir, true);

        uint256 activeCount = 0;

        // PRE FILES: state snapshot before any interactions (one per pool)
        for (uint256 i = 0; i < pools.length; i++) {
            if (!_poolMatchesFilter(pools[i].label, poolFilter)) {
                continue;
            }
            activeCount++;

            _jsonKey = string.concat("pre_", vm.toString(i));
            vm.serializeString(_jsonKey, "proxy", vm.toString(pools[i].proxy));
            vm.serializeString(_jsonKey, "minter", vm.toString(pools[i].minter));
            vm.serializeString(_jsonKey, "label", pools[i].label);
            _serializePoolState(pools[i].proxy, poolDepositors[pools[i].proxy], "state");

            vm.writeJson(
                vm.serializeString(_jsonKey, "_complete", "true"),
                string.concat(preDir, "/", pools[i].label, ".json")
            );
            console.log("Pre:", pools[i].label);
        }

        // INTERACTIONS: deposit, depositReward, warp, claim, withdraw
        for (uint256 i = 0; i < pools.length; i++) {
            if (!_poolMatchesFilter(pools[i].label, poolFilter)) {
                continue;
            }
            _jsonKey = string.concat("post_", vm.toString(i));
            vm.serializeString(_jsonKey, "proxy", vm.toString(pools[i].proxy));
            vm.serializeString(_jsonKey, "minter", vm.toString(pools[i].minter));
            vm.serializeString(_jsonKey, "label", pools[i].label);
            _doInteractions(pools[i].proxy, "interact");
        }

        // POST FILES: interaction results + state after interactions (one per pool)
        for (uint256 i = 0; i < pools.length; i++) {
            if (!_poolMatchesFilter(pools[i].label, poolFilter)) {
                continue;
            }
            _jsonKey = string.concat("post_", vm.toString(i));
            address[] memory depositors = poolDepositors[pools[i].proxy];
            address[] memory postDepositors = new address[](depositors.length + 1);
            for (uint256 j = 0; j < depositors.length; j++) {
                postDepositors[j] = depositors[j];
            }
            postDepositors[depositors.length] = testUser;
            _serializePoolState(pools[i].proxy, postDepositors, "state");

            vm.writeJson(
                vm.serializeString(_jsonKey, "_complete", "true"),
                string.concat(postDir, "/", pools[i].label, ".json")
            );
            console.log("Post:", pools[i].label);
        }

        console.log("Pool count:", activeCount);
    }

    /// @dev Match poolFilter against a label as a ::-delimited segment, so "ETH"
    /// matches "ETH::fxUSD::..." but NOT "BTC::stETH::..." — consistent with the
    /// ::SEGMENT:: filter in Migrate_StabilityPool_v2_Data_mainnet. Empty = match all.
    function _poolMatchesFilter(string memory label, string memory poolFilter) internal pure returns (bool) {
        if (bytes(poolFilter).length == 0) {
            return true;
        }
        return string.concat("::", label, "::").contains(string.concat("::", poolFilter, "::"));
    }
}
