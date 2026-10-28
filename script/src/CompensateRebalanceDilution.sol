// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {allMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {UpgradeMarketToV3} from "@harbor-script/src/UpgradeMarketToV3.sol";
import {IStabilityPool_v3_Upgrader} from "@harbor-script/UpgradeStabilityPool_v2_v3/IStabilityPool_v3_Upgrader.sol";

/// @notice The v3 upgrade carrying phase 1 of the repayment for the rebalance dilution exploits of 2026-10-16: in each
///         exploited market's own batch, the one transaction that unpauses it, the gains the capped rebalance left in
///         three holders' unclaimed rewards are taken back as their pool is migrated and paid to the multisig; the
///         multisig then redeems, fee-free, its pegged fees from the exploit and the tokens taken back, and mints
///         leveraged tokens fee-free for every holder that lost, with a share of the fund - its wrapped fees, what its
///         pegged fees are worth, and what the tokens taken back are worth - in proportion to what each lost. Nobody can
///         act on a market between its upgrade and its repayment: there is no between.
/// @dev The inputs are the files the incident's report wrote, `doc/incidents/2026-10-16-rebalance-dilution/
///      <market>-compensation.json`: per account its debt in wrapped collateral and its cut in value, and the market's
///      fees; `compensate` puts them into the upgrade's inputs. Nothing here restates how the figures were found. The
///      cut's price enters through the file: the tokens a cut takes are its value times the account's unclaimed reward
///      over that reward's value, all three read there, and the cut's value counts in the fund as the file states it.
///      The pegged fees are valued through each market's oracle when the batch is built, the minters being paused.
///      What the multisig's redemptions return and what its mints buy are priced by the minters when the batch
///      executes: the fund's wrapped collateral then differs from the valuation by the price's move in between, and
///      the multisig's own wrapped collateral covers the difference either way.
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

    /// @notice The payout, sized: the fund and the fraction of each debt it pays; per market, what its pegged fees are
    ///         worth in wrapped collateral and what it mints with in all; per account, the wrapped collateral minted
    ///         with for it.
    struct Payout {
        uint256 fund;
        uint256 fraction;
        uint256[] peggedValues;
        uint256[] mintTotals;
        uint256[][] mints;
    }

    /// @notice The file names a market no deploy configures.
    error MarketNotConfigured(string market);

    /// @notice The file's arrays are not all of one length.
    error ArraysOfDifferentLengths(string file);

    /// @notice The file's debts do not sum to the total it records.
    error DebtsDoNotSumToTheTotal(string market, uint256 sum, uint256 total);

    /// @notice A compensation file names a market the upgrade's inputs do not.
    error MarketNotInTheUpgrade(string market);

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

    /// @notice What `pegged` pegged tokens are worth in wrapped collateral by `oracle`, which prices the underlying
    ///         collateral in pegged units and gives the wrapped-to-underlying rate, each read at the middle of its band
    ///         as the incident's report read them.
    function peggedInWrapped(address oracle, uint256 pegged) internal view returns (uint256) {
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(oracle)
            .latestAnswer();
        uint256 wrappedInPegged = Math.mulDiv((minPrice + maxPrice + 1) / 2, (minRate + maxRate + 1) / 2, 1 ether);
        return Math.mulDiv(pegged, 1 ether, wrappedInPegged);
    }

    /// @notice Size the payout. The fund is every market's wrapped fees, what its pegged fees are worth and what its
    ///         cuts are worth; the fraction is the fund over every debt; each loser is minted for with that fraction of
    ///         its debt. A zero debt gets nothing.
    /// @param peggedValues Per market, what its pegged fees are worth in wrapped collateral.
    function sizePayout(
        MarketCompensation[] memory markets,
        uint256[] memory peggedValues
    ) internal pure returns (Payout memory p) {
        uint256 debts;
        for (uint256 m = 0; m < markets.length; ++m) {
            p.fund += markets[m].feesWrapped + peggedValues[m] + markets[m].totalCutValue;
            debts += markets[m].totalDebt;
        }
        p.fraction = Math.mulDiv(p.fund, 1 ether, debts);
        p.peggedValues = peggedValues;
        p.mintTotals = new uint256[](markets.length);
        p.mints = new uint256[][](markets.length);
        for (uint256 m = 0; m < markets.length; ++m) {
            uint256 count = markets[m].accounts.length;
            p.mints[m] = new uint256[](count);
            for (uint256 i = 0; i < count; ++i) {
                p.mints[m][i] = Math.mulDiv(markets[m].debts[i], p.fraction, 1 ether);
                p.mintTotals[m] += p.mints[m][i];
            }
        }
    }

    /// @notice Put the compensation into the upgrade's inputs: for each market a file describes, its leveraged pool
    ///         takes back the gainers' cuts, and the owner's operations after its upgrade redeem the pegged fees and the
    ///         tokens taken back and mint for each loser its share of the fund, sized here with the pegged fees valued
    ///         through the oracle each input names.
    function compensate(
        MarketUpgradeInput[] memory inputs,
        MarketCompensation[] memory markets
    ) internal returns (Payout memory p) {
        uint256[] memory at = new uint256[](markets.length);
        uint256[] memory peggedValues = new uint256[](markets.length);
        for (uint256 m = 0; m < markets.length; ++m) {
            at[m] = _inputOf(inputs, markets[m].name);
            if (markets[m].feesPegged > 0) {
                peggedValues[m] = peggedInWrapped(inputs[at[m]].priceOracle, markets[m].feesPegged);
            }
        }
        p = sizePayout(markets, peggedValues);
        for (uint256 m = 0; m < markets.length; ++m) {
            inputs[at[m]].leveragedPool.deductions = deductions(markets[m]);
            inputs[at[m]].ownerOperations = OwnerOperations({
                peggedRedeemed: markets[m].feesPegged,
                leveragedRedeemed: markets[m].totalCutTokens,
                accounts: markets[m].accounts,
                mints: p.mints[m]
            });
        }
    }

    /// @notice Write the payout as a document: the fund, the fraction, and per market every account's debt, cut taken
    ///         and wrapped collateral minted with.
    function writePayoutReport(string memory path, MarketCompensation[] memory markets, Payout memory p) internal {
        string memory text = string.concat(
            "# Phase 1 of the repayment, as queued\n\n",
            "Generated by the upgrade script, through `script/src/CompensateRebalanceDilution.sol`, at block ",
            block.number.toString(),
            ". Amounts in tokens, 18 decimals.\n\n",
            "- Fund: ",
            _scaled(p.fund),
            " wrapped collateral - each market's wrapped fees, what its pegged fees are worth, and what its cuts are ",
            "worth.\n- Fraction of each debt paid: ",
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
                ", worth ",
                _scaled(p.peggedValues[m]),
                " wrapped\n- Cut tokens taken back: ",
                _scaled(markets[m].totalCutTokens),
                ", worth ",
                _scaled(markets[m].totalCutValue),
                " wrapped\n- Minted with: ",
                _scaled(p.mintTotals[m]),
                " wrapped\n\n| Account | Debt (wrapped) | Cut taken (leveraged) | Minted with (wrapped) |\n",
                "|---|---|---|---|\n"
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
