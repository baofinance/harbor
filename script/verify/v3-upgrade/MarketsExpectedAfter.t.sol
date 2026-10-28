// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {allMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {CompensateRebalanceDilution} from "@harbor-script/src/CompensateRebalanceDilution.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {IStabilityPool_v3_Upgrader} from "@harbor-script/UpgradeStabilityPool_v2_v3/IStabilityPool_v3_Upgrader.sol";
import {
    BTC_STETH_COMPENSATION,
    EUR_STETH_COMPENSATION,
    FROZEN_MARKETS_CAPTURE
} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";
import {CompensationRun} from "@harbor-script/verify/incidents/CompensationRun.sol";
import {CaptureExpectationsLib} from "@harbor-script/verify/v3-upgrade/CaptureExpectationsLib.sol";

/// @notice What every market contract is expected to read after the upgrade, written down beforehand: for each record
///         `MarketsCapture` took before, the record it must have after - each value as it was, or as an expectation
///         below says, with its reason. Writes tmp/v3-upgrade/expected-after/{pre,post}/{saltKey}.json, which the
///         runner diffs against the after record.
contract MarketsExpectedAfter is Test, HarborDeployer {
    string internal constant ROOT = "tmp/v3-upgrade/";

    /// @dev The fork of mainnet at the capture's block, where the before was taken.
    uint256 internal mainnetAtCapture;

    /// @dev The compensation's own functions, and what the incident's files say each compensated market carries in
    ///      its batch: deductions in its leveraged pool's migration, the multisig's redemptions and mints after.
    CompensationRun internal compensation;
    CompensateRebalanceDilution.MarketCompensation[] internal compensated;

    /// @dev The deductions a pool's migration takes, placed in the capture's record: by captured holder index and
    ///      reward token index; and whether it takes any - then the migration's checkpoint folded every stream.
    struct Cuts {
        bool folded;
        uint256[][] amounts;
    }

    /// @notice Write the expected-after record of every contract the capture recorded. The oracle the deploy predicts
    ///         for each market, and what that proxy runs, are read on mainnet at the capture's block, where the before
    ///         was taken; what a compensated market's batch did is read from its minter's events on anvil.
    function test_writeExpectedAfter() public {
        mainnetAtCapture = vm.createSelectFork(
            vm.rpcUrl("mainnet"),
            HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE)
        );
        _setSaltPrefix("harbor_v1");
        Config_MinterMarket[] memory markets = allMintersConfig();
        string[] memory files = new string[](2);
        files[0] = BTC_STETH_COMPENSATION;
        files[1] = EUR_STETH_COMPENSATION;
        compensation = new CompensationRun("harbor_v1", markets, FROZEN_MARKETS_CAPTURE, files);
        for (uint256 f = 0; f < files.length; ++f) {
            compensated.push(compensation.read(files[f]));
        }
        vm.createDir(string.concat(ROOT, "expected-after/pre"), true);
        vm.createDir(string.concat(ROOT, "expected-after/post"), true);
        for (uint256 i = 0; i < markets.length; ++i) {
            string memory before = _read("before", "pre", minterKey(markets[i]));
            CaptureExpectationsLib.Expectation[] memory minter = _minterExpectations(markets[i], before);
            (bool isCompensated, uint256 c) = _compensationOf(markets[i]);
            if (isCompensated) {
                minter = _concat(minter, _compensationExpectations(compensated[c], before));
            }
            _write("pre", minterKey(markets[i]), minter);
            _write("pre", stabilityPoolManagerKey(markets[i]), _managerExpectations());
            _writePool(markets[i], StabilityPoolType.Collateral);
            _writePool(markets[i], StabilityPoolType.Leveraged);
        }
    }

    /// @dev Whether `market` is one the incident's files describe, and which.
    function _compensationOf(Config_MinterMarket market) private view returns (bool, uint256) {
        bytes32 name = keccak256(bytes(MinterMarketConfigLib.salt(market)));
        for (uint256 c = 0; c < compensated.length; ++c) {
            if (keccak256(bytes(compensated[c].name)) == name) {
                return (true, c);
            }
        }
        return (false, 0);
    }

    /// @dev What the compensation did to a market's minter, read from the minter's events on anvil since the upgrade
    ///      ran: its pegged supply less the pegged fee redeemed; its leveraged supply less the cuts redeemed plus the
    ///      leveraged minted; the wrapped collateral it holds less the redemptions plus the mints; and the backing it
    ///      records moved by the same, each mint's wrapped collateral converted at the oracle's low rate and floored,
    ///      each redemption's at the high rate and ceiled - within 2 wei per operation.
    function _compensationExpectations(
        CompensateRebalanceDilution.MarketCompensation memory m,
        string memory before
    ) private returns (CaptureExpectationsLib.Expectation[] memory expectations) {
        MinterEvents memory did = _whatTheMinterDid(minterAddress(m.market), wrappedPriceOracleAddress(m.market));
        require(did.peggedBurned == m.feesPegged, string.concat(m.name, ": the pegged fee was not redeemed whole"));
        require(did.leveragedBurned == m.totalCutTokens, string.concat(m.name, ": the cuts were not redeemed whole"));
        require(did.operations > 0, string.concat(m.name, ": its minter's events show no compensation"));

        expectations = new CaptureExpectationsLib.Expectation[](4);
        expectations[0] = CaptureExpectationsLib.Expectation({
            key: "minter_peggedBalance",
            kind: CaptureExpectationsLib.Kind.Value,
            value: vm.toString(_uint(before, "minter_peggedBalance") - did.peggedBurned),
            bound: 0,
            reason: "the multisig redeems its pegged fee from the exploit, fee-free, in the market's batch"
        });
        expectations[1] = CaptureExpectationsLib.Expectation({
            key: "minter_leveragedBalance",
            kind: CaptureExpectationsLib.Kind.Value,
            value: vm.toString(_uint(before, "minter_leveragedBalance") - did.leveragedBurned + did.minted),
            bound: 0,
            reason: "the multisig redeems the cuts taken back and mints fee-free for each loser, in the market's batch"
        });
        expectations[2] = CaptureExpectationsLib.Expectation({
            key: "minter_wrappedCollateralHeld",
            kind: CaptureExpectationsLib.Kind.Value,
            value: vm.toString(_uint(before, "minter_wrappedCollateralHeld") - did.collateralOut + did.collateralIn),
            bound: 0,
            reason: "the redemptions take wrapped collateral out of the minter and the mints put it in"
        });
        expectations[3] = CaptureExpectationsLib.Expectation({
            key: "minter_recordedBacking",
            kind: CaptureExpectationsLib.Kind.Within,
            value: vm.toString(_uint(before, "minter_recordedBacking") + did.recordAdded - did.recordGiven),
            bound: 2 * did.operations,
            reason: "the record follows the holding: a mint's wrapped collateral credited at the low rate, floored; a redemption's debited at the high rate, ceiled"
        });
    }

    /// @dev What a minter's events on anvil say its batch did: the pegged and leveraged burned, the leveraged minted,
    ///      the wrapped collateral in and out, the record's credits (at the low rate, floored) and debits (at the high
    ///      rate, ceiled), and how many operations.
    struct MinterEvents {
        uint256 peggedBurned;
        uint256 leveragedBurned;
        uint256 minted;
        uint256 collateralIn;
        uint256 collateralOut;
        uint256 recordAdded;
        uint256 recordGiven;
        uint256 operations;
    }

    /// @dev Read `minter`'s events on anvil since the upgrade ran, with the rates `oracle` gives there; the fork of
    ///      mainnet at the capture is selected again after.
    function _whatTheMinterDid(address minter, address oracle) private returns (MinterEvents memory did) {
        vm.createSelectFork(vm.rpcUrl("local"));
        Vm.EthGetLogs[] memory logs = vm.eth_getLogs(
            vm.envUint("UPGRADE_FROM_BLOCK") + 1,
            block.number,
            minter,
            new bytes32[](0)
        );
        (, , uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(oracle).latestAnswer();
        for (uint256 l = 0; l < logs.length; ++l) {
            bytes32 topic = logs[l].topics[0];
            if (topic == IMinter_v3.MintLeveragedToken.selector) {
                (uint256 wrappedIn, uint256 leveragedOut) = abi.decode(logs[l].data, (uint256, uint256));
                did.minted += leveragedOut;
                did.collateralIn += wrappedIn;
                did.recordAdded += Math.mulDiv(wrappedIn, minRate, 1 ether);
                ++did.operations;
            } else if (topic == IMinter_v3.RedeemPeggedToken.selector) {
                (uint256 burned, uint256 wrappedOut, ) = abi.decode(logs[l].data, (uint256, uint256, uint256));
                did.peggedBurned += burned;
                did.collateralOut += wrappedOut;
                did.recordGiven += Math.ceilDiv(wrappedOut * maxRate, 1 ether);
                ++did.operations;
            } else if (topic == IMinter_v3.RedeemLeveragedToken.selector) {
                (uint256 burned, uint256 wrappedOut) = abi.decode(logs[l].data, (uint256, uint256));
                did.leveragedBurned += burned;
                did.collateralOut += wrappedOut;
                did.recordGiven += Math.ceilDiv(wrappedOut * maxRate, 1 ether);
                ++did.operations;
            }
        }
        vm.selectFork(mainnetAtCapture);
    }

    function _concat(
        CaptureExpectationsLib.Expectation[] memory a,
        CaptureExpectationsLib.Expectation[] memory b
    ) private pure returns (CaptureExpectationsLib.Expectation[] memory all) {
        all = new CaptureExpectationsLib.Expectation[](a.length + b.length);
        for (uint256 i = 0; i < a.length; ++i) {
            all[i] = a[i];
        }
        for (uint256 i = 0; i < b.length; ++i) {
            all[a.length + i] = b[i];
        }
    }

    /// @dev A minter that holds no wrapped collateral must record no backing: one that records any has the record set
    ///      to zero in its batch. A minter that reads an oracle other than the proxy the deploy predicts is pointed at
    ///      that proxy, which must run the oracle it read before or, running other code, answer as that oracle did at
    ///      the capture's block - refused otherwise.
    function _minterExpectations(
        Config_MinterMarket market,
        string memory before
    ) private returns (CaptureExpectationsLib.Expectation[] memory expectations) {
        bool unheld = _uint(before, "minter_wrappedCollateralHeld") == 0 && _uint(before, "minter_recordedBacking") > 0;
        address oracleRead = vm.parseJsonAddress(before, ".minter_priceOracle");
        address predictedOracle = wrappedPriceOracleAddress(market);
        bool movesOracle = oracleRead != predictedOracle;
        expectations = new CaptureExpectationsLib.Expectation[]((unheld ? 1 : 0) + (movesOracle ? 2 : 0));
        uint256 count;
        if (unheld) {
            expectations[count++] = CaptureExpectationsLib.Expectation({
                key: "minter_recordedBacking",
                kind: CaptureExpectationsLib.Kind.Value,
                value: "0",
                bound: 0,
                reason: "a minter holding no wrapped collateral records none: its batch upgrades it through Minter_v3_Upgrader, which sets the record to zero"
            });
        }
        if (movesOracle) {
            expectations[count++] = CaptureExpectationsLib.Expectation({
                key: "minter_priceOracle",
                kind: CaptureExpectationsLib.Kind.Value,
                value: vm.toString(predictedOracle),
                bound: 0,
                reason: "its batch points it at the oracle proxy the deploy predicts"
            });
            address proxyRuns = address(uint160(uint256(vm.load(predictedOracle, ERC1967Utils.IMPLEMENTATION_SLOT))));
            if (proxyRuns == oracleRead) {
                expectations[count++] = CaptureExpectationsLib.Expectation({
                    key: "minter_priceOracle_implementation",
                    kind: CaptureExpectationsLib.Kind.Value,
                    value: vm.toString(oracleRead),
                    bound: 0,
                    reason: "the proxy it reads runs the implementation it read before"
                });
            } else {
                string memory answerRead = _answer(oracleRead);
                string memory answerPredicted = _answer(predictedOracle);
                require(
                    keccak256(bytes(answerRead)) == keccak256(bytes(answerPredicted)),
                    string.concat(
                        minterKey(market),
                        ": the oracle it reads, ",
                        vm.toString(oracleRead),
                        ", answers ",
                        answerRead,
                        " at the capture's block; the oracle proxy the deploy predicts, ",
                        vm.toString(predictedOracle),
                        ", runs ",
                        vm.toString(proxyRuns),
                        " and answers ",
                        answerPredicted
                    )
                );
                expectations[count++] = CaptureExpectationsLib.Expectation({
                    key: "minter_priceOracle_implementation",
                    kind: CaptureExpectationsLib.Kind.Value,
                    value: vm.toString(proxyRuns),
                    bound: 0,
                    reason: "the proxy it reads runs other code, which answered as the oracle it read at the capture's block"
                });
            }
        }
    }

    /// @dev The oracle at `oracle`'s answer, as text: its price band, then its rate band, each low then high.
    function _answer(address oracle) private view returns (string memory) {
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(oracle)
            .latestAnswer();
        return
            string.concat(
                "price ",
                vm.toString(minPrice),
                " to ",
                vm.toString(maxPrice),
                ", rate ",
                vm.toString(minRate),
                " to ",
                vm.toString(maxRate)
            );
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
        string memory beforePre = _read("before", "pre", label);
        int256 gap = _gapOf(beforePre);
        Cuts memory cuts = _cutsIn(market, poolType, beforePre);
        _write("pre", label, _poolExpectations(beforePre, gap, _minterNamed(market), _preRewards(label, gap, cuts)));
        _write(
            "post",
            label,
            _poolExpectations(_read("before", "post", label), gap, _minterNamed(market), _postRewards(label, gap, cuts))
        );
    }

    /// @dev The pool's ledger gap from its before record: the supply less what the captured holders hold.
    function _gapOf(string memory beforePre) private pure returns (int256) {
        uint256 held;
        uint256 holders = _uint(beforePre, "state_depositorCount");
        for (uint256 i = 0; i < holders; ++i) {
            held += _uint(beforePre, string.concat("state_user_", vm.toString(i), "_assetBalance"));
        }
        return int256(_uint(beforePre, "state_totalAssetSupply")) - int256(held);
    }

    /// @dev The minter the market's manager named before the upgrade, which its pools must name after.
    function _minterNamed(Config_MinterMarket market) private view returns (string memory) {
        return vm.parseJsonString(_read("before", "pre", stabilityPoolManagerKey(market)), ".manager_minter");
    }

    /// @dev The pre record's reward expectations: the shifts and cuts where the pool has a gap or was folded, and the
    ///      streams' folding where it was.
    function _preRewards(
        string memory label,
        int256 gap,
        Cuts memory cuts
    ) private view returns (CaptureExpectationsLib.Expectation[] memory rewards) {
        string memory beforePre = _read("before", "pre", label);
        if (gap != 0 || cuts.folded) {
            rewards = _preRewardShifts(beforePre, gap, cuts);
        }
        if (cuts.folded) {
            rewards = _concat(rewards, _foldedStreams(beforePre, _read("after", "pre", label)));
        }
    }

    /// @dev The post record's reward expectations: the shifts and cuts where the pool has a gap or was folded.
    function _postRewards(
        string memory label,
        int256 gap,
        Cuts memory cuts
    ) private view returns (CaptureExpectationsLib.Expectation[] memory rewards) {
        if (gap != 0 || cuts.folded) {
            rewards = _postRewardShifts(_read("before", "pre", label), _read("before", "post", label), gap, cuts);
        }
    }

    /// @dev The deductions the `poolType` pool's migration takes - the compensation's, for the leveraged pool of a
    ///      market the incident's files describe - placed by the before record's holder and token indices.
    function _cutsIn(
        Config_MinterMarket market,
        StabilityPoolType poolType,
        string memory beforePre
    ) private returns (Cuts memory cuts) {
        uint256 holders = _uint(beforePre, "state_depositorCount");
        uint256 tokens = _uint(beforePre, "state_activeRewardTokenCount");
        cuts.amounts = new uint256[][](holders);
        for (uint256 i = 0; i < holders; ++i) {
            cuts.amounts[i] = new uint256[](tokens);
        }
        (bool isCompensated, uint256 c) = _compensationOf(market);
        if (!isCompensated || poolType != StabilityPoolType.Leveraged) {
            return cuts;
        }
        IStabilityPool_v3_Upgrader.Deduction[] memory taken = compensation.deductionsOf(compensated[c]);
        cuts.folded = taken.length > 0;
        for (uint256 d = 0; d < taken.length; ++d) {
            uint256 i = holders;
            for (uint256 h = 0; h < holders; ++h) {
                if (
                    vm.parseJsonAddress(beforePre, string.concat(".state_user_", vm.toString(h), "_address")) ==
                    taken[d].account
                ) {
                    i = h;
                }
            }
            uint256 t = tokens;
            for (uint256 k = 0; k < tokens; ++k) {
                if (
                    vm.parseJsonAddress(beforePre, string.concat(".state_reward_", vm.toString(k), "_token")) ==
                    taken[d].token
                ) {
                    t = k;
                }
            }
            require(i < holders && t < tokens, "a deduction names a holder or token the capture does not record");
            cuts.amounts[i][t] = taken[d].amount;
        }
    }

    /// @dev A pool whose migration took rewards back was checkpointed at the migration's moment, which folded every
    ///      stream: each stream's last update is that moment - the after's own reading, required to lie after the
    ///      before's and no later than the captures' time - and what it has left to distribute at the captures' time is
    ///      its rate over the time from that moment to then, within its period.
    function _foldedStreams(
        string memory beforePre,
        string memory afterPre
    ) private view returns (CaptureExpectationsLib.Expectation[] memory expectations) {
        uint256 at = vm.envUint("START_TIMESTAMP");
        uint256 tokens = _uint(beforePre, "state_activeRewardTokenCount");
        expectations = new CaptureExpectationsLib.Expectation[](2 * tokens);
        for (uint256 t = 0; t < tokens; ++t) {
            string memory stream = string.concat("state_reward_", vm.toString(t));
            uint256 folded = _uint(afterPre, string.concat(stream, "_lastUpdate"));
            require(
                folded > _uint(beforePre, string.concat(stream, "_lastUpdate")) && folded <= at,
                string.concat(stream, ": the after's last update is not between the before's and the captures' time")
            );
            uint256 finishAt = _uint(beforePre, string.concat(stream, "_finishAt"));
            uint256 end = Math.min(at, finishAt);
            expectations[2 * t] = CaptureExpectationsLib.Expectation({
                key: string.concat(stream, "_lastUpdate"),
                kind: CaptureExpectationsLib.Kind.Value,
                value: vm.toString(folded),
                bound: 0,
                reason: "the migration's checkpoint, taking rewards back, folded every stream at its moment"
            });
            expectations[2 * t + 1] = CaptureExpectationsLib.Expectation({
                key: string.concat(stream, "_pendingDistributable"),
                kind: CaptureExpectationsLib.Kind.Value,
                value: vm.toString(
                    end > folded ? _uint(beforePre, string.concat(stream, "_rate")) * (end - folded) : 0
                ),
                bound: 0,
                reason: "what the stream has left to distribute runs from the migration's moment, where it was folded"
            });
        }
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

    /// @dev The pre record's claimables: fold 0, read as the unfolded stream; less each holder's cut, where the
    ///      migration took one, and then one fold more - the migration's, which folded the stream up to its moment at
    ///      the same divisor, so the shift is the same to a floor.
    function _preRewardShifts(
        string memory beforePre,
        int256 gap,
        Cuts memory cuts
    ) private pure returns (CaptureExpectationsLib.Expectation[] memory expectations) {
        uint256 holders = _uint(beforePre, "state_depositorCount");
        uint256 tokens = _uint(beforePre, "state_activeRewardTokenCount");
        expectations = new CaptureExpectationsLib.Expectation[](holders * tokens);
        for (uint256 i = 0; i < holders; ++i) {
            for (uint256 t = 0; t < tokens; ++t) {
                expectations[i * tokens + t] = _shifted(
                    beforePre,
                    _rewardKey("state", i, t, "_claimable"),
                    _pendingShift(beforePre, i, t, gap) - int256(cuts.amounts[i][t]),
                    cuts.folded ? 2 : 1
                );
            }
        }
    }

    /// @dev The post record's reward readings, through the interactions: the captured holders, then the test user,
    ///      who deposited after fold 0 and so has no share in it, nor a cut. Every interaction ran: one that reverts
    ///      fails the capture.
    function _postRewardShifts(
        string memory beforePre,
        string memory beforePost,
        int256 gap,
        Cuts memory cuts
    ) private pure returns (CaptureExpectationsLib.Expectation[] memory expectations) {
        uint256 holders = _uint(beforePre, "state_depositorCount");
        uint256 tokens = _uint(beforePre, "state_activeRewardTokenCount");
        UserFolds memory folds;
        folds.gap = gap;
        folds.depositedSupply = _uint(beforePost, "interact_postDeposit_totalAssetSupply");
        folds.extra = cuts.folded ? 1 : 0;
        expectations = new CaptureExpectationsLib.Expectation[]((holders + 1) * tokens * 7);
        uint256 count;
        for (uint256 i = 0; i <= holders; ++i) {
            for (uint256 t = 0; t < tokens; ++t) {
                folds.shift0 = i < holders ? _pendingShift(beforePre, i, t, gap) : int256(0);
                folds.cut = i < holders ? int256(cuts.amounts[i][t]) : int256(0);
                count = _userRewardShifts(beforePost, i, t, folds, expectations, count);
            }
        }
    }

    /// @dev What one user's post-record reward readings in one token follow: the pool's gap, its supply after the two
    ///      deposits, the user's fold 0 shift, the cut the migration took from the user, and the fold the migration
    ///      added for everyone - one more floor per reading.
    struct UserFolds {
        int256 gap;
        uint256 depositedSupply;
        int256 shift0;
        int256 cut;
        uint256 extra;
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
        // The cut comes off what the user may claim until its first claim, the half-period one, which pays it out;
        // the full-period readings follow that claim and carry no cut.
        int256 shift0 = folds.shift0 - folds.cut;
        uint256 extra = folds.extra;
        all[count++] = _shifted(
            beforePost,
            _rewardKey("interact_preReward", user, token, "_claimable"),
            shift0,
            1 + extra
        );
        all[count++] = _shifted(
            beforePost,
            _rewardKey("interact_postReward", user, token, "_claimable"),
            shift0,
            1 + extra
        );
        all[count++] = _shifted(
            beforePost,
            _rewardKey("interact_half_preClaim", user, token, "_claimable"),
            shift0 + shift1,
            2 + extra
        );
        all[count++] = _shifted(
            beforePost,
            _rewardKey("interact_full_preClaim", user, token, "_claimable"),
            shift2,
            1 + extra
        );
        all[count++] = _shifted(
            beforePost,
            _rewardKey("interact_half_claim", user, token, "_delta"),
            shift0 + shift1,
            2 + extra
        );
        all[count++] = _shifted(
            beforePost,
            _rewardKey("interact_full_claim", user, token, "_delta"),
            shift2,
            1 + extra
        );
        all[count++] = _shifted(
            beforePost,
            _rewardKey("state", user, token, "_claimed"),
            shift0 + shift1 + shift2,
            3 + extra
        );
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
