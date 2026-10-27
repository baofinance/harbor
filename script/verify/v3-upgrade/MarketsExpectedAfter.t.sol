// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {allMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {FROZEN_MARKETS_CAPTURE} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";
import {CaptureExpectationsLib} from "@harbor-script/verify/v3-upgrade/CaptureExpectationsLib.sol";

/// @notice What every market contract is expected to read after the upgrade, written down beforehand: for each record
///         `MarketsCapture` took before, the record it must have after - each value as it was, or as an expectation
///         below says, with its reason. Writes tmp/v3-upgrade/expected-after/{pre,post}/{saltKey}.json, which the
///         runner diffs against the after record.
contract MarketsExpectedAfter is Test, HarborDeployer {
    string internal constant ROOT = "tmp/v3-upgrade/";

    /// @notice Write the expected-after record of every contract the capture recorded. The oracle the deploy predicts
    ///         for each market, and what that proxy runs, are read on mainnet at the capture's block, where the before
    ///         was taken.
    function test_writeExpectedAfter() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE));
        _setSaltPrefix("harbor_v1");
        Config_MinterMarket[] memory markets = allMintersConfig();
        vm.createDir(string.concat(ROOT, "expected-after/pre"), true);
        vm.createDir(string.concat(ROOT, "expected-after/post"), true);
        for (uint256 i = 0; i < markets.length; ++i) {
            _write(
                "pre",
                minterKey(markets[i]),
                _minterExpectations(markets[i], _read("before", "pre", minterKey(markets[i])))
            );
            _write("pre", stabilityPoolManagerKey(markets[i]), _managerExpectations());
            _writePool(markets[i], StabilityPoolType.Collateral);
            _writePool(markets[i], StabilityPoolType.Leveraged);
        }
    }

    /// @dev Every minter runs on Minter_v3 unimpaired. A minter that records backing but holds no wrapped collateral has
    ///      the record set to zero in its batch: it records what it holds, nothing. A minter that reads the very
    ///      implementation its predicted oracle proxy runs is pointed at the proxy: afterwards it reads the proxy, and
    ///      the proxy runs the oracle it read before.
    function _minterExpectations(
        Config_MinterMarket market,
        string memory before
    ) private returns (CaptureExpectationsLib.Expectation[] memory expectations) {
        bool unheld = _uint(before, "minter_wrappedCollateralHeld") == 0 && _uint(before, "minter_recordedBacking") > 0;
        string memory oracleRead = vm.parseJsonString(before, ".minter_priceOracle");
        address predictedOracle = wrappedPriceOracleAddress(market);
        bool movesOracle = keccak256(bytes(oracleRead)) != keccak256(bytes(vm.toString(predictedOracle))) &&
            keccak256(bytes(oracleRead)) ==
                keccak256(
                    bytes(
                        vm.toString(
                            address(uint160(uint256(vm.load(predictedOracle, ERC1967Utils.IMPLEMENTATION_SLOT))))
                        )
                    )
                );
        expectations = new CaptureExpectationsLib.Expectation[](1 + (unheld ? 1 : 0) + (movesOracle ? 2 : 0));
        uint256 count;
        expectations[count++] = CaptureExpectationsLib.Expectation({
            key: "minter_impaired",
            kind: CaptureExpectationsLib.Kind.Value,
            value: "false",
            bound: 0,
            reason: "Minter_v3 halts a minter that records more backing than it holds; the upgrade leaves none so"
        });
        if (unheld) {
            expectations[count++] = CaptureExpectationsLib.Expectation({
                key: "minter_recordedBacking",
                kind: CaptureExpectationsLib.Kind.Value,
                value: "0",
                bound: 0,
                reason: "its batch upgrades it through Minter_v3_Upgrader, which sets the backing it does not hold to zero"
            });
        }
        if (movesOracle) {
            expectations[count++] = CaptureExpectationsLib.Expectation({
                key: "minter_priceOracle",
                kind: CaptureExpectationsLib.Kind.Value,
                value: vm.toString(predictedOracle),
                bound: 0,
                reason: "its batch points it at the oracle proxy the deploy predicts, which runs the oracle it read"
            });
            expectations[count++] = CaptureExpectationsLib.Expectation({
                key: "minter_priceOracle_implementation",
                kind: CaptureExpectationsLib.Kind.Value,
                value: oracleRead,
                bound: 0,
                reason: "the proxy it reads runs the implementation it read before"
            });
        }
    }

    /// @dev The manager runs StabilityPoolManager_v2, which starts with no yield vault.
    function _managerExpectations() private pure returns (CaptureExpectationsLib.Expectation[] memory expectations) {
        expectations = new CaptureExpectationsLib.Expectation[](2);
        expectations[0] = CaptureExpectationsLib.Expectation({
            key: "manager_reportsStabilityPoolManager_v2",
            kind: CaptureExpectationsLib.Kind.Value,
            value: "true",
            bound: 0,
            reason: "the upgrade puts StabilityPoolManager_v2 behind the manager"
        });
        expectations[1] = CaptureExpectationsLib.Expectation({
            key: "manager_yieldVaultCount",
            kind: CaptureExpectationsLib.Kind.Value,
            value: "0",
            bound: 0,
            reason: "StabilityPoolManager_v2 adds yield vaults; none is registered by the upgrade"
        });
    }

    /// @dev Write the pool's expected-after records, pre and post. Its ledger gap - the supply less what the captured
    ///      holders hold, from the before's pre record - decides how its rewards move. The minter it must name is the
    ///      one the market's manager named before the upgrade.
    function _writePool(Config_MinterMarket market, StabilityPoolType poolType) private {
        string memory label = stabilityPoolKey(market, poolType);
        string memory minter = vm.parseJsonString(
            _read("before", "pre", stabilityPoolManagerKey(market)),
            ".manager_minter"
        );
        string memory beforePre = _read("before", "pre", label);
        string memory beforePost = _read("before", "post", label);
        uint256 supply = _uint(beforePre, "state_totalAssetSupply");
        uint256 held;
        uint256 holders = _uint(beforePre, "state_depositorCount");
        for (uint256 i = 0; i < holders; ++i) {
            held += _uint(beforePre, string.concat("state_user_", vm.toString(i), "_assetBalance"));
        }
        int256 gap = int256(supply) - int256(held);
        CaptureExpectationsLib.Expectation[] memory preRewards;
        CaptureExpectationsLib.Expectation[] memory postRewards;
        if (gap != 0) {
            preRewards = _preRewardShifts(beforePre, gap);
            postRewards = _postRewardShifts(beforePre, beforePost, gap);
        }
        _write("pre", label, _poolExpectations(beforePre, gap, minter, preRewards));
        _write("post", label, _poolExpectations(beforePost, gap, minter, postRewards));
    }

    /// @dev The pool's expectations in one record: StabilityPool_v3 has no `LIQUIDATION_TOKEN` or `MIN_DEPOSIT`; it
    ///      names its minter, which v2 does not: `minter`, the market's; it divides rewards by the supply less the
    ///      ledger gap - what the holders hold; and `rewards`, how that moves the record's reward readings.
    function _poolExpectations(
        string memory before,
        int256 gap,
        string memory minter,
        CaptureExpectationsLib.Expectation[] memory rewards
    ) private pure returns (CaptureExpectationsLib.Expectation[] memory expectations) {
        expectations = new CaptureExpectationsLib.Expectation[](4 + rewards.length);
        uint256 count;
        expectations[count++] = _removed(
            "state_liquidationToken",
            "StabilityPool_v3 names no single liquidation token"
        );
        expectations[count++] = _removed(
            "state_minDeposit",
            "StabilityPool_v3 calls its minimum the floor, MIN_TOTAL_ASSET_SUPPLY"
        );
        expectations[count++] = CaptureExpectationsLib.Expectation({
            key: "state_minter",
            kind: CaptureExpectationsLib.Kind.Value,
            value: minter,
            bound: 0,
            reason: "StabilityPool_v3 names its minter, which v2 does not: the market's"
        });
        expectations[count++] = CaptureExpectationsLib.Expectation({
            key: "state_rewardDivisor",
            kind: CaptureExpectationsLib.Kind.Value,
            value: vm.toString(uint256(int256(_uint(before, "state_totalAssetSupply")) - gap)),
            bound: 0,
            reason: "StabilityPool_v3 divides rewards by the supply less the ledger gap"
        });
        for (uint256 r = 0; r < rewards.length; ++r) {
            expectations[count++] = rewards[r];
        }
    }

    // ========================================================================
    // THE SHIFT OF A POOL'S REWARDS
    // ========================================================================
    //
    // A holder's claimable is what is settled into their record, plus their share of what the pool has folded into its
    // reward-per-share since their checkpoint, plus their share of the stream the pool has not folded yet. The first
    // two were computed by StabilityPool_v2 and are copied; only reward folded after the upgrade - or read as the
    // unfolded stream - is divided by v3's divisor, the supply less the gap, where v2 divided by the supply. For each
    // such fold v3 credits a holder `_shift` more than v2 credited.
    //
    // The capture's interactions fold three times: the test user's deposit folds the stream pending at the start, at
    // the pre-interaction supply (fold 0); the half-period claims fold the first half of the rehearsal's reward stream,
    // and the full-period claims the second, both at the supply after the two deposits (folds 1 and 2). Fold 0's
    // credit is each captured holder's share of the pending stream; folds 1 and 2's are read from v2's own readings.
    //
    // Bound: each version floors a reading once per fold in it, so their difference is within 1 of the real shift per
    // fold; the computed shift truncates once per fold, within 1 more - 2 per fold.

    /// @dev The pre record's claimables: fold 0, read as the unfolded stream.
    function _preRewardShifts(
        string memory beforePre,
        int256 gap
    ) private pure returns (CaptureExpectationsLib.Expectation[] memory expectations) {
        uint256 supply = _uint(beforePre, "state_totalAssetSupply");
        uint256 holders = _uint(beforePre, "state_depositorCount");
        uint256 tokens = _uint(beforePre, "state_activeRewardTokenCount");
        expectations = new CaptureExpectationsLib.Expectation[](holders * tokens);
        for (uint256 i = 0; i < holders; ++i) {
            for (uint256 t = 0; t < tokens; ++t) {
                expectations[i * tokens + t] = _shifted(
                    beforePre,
                    _rewardKey("state", i, t, "_claimable"),
                    _pendingShift(beforePre, i, t, gap),
                    1
                );
            }
        }
    }

    /// @dev The post record's reward readings, through the interactions: the captured holders, then the test user,
    ///      who deposited after fold 0 and so has no share in it. Every interaction ran: one that reverts fails the
    ///      capture.
    function _postRewardShifts(
        string memory beforePre,
        string memory beforePost,
        int256 gap
    ) private pure returns (CaptureExpectationsLib.Expectation[] memory expectations) {
        uint256 holders = _uint(beforePre, "state_depositorCount");
        uint256 tokens = _uint(beforePre, "state_activeRewardTokenCount");
        UserFolds memory folds;
        folds.gap = gap;
        folds.depositedSupply = _uint(beforePost, "interact_postDeposit_totalAssetSupply");
        expectations = new CaptureExpectationsLib.Expectation[]((holders + 1) * tokens * 7);
        uint256 count;
        for (uint256 i = 0; i <= holders; ++i) {
            for (uint256 t = 0; t < tokens; ++t) {
                folds.shift0 = i < holders ? _pendingShift(beforePre, i, t, gap) : int256(0);
                count = _userRewardShifts(beforePost, i, t, folds, expectations, count);
            }
        }
    }

    /// @dev What one user's post-record reward readings in one token follow: the pool's gap, its supply after the two
    ///      deposits, and the user's fold 0 shift.
    struct UserFolds {
        int256 gap;
        uint256 depositedSupply;
        int256 shift0;
    }

    /// @dev Add user `user`'s expectations in reward token `token` to `all` from `count`; return the new count.
    function _userRewardShifts(
        string memory beforePost,
        uint256 user,
        uint256 token,
        UserFolds memory folds,
        CaptureExpectationsLib.Expectation[] memory all,
        uint256 count
    ) private pure returns (uint256) {
        int256 shift1 = _shift(
            _accrued(beforePost, user, token, "interact_postReward", "interact_half_preClaim"),
            folds.gap,
            folds.depositedSupply
        );
        int256 shift2 = _shift(
            _accrued(beforePost, user, token, "interact_half_postClaim", "interact_full_preClaim"),
            folds.gap,
            folds.depositedSupply
        );
        int256 shift0 = folds.shift0;
        all[count++] = _shifted(beforePost, _rewardKey("interact_preReward", user, token, "_claimable"), shift0, 1);
        all[count++] = _shifted(beforePost, _rewardKey("interact_postReward", user, token, "_claimable"), shift0, 1);
        all[count++] = _shifted(
            beforePost,
            _rewardKey("interact_half_preClaim", user, token, "_claimable"),
            shift0 + shift1,
            2
        );
        all[count++] = _shifted(beforePost, _rewardKey("interact_full_preClaim", user, token, "_claimable"), shift2, 1);
        all[count++] = _shifted(
            beforePost,
            _rewardKey("interact_half_claim", user, token, "_delta"),
            shift0 + shift1,
            2
        );
        all[count++] = _shifted(beforePost, _rewardKey("interact_full_claim", user, token, "_delta"), shift2, 1);
        all[count++] = _shifted(beforePost, _rewardKey("state", user, token, "_claimed"), shift0 + shift1 + shift2, 3);
        return count;
    }

    /// @dev Fold 0's shift for captured holder `holder` and reward token `token`: their share of the stream pending at
    ///      the start, credited by v2 over the supply.
    function _pendingShift(
        string memory beforePre,
        uint256 holder,
        uint256 token,
        int256 gap
    ) private pure returns (int256) {
        uint256 supply = _uint(beforePre, "state_totalAssetSupply");
        uint256 credit = Math.mulDiv(
            _uint(beforePre, string.concat("state_user_", vm.toString(holder), "_assetBalance")),
            _uint(beforePre, string.concat("state_reward_", vm.toString(token), "_pendingDistributable")),
            supply
        );
        return _shift(credit, gap, supply);
    }

    /// @dev What v2 credited user `user` in reward token `token` between the readings `from` and `to`.
    function _accrued(
        string memory beforePost,
        uint256 user,
        uint256 token,
        string memory from,
        string memory to
    ) private pure returns (uint256) {
        uint256 start = _uint(beforePost, _rewardKey(from, user, token, "_claimable"));
        uint256 end = _uint(beforePost, _rewardKey(to, user, token, "_claimable"));
        require(
            end >= start,
            string.concat(_rewardKey(to, user, token, "_claimable"), " reads less than ", from, " before the upgrade")
        );
        return end - start;
    }

    /// @dev How much more StabilityPool_v3 credits than v2 for a fold v2 credited `credit` over `divisor`: v3 divides by
    ///      `divisor - gap`, so credits `credit * divisor / (divisor - gap)`, which is `credit` plus this, truncated.
    function _shift(uint256 credit, int256 gap, uint256 divisor) private pure returns (int256) {
        uint256 magnitude = Math.mulDiv(credit, gap < 0 ? uint256(-gap) : uint256(gap), uint256(int256(divisor) - gap));
        return gap < 0 ? -int256(magnitude) : int256(magnitude);
    }

    /// @dev `key`'s before value moved by `shift`, to within 2 per fold in it.
    function _shifted(
        string memory before,
        string memory key,
        int256 shift,
        uint256 folds
    ) private pure returns (CaptureExpectationsLib.Expectation memory) {
        return
            CaptureExpectationsLib.Expectation({
                key: key,
                kind: CaptureExpectationsLib.Kind.Within,
                value: vm.toString(uint256(int256(_uint(before, key)) + shift)),
                bound: 2 * folds,
                reason: "StabilityPool_v3 divides the reward it folds after the upgrade by what the holders hold"
            });
    }

    function _rewardKey(
        string memory prefix,
        uint256 user,
        uint256 token,
        string memory what
    ) private pure returns (string memory) {
        return string.concat(prefix, "_user_", vm.toString(user), "_reward_", vm.toString(token), what);
    }

    function _removed(
        string memory key,
        string memory reason
    ) private pure returns (CaptureExpectationsLib.Expectation memory) {
        return
            CaptureExpectationsLib.Expectation({
                key: key,
                kind: CaptureExpectationsLib.Kind.Removed,
                value: "",
                bound: 0,
                reason: reason
            });
    }

    /// @dev Write `label`'s expected-after record for `phase` from its before and after records and `expectations`.
    function _write(
        string memory phase,
        string memory label,
        CaptureExpectationsLib.Expectation[] memory expectations
    ) private {
        string memory json = CaptureExpectationsLib.expectedAfter(
            string.concat("expected_", phase, "_", label),
            _read("before", phase, label),
            _read("after", phase, label),
            expectations
        );
        vm.writeJson(json, string.concat(ROOT, "expected-after/", phase, "/", label, ".json"));
    }

    function _read(
        string memory version,
        string memory phase,
        string memory label
    ) private view returns (string memory) {
        return vm.readFile(string.concat(ROOT, version, "/", phase, "/", label, ".json"));
    }

    function _uint(string memory json, string memory key) private pure returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, string.concat(".", key)));
    }
}
