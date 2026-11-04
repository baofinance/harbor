// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {MinterValuationLib} from "@harbor/minter/library/MinterValuationLib.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {JsonSerializer} from "@bao-script/deployment/JsonSerializer.sol";
import {allMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {UpgradeMarketToV3} from "@harbor-script/src/UpgradeMarketToV3.sol";
import {IStabilityPool_v3_Upgrader} from "@harbor-script/UpgradeStabilityPool_v2_v3/IStabilityPool_v3_Upgrader.sol";

/// @notice The v3 upgrade carrying phase 1 of the repayment for the rebalance dilution exploits of 2026-10-16: in each
///         exploited market's own batch, the one transaction that unpauses it, the gains the capped rebalance left in
///         three holders' unclaimed rewards are taken back as their pool is migrated and paid to the multisig; the
///         multisig then redeems, fee-free, its pegged fees from the exploit and the tokens taken back, and mints
///         leveraged tokens fee-free for every holder that lost, with a share of the fund - its wrapped fees and what
///         its two redemptions return - in proportion to what each lost. Nobody can act on a market between its
///         upgrade and its repayment: there is no between.
/// @dev The inputs are the files the incident's report wrote, `doc/incidents/2026-10-16-rebalance-dilution/
///      <market>-compensation.json`: per account its debt in wrapped collateral and its cut in value, and the market's
///      fees; `compensate` puts them into the upgrade's inputs. Nothing here restates how the figures were found. The
///      cut's price enters through the file: the tokens a cut takes are its value times the account's unclaimed reward
///      over that reward's value, all three read there.
///
///      Every amount the batch moves is fixed when it is built. The owner's operations are priced by Minter_v3 at the
///      oracle reading of the capture's block - the last before the pause, where the batch's every input is read and
///      the market's state has stood still since - which the batch holds still for them (`UpgradeMarketToV3`). What
///      the two redemptions return and the leveraged tokens each mint returns are sized here by the minter's own
///      arithmetic (`MinterValuationLib`) on that reading and the minter's state at that block, each operation on the
///      state the one before leaves. So the fund is exactly what the multisig will hold to mint with, and the batch
///      cannot run short; the multisig's own wrapped collateral is untouched but for the mints' floor dust, at most a
///      wei an account. A reading with a band - two prices or two rates - is refused: the sizing is proven for one
///      price and one rate, which is what the oracles reported at the pause.
abstract contract CompensateRebalanceDilution is UpgradeMarketToV3 {
    using LibString for uint256;
    using LibString for address;

    Vm private constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice One market's compensation inputs, as its file records them, with each cut in tokens.
    struct MarketCompensation {
        Config_MinterMarket market;
        string name;
        address[] accounts;
        uint256[] debts;
        uint256[] cutTokens;
        uint256 totalDebt;
        uint256 totalCutTokens;
        uint256 totalCutValue;
        uint256 feesWrapped;
        uint256 feesPegged;
    }

    /// @notice What a market's minter prices every operation from, read at the capture's block: the reading its
    ///         oracle gave, the backing it records, its pegged and leveraged supply, and the wrapped collateral token
    ///         it holds - the fund's unit, which every market must share; with the block it was read at and that
    ///         block's time.
    struct FrozenMarket {
        OracleAnswer answer;
        uint256 backing;
        uint256 peggedSupply;
        uint256 leveragedSupply;
        address wrapped;
        uint256 readBlock;
        uint256 readTime;
    }

    /// @notice The payout, sized: the fund and the fraction of each debt it pays; per market, the wrapped collateral
    ///         its pegged fees redeem for, the wrapped collateral its cuts redeem for, what it mints with in all, and
    ///         the minter's state before its operations and after them; per account, the wrapped collateral minted
    ///         with for it and the leveraged tokens that mint returns - each as Minter_v3 computes it at the market's
    ///         frozen reading, so each is what the batch moves.
    struct Payout {
        uint256 fund;
        uint256 fraction;
        uint256[] peggedReturns;
        uint256[] leveragedReturns;
        uint256[] mintTotals;
        uint256[][] mints;
        uint256[][] leveraged;
        FrozenMarket[] stateBefore;
        FrozenMarket[] stateAfter;
    }

    /// @notice The file names a market no deploy configures.
    error MarketNotConfigured(string market);

    /// @notice The file's arrays are not all of one length.
    error ArraysOfDifferentLengths(string file);

    /// @notice The file's debts do not sum to the total it records.
    error DebtsDoNotSumToTheTotal(string market, uint256 sum, uint256 total);

    /// @notice A market's oracle reported two prices or two rates at the capture's block, which the sizing is not
    ///         proven for.
    error OracleAnswerHasABand(string market, uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate);

    /// @notice Two markets hold different wrapped collateral tokens, so their fees and debts cannot be one fund.
    error MarketsOfDifferentWrappedCollateral(string market, string other);

    /// @notice What upgrading `markets` needs, as the upgrade script reads it: each market's inputs, and the compensation
    ///         `files` describe, put into the inputs of the markets among them. The payout is sized over every file
    ///         whichever markets are named, because they share one fund and one fraction of each debt, so a market run
    ///         alone queues what a run of them all queues. Where no market named is one a file describes, nothing is
    ///         sized and `compensated` is empty.
    function readUpgradeInputsAndCompensation(
        Config_MinterMarket[] memory markets,
        string memory capture,
        string memory network,
        string[] memory files
    )
        internal
        returns (MarketUpgradeInput[] memory inputs, MarketCompensation[] memory compensated, Payout memory payout)
    {
        inputs = readUpgradeInputs(markets, capture, network);
        MarketCompensation[] memory described = new MarketCompensation[](files.length);
        bool isCompensated;
        for (uint256 f = 0; f < files.length; ++f) {
            described[f] = readCompensation(files[f]);
            for (uint256 m = 0; m < markets.length; ++m) {
                isCompensated =
                    isCompensated || LibString.eq(MinterMarketConfigLib.salt(markets[m]), described[f].name);
            }
        }
        if (isCompensated) {
            compensated = described;
            payout = compensate(inputs, compensated, readFrozenMarkets(compensated, capture, network));
        }
    }

    /// @notice Read a market's compensation file.
    function readCompensation(string memory file) internal returns (MarketCompensation memory m) {
        string memory json = _vm.readFile(file);
        m.name = _vm.parseJsonString(json, ".market");
        m.market = _marketNamed(m.name);
        m.accounts = _vm.parseJsonAddressArray(json, ".accounts");
        m.debts = _vm.parseJsonUintArray(json, ".debts");
        uint256[] memory cuts = _vm.parseJsonUintArray(json, ".cuts");
        uint256[] memory unclaimed = _vm.parseJsonUintArray(json, ".unclaimedLeveraged");
        uint256[] memory unclaimedValue = _vm.parseJsonUintArray(json, ".unclaimedLeveragedValue");
        m.totalDebt = _vm.parseJsonUint(json, ".totalDebt");
        m.totalCutValue = _vm.parseJsonUint(json, ".totalCut");
        m.feesWrapped = _vm.parseJsonUint(json, ".feesWrapped");
        m.feesPegged = _vm.parseJsonUint(json, ".feesPegged");

        uint256 count = m.accounts.length;
        if (
            m.debts.length != count ||
            cuts.length != count ||
            unclaimed.length != count ||
            unclaimedValue.length != count
        ) {
            revert ArraysOfDifferentLengths(file);
        }
        m.cutTokens = new uint256[](count);
        uint256 sum;
        for (uint256 i = 0; i < count; ++i) {
            sum += m.debts[i];
            if (cuts[i] > 0) {
                m.cutTokens[i] = Math.mulDiv(cuts[i], unclaimed[i], unclaimedValue[i]);
                m.totalCutTokens += m.cutTokens[i];
            }
        }
        if (sum != m.totalDebt) {
            revert DebtsDoNotSumToTheTotal(m.name, sum, m.totalDebt);
        }
    }

    /// @notice Read each market's minter at the capture's block - the block the upgrade's inputs are read at, selected
    ///         by `selectFrozenReadBlock` - as `FrozenMarket`s, in the markets' order. The fork selected before is
    ///         selected again after.
    function readFrozenMarkets(
        MarketCompensation[] memory markets,
        string memory capture,
        string memory network
    ) internal returns (FrozenMarket[] memory frozen) {
        Config_MinterMarket[] memory configs = new Config_MinterMarket[](markets.length);
        for (uint256 m = 0; m < markets.length; ++m) {
            configs[m] = markets[m].market;
        }
        uint256 head = selectFrozenReadBlock(configs, capture, network);
        frozen = new FrozenMarket[](markets.length);
        for (uint256 m = 0; m < markets.length; ++m) {
            address minter = minterAddress(markets[m].market);
            OracleAnswer memory answer = frozen[m].answer;
            (answer.minPrice, answer.maxPrice, answer.minRate, answer.maxRate) = IWrappedPriceOracle(
                IMinter(minter).priceOracle()
            ).latestAnswer();
            frozen[m].backing = IMinter(minter).collateralTokenBalance();
            frozen[m].peggedSupply = IMinter(minter).peggedTokenBalance();
            frozen[m].leveragedSupply = IMinter(minter).leveragedTokenBalance();
            frozen[m].wrapped = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();
            frozen[m].readBlock = block.number;
            frozen[m].readTime = block.timestamp;
        }
        _vm.selectFork(head);
    }

    /// @notice The rewards a market's leveraged pool migration takes back: each gainer's cut in tokens of the market's
    ///         leveraged token, the pool's reward.
    function deductions(
        MarketCompensation memory m
    ) internal returns (IStabilityPool_v3_Upgrader.Deduction[] memory taken) {
        uint256 count;
        for (uint256 i = 0; i < m.accounts.length; ++i) {
            if (m.cutTokens[i] > 0) {
                ++count;
            }
        }
        taken = new IStabilityPool_v3_Upgrader.Deduction[](count);
        address leveraged = leveragedTokenAddress(m.market);
        uint256 at;
        for (uint256 i = 0; i < m.accounts.length; ++i) {
            if (m.cutTokens[i] > 0) {
                taken[at++] = IStabilityPool_v3_Upgrader.Deduction({
                    account: m.accounts[i],
                    token: leveraged,
                    amount: m.cutTokens[i]
                });
            }
        }
    }

    /// @notice Size the payout, each market's operations priced as Minter_v3 prices them at the market's frozen
    ///         reading and state, each on the state the one before leaves: the pegged fees redeemed for wrapped
    ///         collateral, then the cuts redeemed, then each loser minted for. The fund is every market's wrapped
    ///         fees and what its two redemptions return; the fraction is the fund over every debt, at most the whole
    ///         debt; each loser is minted for with that fraction of its debt, floored. A zero debt gets nothing, and
    ///         what the fund holds beyond the debts is not minted with.
    /// @dev The record of backing follows the minter's own rule: credited with a mint's wrapped collateral converted
    ///      at the rate and floored, debited a redemption's collateral ceiled.
    function sizePayout(
        MarketCompensation[] memory markets,
        FrozenMarket[] memory frozen
    ) internal pure returns (Payout memory p) {
        uint256 count = markets.length;
        p.peggedReturns = new uint256[](count);
        p.leveragedReturns = new uint256[](count);
        p.mintTotals = new uint256[](count);
        p.mints = new uint256[][](count);
        p.leveraged = new uint256[][](count);
        p.stateBefore = new FrozenMarket[](count);
        // The operations move each market's state along, each starting from where the one before left it: a copy,
        // so the caller's reading is not changed under it, kept as the state after.
        FrozenMarket[] memory state = new FrozenMarket[](count);
        p.stateAfter = state;
        uint256 debts;
        for (uint256 m = 0; m < count; ++m) {
            OracleAnswer memory answer = frozen[m].answer;
            if (answer.minPrice != answer.maxPrice || answer.minRate != answer.maxRate) {
                revert OracleAnswerHasABand(
                    markets[m].name,
                    answer.minPrice,
                    answer.maxPrice,
                    answer.minRate,
                    answer.maxRate
                );
            }
            if (frozen[m].wrapped != frozen[0].wrapped) {
                revert MarketsOfDifferentWrappedCollateral(markets[0].name, markets[m].name);
            }
            p.stateBefore[m] = FrozenMarket(
                answer,
                frozen[m].backing,
                frozen[m].peggedSupply,
                frozen[m].leveragedSupply,
                frozen[m].wrapped,
                frozen[m].readBlock,
                frozen[m].readTime
            );
            state[m] = FrozenMarket(
                answer,
                frozen[m].backing,
                frozen[m].peggedSupply,
                frozen[m].leveragedSupply,
                frozen[m].wrapped,
                frozen[m].readBlock,
                frozen[m].readTime
            );
            if (markets[m].feesPegged > 0) {
                uint256 outE36 = MinterValuationLib.collateralForPegged(
                    markets[m].feesPegged,
                    state[m].peggedSupply,
                    state[m].backing,
                    answer.minPrice
                );
                p.peggedReturns[m] = outE36 / answer.minRate;
                state[m].backing -= Math.ceilDiv(outE36, 1 ether);
                state[m].peggedSupply -= markets[m].feesPegged;
            }
            if (markets[m].totalCutTokens > 0) {
                uint256 outE36 = MinterValuationLib.collateralForLeveraged(
                    markets[m].totalCutTokens,
                    state[m].peggedSupply,
                    state[m].backing,
                    answer.minPrice,
                    state[m].leveragedSupply
                );
                p.leveragedReturns[m] = outE36 / answer.minRate;
                state[m].backing -= Math.ceilDiv(outE36, 1 ether);
                state[m].leveragedSupply -= markets[m].totalCutTokens;
            }
            p.fund += markets[m].feesWrapped + p.peggedReturns[m] + p.leveragedReturns[m];
            debts += markets[m].totalDebt;
        }
        p.fraction = Math.min(Math.mulDiv(p.fund, 1 ether, debts), 1 ether);
        for (uint256 m = 0; m < count; ++m) {
            uint256 accounts = markets[m].accounts.length;
            p.mints[m] = new uint256[](accounts);
            p.leveraged[m] = new uint256[](accounts);
            for (uint256 i = 0; i < accounts; ++i) {
                uint256 mint = Math.mulDiv(markets[m].debts[i], p.fraction, 1 ether);
                if (mint > 0) {
                    uint256 added = MinterValuationLib.wrappedAsCollateral(mint, state[m].answer.minRate);
                    uint256 leveraged = MinterValuationLib.leveragedForCollateral(
                        added,
                        state[m].backing,
                        state[m].answer.minPrice,
                        state[m].peggedSupply,
                        state[m].leveragedSupply
                    );
                    p.mints[m][i] = mint;
                    p.leveraged[m][i] = leveraged;
                    p.mintTotals[m] += mint;
                    state[m].backing += added;
                    state[m].leveragedSupply += leveraged;
                }
            }
        }
    }

    /// @notice What a wrapped collateral token is worth in pegged units at `answer`: the collateral's price times the
    ///         wrapped-to-underlying rate, each read where the sizing reads it.
    function wrappedInPeggedOf(OracleAnswer memory answer) internal pure returns (uint256) {
        return Math.mulDiv(answer.minPrice, answer.minRate, 1 ether);
    }

    /// @notice The leveraged token's price at `state`, as the minter reports it: in pegged units, and in wrapped
    ///         collateral through `wrappedInPeggedOf`, each floored to the wei.
    function leveragedPriceOf(FrozenMarket memory state) internal pure returns (uint256 pegged, uint256 wrapped) {
        pegged =
            MinterValuationLib.leveragedTokenPriceE36(
                state.peggedSupply,
                state.backing,
                state.answer.minPrice,
                state.leveragedSupply
            ) / 1 ether;
        wrapped = Math.mulDiv(pegged, 1 ether, wrappedInPeggedOf(state.answer));
    }

    /// @notice The collateral ratio at `state`, as the minter reports it.
    function collateralRatioOf(FrozenMarket memory state) internal pure returns (uint256) {
        return MinterValuationLib.collateralRatio(state.backing, state.answer.minPrice, state.peggedSupply);
    }

    /// @notice Put the compensation into the upgrade's inputs: for each market a file describes that `inputs` holds, its
    ///         leveraged pool takes back the gainers' cuts, and the owner's operations after its upgrade - priced at the
    ///         market's frozen reading - redeem the pegged fees and the tokens taken back and mint for each loser its
    ///         share of the fund, sized here over every file.
    function compensate(
        MarketUpgradeInput[] memory inputs,
        MarketCompensation[] memory markets,
        FrozenMarket[] memory frozen
    ) internal returns (Payout memory p) {
        p = sizePayout(markets, frozen);
        for (uint256 m = 0; m < markets.length; ++m) {
            for (uint256 i = 0; i < inputs.length; ++i) {
                if (LibString.eq(MinterMarketConfigLib.salt(inputs[i].market), markets[m].name)) {
                    inputs[i].leveragedPool.deductions = deductions(markets[m]);
                    inputs[i].ownerOperations = OwnerOperations({
                        answer: frozen[m].answer,
                        peggedRedeemed: markets[m].feesPegged,
                        leveragedRedeemed: markets[m].totalCutTokens,
                        accounts: markets[m].accounts,
                        mints: p.mints[m]
                    });
                }
            }
        }
    }

    /// @notice Write the payout as a document, every amount named in its token - the symbols read from the market's
    ///         tokens: the fund and the fraction; per market the reading held still, with the leveraged token's price
    ///         and the collateral ratio before the operations and after them, what its redemptions return and what it
    ///         mints; per account what it is owed, the cut taken, the leveraged tokens it receives, their worth at the
    ///         reading - the wrapped collateral minted with - and what it is still owed after, the remainder phase 2
    ///         settles.
    function writePayoutReport(string memory path, MarketCompensation[] memory markets, Payout memory p) internal {
        // The fund's unit: the wrapped collateral every market holds, as the sizing requires.
        string memory wrapped = IERC20Metadata(p.stateBefore[0].wrapped).symbol();
        string memory text = string.concat(
            "# Phase 1 of the repayment, as queued\n\n",
            "Generated by the upgrade script, through `script/src/CompensateRebalanceDilution.sol`, on ",
            JsonSerializer.formatTimestamp(block.timestamp),
            ". Amounts in tokens, 18 decimals, each named in its token. Every amount is what the market's batch ",
            "moves, priced at the oracle reading of block ",
            p.stateBefore[0].readBlock.toString(),
            " (",
            JsonSerializer.formatTimestamp(p.stateBefore[0].readTime),
            "), the last block before the pause that froze the markets - where the upgrade reads them, and the "
        );
        text = string.concat(
            text,
            "reading the batch holds still for the operations. Each wallet that lost receives the market's leveraged ",
            "token, minted fee-free with its share of the fund; what it receives is worth, at that reading, the ",
            wrapped,
            " minted with.\n\n"
        );
        text = string.concat(
            text,
            "- Fund: ",
            _scaled(p.fund),
            " ",
            wrapped,
            " - each market's ",
            wrapped,
            " fees and what its two redemptions return.\n- Fraction of each debt paid: ",
            _scaled(p.fraction),
            "\n"
        );
        for (uint256 m = 0; m < markets.length; ++m) {
            text = string.concat(text, _marketReport(markets[m], p, m));
        }
        _vm.writeFile(path, text);
    }

    /// @dev The symbols of a market's three tokens, as the tokens give them.
    struct Symbols {
        string wrapped;
        string pegged;
        string leveraged;
    }

    /// @dev One market's section of the payout report.
    function _marketReport(
        MarketCompensation memory market,
        Payout memory p,
        uint256 m
    ) private returns (string memory text) {
        Symbols memory s = Symbols({
            wrapped: IERC20Metadata(IHarborConfig(address(market.market)).wrappedCollateralToken()).symbol(),
            pegged: IERC20Metadata(peggedTokenAddress(market.market)).symbol(),
            leveraged: IERC20Metadata(leveragedTokenAddress(market.market)).symbol()
        });
        text = string.concat("\n## ", market.name, "\n\n", _readingReport(p, m, s), _marketLines(market, p, m, s));
        text = string.concat(
            text,
            "| Account | Owed (",
            s.wrapped,
            ") | Taken back (",
            s.leveraged,
            ") | Receives (",
            s.leveraged,
            ") | Worth at the reading ("
        );
        text = string.concat(text, s.wrapped, ") | Still owed (", s.wrapped, ") |\n|---|---|---|---|---|---|\n");
        for (uint256 i = 0; i < market.accounts.length; ++i) {
            text = string.concat(text, _accountRow(market, p, m, i));
        }
    }

    /// @dev A market's figures: its fees, what its redemptions return, what it mints and what is still owed after.
    function _marketLines(
        MarketCompensation memory market,
        Payout memory p,
        uint256 m,
        Symbols memory s
    ) private pure returns (string memory text) {
        text = string.concat("- ", s.wrapped, " fees: ", _scaled(market.feesWrapped), "\n- ", s.pegged, " fees: ");
        text = string.concat(
            text,
            _scaled(market.feesPegged),
            ", redeemed for ",
            _scaled(p.peggedReturns[m]),
            " ",
            s.wrapped,
            "\n- ",
            s.leveraged
        );
        text = string.concat(
            text,
            " taken back: ",
            _scaled(market.totalCutTokens),
            ", redeemed for ",
            _scaled(p.leveragedReturns[m]),
            " ",
            s.wrapped,
            "\n- Minted: "
        );
        text = string.concat(
            text,
            _scaled(_sum(p.leveraged[m])),
            " ",
            s.leveraged,
            " in all, with ",
            _scaled(p.mintTotals[m]),
            " ",
            s.wrapped
        );
        text = string.concat(
            text,
            "\n- Still owed after, in all: ",
            _scaled(market.totalDebt - p.mintTotals[m]),
            " ",
            s.wrapped,
            ", for phase 2\n\n"
        );
    }

    /// @dev One account's row: what it is owed, the cut taken, what it receives, its worth at the reading and what
    ///      it is still owed.
    function _accountRow(
        MarketCompensation memory market,
        Payout memory p,
        uint256 m,
        uint256 i
    ) private pure returns (string memory text) {
        text = string.concat(
            "| `",
            market.accounts[i].toHexStringChecksummed(),
            "` | ",
            _scaled(market.debts[i]),
            " | ",
            _scaled(market.cutTokens[i]),
            " | "
        );
        text = string.concat(
            text,
            _scaled(p.leveraged[m][i]),
            " | ",
            _scaled(p.mints[m][i]),
            " | ",
            _scaled(market.debts[i] - p.mints[m][i]),
            " |\n"
        );
    }

    /// @dev The reading a market's batch holds still, and the leveraged token's price and the collateral ratio at it,
    ///      before the market's operations and after them.
    function _readingReport(Payout memory p, uint256 m, Symbols memory s) private pure returns (string memory text) {
        (uint256 peggedBefore, uint256 wrappedBefore) = leveragedPriceOf(p.stateBefore[m]);
        text = string.concat(
            "- The reading held still: 1 ",
            s.wrapped,
            " = ",
            _scaled(wrappedInPeggedOf(p.stateBefore[m].answer)),
            " ",
            s.pegged,
            ". At it, 1 ",
            s.leveraged
        );
        text = string.concat(
            text,
            " = ",
            _scaled(peggedBefore),
            " ",
            s.pegged,
            " (",
            _scaled(wrappedBefore),
            " ",
            s.wrapped
        );
        (uint256 peggedAfter, uint256 wrappedAfter) = leveragedPriceOf(p.stateAfter[m]);
        text = string.concat(
            text,
            ") before the batch and ",
            _scaled(peggedAfter),
            " ",
            s.pegged,
            " (",
            _scaled(wrappedAfter),
            " ",
            s.wrapped
        );
        text = string.concat(
            text,
            ") after; the collateral ratio ",
            _scaled(collateralRatioOf(p.stateBefore[m])),
            " before and ",
            _scaled(collateralRatioOf(p.stateAfter[m])),
            " after.\n"
        );
    }

    function _sum(uint256[] memory amounts) private pure returns (uint256 total) {
        for (uint256 i = 0; i < amounts.length; ++i) {
            total += amounts[i];
        }
    }

    /// @dev The market config `allMintersConfig` lists under `name`, as "<peg>::<collateral>".
    function _marketNamed(string memory name) private returns (Config_MinterMarket) {
        Config_MinterMarket[] memory markets = allMintersConfig();
        bytes32 wanted = keccak256(bytes(name));
        for (uint256 i = 0; i < markets.length; ++i) {
            if (keccak256(bytes(MinterMarketConfigLib.salt(markets[i]))) == wanted) {
                return markets[i];
            }
        }
        revert MarketNotConfigured(name);
    }
}
