// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Deployer} from "@bao-script/deployment/Deployer.sol";
import {BaoTest} from "@bao-test/BaoTest.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
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
import {IStabilityPool_v3_Upgrader} from "@harbor-script/UpgradeStabilityPool_v2_v3/IStabilityPool_v3_Upgrader.sol";
import {
    BTC_STETH_COMPENSATION,
    EUR_STETH_COMPENSATION,
    FROZEN_MARKETS_CAPTURE
} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";

import {CompensationRun} from "@harbor-script/verify/incidents/CompensationRun.sol";

/// @notice Phase 1 of the repayment for the rebalance dilution exploits: the compensation's inputs read as the
///         incident's files record them, the deductions and the payout sized from them, and the compensated upgrade of
///         the two exploited markets run as it will run - at the block after the pause, each market's batch executed
///         as the multisig - taking back the gains and paying the losers in the same transaction as the upgrade.
/// @dev Needs MAINNET_RPC_URL, archival at the capture's block, and `--disable-block-gas-limit`: the two markets'
///      upgrade runs in one test call, beyond a block's gas (`run-compensation-test`). Under `script/verify/`, with
///      the incident's report that writes the files it reads.
contract CompensateRebalanceDilutionTest is BaoTest {
    string private constant SALT = "harbor_v1";

    /// @dev The capture's block, where the frozen markets are read; the next block, where every minter and pool is
    ///      paused and the upgrade runs, is 12 seconds later.
    uint256 private constant BLOCK_TIME = 12;

    /// @dev What one market reads before its upgrade: its contracts, each account's claimable leveraged reward in the
    ///      leveraged pool and its leveraged balance, the pool's leveraged tokens, the multisig's holdings, the
    ///      leveraged reward stream's rate and the collateral ratio.
    struct Before {
        address minter;
        address pool;
        address leveraged;
        address pegged;
        uint256[] claimables;
        uint256[] balances;
        uint256 poolLeveraged;
        uint256 multisigPegged;
        uint256 multisigLeveraged;
        uint256 rate;
        uint256 collateralRatio;
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

    /// @notice The fund is every market's wrapped fees, what its pegged fees are worth and what its cuts are worth; the
    ///         fraction is the fund over every debt; each account is minted for with that fraction of its debt, a zero
    ///         debt getting nothing.
    function test_sizePayout_sharesTheFundByDebt() public {
        CompensationRun run = _aRun();
        CompensateRebalanceDilution.MarketCompensation[] memory markets = _twoSyntheticMarkets();
        uint256[] memory peggedValues = new uint256[](2);
        peggedValues[0] = 1.9 ether;
        peggedValues[1] = 2 ether;

        CompensateRebalanceDilution.Payout memory p = run.size(markets, peggedValues);

        // 2 + 1.9 + 0.4 and 1 + 2 + 0: 7.3 over debts of 20.
        assertEq(p.fund, 7.3 ether, "the fund");
        assertEq(p.fraction, 0.365 ether, "the fraction of each debt it pays");
        assertEq(p.mints[0].length, 3, "each account of the first market");
        assertEq(p.mints[0][0], 1.46 ether, "a debt of 4");
        assertEq(p.mints[0][1], 2.19 ether, "a debt of 6");
        assertEq(p.mints[0][2], 0, "no debt, nothing");
        assertEq(p.mintTotals[0], 3.65 ether, "the first market's total");
        assertEq(p.mints[1].length, 1, "the one account of the second");
        assertEq(p.mints[1][0], 3.65 ether, "a debt of 10");
        assertEq(p.mintTotals[1], 3.65 ether, "the second market's total");
    }

    /// @dev Two markets with round figures: debts of 4, 6 and 0 against wrapped fees of 2 and a cut worth 0.4, and a
    ///      debt of 10 against wrapped fees of 1.
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
        markets[0].totalDebt = 10 ether;
        markets[0].totalCutValue = 0.4 ether;
        markets[0].feesWrapped = 2 ether;
        markets[1].name = "B";
        markets[1].accounts = new address[](1);
        markets[1].accounts[0] = address(0xB1);
        markets[1].debts = new uint256[](1);
        markets[1].debts[0] = 10 ether;
        markets[1].cutTokens = new uint256[](1);
        markets[1].totalDebt = 10 ether;
        markets[1].feesWrapped = 1 ether;
    }

    /// @notice The compensated upgrade, as it will run: each market's batch, executed as the multisig at the block after
    ///         the pause, migrates the leveraged pool taking each gainer's cut - its claimable reward falls by exactly
    ///         that, the others' are untouched, the pool pays the multisig - then the multisig redeems its pegged fee
    ///         and the tokens taken back, fee-free, and mints fee-free for each loser with its share of the fund: every
    ///         loser's leveraged balance rises by what its mint returned, worth what was paid to the oracle's band; the
    ///         multisig's pegged fee is gone, its leveraged tokens are as they were, and its wrapped collateral is what
    ///         it was plus the redemptions less the mints; each market's collateral ratio rises. The batches queue the
    ///         compensation after the market's upgrade, in order.
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

        // The batches first: they record what each mint was queued with, which the value check below reads.
        _checkBatches(run, markets);
        uint256 wrappedOut;
        uint256 wrappedIn;
        for (uint256 m = 0; m < 2; ++m) {
            Done memory done = _whatTheMinterDid(logs, before[m].minter, markets[m].accounts);
            _checkMarketAfter(markets[m], before[m], done, multisig);
            wrappedOut += done.collateralOut;
            wrappedIn += done.collateralIn;
        }
        assertEq(
            IERC20(wrapped).balanceOf(multisig),
            multisigWrapped + wrappedOut - wrappedIn,
            "the multisig's wrapped collateral: the redemptions in, the mints out"
        );
    }

    /// @dev One market's contracts and what only its running contracts answer, on the frozen fork: each account's
    ///      claimable leveraged reward, the stream's rate and the collateral ratio.
    function _readFrozen(
        CompensationRun run,
        CompensateRebalanceDilution.MarketCompensation memory market
    ) private returns (Before memory b) {
        b.minter = run.minterAddress(market.market);
        b.pool = run.stabilityPoolAddress(market.market, HarborDeployer.StabilityPoolType.Leveraged);
        b.leveraged = run.leveragedTokenAddress(market.market);
        b.pegged = run.peggedTokenAddress(market.market);
        b.claimables = new uint256[](market.accounts.length);
        for (uint256 i = 0; i < market.accounts.length; ++i) {
            b.claimables[i] = IMultipleRewardAccumulator(b.pool).claimable(market.accounts[i], b.leveraged);
        }
        (, , b.rate, ) = IMultipleRewardDistributor(b.pool).rewardData(b.leveraged);
        b.collateralRatio = IMinter(b.minter).collateralRatio();
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

    /// @dev One market after its batch: the gainers' claimables less their cuts and the others' as they were - to the
    ///      leveraged reward stream's 12 seconds between the capture's block and the upgrade's, and a wei at each of
    ///      the fold's two divisions - a cut telling against no cut; the pool paid the cuts; every account's leveraged
    ///      balance rose by its mint's return, worth what was paid to the oracle's band; the multisig's pegged fee gone
    ///      and its leveraged as it was; the collateral ratio up.
    function _checkMarketAfter(
        CompensateRebalanceDilution.MarketCompensation memory market,
        Before memory b,
        Done memory done,
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
            assertEq(done.paid[i], _mintQueuedFor(market, i), string.concat(who, ": the mint paid what was queued"));
            assertEq(
                IERC20(b.leveraged).balanceOf(market.accounts[i]),
                b.balances[i] + done.minted[i],
                string.concat(who, ": the leveraged balance plus the mint")
            );
            _checkMintValue(b.minter, done.minted[i], done.paid[i], 4 + market.accounts.length, who);
        }
        assertEq(
            IERC20(b.leveraged).balanceOf(b.pool),
            b.poolLeveraged - market.totalCutTokens,
            string.concat(market.name, ": the pool paid the cuts")
        );
        assertEq(done.peggedBurned, market.feesPegged, string.concat(market.name, ": the pegged fee redeemed"));
        assertEq(done.leveragedBurned, market.totalCutTokens, string.concat(market.name, ": the cuts redeemed"));
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
    }

    /// @dev The leveraged `minted` is worth the wrapped collateral `paid` at the market's price after the batch, to
    ///      the oracle's band and the roundings between, each a floor; and not worth what a mint priced in pegged units
    ///      would have returned. The minter rounds in pegged units, and a pegged wei is worth up to
    ///      `1e18 / wrappedInPegged` wrapped wei - about 27 for BTC::stETH - so the floors on the price path count in
    ///      those: the mint's own price and the price read back, one pegged wei each over the tokens minted; and the
    ///      price moves by at most one pegged wei at each of the batch's `operations` after the mint, each a floor. In
    ///      wrapped wei: the mint's token count (one token-wei, worth the price), and the conversion and the value
    ///      product, one each.
    function _checkMintValue(
        address minter,
        uint256 minted,
        uint256 paid,
        uint256 operations,
        string memory who
    ) private view {
        if (paid == 0) {
            // A zero debt: nothing paid, nothing minted, and no value to judge.
            assertEq(minted, 0, string.concat(who, ": nothing minted where nothing was paid"));
            return;
        }
        (uint256 price, uint256 wrappedInPegged) = _leveragedPriceInWrapped(minter);
        uint256 wrappedPerPeggedWei = Math.ceilDiv(1 ether, wrappedInPegged);
        uint256 tokens = Math.ceilDiv(minted, 1 ether);
        uint256 tolerance = price / 1 ether + 2 + wrappedPerPeggedWei * tokens * (2 + operations);
        uint256 value = Math.mulDiv(minted, price, 1 ether);
        assertApprox(
            value,
            paid,
            tolerance,
            _oracleBand(minter),
            string.concat(who, ": the mint is worth what was paid")
        );
        assertDiscriminates(
            value,
            paid,
            tolerance,
            Math.mulDiv(paid, wrappedInPegged, 1 ether),
            string.concat(who, ": the mint is not worth what a mint priced in pegged units would return")
        );
    }

    /// @dev The wrapped collateral the batch queued to mint with for the market's account `i`, read from the queued
    ///      mints; zero where none was queued.
    function _mintQueuedFor(
        CompensateRebalanceDilution.MarketCompensation memory market,
        uint256 i
    ) private view returns (uint256) {
        return _mintsQueued[keccak256(abi.encode(market.name, market.accounts[i]))];
    }

    mapping(bytes32 => uint256) private _mintsQueued;

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

    /// @dev Each market's batch as queued: after its manager's upgrade, the compensation in order - the pegged
    ///      approval and fee-free redemption, where there is a cut the leveraged approval and fee-free redemption, the
    ///      wrapped collateral approval for the mints' total, then a fee-free mint per account with a debt, each
    ///      recorded for the value check; and the leveraged pool's migration carries the market's deductions.
    function _checkBatches(
        CompensationRun run,
        CompensateRebalanceDilution.MarketCompensation[] memory markets
    ) private {
        Deployer.Transaction[] memory queued = run.batches();
        uint256 at;
        for (uint256 m = 0; m < markets.length; ++m) {
            at = _checkMarketBatch(run, queued, at, markets[m]);
        }
        assertEq(at, queued.length, "nothing else is queued");
    }

    /// @dev One market's batch from `at`: the upgrade's own calls, the leveraged pool's carrying the deductions, then
    ///      the compensation; return the index after it.
    function _checkMarketBatch(
        CompensationRun run,
        Deployer.Transaction[] memory queued,
        uint256 at,
        CompensateRebalanceDilution.MarketCompensation memory market
    ) private returns (uint256) {
        address pool = run.stabilityPoolAddress(market.market, HarborDeployer.StabilityPoolType.Leveraged);
        address manager = run.stabilityPoolManagerAddress(market.market);
        while (
            !(queued[at].target == manager && bytes4(queued[at].data) == UUPSUpgradeable.upgradeToAndCall.selector)
        ) {
            if (queued[at].target == pool) {
                _checkDeductionsIn(queued[at].data, run.deductionsOf(market), market.name);
            }
            ++at;
        }
        ++at;
        at = _checkRedemptions(run, queued, at, market);
        return _checkMints(run, queued, at, market);
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
    ///      per account with a debt, in the file's order, each recorded for the value check.
    function _checkMints(
        CompensationRun run,
        Deployer.Transaction[] memory queued,
        uint256 at,
        CompensateRebalanceDilution.MarketCompensation memory market
    ) private returns (uint256) {
        address minter = run.minterAddress(market.market);
        address wrapped = IHarborConfig(address(market.market)).wrappedCollateralToken();
        uint256 approvalAt = at;
        at = _expect(queued, at, wrapped, IERC20.approve.selector, market.name);
        uint256 mints;
        for (uint256 i = 0; i < market.accounts.length; ++i) {
            if (market.debts[i] > 0) {
                at = _expect(queued, at, minter, IMinter_v3.freeMintLeveragedToken.selector, market.name);
                (uint256 mint, address account) = abi.decode(_arguments(queued[at - 1].data), (uint256, address));
                assertEq(account, market.accounts[i], string.concat(market.name, ": the mint's receiver, in order"));
                _mintsQueued[keccak256(abi.encode(market.name, account))] = mint;
                mints += mint;
            }
        }
        assertGt(mints, 0, string.concat(market.name, ": something is minted"));
        _expectApproval(
            queued,
            approvalAt,
            wrapped,
            minter,
            mints,
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

    /// @dev A minter's leveraged token price in its wrapped collateral, 18 decimals, and the wrapped collateral's price
    ///      in pegged units it is converted by: the minter prices the token in pegged units; the oracle's price of the
    ///      collateral in pegged units and its wrapped-to-underlying rate, each read at the middle of its band, turn
    ///      that into wrapped collateral.
    function _leveragedPriceInWrapped(address minter) private view returns (uint256 price, uint256 wrappedInPegged) {
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(
            IMinter_v3(minter).priceOracle()
        ).latestAnswer();
        wrappedInPegged = Math.mulDiv((minPrice + maxPrice + 1) / 2, (minRate + maxRate + 1) / 2, 1 ether);
        price = Math.mulDiv(IMinter_v3(minter).leveragedTokenPrice(), 1 ether, wrappedInPegged);
    }

    /// @dev The relative width of the minter's oracle reading, price and rate together: a fee-free mint is priced at
    ///      the high price and the low rate, the value read at the middle, so the two differ by at most this.
    function _oracleBand(address minter) private view returns (uint256) {
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(
            IMinter_v3(minter).priceOracle()
        ).latestAnswer();
        return ((maxPrice - minPrice) * 1 ether) / minPrice + ((maxRate - minRate) * 1 ether) / minRate;
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
