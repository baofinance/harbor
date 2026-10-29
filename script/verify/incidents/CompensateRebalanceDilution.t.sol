// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Deployer} from "@bao-script/deployment/Deployer.sol";
import {JsonSerializer} from "@bao-script/deployment/JsonSerializer.sol";
import {BaoTest} from "@bao-test/BaoTest.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardAccumulator_v3} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {btcMintersConfig} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {eurMintersConfig} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {CompensateRebalanceDilution} from "@harbor-script/src/CompensateRebalanceDilution.sol";
import {UpgradeMarketToV3} from "@harbor-script/src/UpgradeMarketToV3.sol";
import {IStabilityPool_v3_Upgrader} from "@harbor-script/UpgradeStabilityPool_v2_v3/IStabilityPool_v3_Upgrader.sol";
import {
    BTC_STETH_COMPENSATION,
    EUR_STETH_COMPENSATION,
    FROZEN_MARKETS_CAPTURE
} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";

import {CompensationRun} from "@harbor-script/verify/incidents/CompensationRun.sol";

/// @notice Phase 1 of the repayment for the rebalance dilution exploits: the compensation's inputs read as the
///         incident's files record them, the deductions and the payout sized from them by the minter's own arithmetic
///         at the capture block's reading, and the compensated upgrade of the two exploited markets run as it will run
///         - at the block after the pause, each market's batch executed as the multisig - taking back the gains and
///         paying the losers in the same transaction as the upgrade, every amount exactly as sized.
/// @dev Needs MAINNET_RPC_URL, archival at the capture's block, and `--disable-block-gas-limit`: the two markets'
///      upgrade runs in one test call, beyond a block's gas (`run-compensation-test`). Under `script/verify/`, with
///      the incident's report that writes the files it reads.
contract CompensateRebalanceDilutionTest is BaoTest {
    string private constant SALT = "harbor_v1";

    /// @dev The capture's block, where the frozen markets are read; the next block, where every minter and pool is
    ///      paused and the upgrade runs, is 12 seconds later.
    uint256 private constant BLOCK_TIME = 12;

    /// @dev What one market reads before its upgrade: its contracts and the oracle proxy the deploy predicts for it;
    ///      each account's claimable leveraged reward in the leveraged pool and its leveraged balance; the pool's
    ///      leveraged tokens; the multisig's holdings; the leveraged reward stream's rate; the collateral ratio; and,
    ///      as the running minter gives them at the capture's block, its oracle's answer and the leveraged token's
    ///      price in pegged units.
    struct Before {
        address minter;
        address pool;
        address leveraged;
        address pegged;
        address predictedOracle;
        uint256[] claimables;
        uint256[] balances;
        uint256 poolLeveraged;
        uint256 multisigPegged;
        uint256 multisigLeveraged;
        uint256 rate;
        uint256 collateralRatio;
        UpgradeMarketToV3.OracleAnswer answer;
        uint256 leveragedPrice;
    }

    /// @dev What the minters' events say the batches did to one market: the pegged and leveraged burned, the wrapped
    ///      collateral returned and taken, and per account the wrapped collateral paid for it and the leveraged minted.
    struct Done {
        uint256 peggedBurned;
        uint256 leveragedBurned;
        uint256 collateralOut;
        uint256 collateralIn;
        uint256[] paid;
        uint256[] minted;
    }

    /// @dev One market's share of the payout as the run sized it: what its two redemptions return, per account the
    ///      wrapped collateral minted with and the leveraged that mint returns, and the minter's state before the
    ///      operations and after them.
    struct Sized {
        uint256 peggedReturn;
        uint256 leveragedReturn;
        uint256[] mints;
        uint256[] leveraged;
        CompensateRebalanceDilution.FrozenMarket stateBefore;
        CompensateRebalanceDilution.FrozenMarket stateAfter;
    }

    /// @dev The compensated upgrade of BTC::stETH and EUR::stETH, from the frozen capture and the two incident files.
    function _aRun() private returns (CompensationRun run) {
        (, Config_MinterMarket[] memory btc) = btcMintersConfig();
        (, Config_MinterMarket[] memory eur) = eurMintersConfig();
        Config_MinterMarket[] memory markets = new Config_MinterMarket[](2);
        markets[0] = btc[1]; // BTC::stETH
        markets[1] = eur[1]; // EUR::stETH
        // A contract made on one fork is absent from another unless persistent: the run reads the frozen markets on
        // forks of its own.
        vm.makePersistent(address(markets[0]));
        vm.makePersistent(address(markets[1]));
        string[] memory files = new string[](2);
        files[0] = BTC_STETH_COMPENSATION;
        files[1] = EUR_STETH_COMPENSATION;
        run = new CompensationRun(SALT, markets, FROZEN_MARKETS_CAPTURE, files);
        run.ensureFactory();
    }

    /// @notice Both incident files read whole: the market found by its name, every account with its debt summing to the
    ///         total, the cuts' value, the EUR pegged fee - written as a string, being too large for a JSON number -
    ///         read entire, and the three BTC cuts in tokens as the cut's value times the unclaimed reward over the
    ///         reward's value, zero elsewhere.
    function test_readCompensation_readsTheIncidentFiles() public {
        CompensationRun run = _aRun();
        CompensateRebalanceDilution.MarketCompensation memory btc = run.read(BTC_STETH_COMPENSATION);
        assertEq(btc.name, "BTC::stETH", "the BTC file's market");
        assertEq(MinterMarketConfigLib.salt(btc.market), "BTC::stETH", "its config");
        assertEq(btc.accounts.length, 15, "its accounts");
        assertEq(btc.totalDebt, 11549111694056738493, "its debts' total");
        assertEq(btc.totalCutValue, 127141796885398621, "its cuts' value");
        assertEq(btc.feesWrapped, 3002792846575236128, "its wrapped fees");
        assertEq(btc.feesPegged, 74048026841324418, "its pegged fees");
        uint256 sum;
        for (uint256 i = 0; i < btc.debts.length; ++i) {
            sum += btc.debts[i];
        }
        assertEq(sum, btc.totalDebt, "the debts sum to the total");
        // The three gainers, in the file's order: cut x unclaimed / value, each from the file.
        assertEq(btc.accounts[0], 0x0e4d5032c0B076cB132a10347d940BfBB8354869, "the first gainer");
        assertEq(
            btc.cutTokens[0],
            Math.mulDiv(73920778919683581, 56135175912542335, 92714319397198985),
            "its cut in tokens"
        );
        assertEq(btc.accounts[1], 0x13F210c8bAf5f5DBAFf3E917E2e5A49E73BBAF12, "the second gainer");
        assertEq(
            btc.cutTokens[1],
            Math.mulDiv(30769726058583512, 142690333130136740, 235671072650265913),
            "its cut in tokens"
        );
        assertEq(btc.accounts[4], 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F, "the third gainer");
        assertEq(
            btc.cutTokens[4],
            Math.mulDiv(22451291907131528, 104114749521368204, 171958633497873106),
            "its cut in tokens"
        );
        assertEq(btc.totalCutTokens, btc.cutTokens[0] + btc.cutTokens[1] + btc.cutTokens[4], "the cuts' total");
        for (uint256 i = 0; i < btc.cutTokens.length; ++i) {
            if (i != 0 && i != 1 && i != 4) {
                assertEq(btc.cutTokens[i], 0, "no cut elsewhere");
            }
        }

        CompensateRebalanceDilution.MarketCompensation memory eur = run.read(EUR_STETH_COMPENSATION);
        assertEq(eur.name, "EUR::stETH", "the EUR file's market");
        assertEq(eur.accounts.length, 7, "its accounts");
        assertEq(eur.totalDebt, 3027147945233843698, "its debts' total");
        assertEq(eur.feesWrapped, 989921357011392341, "its wrapped fees");
        assertEq(eur.feesPegged, 1584045666291765088685, "its pegged fees, read whole from a string");
        assertEq(eur.totalCutTokens, 0, "no cut");
        assertEq(eur.totalCutValue, 0, "no cut value");
    }

    /// @notice A file whose debts do not sum to the total it records is refused, naming both.
    function test_readCompensation_refusesDebtsNotSummingToTheTotal() public {
        CompensationRun run = _aRun();
        vm.expectRevert(
            abi.encodeWithSelector(
                CompensateRebalanceDilution.DebtsDoNotSumToTheTotal.selector,
                "BTC::stETH",
                uint256(5),
                uint256(6)
            )
        );
        run.read("script/verify/incidents/compensation-debts-not-summing.json");
    }

    /// @notice The deductions a market's leveraged pool migration takes back are its gainers' cuts in tokens of its
    ///         leveraged token, in the file's order; a market with no cut has none.
    function test_deductions_areTheGainersCutsInTokens() public {
        CompensationRun run = _aRun();
        CompensateRebalanceDilution.MarketCompensation memory btc = run.read(BTC_STETH_COMPENSATION);
        address leveraged = run.leveragedTokenAddress(btc.market);

        IStabilityPool_v3_Upgrader.Deduction[] memory taken = run.deductionsOf(btc);
        assertEq(taken.length, 3, "three gainers");
        assertEq(taken[0].account, btc.accounts[0], "the first gainer");
        assertEq(taken[0].token, leveraged, "in the leveraged token");
        assertEq(taken[0].amount, btc.cutTokens[0], "its cut");
        assertEq(taken[1].account, btc.accounts[1], "the second gainer");
        assertEq(taken[1].token, leveraged, "in the leveraged token");
        assertEq(taken[1].amount, btc.cutTokens[1], "its cut");
        assertEq(taken[2].account, btc.accounts[4], "the third gainer");
        assertEq(taken[2].token, leveraged, "in the leveraged token");
        assertEq(taken[2].amount, btc.cutTokens[4], "its cut");

        assertEq(run.deductionsOf(run.read(EUR_STETH_COMPENSATION)).length, 0, "no cut in EUR::stETH");
    }

    /// @notice The payout is sized as the minter prices each operation at the market's frozen reading, each on the
    ///         state the one before leaves: the pegged fees redeem for their worth at the price over the rate, debiting
    ///         the record; the cuts redeem for their share of the residual the pegged redemption leaves; the fund is
    ///         every market's wrapped fees and the two returns; the fraction is the fund over every debt; each
    ///         account is minted for with that fraction of its debt and receives the leveraged that buys of the
    ///         residual the redemptions leave, a zero debt getting nothing.
    function test_sizePayout_pricesEachOperationAsTheMinterDoes() public {
        CompensationRun run = _aRun();
        CompensateRebalanceDilution.MarketCompensation[] memory markets = _twoSyntheticMarkets();
        CompensateRebalanceDilution.FrozenMarket[] memory frozen = _twoFrozenMarkets();

        CompensateRebalanceDilution.Payout memory p = run.size(markets, frozen);

        // Each market: 100 backing worth 2 pegged each against 100 pegged, 50 leveraged: a residual of 100 pegged,
        // 2 pegged - one collateral - a leveraged token. 2 pegged redeem for 1 collateral, leaving 99 backing against
        // 98 pegged: a residual of 100 pegged over 50 leveraged still. In the first market 0.4 leveraged then redeem
        // for 0.4, leaving 98.6 backing, 98 pegged and 49.6 leveraged.
        assertEq(p.peggedReturns[0], 1 ether, "the first market's pegged fees redeem for 1");
        assertEq(p.leveragedReturns[0], 0.4 ether, "its cuts redeem for 0.4");
        assertEq(p.peggedReturns[1], 1 ether, "the second market's pegged fees redeem for 1");
        assertEq(p.leveragedReturns[1], 0, "it has no cut to redeem");
        // 2 + 1 + 0.4 and 1 + 1: 5.4 over debts of 20.
        assertEq(p.fund, 5.4 ether, "the fund");
        assertEq(p.fraction, 0.27 ether, "the fraction of each debt it pays");
        assertEq(p.mints[0].length, 3, "each account of the first market");
        assertEq(p.mints[0][0], 1.08 ether, "a debt of 4");
        assertEq(p.mints[0][1], 1.62 ether, "a debt of 6");
        assertEq(p.mints[0][2], 0, "no debt, nothing");
        assertEq(p.mintTotals[0], 2.7 ether, "the first market's total");
        assertEq(p.mints[1].length, 1, "the one account of the second");
        assertEq(p.mints[1][0], 2.7 ether, "a debt of 10");
        assertEq(p.mintTotals[1], 2.7 ether, "the second market's total");
        // A collateral buys a leveraged token: 1.08 collateral into a residual of 99.2 pegged over 49.6 leveraged, then
        // 1.62 into 101.36 over 50.68; 2.7 into 100 over 50.
        assertEq(p.leveraged[0][0], 1.08 ether, "1.08 collateral buys 1.08 leveraged");
        assertEq(p.leveraged[0][1], 1.62 ether, "1.62 collateral buys 1.62 leveraged, after the first mint");
        assertEq(p.leveraged[0][2], 0, "nothing paid, nothing received");
        assertEq(p.leveraged[1][0], 2.7 ether, "2.7 collateral buys 2.7 leveraged");
        // The state each market's operations leave: the first 98.6 + 1.08 + 1.62 backing against 98 pegged and
        // 49.6 + 1.08 + 1.62 leveraged; the second 99 + 2.7 against 98 and 50 + 2.7. The reading is untouched.
        assertEq(p.stateBefore[0].backing, 100 ether, "the first market's backing before");
        assertEq(p.stateAfter[0].backing, 101.3 ether, "its backing after");
        assertEq(p.stateAfter[0].peggedSupply, 98 ether, "its pegged supply after");
        assertEq(p.stateAfter[0].leveragedSupply, 52.3 ether, "its leveraged supply after");
        assertEq(p.stateAfter[1].backing, 101.7 ether, "the second market's backing after");
        assertEq(p.stateAfter[1].peggedSupply, 98 ether, "its pegged supply after");
        assertEq(p.stateAfter[1].leveragedSupply, 52.7 ether, "its leveraged supply after");
        assertEq(p.stateAfter[0].answer.minPrice, 2 ether, "the reading is as it was");
        // Every operation is at the price, so the leveraged token's price is where it was - 2 pegged, one collateral,
        // and at a rate of one 1 wrapped - and the collateral ratio rises with the fees put in: from 200 / 100 to
        // 202.6 / 98 and 203.4 / 98.
        (uint256 priceBefore, uint256 wrappedBefore) = run.leveragedPriceAt(p.stateBefore[0]);
        (uint256 priceAfter, uint256 wrappedAfter) = run.leveragedPriceAt(p.stateAfter[0]);
        assertEq(priceBefore, 2 ether, "the leveraged price before, in pegged units");
        assertEq(wrappedBefore, 1 ether, "the leveraged price before, in wrapped collateral");
        assertEq(priceAfter, 2 ether, "the leveraged price after, unchanged");
        assertEq(wrappedAfter, 1 ether, "in wrapped collateral too");
        assertEq(run.collateralRatioAt(p.stateBefore[0]), 2 ether, "the collateral ratio before");
        assertEq(run.collateralRatioAt(p.stateAfter[0]), 2.067346938775510204 ether, "the first market's ratio after");
        assertEq(run.collateralRatioAt(p.stateAfter[1]), 2.075510204081632653 ether, "the second market's ratio after");
    }

    /// @notice A fund larger than every debt pays each debt whole and no more: the fraction is capped at one, and what
    ///         the fund holds beyond the debts is not minted with.
    function test_sizePayout_paysNoMoreThanTheDebt() public {
        CompensationRun run = _aRun();
        CompensateRebalanceDilution.MarketCompensation[] memory markets = _twoSyntheticMarkets();
        // Debts of 0.4, 0.6 and 0 against a fund of 5.4: the fraction would be 5.4.
        markets[0].debts[0] = 0.4 ether;
        markets[0].debts[1] = 0.6 ether;
        markets[0].totalDebt = 1 ether;
        markets[1].debts[0] = 0;
        markets[1].totalDebt = 0;

        CompensateRebalanceDilution.Payout memory p = run.size(markets, _twoFrozenMarkets());

        assertEq(p.fund, 5.4 ether, "the fund");
        assertEq(p.fraction, 1 ether, "the fraction is capped at the whole debt");
        assertEq(p.mints[0][0], 0.4 ether, "a debt of 0.4 is paid whole");
        assertEq(p.mints[0][1], 0.6 ether, "a debt of 0.6 is paid whole");
        assertEq(p.mintTotals[0] + p.mintTotals[1], 1 ether, "the debts are paid, the rest of the fund is not minted");
    }

    /// @notice A market whose oracle reported two prices or two rates at the capture's block is refused, naming the
    ///         market and the reading.
    function test_sizePayout_refusesAReadingWithABand() public {
        CompensationRun run = _aRun();
        CompensateRebalanceDilution.MarketCompensation[] memory markets = _twoSyntheticMarkets();
        CompensateRebalanceDilution.FrozenMarket[] memory frozen = _twoFrozenMarkets();
        frozen[1].answer.maxRate = 1 ether + 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                CompensateRebalanceDilution.OracleAnswerHasABand.selector,
                "B",
                2 ether,
                2 ether,
                1 ether,
                1 ether + 1
            )
        );
        run.size(markets, frozen);
    }

    /// @dev Two markets with round figures: debts of 4, 6 and 0 against wrapped fees of 2, pegged fees of 2 and a cut
    ///      of 0.4 leveraged, and a debt of 10 against wrapped fees of 1 and pegged fees of 2.
    function _twoSyntheticMarkets()
        private
        pure
        returns (CompensateRebalanceDilution.MarketCompensation[] memory markets)
    {
        markets = new CompensateRebalanceDilution.MarketCompensation[](2);
        markets[0].name = "A";
        markets[0].accounts = new address[](3);
        markets[0].accounts[0] = address(0xA1);
        markets[0].accounts[1] = address(0xA2);
        markets[0].accounts[2] = address(0xA3);
        markets[0].debts = new uint256[](3);
        markets[0].debts[0] = 4 ether;
        markets[0].debts[1] = 6 ether;
        markets[0].cutTokens = new uint256[](3);
        markets[0].cutTokens[0] = 0.4 ether;
        markets[0].totalDebt = 10 ether;
        markets[0].totalCutTokens = 0.4 ether;
        markets[0].feesWrapped = 2 ether;
        markets[0].feesPegged = 2 ether;
        markets[1].name = "B";
        markets[1].accounts = new address[](1);
        markets[1].accounts[0] = address(0xB1);
        markets[1].debts = new uint256[](1);
        markets[1].debts[0] = 10 ether;
        markets[1].cutTokens = new uint256[](1);
        markets[1].totalDebt = 10 ether;
        markets[1].feesWrapped = 1 ether;
        markets[1].feesPegged = 2 ether;
    }

    /// @dev The two markets' minters at the reading: one price of 2 pegged a collateral at a rate of one, 100 backing
    ///      against 100 pegged and 50 leveraged.
    function _twoFrozenMarkets() private pure returns (CompensateRebalanceDilution.FrozenMarket[] memory frozen) {
        frozen = new CompensateRebalanceDilution.FrozenMarket[](2);
        for (uint256 m = 0; m < 2; ++m) {
            frozen[m].answer = UpgradeMarketToV3.OracleAnswer(2 ether, 2 ether, 1 ether, 1 ether);
            frozen[m].backing = 100 ether;
            frozen[m].peggedSupply = 100 ether;
            frozen[m].leveragedSupply = 50 ether;
            frozen[m].wrapped = address(0xEE);
            frozen[m].readBlock = 1000;
            frozen[m].readTime = 1_700_000_000;
        }
    }

    /// @notice Two markets holding different wrapped collateral tokens cannot share a fund: the sizing refuses them,
    ///         naming both.
    function test_sizePayout_refusesMarketsOfDifferentWrappedCollateral() public {
        CompensationRun run = _aRun();
        CompensateRebalanceDilution.MarketCompensation[] memory markets = _twoSyntheticMarkets();
        CompensateRebalanceDilution.FrozenMarket[] memory frozen = _twoFrozenMarkets();
        frozen[1].wrapped = address(0xFF);

        vm.expectRevert(
            abi.encodeWithSelector(CompensateRebalanceDilution.MarketsOfDifferentWrappedCollateral.selector, "A", "B")
        );
        run.size(markets, frozen);
    }

    /// @notice The compensated upgrade, as it will run: each market's batch, executed as the multisig at the block after
    ///         the pause, migrates the leveraged pool taking each gainer's cut - its claimable reward falls by exactly
    ///         that, the others' are untouched, the pool pays the multisig - then, the minter reading the capture
    ///         block's answer held still, the multisig redeems its pegged fee and the tokens taken back, fee-free, for
    ///         exactly the wrapped collateral sized, and mints fee-free for each loser with its share of the fund:
    ///         every loser's leveraged balance rises by exactly the leveraged sized; the multisig's pegged fee is
    ///         gone, its leveraged tokens are as they were, its wrapped collateral is its own but for the mints'
    ///         floor dust; each market's collateral ratio rises and its minter reads the oracle proxy the deploy
    ///         predicts. The batches point each minter at the frozen reading before the pools' migration and at the
    ///         proxy after the compensation, queued after the market's upgrade, in order.
    function test_theCompensatedUpgrade_takesBackTheCutsAndPaysTheLosers() public {
        uint256 readBlock = HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE);
        // The block after the capture's, where every minter and pool is paused and the upgrade runs. The run and the
        // configs the files name are made here and persist, so the frozen fork below can ask them for addresses.
        uint256 paused = vm.createSelectFork(vm.rpcUrl("mainnet"), readBlock + 1);
        CompensationRun run = _aRun();
        vm.makePersistent(address(run));
        CompensateRebalanceDilution.MarketCompensation[]
            memory markets = new CompensateRebalanceDilution.MarketCompensation[](2);
        markets[0] = run.read(BTC_STETH_COMPENSATION);
        markets[1] = run.read(EUR_STETH_COMPENSATION);
        vm.makePersistent(address(markets[0].market));
        vm.makePersistent(address(markets[1].market));
        address multisig = run.owner();
        address wrapped = IHarborConfig(address(markets[0].market)).wrappedCollateralToken();

        // What the paused contracts no longer answer is read at the capture's block, where they still run.
        vm.createSelectFork(vm.rpcUrl("mainnet"), readBlock);
        Before[] memory before = new Before[](2);
        for (uint256 m = 0; m < 2; ++m) {
            before[m] = _readFrozen(run, markets[m]);
        }
        vm.selectFork(paused);
        for (uint256 m = 0; m < 2; ++m) {
            _readBalances(before[m], markets[m], multisig);
        }
        uint256 multisigWrapped = IERC20(wrapped).balanceOf(multisig);

        vm.recordLogs();
        run.run(SALT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        CompensateRebalanceDilution.Payout memory p = run.payout();
        _run = run;

        _checkBatches(run, markets, before, p);
        uint256 wrappedOut;
        uint256 wrappedIn;
        uint256 fees;
        for (uint256 m = 0; m < 2; ++m) {
            Done memory done = _whatTheMinterDid(logs, before[m].minter, markets[m].accounts);
            _checkMarketAfter(markets[m], before[m], done, _sizedFor(p, m), multisig);
            wrappedOut += done.collateralOut;
            wrappedIn += done.collateralIn;
            fees += markets[m].feesWrapped;
        }
        assertEq(
            IERC20(wrapped).balanceOf(multisig),
            multisigWrapped + wrappedOut - wrappedIn,
            "the multisig's wrapped collateral: the redemptions in, the mints out"
        );
        // The fund is spent to the wei the mints' floors leave: the multisig's own wrapped collateral is untouched.
        uint256 dust = p.fund - (p.mintTotals[0] + p.mintTotals[1]);
        assertLe(dust, markets[0].accounts.length + markets[1].accounts.length, "the floors leave at most a wei each");
        assertEq(
            IERC20(wrapped).balanceOf(multisig),
            multisigWrapped - fees + dust,
            "the multisig keeps what it held beyond the fees, and the dust"
        );
        _checkReport(run, markets, p, before);
    }

    /// @dev The run under test, for the checks after it.
    CompensationRun private _run;

    /// @dev The payout report, written as the upgrade script writes it: every amount named in its token, the symbols
    ///      the tokens give, each market's reading held still with the leveraged price before and after, and each
    ///      account's row. Written under `tmp/`, where it also serves as a preview of the upgrade's own report.
    function _checkReport(
        CompensationRun run,
        CompensateRebalanceDilution.MarketCompensation[] memory markets,
        CompensateRebalanceDilution.Payout memory p,
        Before[] memory before
    ) private {
        string memory path = "tmp/phase1-preview.md";
        run.writeReport(path, markets, p);
        string memory report = vm.readFile(path);
        // The header names the block the figures are priced at, with its time and why it was chosen, not the block
        // the report was written at.
        assertTrue(
            vm.contains(
                report,
                string.concat(
                    "priced at the oracle reading of block ",
                    vm.toString(p.stateBefore[0].readBlock),
                    " (",
                    JsonSerializer.formatTimestamp(p.stateBefore[0].readTime),
                    "), the last block before the pause"
                )
            ),
            "the header names the capture's block, its time and why"
        );
        assertEq(
            p.stateBefore[0].readBlock,
            HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE),
            "which is the capture's block"
        );
        assertFalse(vm.contains(report, ", at block "), "the report is not stamped with the block it was written at");
        for (uint256 m = 0; m < markets.length; ++m) {
            string memory leveraged = IERC20Metadata(before[m].leveraged).symbol();
            string memory pegged = IERC20Metadata(before[m].pegged).symbol();
            assertTrue(
                vm.contains(report, string.concat("| Receives (", leveraged, ") | Worth at the reading (wstETH) |")),
                string.concat(markets[m].name, ": the table names the leveraged token received and its worth")
            );
            assertTrue(
                vm.contains(report, string.concat("- ", pegged, " fees: ", _scaled(markets[m].feesPegged))),
                string.concat(markets[m].name, ": the pegged fees are named in the pegged token")
            );
            (uint256 priceBefore, uint256 wrappedBefore) = run.leveragedPriceAt(p.stateBefore[m]);
            assertTrue(
                vm.contains(
                    report,
                    string.concat(
                        "1 ",
                        leveraged,
                        " = ",
                        _scaled(priceBefore),
                        " ",
                        pegged,
                        " (",
                        _scaled(wrappedBefore),
                        " wstETH) before the batch"
                    )
                ),
                string.concat(markets[m].name, ": the leveraged price before, in both units")
            );
        }
        assertFalse(vm.contains(report, "wrapped)"), "no amount is named 'wrapped'");
        assertFalse(vm.contains(report, "(leveraged)"), "no amount is named 'leveraged'");
    }

    /// @dev An 18-decimal amount as the report prints it.
    function _scaled(uint256 amount) private pure returns (string memory) {
        string memory fraction = vm.toString(amount % 1 ether);
        bytes memory zeros = new bytes(18 - bytes(fraction).length);
        for (uint256 i = 0; i < zeros.length; ++i) {
            zeros[i] = "0";
        }
        return string.concat(vm.toString(amount / 1 ether), ".", string(zeros), fraction);
    }

    /// @dev One market's contracts and what only its running contracts answer, on the frozen fork: each account's
    ///      claimable leveraged reward, the stream's rate, the collateral ratio, the oracle's answer and the leveraged
    ///      token's price.
    function _readFrozen(
        CompensationRun run,
        CompensateRebalanceDilution.MarketCompensation memory market
    ) private returns (Before memory b) {
        b.minter = run.minterAddress(market.market);
        b.pool = run.stabilityPoolAddress(market.market, HarborDeployer.StabilityPoolType.Leveraged);
        b.leveraged = run.leveragedTokenAddress(market.market);
        b.pegged = run.peggedTokenAddress(market.market);
        b.predictedOracle = run.wrappedPriceOracleAddress(market.market);
        b.claimables = new uint256[](market.accounts.length);
        for (uint256 i = 0; i < market.accounts.length; ++i) {
            b.claimables[i] = IMultipleRewardAccumulator(b.pool).claimable(market.accounts[i], b.leveraged);
        }
        (, , b.rate, ) = IMultipleRewardDistributor(b.pool).rewardData(b.leveraged);
        b.collateralRatio = IMinter(b.minter).collateralRatio();
        (b.answer.minPrice, b.answer.maxPrice, b.answer.minRate, b.answer.maxRate) = IWrappedPriceOracle(
            IMinter(b.minter).priceOracle()
        ).latestAnswer();
        b.leveragedPrice = IMinter(b.minter).leveragedTokenPrice();
    }

    /// @dev The token balances the batch moves, read where it runs, just before it.
    function _readBalances(
        Before memory b,
        CompensateRebalanceDilution.MarketCompensation memory market,
        address multisig
    ) private view {
        b.balances = new uint256[](market.accounts.length);
        for (uint256 i = 0; i < market.accounts.length; ++i) {
            b.balances[i] = IERC20(b.leveraged).balanceOf(market.accounts[i]);
        }
        b.poolLeveraged = IERC20(b.leveraged).balanceOf(b.pool);
        b.multisigPegged = IERC20(b.pegged).balanceOf(multisig);
        b.multisigLeveraged = IERC20(b.leveraged).balanceOf(multisig);
    }

    /// @dev Market `m`'s share of the payout `p`.
    function _sizedFor(
        CompensateRebalanceDilution.Payout memory p,
        uint256 m
    ) private pure returns (Sized memory sized) {
        sized.peggedReturn = p.peggedReturns[m];
        sized.leveragedReturn = p.leveragedReturns[m];
        sized.mints = p.mints[m];
        sized.leveraged = p.leveraged[m];
        sized.stateBefore = p.stateBefore[m];
        sized.stateAfter = p.stateAfter[m];
    }

    /// @dev One market after its batch: the gainers' claimables less their cuts and the others' as they were - to the
    ///      leveraged reward stream's 12 seconds between the capture's block and the upgrade's, and a wei at each of
    ///      the fold's two divisions - a cut telling against no cut; the pool paid the cuts; every account was paid
    ///      exactly the wrapped collateral sized and its leveraged balance rose by exactly the leveraged sized; the
    ///      redemptions burned the fee and the cuts and returned exactly what was sized; the multisig's pegged fee
    ///      gone and its leveraged as it was; the collateral ratio up; the minter reading the oracle proxy the deploy
    ///      predicts.
    function _checkMarketAfter(
        CompensateRebalanceDilution.MarketCompensation memory market,
        Before memory b,
        Done memory done,
        Sized memory sized,
        address multisig
    ) private {
        uint256 streamed = b.rate * BLOCK_TIME + 2;
        for (uint256 i = 0; i < market.accounts.length; ++i) {
            uint256 claimable = IMultipleRewardAccumulator_v3(b.pool).claimable(market.accounts[i], _one(b.leveraged))[
                0
            ];
            string memory who = string.concat(market.name, " ", vm.toString(market.accounts[i]));
            if (market.cutTokens[i] > 0) {
                assertDiscriminates(
                    claimable,
                    b.claimables[i] - market.cutTokens[i],
                    streamed,
                    b.claimables[i],
                    string.concat(who, ": the claimable reward less its cut, not uncut")
                );
            } else {
                assertApprox(
                    claimable,
                    b.claimables[i],
                    streamed,
                    string.concat(who, ": the claimable reward as it was")
                );
            }
            assertEq(done.paid[i], sized.mints[i], string.concat(who, ": the mint paid what was sized"));
            assertEq(done.minted[i], sized.leveraged[i], string.concat(who, ": the mint returned the leveraged sized"));
            assertEq(
                IERC20(b.leveraged).balanceOf(market.accounts[i]),
                b.balances[i] + done.minted[i],
                string.concat(who, ": the leveraged balance plus the mint")
            );
        }
        assertEq(
            IERC20(b.leveraged).balanceOf(b.pool),
            b.poolLeveraged - market.totalCutTokens,
            string.concat(market.name, ": the pool paid the cuts")
        );
        assertEq(done.peggedBurned, market.feesPegged, string.concat(market.name, ": the pegged fee redeemed"));
        assertEq(done.leveragedBurned, market.totalCutTokens, string.concat(market.name, ": the cuts redeemed"));
        assertEq(
            done.collateralOut,
            sized.peggedReturn + sized.leveragedReturn,
            string.concat(market.name, ": the redemptions returned what was sized")
        );
        _checkCutValue(market, b, sized.leveragedReturn);
        assertEq(
            IERC20(b.pegged).balanceOf(multisig),
            b.multisigPegged - market.feesPegged,
            string.concat(market.name, ": the multisig's pegged fee is gone")
        );
        assertEq(
            IERC20(b.leveraged).balanceOf(multisig),
            b.multisigLeveraged,
            string.concat(market.name, ": the multisig's leveraged: the cuts in, the cuts out")
        );
        assertGt(
            IMinter_v3(b.minter).collateralRatio(),
            b.collateralRatio,
            string.concat(market.name, ": the collateral ratio rises")
        );
        assertEq(
            IMinter_v3(b.minter).priceOracle(),
            b.predictedOracle,
            string.concat(market.name, ": the minter reads the oracle proxy the deploy predicts after")
        );
        _checkStateAsSized(market, b, sized);
    }

    /// @dev The minter's state the sizing started from is what the running minter answered at the capture's block,
    ///      with the leveraged price and collateral ratio it reported there; the state the sizing says the operations
    ///      leave is the minter's state after the batch, exactly: the backing it records, its pegged and leveraged
    ///      supply.
    function _checkStateAsSized(
        CompensateRebalanceDilution.MarketCompensation memory market,
        Before memory b,
        Sized memory sized
    ) private {
        (uint256 priceBefore, ) = _run.leveragedPriceAt(sized.stateBefore);
        assertEq(priceBefore, b.leveragedPrice, string.concat(market.name, ": the leveraged price sized from"));
        assertEq(
            _run.collateralRatioAt(sized.stateBefore),
            b.collateralRatio,
            string.concat(market.name, ": the collateral ratio sized from")
        );
        assertEq(
            IMinter_v3(b.minter).collateralTokenBalance(),
            sized.stateAfter.backing,
            string.concat(market.name, ": the backing recorded after is as sized")
        );
        assertEq(
            IMinter_v3(b.minter).peggedTokenBalance(),
            sized.stateAfter.peggedSupply,
            string.concat(market.name, ": the pegged supply after is as sized")
        );
        assertEq(
            IMinter_v3(b.minter).leveragedTokenBalance(),
            sized.stateAfter.leveragedSupply,
            string.concat(market.name, ": the leveraged supply after is as sized")
        );
    }

    /// @dev The cuts taken back, in tokens of the file's making, redeem for the file's value of them, to the roundings
    ///      between the two: the file values each unclaimed reward at the running minter's leveraged price in pegged
    ///      units, floored to the pegged wei a token, over the wrapped collateral's price in pegged units, floored to
    ///      the wei, and floors the value; each cut's tokens are the cut's value times the reward over that value,
    ///      floored to the token wei. The minter redeems the tokens' share of the residual, floored twice. So the two
    ///      differ by at most: the cuts' value over the leveraged price and over the wrapped price, a wei a cut for
    ///      the value's floor, a token wei's worth a cut, and the minter's two floors.
    function _checkCutValue(
        CompensateRebalanceDilution.MarketCompensation memory market,
        Before memory b,
        uint256 returned
    ) private {
        if (market.totalCutTokens == 0) {
            assertEq(returned, 0, string.concat(market.name, ": no cut, nothing redeemed"));
            return;
        }
        uint256 cuts;
        for (uint256 i = 0; i < market.cutTokens.length; ++i) {
            if (market.cutTokens[i] > 0) {
                ++cuts;
            }
        }
        uint256 wrappedInPegged = Math.mulDiv(b.answer.minPrice, b.answer.minRate, 1 ether);
        uint256 bound = Math.ceilDiv(market.totalCutValue, b.leveragedPrice) +
            Math.ceilDiv(market.totalCutValue, wrappedInPegged) +
            cuts +
            cuts * Math.ceilDiv(b.leveragedPrice, wrappedInPegged) +
            2;
        assertApproxEqAbs(
            returned,
            market.totalCutValue,
            bound,
            string.concat(market.name, ": the cuts redeem for the file's value of them")
        );
    }

    /// @dev What `minter`'s events say its market's batch did, the mints by account.
    function _whatTheMinterDid(
        Vm.Log[] memory logs,
        address minter,
        address[] memory accounts
    ) private pure returns (Done memory done) {
        done.paid = new uint256[](accounts.length);
        done.minted = new uint256[](accounts.length);
        for (uint256 l = 0; l < logs.length; ++l) {
            if (logs[l].emitter != minter) {
                continue;
            }
            bytes32 topic = logs[l].topics[0];
            if (topic == IMinter_v3.MintLeveragedToken.selector) {
                (uint256 collateralIn, uint256 leveragedOut) = abi.decode(logs[l].data, (uint256, uint256));
                uint256 account = _indexOf(accounts, address(uint160(uint256(logs[l].topics[2]))));
                done.collateralIn += collateralIn;
                done.paid[account] += collateralIn;
                done.minted[account] += leveragedOut;
            } else if (topic == IMinter_v3.RedeemPeggedToken.selector) {
                (uint256 burned, uint256 collateralOut, ) = abi.decode(logs[l].data, (uint256, uint256, uint256));
                done.peggedBurned += burned;
                done.collateralOut += collateralOut;
            } else if (topic == IMinter_v3.RedeemLeveragedToken.selector) {
                (uint256 burned, uint256 collateralOut) = abi.decode(logs[l].data, (uint256, uint256));
                done.leveragedBurned += burned;
                done.collateralOut += collateralOut;
            }
        }
    }

    /// @dev Each market's batch as queued: before its pools' migration, the minter pointed at an oracle of the batch's
    ///      own answering what its oracle answered at the capture's block; the leveraged pool's migration carrying the
    ///      market's deductions; after its manager's upgrade, the manager's rebalance then harvest terms set to the
    ///      market config's; then the compensation in order - the pegged approval and
    ///      fee-free redemption, where there is a cut the leveraged approval and fee-free redemption, the wrapped
    ///      collateral approval for the mints' total, then a fee-free mint per account with a debt, each what was
    ///      sized; then the minter pointed at the oracle proxy the deploy predicts.
    function _checkBatches(
        CompensationRun run,
        CompensateRebalanceDilution.MarketCompensation[] memory markets,
        Before[] memory before,
        CompensateRebalanceDilution.Payout memory p
    ) private {
        Deployer.Transaction[] memory queued = run.batches();
        uint256 at;
        for (uint256 m = 0; m < markets.length; ++m) {
            at = _checkMarketBatch(run, queued, at, markets[m], before[m], p.mints[m]);
        }
        assertEq(at, queued.length, "nothing else is queued");
    }

    /// @dev One market's batch from `at`: the upgrade's own calls, with the minter's move to the frozen reading and the
    ///      leveraged pool's deductions among them, the manager's terms after its upgrade, then the compensation and
    ///      the minter's move to the proxy; return the index after it.
    function _checkMarketBatch(
        CompensationRun run,
        Deployer.Transaction[] memory queued,
        uint256 at,
        CompensateRebalanceDilution.MarketCompensation memory market,
        Before memory b,
        uint256[] memory mints
    ) private returns (uint256) {
        address manager = run.stabilityPoolManagerAddress(market.market);
        bool movedToTheReading;
        while (
            !(queued[at].target == manager && bytes4(queued[at].data) == UUPSUpgradeable.upgradeToAndCall.selector)
        ) {
            if (queued[at].target == b.pool) {
                _checkDeductionsIn(queued[at].data, run.deductionsOf(market), market.name);
            }
            if (queued[at].target == b.minter && bytes4(queued[at].data) == IMinter.updatePriceOracle.selector) {
                address frozen = abi.decode(_arguments(queued[at].data), (address));
                assertNotEq(
                    frozen,
                    b.predictedOracle,
                    string.concat(market.name, ": the minter is moved first to an oracle of the batch's own")
                );
                assertEq(
                    _answerOf(frozen),
                    abi.encode(b.answer),
                    string.concat(market.name, ": which answers what its oracle answered at the capture's block")
                );
                movedToTheReading = true;
            }
            ++at;
        }
        assertTrue(movedToTheReading, string.concat(market.name, ": the minter is moved before the pools' migration"));
        ++at;
        {
            IHarborConfig config = IHarborConfig(address(market.market));
            at = _expect(queued, at, manager, IStabilityPoolManager_v2.updateRebalanceConfig.selector, market.name);
            assertEq(
                _arguments(queued[at - 1].data),
                abi.encode(config.rebalanceBountyRatio(), config.rebalanceBountyCeiling(), config.rebalanceCutRatio()),
                string.concat(market.name, ": the manager's rebalance terms are the market config's")
            );
            at = _expect(queued, at, manager, IStabilityPoolManager_v2.updateHarvestConfig.selector, market.name);
            assertEq(
                _arguments(queued[at - 1].data),
                abi.encode(config.harvestBountyRatio(), config.harvestBountyCeiling(), config.harvestCutRatio()),
                string.concat(market.name, ": the manager's harvest terms are the market config's")
            );
        }
        at = _checkRedemptions(run, queued, at, market);
        at = _checkMints(run, queued, at, market, mints);
        at = _expect(queued, at, b.minter, IMinter.updatePriceOracle.selector, market.name);
        assertEq(
            abi.decode(_arguments(queued[at - 1].data), (address)),
            b.predictedOracle,
            string.concat(market.name, ": the minter is moved last to the oracle proxy the deploy predicts")
        );
        return at;
    }

    /// @dev The multisig's redemptions from `at`: the pegged fee approved and redeemed fee-free for wrapped collateral
    ///      alone, to the multisig; where there is a cut, the cuts approved and redeemed fee-free to the multisig.
    function _checkRedemptions(
        CompensationRun run,
        Deployer.Transaction[] memory queued,
        uint256 at,
        CompensateRebalanceDilution.MarketCompensation memory market
    ) private returns (uint256) {
        address minter = run.minterAddress(market.market);
        at = _expectApproval(
            queued,
            at,
            run.peggedTokenAddress(market.market),
            minter,
            market.feesPegged,
            string.concat(market.name, ": the pegged fee")
        );
        at = _expect(queued, at, minter, IMinter_v3.freeRedeemPeggedToken.selector, market.name);
        (uint256 peggedRedeemed, uint256 peggedForLeveraged, address receiver) = abi.decode(
            _arguments(queued[at - 1].data),
            (uint256, uint256, address)
        );
        assertEq(peggedRedeemed, market.feesPegged, string.concat(market.name, ": the pegged fee is redeemed"));
        assertEq(peggedForLeveraged, 0, string.concat(market.name, ": for wrapped collateral alone"));
        assertEq(receiver, run.owner(), string.concat(market.name, ": to the multisig"));
        if (market.totalCutTokens > 0) {
            at = _expectApproval(
                queued,
                at,
                run.leveragedTokenAddress(market.market),
                minter,
                market.totalCutTokens,
                string.concat(market.name, ": the cuts")
            );
            at = _expect(queued, at, minter, IMinter_v3.freeRedeemLeveragedToken.selector, market.name);
            (uint256 cutsRedeemed, address cutsTo) = abi.decode(_arguments(queued[at - 1].data), (uint256, address));
            assertEq(cutsRedeemed, market.totalCutTokens, string.concat(market.name, ": the cuts are redeemed"));
            assertEq(cutsTo, run.owner(), string.concat(market.name, ": to the multisig"));
        }
        return at;
    }

    /// @dev The multisig's mints from `at`: the wrapped collateral approved for the mints' total, then a fee-free mint
    ///      per account with a debt, in the file's order, each with exactly the wrapped collateral sized for it.
    function _checkMints(
        CompensationRun run,
        Deployer.Transaction[] memory queued,
        uint256 at,
        CompensateRebalanceDilution.MarketCompensation memory market,
        uint256[] memory mints
    ) private returns (uint256) {
        address minter = run.minterAddress(market.market);
        address wrapped = IHarborConfig(address(market.market)).wrappedCollateralToken();
        uint256 approvalAt = at;
        at = _expect(queued, at, wrapped, IERC20.approve.selector, market.name);
        uint256 total;
        for (uint256 i = 0; i < market.accounts.length; ++i) {
            if (market.debts[i] > 0) {
                at = _expect(queued, at, minter, IMinter_v3.freeMintLeveragedToken.selector, market.name);
                (uint256 mint, address account) = abi.decode(_arguments(queued[at - 1].data), (uint256, address));
                assertEq(account, market.accounts[i], string.concat(market.name, ": the mint's receiver, in order"));
                assertEq(mint, mints[i], string.concat(market.name, ": the mint queued what was sized"));
                total += mint;
            } else {
                assertEq(mints[i], 0, string.concat(market.name, ": nothing sized for a zero debt"));
            }
        }
        assertGt(total, 0, string.concat(market.name, ": something is minted"));
        _expectApproval(
            queued,
            approvalAt,
            wrapped,
            minter,
            total,
            string.concat(market.name, ": the wrapped collateral to mint with")
        );
        return at;
    }

    /// @dev Require `queued[at]` to approve `spender` for `amount` of `token`; return the next index.
    function _expectApproval(
        Deployer.Transaction[] memory queued,
        uint256 at,
        address token,
        address spender,
        uint256 amount,
        string memory what
    ) private returns (uint256) {
        at = _expect(queued, at, token, IERC20.approve.selector, what);
        (address approved, uint256 allowance) = abi.decode(_arguments(queued[at - 1].data), (address, uint256));
        assertEq(approved, spender, string.concat(what, ": approved for the minter"));
        assertEq(allowance, amount, string.concat(what, ": the amount approved"));
        return at;
    }

    /// @dev Require `queued[at]` to call `selector` on `target`; return the next index.
    function _expect(
        Deployer.Transaction[] memory queued,
        uint256 at,
        address target,
        bytes4 selector,
        string memory market
    ) private pure returns (uint256) {
        require(at < queued.length, string.concat(market, ": a call is missing from the batch"));
        require(queued[at].target == target, string.concat(market, ": ", queued[at].description, " - not the target"));
        require(
            bytes4(queued[at].data) == selector,
            string.concat(market, ": ", queued[at].description, " - not the call")
        );
        return at + 1;
    }

    /// @dev Require the pool's `upgradeToAndCall` in `data` to migrate with exactly `expected` deductions.
    function _checkDeductionsIn(
        bytes memory data,
        IStabilityPool_v3_Upgrader.Deduction[] memory expected,
        string memory market
    ) private pure {
        (, bytes memory migrate) = abi.decode(_arguments(data), (address, bytes));
        (, , IStabilityPool_v3_Upgrader.Deduction[] memory taken, ) = abi.decode(
            _arguments(migrate),
            (int256, address[], IStabilityPool_v3_Upgrader.Deduction[], address)
        );
        assertEq(taken.length, expected.length, string.concat(market, ": the migration's deductions"));
        for (uint256 d = 0; d < taken.length; ++d) {
            assertEq(taken[d].account, expected[d].account, string.concat(market, ": a deduction's account"));
            assertEq(taken[d].token, expected[d].token, string.concat(market, ": a deduction's token"));
            assertEq(taken[d].amount, expected[d].amount, string.concat(market, ": a deduction's amount"));
        }
    }

    /// @dev The oracle at `oracle`'s answer - its price and rate bands - encoded for comparison.
    function _answerOf(address oracle) private view returns (bytes memory) {
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(oracle)
            .latestAnswer();
        return abi.encode(minPrice, maxPrice, minRate, maxRate);
    }

    /// @dev The calldata without its selector.
    function _arguments(bytes memory data) private pure returns (bytes memory arguments) {
        arguments = new bytes(data.length - 4);
        for (uint256 i = 0; i < arguments.length; ++i) {
            arguments[i] = data[i + 4];
        }
    }

    function _one(address token) private pure returns (address[] memory tokens) {
        tokens = new address[](1);
        tokens[0] = token;
    }

    function _indexOf(address[] memory accounts, address account) private pure returns (uint256) {
        for (uint256 i = 0; i < accounts.length; ++i) {
            if (accounts[i] == account) {
                return i;
            }
        }
        revert("a mint for an account of no market");
    }
}
