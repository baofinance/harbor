// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {MinterValuationLib} from "@harbor/minter/library/MinterValuationLib.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
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
    ///         oracle gave, the backing it records, and its pegged and leveraged supply.
    struct FrozenMarket {
        OracleAnswer answer;
        uint256 backing;
        uint256 peggedSupply;
        uint256 leveragedSupply;
    }

    /// @notice The payout, sized: the fund and the fraction of each debt it pays; per market, the wrapped collateral
    ///         its pegged fees redeem for, the wrapped collateral its cuts redeem for, and what it mints with in all;
    ///         per account, the wrapped collateral minted with for it and the leveraged tokens that mint returns -
    ///         each as Minter_v3 computes it at the market's frozen reading, so each is what the batch moves.
    struct Payout {
        uint256 fund;
        uint256 fraction;
        uint256[] peggedReturns;
        uint256[] leveragedReturns;
        uint256[] mintTotals;
        uint256[][] mints;
        uint256[][] leveraged;
    }

    /// @notice The file names a market no deploy configures.
    error MarketNotConfigured(string market);

    /// @notice The file's arrays are not all of one length.
    error ArraysOfDifferentLengths(string file);

    /// @notice The file's debts do not sum to the total it records.
    error DebtsDoNotSumToTheTotal(string market, uint256 sum, uint256 total);

    /// @notice A compensation file names a market the upgrade's inputs do not.
    error MarketNotInTheUpgrade(string market);

    /// @notice A market's oracle reported two prices or two rates at the capture's block, which the sizing is not
    ///         proven for.
    error OracleAnswerHasABand(string market, uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate);

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
    ///         fees and what its two redemptions return; the fraction is the fund over every debt; each loser is
    ///         minted for with that fraction of its debt, floored. A zero debt gets nothing.
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
        // The redemptions leave each market's state where the mints start from: a copy, so the caller's reading is
        // not changed under it.
        FrozenMarket[] memory state = new FrozenMarket[](count);
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
            state[m] = FrozenMarket(answer, frozen[m].backing, frozen[m].peggedSupply, frozen[m].leveragedSupply);
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
        p.fraction = Math.mulDiv(p.fund, 1 ether, debts);
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

    /// @notice Put the compensation into the upgrade's inputs: for each market a file describes, its leveraged pool
    ///         takes back the gainers' cuts, and the owner's operations after its upgrade - priced at the market's
    ///         frozen reading - redeem the pegged fees and the tokens taken back and mint for each loser its share of
    ///         the fund, sized here.
    function compensate(
        MarketUpgradeInput[] memory inputs,
        MarketCompensation[] memory markets,
        FrozenMarket[] memory frozen
    ) internal returns (Payout memory p) {
        p = sizePayout(markets, frozen);
        for (uint256 m = 0; m < markets.length; ++m) {
            uint256 at = _inputOf(inputs, markets[m].name);
            inputs[at].leveragedPool.deductions = deductions(markets[m]);
            inputs[at].ownerOperations = OwnerOperations({
                answer: frozen[m].answer,
                peggedRedeemed: markets[m].feesPegged,
                leveragedRedeemed: markets[m].totalCutTokens,
                accounts: markets[m].accounts,
                mints: p.mints[m]
            });
        }
    }

    /// @notice Write the payout as a document: the fund, the fraction, and per market what its redemptions return and
    ///         every account's debt, cut taken, wrapped collateral minted with and leveraged tokens received.
    function writePayoutReport(string memory path, MarketCompensation[] memory markets, Payout memory p) internal {
        string memory text = string.concat(
            "# Phase 1 of the repayment, as queued\n\n",
            "Generated by the upgrade script, through `script/src/CompensateRebalanceDilution.sol`, at block ",
            block.number.toString(),
            ". Amounts in tokens, 18 decimals; every amount is what the market's batch moves, priced at the oracle ",
            "reading of the capture's block, which the batch holds still for the operations.\n\n",
            "- Fund: ",
            _scaled(p.fund),
            " wrapped collateral - each market's wrapped fees and what its two redemptions return.\n",
            "- Fraction of each debt paid: ",
            _scaled(p.fraction),
            "\n"
        );
        for (uint256 m = 0; m < markets.length; ++m) {
            text = string.concat(
                text,
                "\n## ",
                markets[m].name,
                "\n\n- Wrapped fees: ",
                _scaled(markets[m].feesWrapped),
                "\n- Pegged fees: ",
                _scaled(markets[m].feesPegged),
                ", redeemed for ",
                _scaled(p.peggedReturns[m]),
                " wrapped\n- Cut tokens taken back: ",
                _scaled(markets[m].totalCutTokens),
                ", redeemed for ",
                _scaled(p.leveragedReturns[m]),
                " wrapped\n- Minted with: ",
                _scaled(p.mintTotals[m]),
                " wrapped\n\n| Account | Debt (wrapped) | Cut taken (leveraged) | Minted with (wrapped) | ",
                "Leveraged received |\n|---|---|---|---|---|\n"
            );
            for (uint256 i = 0; i < markets[m].accounts.length; ++i) {
                text = string.concat(
                    text,
                    "| `",
                    markets[m].accounts[i].toHexStringChecksummed(),
                    "` | ",
                    _scaled(markets[m].debts[i]),
                    " | ",
                    _scaled(markets[m].cutTokens[i]),
                    " | ",
                    _scaled(p.mints[m][i]),
                    " | ",
                    _scaled(p.leveraged[m][i]),
                    " |\n"
                );
            }
        }
        _vm.writeFile(path, text);
    }

    /// @dev The index in `inputs` of the market named `name`, as "<peg>::<collateral>".
    function _inputOf(MarketUpgradeInput[] memory inputs, string memory name) private view returns (uint256) {
        bytes32 wanted = keccak256(bytes(name));
        for (uint256 i = 0; i < inputs.length; ++i) {
            if (keccak256(bytes(MinterMarketConfigLib.salt(inputs[i].market))) == wanted) {
                return i;
            }
        }
        revert MarketNotInTheUpgrade(name);
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
