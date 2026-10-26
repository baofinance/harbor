// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {allMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {CaptureExpectationsLib} from "@harbor-script/verify/v3-upgrade/CaptureExpectationsLib.sol";

import {RewardDivisorGapLib} from "@harbor-test/harness/RewardDivisorGapLib.sol";

/// @notice What every market contract is expected to read after the upgrade, written down beforehand: for each record
///         `MarketsCapture` took before, the record it must have after - each value as it was, or as an expectation
///         below says, with its reason. Writes tmp/v3-upgrade/expected-after/{pre,post}/{saltKey}.json, which the
///         runner diffs against the after record.
contract MarketsExpectedAfter is Test, HarborDeployer {
    using LibString for string;

    string internal constant ROOT = "tmp/v3-upgrade/";

    /// @notice Write the expected-after record of every contract the capture recorded.
    function test_writeExpectedAfter() public {
        Config_MinterMarket[] memory markets = allMintersConfig();
        vm.createDir(string.concat(ROOT, "expected-after/pre"), true);
        vm.createDir(string.concat(ROOT, "expected-after/post"), true);
        for (uint256 i = 0; i < markets.length; ++i) {
            _write("pre", minterKey(markets[i]), _minterExpectations(_read("before", "pre", minterKey(markets[i]))));
            _write("pre", stabilityPoolManagerKey(markets[i]), _managerExpectations());
            _writePool(markets[i], StabilityPoolType.Collateral);
            _writePool(markets[i], StabilityPoolType.Leveraged);
        }
    }

    /// @dev Every minter runs on Minter_v3 unimpaired. A minter that records backing but holds no wrapped collateral is
    ///      recognised as impaired in its batch: it records what it holds, nothing.
    function _minterExpectations(
        string memory before
    ) private pure returns (CaptureExpectationsLib.Expectation[] memory expectations) {
        bool unheld = _uint(before, "minter_wrappedCollateralHeld") == 0 && _uint(before, "minter_recordedBacking") > 0;
        expectations = new CaptureExpectationsLib.Expectation[](unheld ? 2 : 1);
        expectations[0] = CaptureExpectationsLib.Expectation({
            key: "minter_impaired",
            kind: CaptureExpectationsLib.Kind.Value,
            value: "false",
            bound: 0,
            reason: "Minter_v3 halts a minter that records more backing than it holds; the upgrade leaves none so"
        });
        if (unheld) {
            expectations[1] = CaptureExpectationsLib.Expectation({
                key: "minter_recordedBacking",
                kind: CaptureExpectationsLib.Kind.Value,
                value: "0",
                bound: 0,
                reason: "the batch recognises the backing it records but does not hold"
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
        uint256 supply = _uint(beforePre, "state_totalAssetSupply");
        uint256 held;
        uint256 holders = _uint(beforePre, "state_depositorCount");
        for (uint256 i = 0; i < holders; ++i) {
            held += _uint(beforePre, string.concat("state_user_", vm.toString(i), "_assetBalance"));
        }
        int256 gap = int256(supply) - int256(held);
        _write("pre", label, _poolExpectations(beforePre, "pre", gap, supply, minter));
        _write("post", label, _poolExpectations(_read("before", "post", label), "post", gap, supply, minter));
    }

    /// @dev The pool's expectations in one record:
    ///      - StabilityPool_v3 has no `LIQUIDATION_TOKEN` or `MIN_DEPOSIT`;
    ///      - it names its minter, which v2 does not: `minter`, the market's;
    ///      - it divides rewards by the supply less the ledger gap - what the holders hold;
    ///      - so, on a pool with a gap, a reward not yet settled into a holder's record moves by at most
    ///        `RewardDivisorGapLib.rewardBound` of itself: every claimable, every claim's payout, and - after the
    ///        interactions, which claim - every claimed total. The bound is taken over the before's pre supply, the
    ///        smallest the pool holds during the interactions, which only deposit into it before they claim.
    function _poolExpectations(
        string memory before,
        string memory phase,
        int256 gap,
        uint256 preSupply,
        string memory minter
    ) private pure returns (CaptureExpectationsLib.Expectation[] memory expectations) {
        string[] memory keys = vm.parseJsonKeys(before, "$");
        CaptureExpectationsLib.Expectation[] memory all = new CaptureExpectationsLib.Expectation[](keys.length + 4);
        uint256 count;
        all[count++] = _removed("state_liquidationToken", "StabilityPool_v3 names no single liquidation token");
        all[count++] = _removed(
            "state_minDeposit",
            "StabilityPool_v3 calls its minimum the floor, MIN_TOTAL_ASSET_SUPPLY"
        );
        all[count++] = CaptureExpectationsLib.Expectation({
            key: "state_minter",
            kind: CaptureExpectationsLib.Kind.Value,
            value: minter,
            bound: 0,
            reason: "StabilityPool_v3 names its minter, which v2 does not: the market's"
        });
        all[count++] = CaptureExpectationsLib.Expectation({
            key: "state_rewardDivisor",
            kind: CaptureExpectationsLib.Kind.Value,
            value: vm.toString(uint256(int256(_uint(before, "state_totalAssetSupply")) - gap)),
            bound: 0,
            reason: "StabilityPool_v3 divides rewards by the supply less the ledger gap"
        });
        if (gap != 0) {
            bool post = keccak256(bytes(phase)) == keccak256("post");
            for (uint256 k = 0; k < keys.length; ++k) {
                if (
                    keys[k].endsWith("_claimable") ||
                    keys[k].endsWith("_delta") ||
                    (post && keys[k].endsWith("_claimed"))
                ) {
                    uint256 value = _uint(before, keys[k]);
                    all[count++] = CaptureExpectationsLib.Expectation({
                        key: keys[k],
                        kind: CaptureExpectationsLib.Kind.Within,
                        value: vm.toString(value),
                        bound: RewardDivisorGapLib.rewardBound(value, gap, preSupply),
                        reason: "StabilityPool_v3 pays an unsettled reward over what the holders hold"
                    });
                }
            }
        }
        expectations = new CaptureExpectationsLib.Expectation[](count);
        for (uint256 e = 0; e < count; ++e) {
            expectations[e] = all[e];
        }
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
