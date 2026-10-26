// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IYieldVaultManager} from "@harbor/interfaces/IYieldVaultManager.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {allMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {FROZEN_MARKETS_CAPTURE} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";

import {MockStabilityPool} from "@harbor-test/mocks/MockStabilityPool.sol";

/// @title MarketsCapture - Prong A of the v3 upgrade's verification
/// @notice Records every market's contracts - minter, both stability pools, manager - to JSON: each one's state, and
///         each pool's behaviour under the same interactions. Run once before the upgrade (`VERSION=before`) and once
///         after (`VERSION=after`); `MarketsExpectedAfter` then writes what the after record must read, and the runner
///         diffs the two. Every value must read the same after as before, or as written down beforehand.
///
///         The before is taken where the markets still run - a fork of mainnet at the block of the upgrade's holder
///         capture, `FROZEN_MARKETS_CAPTURE`, the last before the pause that froze every minter and pool - with each
///         manager's own implementation put back (the managers were paused earlier, at block 26,241,030). The after is
///         taken on anvil, after the upgrade script ran there. Both are warped to the same START_TIMESTAMP, so
///         time-dependent values compare.
///
///         Each version is read through its own form where the two differ (a pool's reward reads, the views v3 dropped
///         or added), into the same keys.
///
/// Writes, per contract (its salt key):
///   tmp/v3-upgrade/{VERSION}/pre/{saltKey}.json   -- its state before any interaction
///   tmp/v3-upgrade/{VERSION}/post/{saltKey}.json  -- a pool's interaction results, then its state after them
///
/// Run by run-upgrade-before-after, with VERSION and START_TIMESTAMP set: the before forks mainnet itself; the after runs
/// on the fork given on the forge command line, anvil.
contract MarketsCapture is Test, HarborDeployer {
    /// @dev The managers were paused in this block; the block before it holds each one's own implementation.
    uint256 internal constant MANAGERS_PAUSED_AT = 26_241_030;

    /// @dev Mutable JSON object key - unique per contract per phase.
    string private _jsonKey;

    bool internal isBefore;
    Config_MinterMarket[] internal markets;
    address internal testUser;

    function setUp() public {
        string memory version = vm.envString("VERSION");
        isBefore = keccak256(bytes(version)) == keccak256("before");
        require(
            isBefore || keccak256(bytes(version)) == keccak256("after"),
            string.concat("VERSION is '", version, "': it must be before or after")
        );
        _setSaltPrefix("harbor_v1");
        testUser = makeAddr("testUser");
        markets = allMintersConfig();
        for (uint256 i = 0; i < markets.length; ++i) {
            vm.makePersistent(address(markets[i]));
        }
    }

    // ========================================================================
    // TEST FUNCTION
    // ========================================================================

    /// @notice Record every market's contracts, and each pool's interactions, to JSON.
    function test_capture() public {
        string memory version = isBefore ? "before" : "after";
        uint256 captureBlock = HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE);
        if (isBefore) {
            vm.createSelectFork(vm.rpcUrl("mainnet"), captureBlock);
            _restoreManagers();
        } else {
            require(
                block.number > captureBlock,
                string.concat(
                    "the after runs at block ",
                    vm.toString(block.number),
                    ", not after the capture's block ",
                    vm.toString(captureBlock)
                )
            );
        }

        // Normalize timestamp so before and after start from the same point: the after runs on anvil after the upgrade
        // script, and the before at the capture's block, days earlier.
        {
            uint256 startTimestamp = vm.envUint("START_TIMESTAMP");
            console.log("Current block:", block.number, "timestamp:", block.timestamp);
            require(startTimestamp >= block.timestamp, "START_TIMESTAMP is in the past");
            vm.roll(block.number + 1);
            vm.warp(startTimestamp);
            console.log("Normalized block:", block.number, "timestamp:", block.timestamp);
        }

        string memory preDir = string.concat("tmp/v3-upgrade/", version, "/pre");
        string memory postDir = string.concat("tmp/v3-upgrade/", version, "/post");
        vm.createDir(preDir, true);
        vm.createDir(postDir, true);

        // PRE FILES: each contract's state before any interaction
        for (uint256 i = 0; i < markets.length; ++i) {
            _writeMinter(markets[i], preDir);
            _writePool(markets[i], StabilityPoolType.Collateral, preDir, "pre_");
            _writePool(markets[i], StabilityPoolType.Leveraged, preDir, "pre_");
            _writeManager(markets[i], preDir);
        }

        // INTERACTIONS: deposit, depositReward, warp, claim, withdraw - pool by pool
        for (uint256 i = 0; i < markets.length; ++i) {
            _interact(markets[i], StabilityPoolType.Collateral);
            _interact(markets[i], StabilityPoolType.Leveraged);
        }

        // POST FILES: each pool's interaction results and its state after them
        for (uint256 i = 0; i < markets.length; ++i) {
            _writePool(markets[i], StabilityPoolType.Collateral, postDir, "post_");
            _writePool(markets[i], StabilityPoolType.Leveraged, postDir, "post_");
        }
    }

    // ========================================================================
    // THE MANAGERS' OWN IMPLEMENTATIONS
    // ========================================================================

    /// @dev Put each manager's own implementation back, as it was in the block before the managers' pause: they have
    ///      been frozen since, so their storage is what it was then. Only on the before's fork, in memory.
    function _restoreManagers() private {
        address[] memory managers = new address[](markets.length);
        for (uint256 i = 0; i < markets.length; ++i) {
            managers[i] = stabilityPoolManagerAddress(markets[i]);
        }
        uint256 beforeFork = vm.activeFork();
        vm.createSelectFork(vm.rpcUrl("mainnet"), MANAGERS_PAUSED_AT - 1);
        bytes32[] memory implementations = new bytes32[](managers.length);
        for (uint256 i = 0; i < managers.length; ++i) {
            implementations[i] = vm.load(managers[i], ERC1967Utils.IMPLEMENTATION_SLOT);
        }
        vm.selectFork(beforeFork);
        for (uint256 i = 0; i < managers.length; ++i) {
            vm.store(managers[i], ERC1967Utils.IMPLEMENTATION_SLOT, implementations[i]);
        }
    }

    // ========================================================================
    // MINTER AND MANAGER
    // ========================================================================

    /// @dev Write the minter's state: the config it holds, the backing it records, its balances, the wrapped collateral
    ///      it holds, whom it reads and pays, and the roles of the manager and genesis.
    function _writeMinter(Config_MinterMarket market, string memory dir) private {
        string memory label = minterKey(market);
        address minter = minterAddress(market);
        _jsonKey = string.concat("pre_", label);
        vm.serializeString(_jsonKey, "label", label);
        vm.serializeString(_jsonKey, "minter_owner", vm.toString(IBaoOwnable(minter).owner()));
        vm.serializeString(_jsonKey, "minter_config", vm.toString(abi.encode(IMinter(minter).config())));
        _serializeUint("minter_recordedBacking", IMinter(minter).collateralTokenBalance());
        _serializeUint("minter_peggedBalance", IMinter(minter).peggedTokenBalance());
        _serializeUint("minter_leveragedBalance", IMinter(minter).leveragedTokenBalance());
        address wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();
        _serializeUint("minter_wrappedCollateralHeld", IERC20(wrappedCollateral).balanceOf(minter));
        vm.serializeString(_jsonKey, "minter_wrappedCollateralToken", vm.toString(wrappedCollateral));
        vm.serializeString(_jsonKey, "minter_peggedToken", vm.toString(IMinter(minter).PEGGED_TOKEN()));
        vm.serializeString(_jsonKey, "minter_leveragedToken", vm.toString(IMinter(minter).LEVERAGED_TOKEN()));
        vm.serializeString(_jsonKey, "minter_priceOracle", vm.toString(IMinter(minter).priceOracle()));
        vm.serializeString(_jsonKey, "minter_reservePool", vm.toString(IMinter(minter).reservePool()));
        vm.serializeString(_jsonKey, "minter_feeReceiver", vm.toString(IMinter(minter).feeReceiver()));
        _serializeUint("minter_rolesOf_manager", IBaoRoles(minter).rolesOf(stabilityPoolManagerAddress(market)));
        _serializeUint("minter_rolesOf_genesis", IBaoRoles(minter).rolesOf(genesisAddress(market)));
        vm.writeJson(vm.serializeString(_jsonKey, "_complete", "true"), string.concat(dir, "/", label, ".json"));
    }

    /// @dev Write the manager's state: its owner, its pools, its harvest and rebalance settings and whom it pays.
    function _writeManager(Config_MinterMarket market, string memory dir) private {
        string memory label = stabilityPoolManagerKey(market);
        address manager = stabilityPoolManagerAddress(market);
        _jsonKey = string.concat("pre_", label);
        vm.serializeString(_jsonKey, "label", label);
        vm.serializeString(_jsonKey, "manager_owner", vm.toString(IBaoOwnable(manager).owner()));
        address[] memory pools = IStabilityPoolManager(manager).stabilityPools();
        for (uint256 i = 0; i < pools.length; ++i) {
            vm.serializeString(
                _jsonKey,
                string.concat("manager_stabilityPool_", vm.toString(i)),
                vm.toString(pools[i])
            );
        }
        _serializeUint("manager_harvestBountyRatio", IStabilityPoolManager(manager).harvestBountyRatio());
        _serializeUint("manager_harvestCutRatio", IStabilityPoolManager(manager).harvestCutRatio());
        _serializeUint("manager_rebalanceBountyRatio", IStabilityPoolManager(manager).rebalanceBountyRatio());
        _serializeUint("manager_rebalanceThreshold", IStabilityPoolManager(manager).rebalanceThreshold());
        vm.serializeString(_jsonKey, "manager_feeReceiver", vm.toString(IStabilityPoolManager(manager).feeReceiver()));
        if (!isBefore) {
            // StabilityPoolManager_v2 also keeps the yield vaults it compounds.
            _serializeUint("manager_yieldVaultCount", IYieldVaultManager(manager).yieldVaultCount());
        }
        vm.writeJson(vm.serializeString(_jsonKey, "_complete", "true"), string.concat(dir, "/", label, ".json"));
    }

    // ========================================================================
    // POOLS
    // ========================================================================

    /// @dev Write the pool's state - and, for `post_`, the interaction results already serialized under its key.
    function _writePool(
        Config_MinterMarket market,
        StabilityPoolType poolType,
        string memory dir,
        string memory phase
    ) private {
        string memory label = stabilityPoolKey(market, poolType);
        address pool = stabilityPoolAddress(market, poolType);
        _jsonKey = string.concat(phase, label);
        vm.serializeString(_jsonKey, "label", label);
        _serializePoolState(pool, _users(label, keccak256(bytes(phase)) == keccak256("post_")), "state");
        vm.writeJson(vm.serializeString(_jsonKey, "_complete", "true"), string.concat(dir, "/", label, ".json"));
    }

    /// @dev The pool's captured holders, and the test user too once it has deposited.
    function _users(string memory label, bool withTestUser) private view returns (address[] memory users) {
        address[] memory holders = HolderCaptureLib.holders(FROZEN_MARKETS_CAPTURE, label);
        users = new address[](holders.length + (withTestUser ? 1 : 0));
        for (uint256 i = 0; i < holders.length; ++i) {
            users[i] = holders[i];
        }
        if (withTestUser) {
            users[holders.length] = testUser;
        }
    }

    /// @dev Serialize a uint256 as a decimal string.
    function _serializeUint(string memory key, uint256 value) internal {
        vm.serializeString(_jsonKey, key, vm.toString(value));
    }

    /// @dev `user`'s claimable reward of `token` from `pool`, as its version reports it.
    function _claimable(address pool, address user, address token) private view returns (uint256) {
        if (isBefore) {
            return IMultipleRewardAccumulator(pool).claimable(user, token);
        }
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        return IClaimReward(pool).claimable(user, tokens)[0];
    }

    /// @dev `user`'s claimed reward of `token` from `pool`, as its version reports it.
    function _claimed(address pool, address user, address token) private view returns (uint256) {
        if (isBefore) {
            return IMultipleRewardAccumulator(pool).claimed(user, token);
        }
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        return IClaimReward(pool).claimed(user, tokens)[0];
    }

    /// @dev StabilityPool_v3's reward divisor, which it keeps internal: read through `MockStabilityPool` - v3 with
    ///      accessors added, built with the pool's own settings - put in place of the pool's code inside a snapshot that
    ///      is then reverted.
    function _rewardDivisor(address pool) private returns (uint256 divisor) {
        uint256 snapshot = vm.snapshotState();
        (uint64 startDelay, uint64 endWindow) = IStabilityPool_v3(pool).getWithdrawalWindow();
        address exposer = address(
            new MockStabilityPool(
                IStabilityPool_v3(pool).MINTER(),
                IStabilityPool_v3(pool).ASSET_TOKEN(),
                startDelay,
                endWindow,
                IStabilityPool_v3(pool).MIN_TOTAL_ASSET_SUPPLY(),
                IERC20Metadata(pool).name(),
                IERC20Metadata(pool).symbol()
            )
        );
        vm.etch(pool, exposer.code);
        divisor = MockStabilityPool(pool).__rewardDivisor();
        vm.revertToState(snapshot);
    }

    /// @dev Serialize totalAssetSupply + per-user assetBalanceOf. Called 2x per pool (pre/post deposit).
    function _serializeBalances(address proxy, address[] memory users, string memory prefix) internal {
        _serializeUint(string.concat(prefix, "_totalAssetSupply"), IStabilityPool_v3(proxy).totalAssetSupply());
        for (uint256 i = 0; i < users.length; i++) {
            _serializeUint(
                string.concat(prefix, "_user_", vm.toString(i), "_assetBalance"),
                IStabilityPool_v3(proxy).assetBalanceOf(users[i])
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
                    _claimable(proxy, users[u], tokens[t])
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

        // Claim for each user. The no-argument claim() is a self-claim on both versions.
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            try IMultipleRewardAccumulator(proxy).claim() {
                vm.serializeString(_jsonKey, string.concat(prefix, "_user_", vm.toString(i), "_success"), "true");
            } catch {
                vm.serializeString(_jsonKey, string.concat(prefix, "_user_", vm.toString(i), "_success"), "false");
            }
            vm.stopPrank();
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
        _serializeUint(string.concat(ui, "_assetBalance"), IStabilityPool_v3(proxy).assetBalanceOf(user));

        {
            (uint64 wStart, uint64 wEnd) = IStabilityPool_v3(proxy).getWithdrawalRequest(user);
            _serializeUint(string.concat(ui, "_withdrawalStart"), uint256(wStart));
            _serializeUint(string.concat(ui, "_withdrawalEnd"), uint256(wEnd));
        }

        for (uint256 t = 0; t < activeTokens.length; t++) {
            string memory ut = string.concat(ui, "_reward_", vm.toString(t));
            _serializeUint(string.concat(ut, "_claimable"), _claimable(proxy, user, activeTokens[t]));
            _serializeUint(string.concat(ut, "_claimed"), _claimed(proxy, user, activeTokens[t]));
        }
    }

    /// @dev Serialize all view functions for a pool into the current JSON object. The views both versions have are read
    ///      through `IStabilityPool_v3`: their selectors are the same in both interfaces.
    function _serializePoolState(address proxy, address[] memory depositors, string memory prefix) internal {
        vm.serializeString(_jsonKey, string.concat(prefix, "_owner"), vm.toString(IBaoOwnable(proxy).owner()));
        {
            IStabilityPool_v3 pool = IStabilityPool_v3(proxy);
            _serializeUint(string.concat(prefix, "_totalAssetSupply"), pool.totalAssetSupply());
            _serializeUint(string.concat(prefix, "_lastAssetLossError"), pool.lastAssetLossError());
            _serializeUint(string.concat(prefix, "_earlyWithdrawalFee"), pool.getEarlyWithdrawalFee());
            vm.serializeString(_jsonKey, string.concat(prefix, "_feeAddress"), vm.toString(pool.getFeeAddress()));
            {
                (uint64 startDelay, uint64 endWindow) = pool.getWithdrawalWindow();
                _serializeUint(string.concat(prefix, "_withdrawalStartDelay"), uint256(startDelay));
                _serializeUint(string.concat(prefix, "_withdrawalEndWindow"), uint256(endWindow));
            }
            _serializeUint(string.concat(prefix, "_minTotalAssetSupply"), pool.MIN_TOTAL_ASSET_SUPPLY());
            vm.serializeString(_jsonKey, string.concat(prefix, "_assetToken"), vm.toString(pool.ASSET_TOKEN()));
        }
        if (isBefore) {
            // StabilityPool_v2 only: v3 names no single liquidation token, and calls its minimum deposit the floor.
            vm.serializeString(
                _jsonKey,
                string.concat(prefix, "_liquidationToken"),
                vm.toString(IStabilityPool(proxy).LIQUIDATION_TOKEN())
            );
            _serializeUint(string.concat(prefix, "_minDeposit"), IStabilityPool(proxy).MIN_DEPOSIT());
        } else {
            // StabilityPool_v3 only: what rewards are divided by.
            _serializeUint(string.concat(prefix, "_rewardDivisor"), _rewardDivisor(proxy));
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

    /// @dev Try all interactions on a pool, recording each outcome under the pool's post key.
    function _interact(Config_MinterMarket market, StabilityPoolType poolType) internal {
        string memory label = stabilityPoolKey(market, poolType);
        address proxy = stabilityPoolAddress(market, poolType);
        _jsonKey = string.concat("post_", label);
        string memory prefix = "interact";
        address[] memory depositors = HolderCaptureLib.holders(FROZEN_MARKETS_CAPTURE, label);
        address[] memory allUsers = _users(label, true);
        address[] memory activeTokens = IMultipleRewardDistributor(proxy).activeRewardTokens();

        // 1. Pre-deposit balances
        _serializeBalances(proxy, allUsers, string.concat(prefix, "_preDeposit"));

        // 2. Deposit (new user)
        {
            address assetToken = IStabilityPool_v3(proxy).ASSET_TOKEN();
            deal(assetToken, testUser, 100 ether);
            vm.startPrank(testUser);
            IERC20(assetToken).approve(proxy, type(uint256).max);
            try IStabilityPool_v3(proxy).deposit(100 ether, testUser, 0) {
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
            address assetToken2 = IStabilityPool_v3(proxy).ASSET_TOKEN();
            deal(assetToken2, existingDepositor, 100 ether);
            vm.startPrank(existingDepositor);
            IERC20(assetToken2).approve(proxy, type(uint256).max);
            try IStabilityPool_v3(proxy).deposit(100 ether, existingDepositor, 0) {
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

        // 5. Deposit a reward in the pool's first reward token (the owner may deposit rewards in both versions)
        {
            address rewardToken = activeTokens[0];
            address owner = IBaoOwnable(proxy).owner();
            deal(rewardToken, owner, 10 ether);
            vm.startPrank(owner);
            IERC20(rewardToken).approve(proxy, type(uint256).max);
            try IMultipleRewardDistributor(proxy).depositReward(rewardToken, 10 ether) {
                vm.serializeString(_jsonKey, string.concat(prefix, "_depositReward_success"), "true");
            } catch {
                vm.serializeString(_jsonKey, string.concat(prefix, "_depositReward_success"), "false");
            }
            vm.stopPrank();
            vm.serializeString(_jsonKey, string.concat(prefix, "_depositReward_token"), vm.toString(rewardToken));
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

        // 15. Whether every claimable is zero after the full period
        {
            bool allZero = true;
            for (uint256 u = 0; u < allUsers.length && allZero; u++) {
                for (uint256 t = 0; t < activeTokens.length && allZero; t++) {
                    if (_claimable(proxy, allUsers[u], activeTokens[t]) > 0) {
                        allZero = false;
                    }
                }
            }
            vm.serializeString(_jsonKey, string.concat(prefix, "_full_allClaimableZero"), allZero ? "true" : "false");
        }

        // 16. Withdraw for test user (request, warp into window, withdraw)
        vm.startPrank(testUser);
        try IStabilityPool_v3(proxy).requestWithdrawal() {
            vm.serializeString(_jsonKey, string.concat(prefix, "_requestWithdrawal_success"), "true");
            vm.stopPrank();

            {
                (uint64 wStart, ) = IStabilityPool_v3(proxy).getWithdrawalRequest(testUser);
                if (wStart > 0) {
                    vm.warp(uint256(wStart) + 1);
                }
            }

            uint256 withdrawAmount = IStabilityPool_v3(proxy).assetBalanceOf(testUser) / 2;
            vm.startPrank(testUser);
            try IStabilityPool_v3(proxy).withdraw(withdrawAmount, testUser, 0) {
                vm.serializeString(_jsonKey, string.concat(prefix, "_withdraw_success"), "true");
            } catch {
                vm.serializeString(_jsonKey, string.concat(prefix, "_withdraw_success"), "false");
            }
            vm.stopPrank();
            _serializeUint(string.concat(prefix, "_withdraw_amount"), withdrawAmount);
        } catch {
            vm.stopPrank();
            vm.serializeString(_jsonKey, string.concat(prefix, "_requestWithdrawal_success"), "false");
            vm.serializeString(_jsonKey, string.concat(prefix, "_withdraw_success"), "false");
            _serializeUint(string.concat(prefix, "_withdraw_amount"), 0);
        }
    }
}
