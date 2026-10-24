// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {HarborPauser_v1} from "@bao/HarborPauser_v1.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {JsonParser} from "@bao-script/deployment/JsonParser.sol";
import {BaoTestLib} from "@bao-test/BaoTestLib.sol";
import {IGenesis} from "@harbor/interfaces/IGenesis.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";

import {Config_MinterMarket, IMarketConfig} from "@harbor-script/config/ConfigBase.sol";
import {ConfigMarket_BTC_stETH_mainnet} from "@harbor-script/config/markets/ConfigMarket_BTC_stETH_mainnet.sol";
import {ConfigMarket_EUR_stETH_mainnet} from "@harbor-script/config/markets/ConfigMarket_EUR_stETH_mainnet.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {btcMintersConfig} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {ethMintersConfig} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {eurMintersConfig} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {goldMintersConfig} from "@harbor-script/src/Deploy_GOLD_Minter.sol";
import {mcapMintersConfig} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {silverMintersConfig} from "@harbor-script/src/Deploy_SILVER_Minter.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {LogCaptureLib} from "@harbor-script/holders/LogCaptureLib.sol";

import {IncidentMarketUpgrade} from "@harbor-script/verify/incidents/IncidentMarketUpgrade.sol";
import {MarketAddresses} from "@harbor-test/harness/MarketAddresses.sol";
import {V3Rule} from "@harbor-test/harness/MarketRule.sol";
import {
    BTC_STETH_EXPLOIT,
    EUR_STETH_EXPLOIT,
    OpenWindowWithdrawer,
    RebalanceDilutionAttacker,
    RebalanceDilutionFork
} from "@harbor-test/deployment/RebalanceDilutionFork.sol";

/// @notice Writes the figures of one exploit of 2026-10-16 into `<market>-figures.md`, and every account's change, in
///         wei, into `<market>-accounts.csv`, both in `DIRECTORY`, from the chain and from the exploit replayed on a
///         fork, so that no figure is copied by hand and the balances can be corrected from exact amounts. A derived
///         contract names the exploit's transaction and market.
///
/// It replays the exploit once to learn what it did - who acted, who lent, who it paid, the mints it made - and goes
/// back. It reads, from the holder capture at the exploit's block, every account that has held a position in either
/// stability pool or held the pegged or the leveraged token, reads what each holds, replays the exploit, and reads
/// again. It decodes the transaction's actions, the fees and the caller's flows from the replay's events, runs the
/// mitigation scenarios through the same installers and attacker the tests use, with the exploit's own mints and loan,
/// and reads every market's configuration at the exploit's block.
///
/// It checks itself before writing anything: the accounts found hold the whole pegged and leveraged supplies, and leave
/// each pool's ledger gap within rounding either way, before and after; every party's change sums to zero, to within
/// the rounding of the valuation; and the caller's flows sum to what it paid out, to within the rounding of its trades.
/// A failed check leaves the files as they were.
///
/// It also follows every holder from just before the exploit to the pause, into `<market>-holders.md`: see
/// `test_writeHolders`.
abstract contract RebalanceDilutionReport is RebalanceDilutionFork {
    /// @dev The header of an accounts file: each row is one account's position in one token, from one reading to the
    ///      next.
    string internal constant ACCOUNTS_HEADER =
        "account,role,position,token,before,after,change,value_change_pegged,value_change_wrapped\n";
    /// @dev The block the minters and the stability pools were paused in, where every holder's history ends: the holder
    ///      capture and the log captures end there, and the last reading is the end of the block before it.
    uint256 internal constant PAUSE_BLOCK = 26_248_724;
    /// @dev The log capture of the exploited markets' minters, pools, managers and tokens, from the first exploit's block
    ///      to the pause, written by `script/holders/capture-logs`.
    string internal constant MARKET_LOG_CAPTURE = "logs-26204584-26248724/";
    /// @dev The log capture of the exploited markets' genesis contracts, from the first harbor deployment to the pause.
    string internal constant GENESIS_LOG_CAPTURE = "logs-24049000-26248724/";
    /// @dev The deployment state file, which records every contract's address under its salt: the names the holders file
    ///      gives the contracts a holder dealt with.
    string internal constant STATE_FILE = "deployments/mainnet/harbor_v1.state.json";
    /// @dev What every call to a contract behind the pauser reverts with: `HarborPauser_v1`'s fallback states it inline.
    string internal constant PAUSED_MESSAGE = "Contract is paused and all functions are disabled";
    /// @dev A party's index when an account is not a party.
    uint256 internal constant NOT_A_PARTY = type(uint256).max;
    /// @dev The rebuilt attacker's role in the new-contracts figures: it keeps what the attack pays it.
    string internal constant OWN_CAPITAL_ATTACKER = "attacker with its own capital, paid by the exploit";

    /// @notice What one account holds: tokens in its wallet, and its positions in the two pools.
    struct Holding {
        uint256 wrapped;
        uint256 pegged;
        uint256 leveraged;
        uint256 leveragedPoolDeposit;
        uint256 leveragedPoolWrapped;
        uint256 leveragedPoolLeveraged;
        uint256 collateralPoolDeposit;
        uint256 collateralPoolWrapped;
    }

    /// @notice Prices in pegged units (1e18), as the minter reads them: the collateral at the oracle's mid price, the
    ///         wrapped collateral at that price and the oracle's mid rate, and the two tokens at the minter's prices.
    struct Prices {
        uint256 collateral;
        uint256 wrapped;
        uint256 pegged;
        uint256 leveraged;
    }

    /// @notice One reading of the market and of every party.
    struct Reading {
        Prices prices;
        uint256 collateralBacking;
        uint256 peggedSupply;
        uint256 leveragedSupply;
        uint256 collateralRatio;
        Holding[] parties;
        /// @dev The wallets of the market's contracts that hold tokens for others: the leveraged pool, the collateral
        ///      pool and the manager.
        Holding[] contracts;
        /// @dev The minter's wrapped collateral beyond its recorded backing, in pegged units.
        int256 minterSurplus;
        /// @dev Each pool's recorded supply less what its depositors hold - its ledger gap, the figure the
        ///      StabilityPool_v3 upgrade seeds - in wei of the pegged token; negative when they hold more.
        int256 leveragedPoolGap;
        int256 collateralPoolGap;
    }

    /// @notice An account the report follows, and why.
    struct Party {
        address account;
        string role;
        /// @dev Whether a holder capture shows the account never deposited in the pool, so that its position there is
        ///      zero and is not read.
        bool outsideLeveragedPool;
        bool outsideCollateralPool;
    }

    /// @notice A kind of minter action in the transaction: how many, and the tokens in and out.
    struct Action {
        uint256 count;
        uint256 tokensIn;
        uint256 tokensOut;
        uint256 fees;
    }

    /// @notice What the transaction did, from its events.
    struct Transaction {
        address caller;
        address lender;
        uint256 borrowed;
        uint256 repaid;
        Action mintLeveraged;
        Action mintPegged;
        Action redeemLeveragedBefore;
        Action redeemLeveragedAfter;
        Action redeemPegged;
        uint256 deposited;
        uint256 rebalancePegged;
        uint256 rebalanceWrapped;
        uint256 rebalanceLeveraged;
        uint256 collateralPoolPegged;
        uint256 collateralPoolWrapped;
        uint256 leveragedPoolPegged;
        uint256 leveragedPoolLeveraged;
        uint256 bountyWrapped;
        uint256 bountyLeveraged;
        uint256 claimedWrapped;
        uint256 claimedLeveraged;
        uint256 withdrawn;
        uint256 earlyWithdrawalFee;
        uint256 callerPoolLoss;
        uint256 callerLeveragedAtRebalance;
        uint256 reservePaid;
        /// @dev The accounts outside the market the caller paid, other than the lender, and what it paid them.
        address[] recipients;
        uint256 paidWrapped;
        uint256 paidPegged;
        uint256 paidLeveraged;
        /// @dev The caller's mints, in order.
        RebalanceDilutionAttacker.Mint[] mints;
    }

    /// @notice One reading of every party in the holders' history, taken after every captured log up to `logKey`
    ///         (`_logKey`), with each party's unclaimed genesis claim.
    struct Point {
        string label;
        uint256 blockNumber;
        uint256 timestamp;
        uint256 logKey;
        Reading reading;
        uint256[] genesisPegged;
        uint256[] genesisLeveraged;
    }

    /// @notice What one party did in one transaction, from the transaction's captured logs.
    struct HolderAction {
        uint256 party;
        /// @dev The reading at the end of the transaction's block.
        uint256 point;
        bytes32 transactionHash;
        string what;
        /// @dev The changes in its wallet's pegged and leveraged tokens.
        int256 pegged;
        int256 leveraged;
        /// @dev The wrapped collateral it paid (negative) or received in its own minter actions and pool claims.
        int256 wrapped;
        /// @dev The leveraged tokens it minted or redeemed, and the wrapped collateral paid or received for them: the
        ///      price it dealt at.
        uint256 minterLeveraged;
        uint256 minterWrapped;
    }

    /// @notice A mint or a redemption, from a minter log: the tokens, the wrapped collateral paid or received for them,
    ///         who acted and who received.
    struct MinterAction {
        bool mint;
        bool leveraged;
        uint256 tokens;
        uint256 wrapped;
        address sender;
        address receiver;
    }

    /// @notice Every holder's history from just before the exploit to the pause, and what it is read with.
    struct History {
        /// @dev The market, `<peg>::<collateral>`, and its file names' form, `<peg>-<collateral>`.
        string name;
        string label;
        string peggedSymbol;
        string leveragedSymbol;
        string wrappedSymbol;
        /// @dev The parties found at the exploit's block, and those found by then and in the capture at the pause: the
        ///      ones in between are new since the exploit. The genesis participants come after both.
        uint256 atTheExploit;
        uint256 atThePause;
        address genesis;
        /// @dev Every account ever given a genesis share.
        uint256 genesisParticipants;
        /// @dev The pause block's time.
        uint256 pausedAt;
        /// @dev The market's captured logs from the exploit's block on, in block and log order.
        LogCaptureLib.CapturedLog[] logs;
        Point[] points;
        HolderAction[] actions;
        /// @dev Every contract the state file records, to name the contracts a holder dealt with.
        DeploymentTypes.ProxyRecord[] contracts;
    }

    /// @notice A mitigation to measure.
    enum Mitigation {
        AsDeployed,
        MinterV3,
        RedemptionFloor,
        WithdrawalFee,
        WithdrawalFeeOpenWindow
    }

    Party[] internal parties;

    constructor() {
        useRule(new V3Rule());
    }

    function test_writeFigures() public {
        Transaction memory exploit = _decodeExploit();
        _findParties(exploit.recipients);
        uint256 beforeExploit = vm.snapshotState();
        Reading memory before = _read();
        vm.transact(exploitTransaction());
        Reading memory afterwards = _read();

        string memory figures = string.concat(
            _header(),
            _marketSection(before, afterwards),
            _transactionSection(exploit),
            _partiesSections(before, afterwards),
            _callerSection(exploit, before, afterwards)
        );
        string memory accounts = _accountsCsv(before, afterwards);
        figures = string.concat(figures, _mitigationSection(beforeExploit, exploit), _marketsSection(beforeExploit));
        string memory market_ = _marketLabel();
        vm.createDir(DIRECTORY, true);
        vm.writeFile(string.concat(DIRECTORY, market_, "-figures.md"), figures);
        vm.writeFile(string.concat(DIRECTORY, market_, "-accounts.csv"), accounts);
    }

    /// @notice The exploit against the new contracts. Just before it, the market is upgraded by the upgrade script's
    ///         own function; the exploit's transaction is replayed on it; and the rebuilt attacker runs the same attack
    ///         without a flash loan, with the exploit's mints and the loan as its own capital. Writes
    ///         `<market>-new-contracts.md`, and every account's change in the attack without a flash loan, in wei, to
    ///         `<market>-new-contracts-accounts.csv`.
    function test_writeNewContractsFigures() public {
        Transaction memory exploit = _decodeExploit();
        _findParties(exploit.recipients);
        address attacker = address(new RebalanceDilutionAttacker(market, exploit.mints));
        _addRole(attacker, OWN_CAPITAL_ATTACKER);
        Reading memory before = _read();

        Config_MinterMarket[] memory toUpgrade = new Config_MinterMarket[](1);
        toUpgrade[0] = exploitedMarket;
        new IncidentMarketUpgrade(toUpgrade, _captureDirectory()).run(SALT_PREFIX);
        Reading memory upgraded = _read();
        string memory upgrade = _upgradeSection(before, upgraded);

        vm.transact(exploitTransaction());
        assertEq(
            keccak256(abi.encode(_read())),
            keccak256(abi.encode(upgraded)),
            "the exploit's transaction changes nothing on the new contracts"
        );

        (string memory ownCapital, string memory accounts) = _ownCapitalAttack(exploit, attacker);
        string memory market_ = _marketLabel();
        vm.writeFile(
            string.concat(DIRECTORY, market_, "-new-contracts.md"),
            string.concat(_newContractsHeader(), ownCapital, _replaySection(), upgrade)
        );
        vm.writeFile(string.concat(DIRECTORY, market_, "-new-contracts-accounts.csv"), accounts);
    }

    /// @dev The rebuilt attacker's run on the market as it stands, with the exploit's loan as its own capital: the
    ///      figures' section for it, with the exploit's tables for this attack, and every account's change in wei.
    function _ownCapitalAttack(
        Transaction memory exploit,
        address attacker
    ) internal returns (string memory section, string memory accounts) {
        deal(market.wrappedCollateral, attacker, exploit.borrowed);
        Reading memory armed = _read();
        Outcome memory outcome = _runAttack(attacker, attacker, exploit.borrowed);
        Reading memory attacked = _read();
        section = string.concat(_ownCapitalSection(exploit, outcome), _partiesSections(armed, attacked));
        accounts = _accountsCsv(armed, attacked);
    }

    /// @dev What the exploit did - who acted, who it paid, its mints - learned from one replay, then undone.
    function _decodeExploit() internal returns (Transaction memory exploit) {
        uint256 start = vm.snapshotState();
        vm.recordLogs();
        vm.transact(exploitTransaction());
        exploit = _decode(vm.getRecordedLogs());
        vm.revertToState(start);
    }

    /// @dev The exploited market, as its files are named: `<peg>-<collateral>`.
    function _marketLabel() internal view returns (string memory) {
        return
            string.concat(
                IMarketConfig(address(exploitedMarket)).peg(),
                "-",
                IMarketConfig(address(exploitedMarket)).collateral()
            );
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Finding the parties
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Every account the capture at the exploit's block lists for either pool (each `UserDepositChange` owner) or
    ///      for the pegged or the leveraged token (each account it has been sent to), the fee receivers, the reserve pool
    ///      and the accounts the exploit paid - less the market's own contracts, whose wallets are read separately.
    function _findParties(address[] memory paidByTheExploit) internal {
        string memory capture = _captureDirectory();
        assertEq(HolderCaptureLib.captureBlock(capture), block.number, "the holder capture is at the exploit's block");
        _addCapturedHolders(capture);
        _addRole(IMinter(market.minter).feeReceiver(), "minter fee receiver");
        _addRole(IStabilityPool(market.leveragedPool).getFeeAddress(), "leveraged pool fee address");
        _addRole(IStabilityPool(market.collateralPool).getFeeAddress(), "collateral pool fee address");
        _addRole(IStabilityPoolManager(market.manager).feeReceiver(), "manager fee receiver (harvest cut)");
        _addRole(IMinter(market.minter).reservePool(), "reserve pool");
        for (uint256 i = 0; i < paidByTheExploit.length; ++i) {
            _addRole(paidByTheExploit[i], "paid by the exploit");
        }
    }

    /// @dev Adds every account `capture` lists for either pool or for the pegged or the leveraged token as a party, less
    ///      the market's own contracts.
    function _addCapturedHolders(string memory capture) internal {
        string[4] memory salts = [
            productionRun.stabilityPoolKey(exploitedMarket, HarborDeployer.StabilityPoolType.Leveraged),
            productionRun.stabilityPoolKey(exploitedMarket, HarborDeployer.StabilityPoolType.Collateral),
            productionRun.peggedTokenKey(exploitedMarket),
            productionRun.leveragedTokenKey(exploitedMarket)
        ];
        address[] memory found = new address[](0);
        for (uint256 s = 0; s < salts.length; ++s) {
            address[] memory listed = HolderCaptureLib.holders(capture, salts[s]);
            for (uint256 i = 0; i < listed.length; ++i) {
                found = _include(found, listed[i]);
            }
        }

        address genesis = productionRun.genesisAddress(exploitedMarket);
        for (uint256 i = 0; i < found.length; ++i) {
            if (
                found[i] != market.minter &&
                found[i] != market.leveragedPool &&
                found[i] != market.collateralPool &&
                found[i] != market.manager
            ) {
                _addRole(found[i], found[i] == genesis ? "genesis contract" : "");
            }
        }
    }

    /// @dev Adds `account` to the parties, or adds `role` to its roles if it is there without it.
    function _addRole(address account, string memory role) internal {
        for (uint256 i = 0; i < parties.length; ++i) {
            if (parties[i].account == account) {
                if (bytes(role).length > 0 && !LibString.contains(parties[i].role, role)) {
                    parties[i].role = bytes(parties[i].role).length > 0
                        ? string.concat(parties[i].role, ", ", role)
                        : role;
                }
                return;
            }
        }
        parties.push(Party(account, role, false, false));
    }

    /// @dev `found` with `account` appended, unless it is there already.
    function _include(address[] memory found, address account) internal pure returns (address[] memory grown) {
        if (_contains(found, account)) {
            return found;
        }
        grown = new address[](found.length + 1);
        for (uint256 i = 0; i < found.length; ++i) {
            grown[i] = found[i];
        }
        grown[found.length] = account;
    }

    function _contains(address[] memory accounts, address account) internal pure returns (bool) {
        for (uint256 i = 0; i < accounts.length; ++i) {
            if (accounts[i] == account) {
                return true;
            }
        }
        return false;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Reading
    // ---------------------------------------------------------------------------------------------------------------

    function _read() internal view returns (Reading memory reading) {
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(market.oracle)
            .latestAnswer();
        // The caller's flows are valued at one price; with a spread they would not sum to what it paid out.
        assertEq(minPrice, maxPrice, "the oracle reports one price");
        assertEq(minRate, maxRate, "the oracle reports one rate");
        // The minter's mid price: the two halves summed and halved, rounding half up.
        reading.prices.collateral = (minPrice + maxPrice + 1) / 2;
        reading.prices.wrapped = Math.mulDiv(reading.prices.collateral, (minRate + maxRate + 1) / 2, 1 ether);
        reading.prices.pegged = IMinter(market.minter).peggedTokenPrice();
        reading.prices.leveraged = IMinter(market.minter).leveragedTokenPrice();
        reading.collateralBacking = IMinter(market.minter).collateralTokenBalance();
        reading.peggedSupply = IMinter(market.minter).peggedTokenBalance();
        reading.leveragedSupply = IMinter(market.minter).leveragedTokenBalance();
        reading.collateralRatio = IMinter(market.minter).collateralRatio();

        reading.parties = new Holding[](parties.length);
        for (uint256 i = 0; i < parties.length; ++i) {
            reading.parties[i] = _holding(
                parties[i].account,
                !parties[i].outsideLeveragedPool,
                !parties[i].outsideCollateralPool
            );
        }
        reading.contracts = new Holding[](3);
        reading.contracts[0] = _holding(market.leveragedPool, true, true);
        reading.contracts[1] = _holding(market.collateralPool, true, true);
        reading.contracts[2] = _holding(market.manager, true, true);
        reading.minterSurplus =
            int256(
                Math.mulDiv(IERC20(market.wrappedCollateral).balanceOf(market.minter), reading.prices.wrapped, 1 ether)
            ) - int256(Math.mulDiv(reading.collateralBacking, reading.prices.collateral, 1 ether));

        _assertComplete(reading);
    }

    /// @dev What `account` holds; its positions in a pool only when `readLeveragedPool` or `readCollateralPool` says so,
    ///      and zero otherwise.
    function _holding(
        address account,
        bool readLeveragedPool,
        bool readCollateralPool
    ) internal view returns (Holding memory holding) {
        holding.wrapped = IERC20(market.wrappedCollateral).balanceOf(account);
        holding.pegged = IERC20(market.pegged).balanceOf(account);
        holding.leveraged = IERC20(market.leveraged).balanceOf(account);
        if (readLeveragedPool) {
            holding.leveragedPoolDeposit = IStabilityPool(market.leveragedPool).assetBalanceOf(account);
            holding.leveragedPoolWrapped = IMultipleRewardAccumulator(market.leveragedPool).claimable(
                account,
                market.wrappedCollateral
            );
            holding.leveragedPoolLeveraged = IMultipleRewardAccumulator(market.leveragedPool).claimable(
                account,
                market.leveraged
            );
        }
        if (readCollateralPool) {
            holding.collateralPoolDeposit = IStabilityPool(market.collateralPool).assetBalanceOf(account);
            holding.collateralPoolWrapped = IMultipleRewardAccumulator(market.collateralPool).claimable(
                account,
                market.wrappedCollateral
            );
        }
    }

    /// @dev The parties found and the market's contracts hold the whole pegged and leveraged supplies - token balances,
    ///      exact. Each pool's ledger gap - its `totalAssetSupply()` less the sum of the depositors' `assetBalanceOf` - is
    ///      recorded, and must be within rounding, either side of zero, by the rule the StabilityPool_v3 upgrade applies
    ///      (`HolderCaptureLib.classify`). It is not zero: a pool spreads each loss with its per-unit share
    ///      rounded up and carries the over-charge to the next loss (`lastAssetLossError`), so its supply and its
    ///      depositors' balances drift apart by design, by up to about its supply in 1e-18 units a liquidation.
    function _assertComplete(Reading memory reading) internal view {
        uint256 leveragedPoolDeposits;
        uint256 collateralPoolDeposits;
        uint256 peggedHeld;
        uint256 leveragedHeld;
        for (uint256 i = 0; i < reading.parties.length; ++i) {
            leveragedPoolDeposits += reading.parties[i].leveragedPoolDeposit;
            collateralPoolDeposits += reading.parties[i].collateralPoolDeposit;
            peggedHeld += reading.parties[i].pegged;
            leveragedHeld += reading.parties[i].leveraged;
        }
        for (uint256 i = 0; i < reading.contracts.length; ++i) {
            peggedHeld += reading.contracts[i].pegged;
            leveragedHeld += reading.contracts[i].leveraged;
        }
        assertEq(peggedHeld, IERC20(market.pegged).totalSupply(), "the holders found hold the pegged supply");
        assertEq(leveragedHeld, IERC20(market.leveraged).totalSupply(), "the holders found hold the leveraged supply");

        uint256 leveragedPoolSupply = IStabilityPool(market.leveragedPool).totalAssetSupply();
        uint256 collateralPoolSupply = IStabilityPool(market.collateralPool).totalAssetSupply();
        reading.leveragedPoolGap = int256(leveragedPoolSupply) - int256(leveragedPoolDeposits);
        reading.collateralPoolGap = int256(collateralPoolSupply) - int256(collateralPoolDeposits);
        assertTrue(
            HolderCaptureLib.classify(reading.leveragedPoolGap, leveragedPoolSupply) == HolderCaptureLib.Gap.Rounding,
            "the depositors found hold the leveraged pool's supply, to within rounding"
        );
        assertTrue(
            HolderCaptureLib.classify(reading.collateralPoolGap, collateralPoolSupply) ==
                HolderCaptureLib.Gap.Rounding,
            "the depositors found hold the collateral pool's supply, to within rounding"
        );
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Valuing
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Everything `holding` holds, in pegged units: three products, each floored.
    function _value(Holding memory holding, Prices memory prices) internal pure returns (int256) {
        return
            _walletValue(holding, prices) +
            _leveragedPoolValue(holding, prices) +
            _collateralPoolValue(holding, prices);
    }

    function _walletValue(Holding memory holding, Prices memory prices) internal pure returns (int256) {
        return
            int256(
                Math.mulDiv(holding.wrapped, prices.wrapped, 1 ether) +
                    Math.mulDiv(holding.pegged, prices.pegged, 1 ether) +
                    Math.mulDiv(holding.leveraged, prices.leveraged, 1 ether)
            );
    }

    function _leveragedPoolValue(Holding memory holding, Prices memory prices) internal pure returns (int256) {
        return
            int256(
                Math.mulDiv(holding.leveragedPoolDeposit, prices.pegged, 1 ether) +
                    Math.mulDiv(holding.leveragedPoolWrapped, prices.wrapped, 1 ether) +
                    Math.mulDiv(holding.leveragedPoolLeveraged, prices.leveraged, 1 ether)
            );
    }

    function _collateralPoolValue(Holding memory holding, Prices memory prices) internal pure returns (int256) {
        return
            int256(
                Math.mulDiv(holding.collateralPoolDeposit, prices.pegged, 1 ether) +
                    Math.mulDiv(holding.collateralPoolWrapped, prices.wrapped, 1 ether)
            );
    }

    /// @dev A value in pegged units, in wrapped collateral at `prices`.
    function _inWrapped(int256 pegged, Prices memory prices) internal pure returns (int256) {
        uint256 magnitude = Math.mulDiv(pegged < 0 ? uint256(-pegged) : uint256(pegged), 1 ether, prices.wrapped);
        return pegged < 0 ? -int256(magnitude) : int256(magnitude);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Decoding the transaction
    // ---------------------------------------------------------------------------------------------------------------

    function _decode(Vm.Log[] memory logs) internal view returns (Transaction memory exploit) {
        // The caller is the account that deposited in the leveraged pool; the rebalance is the manager's redemption.
        uint256 rebalanceLog;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == market.leveragedPool && logs[i].topics[0] == IStabilityPool.Deposit.selector) {
                exploit.caller = _topicAddress(logs[i], 1);
                exploit.deposited = abi.decode(logs[i].data, (uint256));
            }
            if (_isMinterAction(logs[i], IMinter.RedeemPeggedToken.selector, market.manager)) {
                rebalanceLog = i;
                (exploit.rebalancePegged, exploit.rebalanceWrapped, exploit.rebalanceLeveraged) = abi.decode(
                    logs[i].data,
                    (uint256, uint256, uint256)
                );
            }
        }
        assertGt(rebalanceLog, 0, "the transaction rebalanced");

        bytes32 lastAction;
        for (uint256 i = 0; i < logs.length; ++i) {
            lastAction = _decodeMinter(exploit, logs[i], i < rebalanceLog, lastAction);
            _decodePools(exploit, logs[i]);
            _decodeTransfer(exploit, logs[i], i < rebalanceLog, lastAction);
        }
    }

    /// @dev A minter action by the caller; returns the kind of the last one seen, which a fee transfer after it
    ///      belongs to.
    function _decodeMinter(
        Transaction memory exploit,
        Vm.Log memory log,
        bool beforeRebalance,
        bytes32 lastAction
    ) internal view returns (bytes32) {
        if (log.emitter != market.minter || log.topics.length < 2 || _topicAddress(log, 1) != exploit.caller) {
            return lastAction;
        }
        bytes32 kind = log.topics[0];
        if (kind == IMinter.MintLeveragedToken.selector || kind == IMinter.MintPeggedToken.selector) {
            bool leveraged = kind == IMinter.MintLeveragedToken.selector;
            _count(leveraged ? exploit.mintLeveraged : exploit.mintPegged, log.data);
            (uint256 collateralIn, ) = abi.decode(log.data, (uint256, uint256));
            exploit.mints = _withMint(exploit.mints, RebalanceDilutionAttacker.Mint(leveraged, collateralIn));
        } else if (kind == IMinter.RedeemLeveragedToken.selector) {
            _count(beforeRebalance ? exploit.redeemLeveragedBefore : exploit.redeemLeveragedAfter, log.data);
        } else if (kind == IMinter.RedeemPeggedToken.selector) {
            (uint256 peggedIn, uint256 wrappedOut, ) = abi.decode(log.data, (uint256, uint256, uint256));
            exploit.redeemPegged.count++;
            exploit.redeemPegged.tokensIn += peggedIn;
            exploit.redeemPegged.tokensOut += wrappedOut;
        } else {
            return lastAction;
        }
        return beforeRebalance || kind != IMinter.RedeemLeveragedToken.selector ? kind : bytes32("after");
    }

    /// @dev `mints` with `mint` appended.
    function _withMint(
        RebalanceDilutionAttacker.Mint[] memory mints,
        RebalanceDilutionAttacker.Mint memory mint
    ) internal pure returns (RebalanceDilutionAttacker.Mint[] memory grown) {
        grown = new RebalanceDilutionAttacker.Mint[](mints.length + 1);
        for (uint256 i = 0; i < mints.length; ++i) {
            grown[i] = mints[i];
        }
        grown[mints.length] = mint;
    }

    function _count(Action memory action, bytes memory data) internal pure {
        (uint256 tokensIn, uint256 tokensOut) = abi.decode(data, (uint256, uint256));
        action.count++;
        action.tokensIn += tokensIn;
        action.tokensOut += tokensOut;
    }

    function _decodePools(Transaction memory exploit, Vm.Log memory log) internal view {
        bytes32 kind = log.topics[0];
        if (kind == IStabilityPool.Liquidated.selector) {
            (, uint256 pegged, , uint256 reward) = abi.decode(log.data, (address, uint256, address, uint256));
            if (log.emitter == market.leveragedPool) {
                exploit.leveragedPoolPegged += pegged;
                exploit.leveragedPoolLeveraged += reward;
            } else if (log.emitter == market.collateralPool) {
                exploit.collateralPoolPegged += pegged;
                exploit.collateralPoolWrapped += reward;
            }
        }
        if (log.emitter != market.leveragedPool || log.topics.length < 2 || _topicAddress(log, 1) != exploit.caller) {
            return;
        }
        if (kind == IStabilityPool.UserDepositChange.selector) {
            (, uint256 loss) = abi.decode(log.data, (uint256, uint256));
            exploit.callerPoolLoss += loss;
        } else if (kind == IClaimReward.Claim.selector) {
            uint256 amount = abi.decode(log.data, (uint256));
            if (_topicAddress(log, 2) == market.leveraged) {
                exploit.claimedLeveraged += amount;
            } else {
                exploit.claimedWrapped += amount;
            }
        } else if (kind == IStabilityPool.Withdraw.selector) {
            exploit.withdrawn += abi.decode(log.data, (uint256));
        } else if (kind == IStabilityPool.EarlyWithdrawalFee.selector) {
            exploit.earlyWithdrawalFee += abi.decode(log.data, (uint256));
        }
    }

    function _decodeTransfer(
        Transaction memory exploit,
        Vm.Log memory log,
        bool beforeRebalance,
        bytes32 lastAction
    ) internal view {
        if (log.topics[0] != IERC20.Transfer.selector) {
            return;
        }
        address from = _topicAddress(log, 1);
        address to = _topicAddress(log, 2);
        uint256 amount = abi.decode(log.data, (uint256));
        if (log.emitter == market.leveraged && beforeRebalance) {
            if (to == exploit.caller) {
                exploit.callerLeveragedAtRebalance += amount;
            }
            if (from == exploit.caller) {
                exploit.callerLeveragedAtRebalance -= amount;
            }
        }
        if (from == market.manager && to == exploit.caller) {
            if (log.emitter == market.wrappedCollateral) {
                exploit.bountyWrapped += amount;
            } else if (log.emitter == market.leveraged) {
                exploit.bountyLeveraged += amount;
            }
        }
        // What the caller pays outside the market, other than repaying the lender, is the exploit's payout.
        if (from == exploit.caller && !_isMarketContract(to) && to != exploit.lender) {
            exploit.recipients = _include(exploit.recipients, to);
            if (log.emitter == market.wrappedCollateral) {
                exploit.paidWrapped += amount;
            } else if (log.emitter == market.pegged) {
                exploit.paidPegged += amount;
            } else if (log.emitter == market.leveraged) {
                exploit.paidLeveraged += amount;
            }
        }
        if (log.emitter != market.wrappedCollateral) {
            return;
        }
        if (from == market.minter && to == IMinter(market.minter).feeReceiver()) {
            _fee(exploit, lastAction, amount);
        }
        if (from == IMinter(market.minter).reservePool() && to == exploit.caller) {
            exploit.reservePaid += amount;
        }
        if (to == exploit.caller && exploit.lender == address(0) && !_isMarketContract(from)) {
            exploit.lender = from;
        }
        if (from == exploit.lender && to == exploit.caller) {
            exploit.borrowed += amount;
        }
        if (from == exploit.caller && to == exploit.lender) {
            exploit.repaid += amount;
        }
    }

    function _fee(Transaction memory exploit, bytes32 lastAction, uint256 amount) internal pure {
        if (lastAction == IMinter.MintLeveragedToken.selector) {
            exploit.mintLeveraged.fees += amount;
        } else if (lastAction == IMinter.MintPeggedToken.selector) {
            exploit.mintPegged.fees += amount;
        } else if (lastAction == IMinter.RedeemLeveragedToken.selector) {
            exploit.redeemLeveragedBefore.fees += amount;
        } else if (lastAction == bytes32("after")) {
            exploit.redeemLeveragedAfter.fees += amount;
        } else {
            exploit.redeemPegged.fees += amount;
        }
    }

    function _isMinterAction(Vm.Log memory log, bytes32 kind, address sender) internal view returns (bool) {
        return
            log.emitter == market.minter &&
            log.topics.length > 1 &&
            log.topics[0] == kind &&
            _topicAddress(log, 1) == sender;
    }

    function _isMarketContract(address account) internal view returns (bool) {
        return
            account == market.minter ||
            account == market.leveragedPool ||
            account == market.collateralPool ||
            account == market.manager ||
            account == address(0);
    }

    function _topicAddress(Vm.Log memory log, uint256 index) internal pure returns (address) {
        return address(uint160(uint256(log.topics[index])));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Sections
    // ---------------------------------------------------------------------------------------------------------------

    function _header() internal view returns (string memory) {
        string memory title = string.concat(
            "# Figures: the rebalance dilution exploit of ",
            IMarketConfig(address(exploitedMarket)).peg(),
            "::",
            IMarketConfig(address(exploitedMarket)).collateral(),
            ", 2026-10-16\n\n",
            "Generated by `script/verify/incidents/RebalanceDilutionReport.t.sol`; run ",
            "`script/verify/incidents/run-rebalance-dilution-report` to regenerate. Do not edit by hand. ",
            "The explanation is in [README.md](README.md).\n\n"
        );
        return
            string.concat(
                title,
                "Transaction `",
                vm.toString(exploitTransaction()),
                "`, block ",
                vm.toString(block.number),
                " (",
                BaoTestLib.toUtcString(block.timestamp),
                "), replayed on a fork with `vm.transact`. Before is the state the transaction started from; after ",
                "is the state it left. Both are read at the block's time, so a reward that streams over time is read ",
                "as at that moment: a chain read at the end of the previous block shows such a reward slightly lower, ",
                "by what streamed in between, which the transaction did not cause.\n\n",
                "Every amount, price and value is printed in full, to all 18 decimals; only ratios and rates are ",
                "rounded. Values are in ",
                _symbol(market.wrappedCollateral),
                ". Each position is valued at its own end's prices: a ",
                _symbol(market.wrappedCollateral),
                " position at its amount; a token position at its amount times the minter's price for the token, over ",
                "the oracle's price for ",
                _symbol(market.wrappedCollateral),
                ", floored to the wei. A change in value is the value after less the value before, so an account's ",
                "figures here are the sums of its rows in the accounts file. The books check values in pegged units. ",
                "Every account's change, position by position and in wei, is in [",
                _marketLabel(),
                "-accounts.csv](",
                _marketLabel(),
                "-accounts.csv).\n\n"
            );
    }

    function _marketSection(Reading memory before, Reading memory afterwards) internal view returns (string memory) {
        string memory pegged = _symbol(market.pegged);
        string memory leveraged = _symbol(market.leveraged);
        string memory wrapped = _symbol(market.wrappedCollateral);
        string memory table = "## The market\n\n| | Before | After |\n|---|---|---|\n";
        table = string.concat(
            table,
            _row3(
                string.concat("1 ", pegged, " in ", wrapped),
                _wrappedPer(before.prices.pegged, before.prices),
                _wrappedPer(afterwards.prices.pegged, afterwards.prices)
            )
        );
        table = string.concat(
            table,
            _row3(
                string.concat("1 ", leveraged, " in ", wrapped),
                _wrappedPer(before.prices.leveraged, before.prices),
                _wrappedPer(afterwards.prices.leveraged, afterwards.prices)
            )
        );
        table = string.concat(
            table,
            _row3(
                string.concat("1 ", leveraged, " in pegged units"),
                _exact(before.prices.leveraged),
                _exact(afterwards.prices.leveraged)
            )
        );
        table = string.concat(
            table,
            _row3(
                "Collateral backing (underlying)",
                _exact(before.collateralBacking),
                _exact(afterwards.collateralBacking)
            )
        );
        table = string.concat(
            table,
            _row3(string.concat(pegged, " outstanding"), _exact(before.peggedSupply), _exact(afterwards.peggedSupply))
        );
        table = string.concat(
            table,
            _row3(
                string.concat(leveraged, " outstanding"),
                _exact(before.leveragedSupply),
                _exact(afterwards.leveragedSupply)
            )
        );
        table = string.concat(
            table,
            _row3("Collateral ratio", _fixed(before.collateralRatio, 4), _fixed(afterwards.collateralRatio, 4))
        );
        table = string.concat(
            table,
            _row3(
                string.concat("Leveraged pool supply no depositor holds (ledger gap), wei of ", pegged),
                vm.toString(before.leveragedPoolGap),
                vm.toString(afterwards.leveragedPoolGap)
            )
        );
        table = string.concat(
            table,
            _row3(
                string.concat("Collateral pool supply no depositor holds (ledger gap), wei of ", pegged),
                vm.toString(before.collateralPoolGap),
                vm.toString(afterwards.collateralPoolGap)
            )
        );
        return
            string.concat(
                table,
                "\nA pool's ledger gap is its `totalAssetSupply()` less the sum of its depositors' `assetBalanceOf`, ",
                "negative when they hold more. A pool spreads each loss with its per-unit share rounded up and carries ",
                "the over-charge to its next loss, so the two drift apart by design, by up to about the supply in 1e-18 ",
                "units a liquidation; the StabilityPool_v3 upgrade measures the gap and seeds it so rewards divide by ",
                "what depositors hold. This report requires each gap to be within ",
                vm.toString(HolderCaptureLib.MAX_GAP_PARTS_PER_BILLION),
                " parts per billion of the pool's supply, either side of zero, the rule the upgrade applies to a ",
                "holder capture.\n\n"
            );
    }

    function _transactionSection(Transaction memory exploit) internal view returns (string memory) {
        string memory pegged = _symbol(market.pegged);
        string memory leveraged = _symbol(market.leveraged);
        string memory wrapped = _symbol(market.wrappedCollateral);
        string memory table = string.concat(
            "## What the transaction did\n\nCaller (the contract that acted): `",
            vm.toString(exploit.caller),
            "`. Lender: `",
            vm.toString(exploit.lender),
            "`.\n\n| Step | Count | In | Out | Fee to the minter's fee receiver |\n|---|---|---|---|---|\n"
        );
        table = string.concat(
            table,
            _actionRow(string.concat("Borrowed ", wrapped), 1, exploit.borrowed, wrapped, 0, "", 0)
        );
        table = string.concat(
            table,
            _actionRow(string.concat("Minted ", leveraged), exploit.mintLeveraged, wrapped, leveraged)
        );
        table = string.concat(table, _actionRow(string.concat("Minted ", pegged), exploit.mintPegged, wrapped, pegged));
        table = string.concat(
            table,
            _actionRow("Deposited in the leveraged pool", 1, exploit.deposited, pegged, 0, "", 0)
        );
        table = string.concat(
            table,
            _actionRow(
                string.concat("Redeemed ", leveraged, " before the rebalance"),
                exploit.redeemLeveragedBefore,
                leveraged,
                wrapped
            )
        );
        table = string.concat(
            table,
            _actionRow(
                "Rebalance: pegged redeemed by the manager",
                1,
                exploit.rebalancePegged,
                pegged,
                exploit.rebalanceWrapped,
                wrapped,
                0
            )
        );
        table = string.concat(
            table,
            _actionRow(
                string.concat("Rebalance: ", leveraged, " minted for it"),
                1,
                0,
                "",
                exploit.rebalanceLeveraged,
                leveraged,
                0
            )
        );
        table = string.concat(
            table,
            _actionRow(
                "Rebalance: from the collateral pool",
                1,
                exploit.collateralPoolPegged,
                pegged,
                exploit.collateralPoolWrapped,
                wrapped,
                0
            )
        );
        table = string.concat(
            table,
            _actionRow(
                "Rebalance: from the leveraged pool",
                1,
                exploit.leveragedPoolPegged,
                pegged,
                exploit.leveragedPoolLeveraged,
                leveraged,
                0
            )
        );
        table = string.concat(
            table,
            _actionRow(
                string.concat("Rebalance bounty to the caller, ", wrapped),
                1,
                0,
                "",
                exploit.bountyWrapped,
                wrapped,
                0
            )
        );
        table = string.concat(
            table,
            _actionRow(
                string.concat("Rebalance bounty to the caller, ", leveraged),
                1,
                0,
                "",
                exploit.bountyLeveraged,
                leveraged,
                0
            )
        );
        table = string.concat(
            table,
            _actionRow(
                string.concat("Claimed ", leveraged, " from the leveraged pool"),
                1,
                0,
                "",
                exploit.claimedLeveraged,
                leveraged,
                0
            )
        );
        table = string.concat(
            table,
            _actionRow(
                string.concat("Redeemed ", leveraged, " after the rebalance"),
                exploit.redeemLeveragedAfter,
                leveraged,
                wrapped
            )
        );
        table = string.concat(
            table,
            _actionRow(
                "Withdrew from the leveraged pool (the early-withdrawal fee in the last column)",
                1,
                0,
                "",
                exploit.withdrawn,
                pegged,
                exploit.earlyWithdrawalFee
            )
        );
        table = string.concat(
            table,
            _actionRow(string.concat("Redeemed ", pegged), exploit.redeemPegged, pegged, wrapped)
        );
        table = string.concat(
            table,
            _actionRow(string.concat("Repaid ", wrapped), 1, exploit.repaid, wrapped, 0, "", 0)
        );
        table = string.concat(
            table,
            _actionRow(
                string.concat("Paid out, ", wrapped),
                exploit.recipients.length,
                0,
                "",
                exploit.paidWrapped,
                wrapped,
                0
            )
        );
        table = string.concat(
            table,
            _actionRow(
                string.concat("Paid out, ", pegged),
                exploit.recipients.length,
                0,
                "",
                exploit.paidPegged,
                pegged,
                0
            )
        );
        table = string.concat(
            table,
            _actionRow(
                string.concat("Paid out, ", leveraged),
                exploit.recipients.length,
                0,
                "",
                exploit.paidLeveraged,
                leveraged,
                0
            )
        );
        return
            string.concat(
                table,
                "\nThe rebalance paid the leveraged pool ",
                _fixed(Math.mulDiv(exploit.rebalanceLeveraged, 1 ether, exploit.leveragedPoolPegged), 4),
                " ",
                leveraged,
                " per ",
                pegged,
                ": what it minted, before the bounty, over the pegged tokens the leveraged pool gave up.\n\n"
            );
    }

    /// @dev The parties: a summary by kind of party that balances to zero, then the three positions holder by holder.
    function _partiesSections(Reading memory before, Reading memory afterwards) internal view returns (string memory) {
        return
            string.concat(
                _summarySection(before, afterwards),
                _leveragedPoolSection(before, afterwards),
                _collateralPoolSection(before, afterwards),
                _heldSection(before, afterwards),
                _holderSection(before, afterwards)
            );
    }

    function _summarySection(Reading memory before, Reading memory afterwards) internal view returns (string memory) {
        int256[6] memory totals; // held, leveraged pool, collateral pool, fee receivers, reserve pool, paid by the exploit
        for (uint256 i = 0; i < parties.length; ++i) {
            int256 change = _value(afterwards.parties[i], afterwards.prices) - _value(before.parties[i], before.prices);
            uint256 kind = _kind(parties[i].role);
            if (kind == 0) {
                totals[0] +=
                    _walletValue(afterwards.parties[i], afterwards.prices) -
                    _walletValue(before.parties[i], before.prices);
                totals[1] +=
                    _leveragedPoolValue(afterwards.parties[i], afterwards.prices) -
                    _leveragedPoolValue(before.parties[i], before.prices);
                totals[2] +=
                    _collateralPoolValue(afterwards.parties[i], afterwards.prices) -
                    _collateralPoolValue(before.parties[i], before.prices);
            } else {
                totals[kind + 2] += change;
            }
        }
        int256 contractsChange = _contractsValue(afterwards) - _contractsValue(before);
        int256 surplusChange = afterwards.minterSurplus - before.minterSurplus;
        int256 residual = totals[0] +
            totals[1] +
            totals[2] +
            totals[3] +
            totals[4] +
            totals[5] +
            contractsChange +
            surplusChange;
        uint256 bound = _booksBound(before, afterwards);
        assertLe(_abs(residual), bound, "every party's change sums to zero, to within the valuation's rounding");

        // Shown in wrapped collateral as the accounts file values each position, so each row is the sum of its rows there.
        int256[6] memory shown; // held, leveraged pool, collateral pool, fee receivers, reserve pool, paid by the exploit
        for (uint256 i = 0; i < parties.length; ++i) {
            uint256 kind = _kind(parties[i].role);
            if (kind == 0) {
                shown[0] += _wrappedChange(before, afterwards, i, 0, 3);
                shown[1] += _wrappedChange(before, afterwards, i, 3, 6);
                shown[2] += _wrappedChange(before, afterwards, i, 6, 8);
            } else {
                shown[kind + 2] += _wrappedChange(before, afterwards, i, 0, 8);
            }
        }
        Prices memory prices = before.prices;
        string memory table = string.concat(
            "## Losses and gains by party\n\n| Party | ",
            _symbol(market.wrappedCollateral),
            " |\n|---|---|\n"
        );
        table = string.concat(table, _row2("Holders: their own wallets", _exactSigned(shown[0])));
        table = string.concat(table, _row2("Holders: their leveraged pool positions", _exactSigned(shown[1])));
        table = string.concat(table, _row2("Holders: their collateral pool positions", _exactSigned(shown[2])));
        table = string.concat(
            table,
            _row2("**All holders**", string.concat("**", _exactSigned(shown[0] + shown[1] + shown[2]), "**"))
        );
        table = string.concat(table, _row2("Fee receivers", _exactSigned(shown[3])));
        table = string.concat(table, _row2("Reserve pool", _exactSigned(shown[4])));
        table = string.concat(table, _row2("Paid by the exploit", _exactSigned(shown[5])));
        table = string.concat(
            table,
            _row2("The pools' and the manager's undistributed balances", _signedWrapped(contractsChange, prices))
        );
        table = string.concat(
            table,
            _row2("The minter's collateral beyond its recorded backing", _signedWrapped(surplusChange, prices))
        );
        return
            string.concat(
                table,
                "\nThe rows sum to ",
                vm.toString(residual),
                " wei of pegged units; the valuation's rounding allows ",
                vm.toString(bound),
                ".\n\n"
            );
    }

    /// @dev The rounding the books can show: every contract, and every party whose valuation can round differently at
    ///      the two ends, valued with at most eight floored products at each end; the leveraged price floored to the
    ///      wei, which undervalues the whole leveraged supply by less than its size in 1e18 units at each end; and the
    ///      backing and the surplus floored once each, at each end. Each position is one floored product of its amount
    ///      and its token's price, so a party whose amounts are the same at both ends, and whose held positions' prices
    ///      are too, is valued the same at both ends and adds no rounding.
    function _booksBound(Reading memory before, Reading memory afterwards) internal view returns (uint256) {
        uint256 rounding;
        for (uint256 i = 0; i < parties.length; ++i) {
            uint256[8] memory amountsBefore = _amounts(before.parties[i]);
            uint256[8] memory amountsAfter = _amounts(afterwards.parties[i]);
            for (uint256 position = 0; position < 8; ++position) {
                address token = _positionToken(position);
                if (
                    amountsBefore[position] != amountsAfter[position] ||
                    (amountsBefore[position] != 0 &&
                        _priceOf(token, before.prices) != _priceOf(token, afterwards.prices))
                ) {
                    ++rounding;
                    break;
                }
            }
        }
        return 2 * 8 * (rounding + 3) + (before.leveragedSupply + afterwards.leveragedSupply) / 1 ether + 2 + 4;
    }

    /// @dev What the pools and the manager hold beyond what the parties are owed by them.
    function _contractsValue(Reading memory reading) internal pure returns (int256 value) {
        for (uint256 i = 0; i < reading.contracts.length; ++i) {
            value += _walletValue(reading.contracts[i], reading.prices);
        }
        for (uint256 i = 0; i < reading.parties.length; ++i) {
            value -=
                _leveragedPoolValue(reading.parties[i], reading.prices) +
                _collateralPoolValue(reading.parties[i], reading.prices);
        }
    }

    /// @dev 0 for a holder, 1 for a fee receiver, 2 for the reserve pool, 3 for an account the exploit paid.
    function _kind(string memory role) internal pure returns (uint256) {
        if (LibString.contains(role, "fee")) {
            return 1;
        }
        if (LibString.contains(role, "reserve pool")) {
            return 2;
        }
        if (LibString.contains(role, "paid by the exploit")) {
            return 3;
        }
        return 0;
    }

    function _leveragedPoolSection(
        Reading memory before,
        Reading memory afterwards
    ) internal view returns (string memory table) {
        table = string.concat(
            "## Leveraged stability pool, depositor by depositor\n\n| Depositor | ",
            _symbol(market.pegged),
            " deposit | ",
            _symbol(market.leveraged),
            " owed | ",
            _symbol(market.wrappedCollateral),
            " owed | Net ",
            _symbol(market.wrappedCollateral),
            " |\n|---|---|---|---|---|\n"
        );
        int256 total;
        for (uint256 i = 0; i < parties.length; ++i) {
            Holding memory b = before.parties[i];
            Holding memory a = afterwards.parties[i];
            int256 change = _wrappedChange(before, afterwards, i, 3, 6);
            if (change == 0 && b.leveragedPoolDeposit == a.leveragedPoolDeposit) {
                continue;
            }
            total += change;
            table = string.concat(
                table,
                _row5(
                    _name(i),
                    _exactSigned(int256(a.leveragedPoolDeposit) - int256(b.leveragedPoolDeposit)),
                    _exactSigned(int256(a.leveragedPoolLeveraged) - int256(b.leveragedPoolLeveraged)),
                    _exactSigned(int256(a.leveragedPoolWrapped) - int256(b.leveragedPoolWrapped)),
                    _exactSigned(change)
                )
            );
        }
        table = string.concat(
            table,
            _row5("**All depositors found**", "", "", "", string.concat("**", _exactSigned(total), "**")),
            "\n"
        );
    }

    function _collateralPoolSection(
        Reading memory before,
        Reading memory afterwards
    ) internal view returns (string memory table) {
        table = string.concat(
            "## Collateral stability pool, depositor by depositor\n\n| Depositor | ",
            _symbol(market.pegged),
            " deposit | ",
            _symbol(market.wrappedCollateral),
            " owed | Net ",
            _symbol(market.wrappedCollateral),
            " |\n|---|---|---|---|\n"
        );
        int256 total;
        for (uint256 i = 0; i < parties.length; ++i) {
            Holding memory b = before.parties[i];
            Holding memory a = afterwards.parties[i];
            int256 change = _wrappedChange(before, afterwards, i, 6, 8);
            if (change == 0 && b.collateralPoolDeposit == a.collateralPoolDeposit) {
                continue;
            }
            total += change;
            table = string.concat(
                table,
                _row4(
                    _name(i),
                    _exactSigned(int256(a.collateralPoolDeposit) - int256(b.collateralPoolDeposit)),
                    _exactSigned(int256(a.collateralPoolWrapped) - int256(b.collateralPoolWrapped)),
                    _exactSigned(change)
                )
            );
        }
        table = string.concat(
            table,
            _row4("**All depositors found**", "", "", string.concat("**", _exactSigned(total), "**")),
            "\n"
        );
    }

    function _heldSection(
        Reading memory before,
        Reading memory afterwards
    ) internal view returns (string memory table) {
        table = string.concat(
            "## ",
            _symbol(market.leveraged),
            " held outside the pools\n\n| Holder | ",
            _symbol(market.leveraged),
            " held before | Net ",
            _symbol(market.wrappedCollateral),
            " |\n|---|---|---|\n"
        );
        int256 total;
        uint256 held;
        for (uint256 i = 0; i < parties.length; ++i) {
            uint256 leveraged = before.parties[i].leveraged;
            if (leveraged == 0 || _kind(parties[i].role) != 0) {
                continue;
            }
            int256 change = _wrappedChange(before, afterwards, i, 2, 3);
            total += change;
            held += leveraged;
            table = string.concat(table, _row3(_name(i), _exact(leveraged), _exactSigned(change)));
        }
        table = string.concat(
            table,
            _row3(
                "**All holders**",
                string.concat("**", _exact(held), "**"),
                string.concat("**", _exactSigned(total), "**")
            ),
            "\n"
        );
    }

    function _holderSection(
        Reading memory before,
        Reading memory afterwards
    ) internal view returns (string memory table) {
        string memory wrapped = _symbol(market.wrappedCollateral);
        table = string.concat(
            "## Every party, all positions together\n\nIn ",
            wrapped,
            ". Parties whose holdings did not change are left out.\n\n| Party | Role | Own wallet | Leveraged pool | Collateral pool | Total |\n|---|---|---|---|---|---|\n"
        );
        for (uint256 i = 0; i < parties.length; ++i) {
            int256 wallet = _wrappedChange(before, afterwards, i, 0, 3);
            int256 leveragedPool = _wrappedChange(before, afterwards, i, 3, 6);
            int256 collateralPool = _wrappedChange(before, afterwards, i, 6, 8);
            if (wallet == 0 && leveragedPool == 0 && collateralPool == 0) {
                continue;
            }
            string[] memory cells = new string[](6);
            cells[0] = string.concat("`", vm.toString(parties[i].account), "`");
            cells[1] = parties[i].role;
            cells[2] = _exactSigned(wallet);
            cells[3] = _exactSigned(leveragedPool);
            cells[4] = _exactSigned(collateralPool);
            cells[5] = _exactSigned(wallet + leveragedPool + collateralPool);
            table = string.concat(table, _row(cells));
        }
        table = string.concat(table, "\n");
    }

    /// @dev The change in value of party `party`'s positions `from` up to `to`, in wrapped collateral, as the accounts
    ///      file values each position.
    function _wrappedChange(
        Reading memory before,
        Reading memory afterwards,
        uint256 party,
        uint256 from,
        uint256 to
    ) internal view returns (int256 change) {
        uint256[8] memory amountsBefore = _amounts(before.parties[party]);
        uint256[8] memory amountsAfter = _amounts(afterwards.parties[party]);
        for (uint256 position = from; position < to; ++position) {
            change +=
                _positionWrappedValue(position, amountsAfter[position], afterwards.prices) -
                _positionWrappedValue(position, amountsBefore[position], before.prices);
        }
    }

    /// @dev A position's value in wrapped collateral: its own amount, for wrapped collateral; otherwise its amount at the
    ///      token's price over the wrapped collateral's price, floored to the wei.
    function _positionWrappedValue(
        uint256 position,
        uint256 amount,
        Prices memory prices
    ) internal view returns (int256) {
        address token = _positionToken(position);
        if (token == market.wrappedCollateral) {
            return int256(amount);
        }
        return int256(Math.mulDiv(amount, _priceOf(token, prices), prices.wrapped));
    }

    /// @dev The caller's gain, flow by flow, checked against what it paid out of the market.
    function _callerSection(
        Transaction memory exploit,
        Reading memory before,
        Reading memory afterwards
    ) internal view returns (string memory) {
        Prices memory b = before.prices;
        Prices memory a = afterwards.prices;
        int256[7] memory flows;
        flows[0] = -int256(Math.mulDiv(exploit.callerPoolLoss, b.pegged, 1 ether));
        flows[1] = int256(
            Math.mulDiv(exploit.claimedLeveraged, a.leveraged, 1 ether) +
                Math.mulDiv(exploit.claimedWrapped, a.wrapped, 1 ether)
        );
        flows[2] = int256(
            Math.mulDiv(exploit.bountyWrapped, a.wrapped, 1 ether) +
                Math.mulDiv(exploit.bountyLeveraged, a.leveraged, 1 ether)
        );
        flows[3] = -int256(Math.mulDiv(exploit.callerLeveragedAtRebalance, b.leveraged - a.leveraged, 1 ether));
        flows[4] = -int256(Math.mulDiv(exploit.earlyWithdrawalFee, a.pegged, 1 ether));
        flows[5] = -int256(Math.mulDiv(_mintingAndRedemptionFees(exploit), b.wrapped, 1 ether));
        flows[6] = int256(Math.mulDiv(exploit.reservePaid, b.wrapped, 1 ether));
        int256 sum = flows[0] + flows[1] + flows[2] + flows[3] + flows[4] + flows[5] + flows[6];
        int256 proceeds = int256(
            Math.mulDiv(exploit.paidWrapped, a.wrapped, 1 ether) +
                Math.mulDiv(exploit.paidPegged, a.pegged, 1 ether) +
                Math.mulDiv(exploit.paidLeveraged, a.leveraged, 1 ether)
        );
        uint256 bound = _callerBound(exploit);
        assertLe(
            _abs(sum - proceeds),
            bound,
            "the caller's flows sum to what it paid out, to within its trades' rounding"
        );

        string memory leveraged = _symbol(market.leveraged);
        string memory table = string.concat(
            "## The caller's gain, flow by flow\n\n| Flow | ",
            _symbol(market.wrappedCollateral),
            " |\n|---|---|\n"
        );
        table = string.concat(
            table,
            _row2(
                string.concat(
                    "Leveraged pool: ",
                    _exact(exploit.callerPoolLoss),
                    " ",
                    _symbol(market.pegged),
                    " taken by the rebalance"
                ),
                _signedWrapped(flows[0], b)
            )
        );
        table = string.concat(
            table,
            _row2(
                string.concat(
                    "Leveraged pool: ",
                    _exact(exploit.claimedLeveraged),
                    " ",
                    leveraged,
                    " claimed, at the price after"
                ),
                _signedWrapped(flows[1], b)
            )
        );
        table = string.concat(table, _row2("Rebalance bounty", _signedWrapped(flows[2], b)));
        table = string.concat(
            table,
            _row2(
                string.concat(
                    "Its own ",
                    _exact(exploit.callerLeveragedAtRebalance),
                    " ",
                    leveraged,
                    " held through the rebalance"
                ),
                _signedWrapped(flows[3], b)
            )
        );
        table = string.concat(table, _row2("Early-withdrawal fee", _signedWrapped(flows[4], b)));
        table = string.concat(table, _row2("Minting and redemption fees", _signedWrapped(flows[5], b)));
        table = string.concat(table, _row2("Paid by the reserve pool", _signedWrapped(flows[6], b)));
        table = string.concat(table, _row2("**Sum**", string.concat("**", _signedWrapped(sum, b), "**")));
        table = string.concat(
            table,
            _row2("**Paid out by the exploit**", string.concat("**", _signedWrapped(proceeds, b), "**"))
        );
        return
            string.concat(
                table,
                "\nThe two differ by ",
                vm.toString(sum - proceeds),
                " wei of pegged units; the trades' rounding allows ",
                vm.toString(bound),
                ".\n\n"
            );
    }

    function _mintingAndRedemptionFees(Transaction memory exploit) internal pure returns (uint256) {
        return
            exploit.mintLeveraged.fees +
            exploit.mintPegged.fees +
            exploit.redeemLeveragedBefore.fees +
            exploit.redeemLeveragedAfter.fees +
            exploit.redeemPegged.fees;
    }

    /// @dev The rounding the caller's flows can show: each of its minter trades floors what it pays and what it gets,
    ///      each of the seven flows is at most two floored products and the payout three, and the leveraged price is
    ///      floored to the wei, which misprices the leveraged tokens it traded, claimed, held and paid out by less than
    ///      their amount in 1e18 units.
    function _callerBound(Transaction memory exploit) internal pure returns (uint256) {
        uint256 trades = exploit.mintLeveraged.count +
            exploit.mintPegged.count +
            exploit.redeemLeveragedBefore.count +
            exploit.redeemLeveragedAfter.count +
            exploit.redeemPegged.count;
        uint256 leveragedTraded = exploit.mintLeveraged.tokensOut +
            exploit.redeemLeveragedBefore.tokensIn +
            exploit.redeemLeveragedAfter.tokensIn +
            exploit.claimedLeveraged +
            exploit.bountyLeveraged +
            exploit.callerLeveragedAtRebalance +
            exploit.paidLeveraged;
        return 2 * trades + 2 * 7 + 3 + leveragedTraded / 1 ether + 1;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Every account, in wei
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev One row per account, position and token whose amount or value changed: the amounts the contracts report
    ///      before and after the transaction and the change, in wei; and the change in value, in pegged-unit wei and in
    ///      wrapped-collateral wei, valued as `_header` states.
    function _accountsCsv(Reading memory before, Reading memory afterwards) internal view returns (string memory csv) {
        csv = ACCOUNTS_HEADER;
        for (uint256 i = 0; i < parties.length; ++i) {
            for (uint256 position = 0; position < 8; ++position) {
                csv = string.concat(csv, _accountRow(before, afterwards, i, position));
            }
        }
    }

    /// @dev Party `party`'s row for `position`, or nothing if neither its amount nor its value changed.
    function _accountRow(
        Reading memory before,
        Reading memory afterwards,
        uint256 party,
        uint256 position
    ) internal view returns (string memory) {
        uint256 amountBefore = _amounts(before.parties[party])[position];
        uint256 amountAfter = _amounts(afterwards.parties[party])[position];
        address token = _positionToken(position);
        int256 peggedChange = int256(Math.mulDiv(amountAfter, _priceOf(token, afterwards.prices), 1 ether)) -
            int256(Math.mulDiv(amountBefore, _priceOf(token, before.prices), 1 ether));
        if (amountAfter == amountBefore && peggedChange == 0) {
            return "";
        }
        int256 wrappedChange = _positionWrappedValue(position, amountAfter, afterwards.prices) -
            _positionWrappedValue(position, amountBefore, before.prices);
        return
            string.concat(
                _accountFields(party, position, amountBefore, amountAfter),
                vm.toString(peggedChange),
                ",",
                vm.toString(wrappedChange),
                "\n"
            );
    }

    /// @dev The first seven fields of an account's row, each followed by a comma.
    function _accountFields(
        uint256 party,
        uint256 position,
        uint256 amountBefore,
        uint256 amountAfter
    ) internal view returns (string memory) {
        string[8] memory positions = [
            string("wallet"),
            "wallet",
            "wallet",
            "leveraged pool deposit",
            "leveraged pool reward",
            "leveraged pool reward",
            "collateral pool deposit",
            "collateral pool reward"
        ];
        return
            string.concat(
                string.concat(
                    vm.toString(parties[party].account),
                    ',"',
                    parties[party].role,
                    '",',
                    positions[position]
                ),
                string.concat(",", _symbol(_positionToken(position)), ",", vm.toString(amountBefore), ","),
                string.concat(
                    vm.toString(amountAfter),
                    ",",
                    vm.toString(int256(amountAfter) - int256(amountBefore)),
                    ","
                )
            );
    }

    /// @dev A holding's eight amounts, in the order `_positionToken` and `_accountFields` name them.
    function _amounts(Holding memory holding) internal pure returns (uint256[8] memory) {
        return
            [
                holding.wrapped,
                holding.pegged,
                holding.leveraged,
                holding.leveragedPoolDeposit,
                holding.leveragedPoolWrapped,
                holding.leveragedPoolLeveraged,
                holding.collateralPoolDeposit,
                holding.collateralPoolWrapped
            ];
    }

    function _positionToken(uint256 position) internal view returns (address) {
        if (position == 0 || position == 4 || position == 7) {
            return market.wrappedCollateral;
        }
        if (position == 2 || position == 5) {
            return market.leveraged;
        }
        return market.pegged;
    }

    function _priceOf(address token, Prices memory prices) internal view returns (uint256) {
        if (token == market.wrappedCollateral) {
            return prices.wrapped;
        }
        if (token == market.leveraged) {
            return prices.leveraged;
        }
        return prices.pegged;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The new contracts
    // ---------------------------------------------------------------------------------------------------------------

    function _newContractsHeader() internal view returns (string memory) {
        string memory market_ = _marketLabel();
        return
            string.concat(
                string.concat(
                    "# The new contracts against the rebalance dilution exploit of ",
                    IMarketConfig(address(exploitedMarket)).peg(),
                    "::",
                    IMarketConfig(address(exploitedMarket)).collateral(),
                    ", 2026-10-16\n\n",
                    "Generated by `script/verify/incidents/RebalanceDilutionReport.t.sol`; run ",
                    "`script/verify/incidents/run-rebalance-dilution-report` to regenerate. Do not edit by hand. ",
                    "The explanation is in [README.md](README.md); the exploit's own figures are in [",
                    market_,
                    "-figures.md](",
                    market_,
                    "-figures.md), whose conventions these follow.\n\n"
                ),
                string.concat(
                    "On a fork at transaction `",
                    vm.toString(exploitTransaction()),
                    "`, block ",
                    vm.toString(block.number),
                    ", just before the exploit, the market is upgraded to Minter_v3, StabilityPool_v3 and ",
                    "StabilityPoolManager_v2 by `UpgradeMarketToV3.upgradeMarketsToV3` - the function ",
                    "`script/Upgrade_MarketsToV3_mainnet.s.sol` runs - with the holder capture at the exploit's block. ",
                    "Its pools are StabilityPool_v3 with StabilityPool_v2's claim functions put back ",
                    "(`StabilityPool_v3WithV2Claims`), because the exploit calls them.\n\n"
                )
            );
    }

    /// @dev Reports the pools' gaps, the holders migrated and the market's figures under each minter, once
    ///      `_assertUpgradeKept` has checked the upgrade moved no token.
    function _upgradeSection(Reading memory before, Reading memory upgraded) internal view returns (string memory) {
        uint256[2] memory supplies = [
            IStabilityPool(market.leveragedPool).totalAssetSupply(),
            IStabilityPool(market.collateralPool).totalAssetSupply()
        ];
        int256[2] memory gaps = [before.leveragedPoolGap, before.collateralPoolGap];
        (uint256 changed, uint256 largest) = _assertUpgradeKept(before, upgraded, supplies, gaps);
        string memory table = string.concat(
            _upgradedPoolsTable(supplies, gaps),
            "\nEvery party's wallet balances and pool deposits, and everything the pools and the manager hold, read the "
            "same after the upgrade as before it. The upgrader copies each holder's settled reward exactly. A reward "
            "still streaming is divided by what the holders hold - the supply less the gap - where StabilityPool_v2 "
            "divided by the supply, so it may read up to that share more, plus a wei of rounding: ",
            vm.toString(changed),
            " rewards read differently, by at most ",
            vm.toString(largest),
            " wei.\n\n"
        );
        return string.concat(table, _upgradedMarketTable(before, upgraded));
    }

    /// @dev Each pool's holders migrated from the capture, its supply and the ledger gap the upgrade seeded.
    function _upgradedPoolsTable(
        uint256[2] memory supplies,
        int256[2] memory gaps
    ) internal view returns (string memory) {
        string memory pegged = _symbol(market.pegged);
        uint256 leveragedHolders = HolderCaptureLib
            .holders(
                _captureDirectory(),
                productionRun.stabilityPoolKey(exploitedMarket, HarborDeployer.StabilityPoolType.Leveraged)
            )
            .length;
        uint256 collateralHolders = HolderCaptureLib
            .holders(
                _captureDirectory(),
                productionRun.stabilityPoolKey(exploitedMarket, HarborDeployer.StabilityPoolType.Collateral)
            )
            .length;
        return
            string.concat(
                "## The upgrade\n\n| | Leveraged pool | Collateral pool |\n|---|---|---|\n",
                _row3(
                    "Holders migrated, from the capture",
                    vm.toString(leveragedHolders),
                    vm.toString(collateralHolders)
                ),
                _row3(string.concat("Supply, wei of ", pegged), vm.toString(supplies[0]), vm.toString(supplies[1])),
                _row3(string.concat("Ledger gap seeded, wei of ", pegged), vm.toString(gaps[0]), vm.toString(gaps[1]))
            );
    }

    /// @dev Asserts the upgrade moved no token: every party's and every contract's wallet balances and pool deposits
    ///      read the same after it as before, and each pool reward the same to within `_rewardBound`. Returns how many
    ///      rewards read differently, and the largest difference.
    function _assertUpgradeKept(
        Reading memory before,
        Reading memory upgraded,
        uint256[2] memory supplies,
        int256[2] memory gaps
    ) internal view returns (uint256 changed, uint256 largest) {
        assertEq(
            keccak256(abi.encode(upgraded.contracts)),
            keccak256(abi.encode(before.contracts)),
            "the upgrade moves nothing the pools and the manager hold"
        );
        for (uint256 i = 0; i < parties.length; ++i) {
            uint256[8] memory was = _amounts(before.parties[i]);
            uint256[8] memory is_ = _amounts(upgraded.parties[i]);
            for (uint256 position = 0; position < 8; ++position) {
                if (position == 4 || position == 5 || position == 7) {
                    uint256 difference = _abs(int256(is_[position]) - int256(was[position]));
                    assertLe(
                        difference,
                        position == 7
                            ? _rewardBound(is_[position], gaps[1], supplies[1])
                            : _rewardBound(is_[position], gaps[0], supplies[0]),
                        _positionLabel(i, position)
                    );
                    if (difference > 0) {
                        ++changed;
                        largest = Math.max(largest, difference);
                    }
                } else {
                    assertEq(is_[position], was[position], _positionLabel(i, position));
                }
            }
        }
    }

    /// @dev How far the upgrade can move a pool reward reading `reward` after it. The upgrader copies each holder's
    ///      settled reward exactly. v3 divides a stream not yet settled by what the holders hold - the supply less the
    ///      ledger gap - where v2 divided by the supply, which moves a holder's share of it by at most the gap over
    ///      that divisor, rounded up; and each version floors the share once, which adds a wei.
    function _rewardBound(uint256 reward, int256 gap, uint256 supply) internal pure returns (uint256) {
        return Math.mulDiv(reward, _abs(gap), uint256(int256(supply) - gap), Math.Rounding.Ceil) + 1;
    }

    /// @dev The upgrade check's message for party `party`'s position `position`.
    function _positionLabel(uint256 party, uint256 position) internal view returns (string memory) {
        return
            string.concat(
                "the upgrade keeps ",
                vm.toString(parties[party].account),
                "'s position ",
                vm.toString(position)
            );
    }

    /// @dev The market's figures under Minter_v2 just before the upgrade, and under Minter_v3 just after it.
    function _upgradedMarketTable(
        Reading memory before,
        Reading memory upgraded
    ) internal view returns (string memory) {
        string memory leveraged = _symbol(market.leveraged);
        return
            string.concat(
                "| | Minter_v2 | Minter_v3 |\n|---|---|---|\n",
                _row3(
                    string.concat("1 ", leveraged, " in pegged units"),
                    _exact(before.prices.leveraged),
                    _exact(upgraded.prices.leveraged)
                ),
                _row3(
                    string.concat("1 ", _symbol(market.pegged), " in pegged units"),
                    _exact(before.prices.pegged),
                    _exact(upgraded.prices.pegged)
                ),
                _row3(
                    "Collateral backing (underlying)",
                    _exact(before.collateralBacking),
                    _exact(upgraded.collateralBacking)
                ),
                _row3("Collateral ratio", _fixed(before.collateralRatio, 4), _fixed(upgraded.collateralRatio, 4)),
                "\n"
            );
    }

    function _replaySection() internal view returns (string memory) {
        string memory market_ = _marketLabel();
        return
            string.concat(
                "## The exploit's transaction on the upgraded market\n\n",
                "Replayed on the upgraded market, the transaction leaves every holding, price and supply exactly as it ",
                "found them. On the new contracts the exploit changes nothing, so each ",
                "account's correction takes it back to what it held just before the exploit: the reverse of its change ",
                "in [",
                market_,
                "-accounts.csv](",
                market_,
                "-accounts.csv).\n\n"
            );
    }

    function _ownCapitalSection(
        Transaction memory exploit,
        Outcome memory outcome
    ) internal view returns (string memory) {
        string memory wrapped = _symbol(market.wrappedCollateral);
        string memory intro = string.concat(
            "## Without a flash loan\n\nThe exploit borrowed ",
            _exact(exploit.borrowed),
            " ",
            wrapped,
            " for the length of its transaction, and had to repay it. The same attack with that much of its own ",
            "capital has nothing to repay. The rebuilt attacker that the exploit's figures run the mitigations with ",
            "runs it here, on the upgraded market: the exploit's mints, in order; its pegged deposit in the leveraged ",
            "pool; leveraged redemptions down to its target collateral ratio, or until the minter redeems no more; the ",
            "rebalance; and everything turned back into "
        );
        intro = string.concat(
            intro,
            wrapped,
            ". The tables after this one are the exploit's tables, for this attack; the attacker is the party \"",
            OWN_CAPITAL_ATTACKER,
            '".\n\n| | |\n|---|---|\n'
        );
        intro = string.concat(
            intro,
            _row2("Rebalanced", outcome.rebalance.rebalanced ? "yes" : "no"),
            _row2("Collateral ratio at the rebalance", _fixed(outcome.rebalance.collateralRatio, 4)),
            _row2(
                string.concat(_symbol(market.pegged), " the rebalance converted"),
                _exact(outcome.rebalance.peggedConverted)
            )
        );
        intro = string.concat(
            intro,
            _row2(
                string.concat(_symbol(market.leveraged), " it minted for them"),
                _exact(outcome.rebalance.leveragedMinted)
            ),
            _row2(
                "1 leveraged token in pegged units, before / after the attack",
                string.concat(_exact(outcome.leveragedPriceBefore), " / ", _exact(outcome.leveragedPriceAfter))
            )
        );
        return
            string.concat(
                intro,
                _row2(
                    string.concat("The attacker's gain, ", wrapped, ", as the mitigation table measures it"),
                    _exactSigned(outcome.attackerGain)
                ),
                "\n"
            );
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Mitigations
    // ---------------------------------------------------------------------------------------------------------------

    function _mitigationSection(
        uint256 beforeExploit,
        Transaction memory exploit
    ) internal returns (string memory table) {
        vm.revertToState(beforeExploit);
        uint256 deployedFee = IStabilityPool(market.leveragedPool).getEarlyWithdrawalFee();
        uint256 leveragedPriceBefore = IMinter(market.minter).leveragedTokenPrice();
        table = string.concat(
            "## Mitigations\n\nEach row starts from the state before the exploit. The replay runs the exploit's own ",
            "transaction, and pays out what reaches the accounts the exploit paid; the rebuilt attacker ",
            "(`test/deployment/RebalanceDilutionFork.sol`) makes the exploit's own mints with the wrapped collateral it ",
            "borrowed and pursues the same goal against the mitigated market. Gains in ",
            _symbol(market.wrappedCollateral),
            "; the fair amount is the pegged converted over the leveraged price at the rebalance.\n\n",
            "| Mitigation | Replay pays out | Attacker's gain | Collateral ratio at the rebalance | Pegged converted | Leveraged minted | Fair amount | Leveraged price after, in pegged units |\n",
            "|---|---|---|---|---|---|---|---|\n"
        );
        int256[5] memory gains;
        for (uint256 m = 0; m <= uint256(Mitigation.WithdrawalFeeOpenWindow); ++m) {
            string memory replay = "not replayed";
            if (m != uint256(Mitigation.MinterV3) && m != uint256(Mitigation.WithdrawalFeeOpenWindow)) {
                vm.revertToState(beforeExploit);
                _install(Mitigation(m));
                replay = _exactSigned(_replay(exploit.recipients));
            }
            vm.revertToState(beforeExploit);
            _install(Mitigation(m));
            Outcome memory outcome = _attack(Mitigation(m), exploit);
            gains[m] = outcome.attackerGain;
            table = string.concat(table, _mitigationRow(Mitigation(m), replay, outcome));
        }
        vm.revertToState(beforeExploit);
        assertGt(gains[uint256(Mitigation.AsDeployed)], 0, "the attack pays on the market as deployed");
        assertLt(
            gains[uint256(Mitigation.WithdrawalFee)],
            gains[uint256(Mitigation.AsDeployed)],
            "the larger fee costs"
        );
        // The fee is a share of what is withdrawn, so the attacker's gain falls in a straight line with it: the line
        // through the deployed fee and the larger one crosses zero at the break-even.
        uint256 breakEven = deployedFee +
            Math.mulDiv(
                uint256(gains[uint256(Mitigation.AsDeployed)]),
                EARLY_WITHDRAWAL_FEE - deployedFee,
                uint256(gains[uint256(Mitigation.AsDeployed)] - gains[uint256(Mitigation.WithdrawalFee)])
            );
        table = string.concat(
            table,
            "\nThe early-withdrawal fee at which the attacker, withdrawing normally, breaks even: ",
            _fixed(breakEven * 100, 2),
            "% (the deployed fee is ",
            _fixed(deployedFee * 100, 2),
            "%). The leveraged price before the exploit was ",
            _exact(leveragedPriceBefore),
            " pegged units.\n\n"
        );
    }

    function _install(Mitigation mitigation) internal {
        if (mitigation == Mitigation.MinterV3) {
            _upgradeToMinterV3();
        } else if (mitigation == Mitigation.RedemptionFloor) {
            _refuseLeveragedRedemptionBelow(REDEMPTION_FLOOR);
        } else if (mitigation == Mitigation.WithdrawalFee || mitigation == Mitigation.WithdrawalFeeOpenWindow) {
            _setEarlyWithdrawalFee(EARLY_WITHDRAWAL_FEE);
        }
    }

    /// @dev The rebuilt attacker, making the exploit's own mints with the wrapped collateral it borrowed.
    function _attack(Mitigation mitigation, Transaction memory exploit) internal returns (Outcome memory) {
        address attacker = address(new RebalanceDilutionAttacker(market, exploit.mints));
        address poolAccount = attacker;
        if (mitigation == Mitigation.WithdrawalFeeOpenWindow) {
            poolAccount = address(new OpenWindowWithdrawer(market.leveragedPool));
            _openWithdrawalWindow(poolAccount);
        }
        return _runAttack(attacker, poolAccount, exploit.borrowed);
    }

    function _mitigationRow(
        Mitigation mitigation,
        string memory replay,
        Outcome memory outcome
    ) internal pure returns (string memory) {
        string[5] memory names = [
            string("As deployed"),
            "Minter_v3, with the manager and both pools",
            "Leveraged redemption refused below a collateral ratio of 1.10",
            "Early-withdrawal fee of 5%, withdrawing normally",
            "Early-withdrawal fee of 5%, through an open withdrawal window"
        ];
        string[] memory cells = new string[](8);
        cells[0] = names[uint256(mitigation)];
        cells[1] = replay;
        cells[2] = _exactSigned(outcome.attackerGain);
        cells[3] = _fixed(outcome.rebalance.collateralRatio, 4);
        cells[4] = _exact(outcome.rebalance.peggedConverted);
        cells[5] = _exact(outcome.rebalance.leveragedMinted);
        cells[6] = _exact(Math.mulDiv(outcome.rebalance.peggedConverted, 1 ether, outcome.rebalance.leveragedPrice));
        cells[7] = _exact(outcome.leveragedPriceAfter);
        return _row(cells);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Every market
    // ---------------------------------------------------------------------------------------------------------------

    function _marketsSection(uint256 beforeExploit) internal returns (string memory table) {
        vm.revertToState(beforeExploit);
        table = string.concat(
            "## Every market at the exploit's block\n\nA rebalance at a collateral ratio of 20/19 or below pays the ",
            "leveraged pool ",
            vm.toString(LEVERAGE_RATIO_CAP),
            " leveraged tokens per pegged token. That overpays by ",
            vm.toString(LEVERAGE_RATIO_CAP),
            " times the leveraged price, wherever the price is above 1/",
            vm.toString(LEVERAGE_RATIO_CAP),
            '. A band refused "below" a ratio refuses that action there.\n\n',
            "| Market | Rebalance threshold | Pegged mint refused below | Leveraged redemption refused below | Next leveraged redemption bound | Leveraged price, in pegged units | Leveraged holders' value, in pegged units | Overpayment at 20/19 |\n",
            "|---|---|---|---|---|---|---|---|\n"
        );
        table = string.concat(
            table,
            _pegRows(btcMintersConfig),
            _pegRows(ethMintersConfig),
            _pegRows(eurMintersConfig)
        );
        table = string.concat(
            table,
            _pegRows(goldMintersConfig),
            _pegRows(mcapMintersConfig),
            _pegRows(silverMintersConfig),
            "\n"
        );
    }

    function _pegRows(
        function() returns (ConfigPeg, Config_MinterMarket[] memory) configs
    ) internal returns (string memory rows) {
        (, Config_MinterMarket[] memory markets) = configs();
        for (uint256 i = 0; i < markets.length; ++i) {
            rows = string.concat(rows, _marketRow(markets[i]));
        }
    }

    function _marketRow(Config_MinterMarket config) internal returns (string memory) {
        MarketAddresses memory addresses = productionRun.marketAddresses(config);
        IMinter.Config memory bands = IMinter(addresses.minter).config();
        uint256 price = IMinter(addresses.minter).leveragedTokenPrice();
        uint256 supply = IMinter(addresses.minter).leveragedTokenBalance();
        string[] memory cells = new string[](8);
        cells[0] = string.concat(
            IMarketConfig(address(config)).peg(),
            "::",
            IMarketConfig(address(config)).collateral()
        );
        cells[1] = _fixed(IStabilityPoolManager(addresses.manager).rebalanceThreshold(), 4);
        cells[2] = _refusedBelow(bands.mintPeggedIncentiveConfig);
        cells[3] = _refusedBelow(bands.redeemLeveragedIncentiveConfig);
        cells[4] = bands.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds.length > 1
            ? _fixed(bands.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[1], 4)
            : "none";
        cells[5] = supply == 0 ? "no leveraged tokens" : _exact(price);
        cells[6] = _exact(Math.mulDiv(supply, price, 1 ether));
        cells[7] = supply == 0 || price * LEVERAGE_RATIO_CAP <= 1 ether
            ? "none"
            : string.concat(_fixed(price * LEVERAGE_RATIO_CAP, 2), " times");
        return _row(cells);
    }

    function _refusedBelow(IMinter.IncentiveConfig memory incentive) internal pure returns (string memory) {
        return
            incentive.incentiveRatios[0] == 1 ether ? _fixed(incentive.collateralRatioBandUpperBounds[0], 4) : "never";
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Every holder, from the exploit to the pause
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Follows every holder from just before the exploit to the pause, into `<market>-holders.md`. Each party is
    ///         read just before the exploit's transaction, just after it, at the end of every later block before the
    ///         pause in which the market's minter, pools, manager, pegged or leveraged token or genesis contract logged
    ///         anything, and at the end of the block before the pause. What each did in between is decoded from those
    ///         logs, captured from Etherscan. The parties are everyone the holder capture at the pause lists, the fee
    ///         receivers, the reserve pool, the accounts the exploit paid, and each genesis participant with an
    ///         unclaimed share: the genesis contract holds their tokens, so each is followed for its own claim.
    ///
    ///         It checks before writing: at every reading, `_read`'s checks (the parties hold the pegged and leveraged
    ///         supplies, and each pool's deposits to within the capture rule); between readings, every party's pegged
    ///         and leveraged wallet change is the net of its captured transfers, and a party's pool deposit changes only
    ///         where that pool logged something; at every reading, the unclaimed genesis claims are what the genesis
    ///         contract holds, less its rounding; and at the pause block, the minter and both pools are behind the
    ///         pauser, and the only logs are the pause's own.
    function test_writeHolders() public {
        // Everything the deploy run and the market's configuration answer is asked here: both live on the fork, which
        // moves to later blocks below.
        History memory history;
        history.name = string.concat(
            IMarketConfig(address(exploitedMarket)).peg(),
            "::",
            IMarketConfig(address(exploitedMarket)).collateral()
        );
        history.label = _marketLabel();
        history.peggedSymbol = _symbol(market.pegged);
        history.leveragedSymbol = _symbol(market.leveraged);
        history.wrappedSymbol = _symbol(market.wrappedCollateral);
        history.genesis = productionRun.genesisAddress(exploitedMarket);
        history.contracts = JsonParser.parseProxies(vm.readFile(STATE_FILE));

        Transaction memory exploit = _decodeExploit();
        _findParties(exploit.recipients);
        history.atTheExploit = parties.length;
        string memory endCapture = string.concat(DIRECTORY, "holders-", vm.toString(PAUSE_BLOCK), "/");
        assertEq(HolderCaptureLib.captureBlock(endCapture), PAUSE_BLOCK, "the holder capture is at the pause");
        _addCapturedHolders(endCapture);
        history.atThePause = parties.length;

        string memory genesisCapture = string.concat(DIRECTORY, GENESIS_LOG_CAPTURE);
        (, uint256 genesisCaptureEnd) = LogCaptureLib.captureRange(genesisCapture);
        assertEq(genesisCaptureEnd, PAUSE_BLOCK, "the genesis log capture ends at the pause");
        LogCaptureLib.CapturedLog[] memory genesisLogs = LogCaptureLib.logs(
            genesisCapture,
            productionRun.genesisKey(exploitedMarket)
        );
        history.genesisParticipants = _addGenesisParticipants(history.genesis, genesisLogs);
        for (uint256 i = 0; i < parties.length; ++i) {
            for (uint256 c = 0; c < history.contracts.length; ++c) {
                if (history.contracts[c].proxy == parties[i].account) {
                    _addRole(parties[i].account, history.contracts[c].id);
                }
            }
        }
        history.logs = _marketLogs(genesisLogs);

        // A pool's capture lists every account whose deposit there ever changed, up to the pause: only those can hold a
        // deposit or a reward in it, so the others' positions there are zero and are not read.
        address[] memory leveragedPoolDepositors = HolderCaptureLib.holders(
            endCapture,
            productionRun.stabilityPoolKey(exploitedMarket, HarborDeployer.StabilityPoolType.Leveraged)
        );
        address[] memory collateralPoolDepositors = HolderCaptureLib.holders(
            endCapture,
            productionRun.stabilityPoolKey(exploitedMarket, HarborDeployer.StabilityPoolType.Collateral)
        );
        for (uint256 i = 0; i < parties.length; ++i) {
            parties[i].outsideLeveragedPool = !_contains(leveragedPoolDepositors, parties[i].account);
            parties[i].outsideCollateralPool = !_contains(collateralPoolDepositors, parties[i].account);
        }

        _readHistory(history);
        _checkHistory(history);
        history.actions = _holderActions(history);
        vm.writeFile(
            string.concat(DIRECTORY, history.label, "-holders.md"),
            string.concat(
                _holdersHeader(history),
                _holdersMarketSection(history),
                _holdersSummarySection(history),
                _holdersRewardsSection(history),
                _holderSections(history)
            )
        );
    }

    /// @dev Adds each genesis participant with an unclaimed share as a party, and returns how many accounts were ever
    ///      given a share: every receiver of a genesis deposit.
    function _addGenesisParticipants(
        address genesis,
        LogCaptureLib.CapturedLog[] memory logs
    ) internal returns (uint256) {
        address[] memory participants = new address[](0);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == IGenesis.Deposit.selector) {
                participants = _include(participants, address(uint160(uint256(logs[i].topics[2]))));
            }
        }
        for (uint256 i = 0; i < participants.length; ++i) {
            (uint256 pegged, uint256 leveraged) = IGenesis(genesis).claimable(participants[i]);
            if (pegged > 0 || leveraged > 0) {
                _addRole(participants[i], "genesis participant, unclaimed");
            }
        }
        return participants.length;
    }

    /// @dev Every captured log of the market's minter, pools, manager, pegged and leveraged tokens and of `genesisLogs`
    ///      from the exploit's block on, in block and log order.
    function _marketLogs(
        LogCaptureLib.CapturedLog[] memory genesisLogs
    ) internal view returns (LogCaptureLib.CapturedLog[] memory merged) {
        string memory capture = string.concat(DIRECTORY, MARKET_LOG_CAPTURE);
        (uint256 fromBlock, uint256 toBlock) = LogCaptureLib.captureRange(capture);
        assertLe(fromBlock, block.number, "the log capture starts by the exploit's block");
        assertEq(toBlock, PAUSE_BLOCK, "the log capture ends at the pause");
        LogCaptureLib.CapturedLog[][] memory sources = new LogCaptureLib.CapturedLog[][](7);
        sources[0] = LogCaptureLib.logs(capture, productionRun.minterKey(exploitedMarket));
        sources[1] = LogCaptureLib.logs(
            capture,
            productionRun.stabilityPoolKey(exploitedMarket, HarborDeployer.StabilityPoolType.Leveraged)
        );
        sources[2] = LogCaptureLib.logs(
            capture,
            productionRun.stabilityPoolKey(exploitedMarket, HarborDeployer.StabilityPoolType.Collateral)
        );
        sources[3] = LogCaptureLib.logs(capture, productionRun.stabilityPoolManagerKey(exploitedMarket));
        sources[4] = LogCaptureLib.logs(capture, productionRun.peggedTokenKey(exploitedMarket));
        sources[5] = LogCaptureLib.logs(capture, productionRun.leveragedTokenKey(exploitedMarket));
        sources[6] = genesisLogs;

        uint256 count;
        for (uint256 s = 0; s < sources.length; ++s) {
            for (uint256 i = 0; i < sources[s].length; ++i) {
                if (sources[s][i].blockNumber >= block.number) {
                    ++count;
                }
            }
        }
        merged = new LogCaptureLib.CapturedLog[](count);
        count = 0;
        for (uint256 s = 0; s < sources.length; ++s) {
            for (uint256 i = 0; i < sources[s].length; ++i) {
                LogCaptureLib.CapturedLog memory log = sources[s][i];
                if (log.blockNumber < block.number) {
                    continue;
                }
                // Insertion into the logs placed so far, which are in order.
                uint256 j = count++;
                while (j > 0 && _logKey(merged[j - 1]) > _logKey(log)) {
                    merged[j] = merged[j - 1];
                    --j;
                }
                merged[j] = log;
            }
        }
    }

    /// @dev A log's place in the chain: its block, then its index in the block.
    function _logKey(LogCaptureLib.CapturedLog memory log) internal pure returns (uint256) {
        return (log.blockNumber << 32) | log.logIndex;
    }

    /// @dev Reads every party at each point of the history: just before the exploit's transaction, just after it, at the
    ///      end of every later block with a captured log before the pause, and at the end of the block before the
    ///      pause. Then the pause block: the minter and both pools are behind the pauser.
    function _readHistory(History memory history) internal {
        uint256 first = type(uint256).max;
        uint256 last;
        uint256[] memory blocks = new uint256[](history.logs.length + 1);
        uint256 count;
        for (uint256 i = 0; i < history.logs.length; ++i) {
            LogCaptureLib.CapturedLog memory log = history.logs[i];
            if (log.transactionHash == exploitTransaction()) {
                first = Math.min(first, _logKey(log));
                last = Math.max(last, _logKey(log));
            } else if (log.blockNumber == PAUSE_BLOCK) {
                assertEq(log.topics[0], IERC1967.Upgraded.selector, "the pause block's only logs are the pause's");
            } else if (log.blockNumber > block.number && (count == 0 || blocks[count - 1] != log.blockNumber)) {
                blocks[count++] = log.blockNumber;
            }
        }
        assertGt(last, 0, "the exploit's transaction is in the log capture");
        if (count == 0 || blocks[count - 1] != PAUSE_BLOCK - 1) {
            blocks[count++] = PAUSE_BLOCK - 1;
        }

        history.points = new Point[](count + 2);
        history.points[0] = _point(history, "before the exploit", first - 1);
        _logReading(history, 0);
        vm.transact(exploitTransaction());
        history.points[1] = _point(history, "after the exploit", last);
        _logReading(history, 1);
        for (uint256 i = 0; i < count; ++i) {
            vm.rollFork(blocks[i]);
            history.points[i + 2] = _point(
                history,
                string.concat("block ", vm.toString(blocks[i])),
                (blocks[i] << 32) | type(uint32).max
            );
            _logReading(history, i + 2);
        }

        vm.rollFork(PAUSE_BLOCK);
        history.pausedAt = block.timestamp;
        bytes memory paused = abi.encodeWithSelector(HarborPauser_v1.Paused.selector, PAUSED_MESSAGE);
        vm.expectRevert(paused);
        IMinter(market.minter).collateralRatio();
        vm.expectRevert(paused);
        IStabilityPool(market.leveragedPool).totalAssetSupply();
        vm.expectRevert(paused);
        IStabilityPool(market.collateralPool).totalAssetSupply();
    }

    /// @dev One line per reading taken, with the time it finished: a run reads every party at every point over the RPC,
    ///      so this is its progress.
    function _logReading(History memory history, uint256 k) internal view {
        console2.log(
            string.concat(
                history.name,
                ": read ",
                history.points[k].label,
                ", ",
                vm.toString(k + 1),
                " of ",
                vm.toString(history.points.length),
                ", at ",
                BaoTestLib.toUtcString(vm.unixTime() / 1000)
            )
        );
    }

    function _point(
        History memory history,
        string memory label,
        uint256 logKey
    ) internal view returns (Point memory point) {
        point.label = label;
        point.blockNumber = block.number;
        point.timestamp = block.timestamp;
        point.logKey = logKey;
        point.reading = _read();
        point.genesisPegged = new uint256[](parties.length);
        point.genesisLeveraged = new uint256[](parties.length);
        for (uint256 i = 0; i < parties.length; ++i) {
            if (LibString.contains(parties[i].role, "genesis participant")) {
                (point.genesisPegged[i], point.genesisLeveraged[i]) = IGenesis(history.genesis).claimable(
                    parties[i].account
                );
            }
        }
    }

    /// @dev At every point, the unclaimed genesis claims are at most what the genesis contract holds, and short of it by
    ///      at most a wei per account ever given a share: each claim is floored, the claimed ones too. Between points,
    ///      `_checkWindow`.
    function _checkHistory(History memory history) internal view {
        uint256 genesisParty = _partyIndex(history.genesis);
        assertTrue(genesisParty != NOT_A_PARTY, "the genesis contract is a party");
        for (uint256 k = 0; k < history.points.length; ++k) {
            Point memory point = history.points[k];
            uint256 claimedPegged;
            uint256 claimedLeveraged;
            for (uint256 i = 0; i < parties.length; ++i) {
                claimedPegged += point.genesisPegged[i];
                claimedLeveraged += point.genesisLeveraged[i];
            }
            Holding memory held = point.reading.parties[genesisParty];
            assertLe(claimedPegged, held.pegged, string.concat(point.label, ": the genesis claims to pegged tokens"));
            assertLe(
                held.pegged - claimedPegged,
                history.genesisParticipants,
                string.concat(point.label, ": the genesis pegged tokens no claim accounts for")
            );
            assertLe(
                claimedLeveraged,
                held.leveraged,
                string.concat(point.label, ": the genesis claims to leveraged tokens")
            );
            assertLe(
                held.leveraged - claimedLeveraged,
                history.genesisParticipants,
                string.concat(point.label, ": the genesis leveraged tokens no claim accounts for")
            );
            if (k > 0) {
                _checkWindow(history, k);
            }
        }
    }

    /// @dev Between point `k - 1` and point `k`: every party's pegged and leveraged wallet change is the net of the
    ///      captured transfers of those tokens to and from it, and a party's deposit in a pool changes only if that pool
    ///      logged something.
    function _checkWindow(History memory history, uint256 k) internal view {
        Point memory previous = history.points[k - 1];
        Point memory point = history.points[k];
        int256[] memory pegged = new int256[](parties.length);
        int256[] memory leveraged = new int256[](parties.length);
        bool leveragedPoolLogged;
        bool collateralPoolLogged;
        for (uint256 i = 0; i < history.logs.length; ++i) {
            LogCaptureLib.CapturedLog memory log = history.logs[i];
            if (_logKey(log) <= previous.logKey || _logKey(log) > point.logKey) {
                continue;
            }
            leveragedPoolLogged = leveragedPoolLogged || log.emitter == market.leveragedPool;
            collateralPoolLogged = collateralPoolLogged || log.emitter == market.collateralPool;
            if (
                log.topics[0] != IERC20.Transfer.selector ||
                (log.emitter != market.pegged && log.emitter != market.leveraged)
            ) {
                continue;
            }
            int256[] memory changes = log.emitter == market.pegged ? pegged : leveraged;
            int256 amount = int256(abi.decode(log.data, (uint256)));
            uint256 from = _partyIndex(address(uint160(uint256(log.topics[1]))));
            uint256 to = _partyIndex(address(uint160(uint256(log.topics[2]))));
            if (from != NOT_A_PARTY) {
                changes[from] -= amount;
            }
            if (to != NOT_A_PARTY) {
                changes[to] += amount;
            }
        }
        for (uint256 i = 0; i < parties.length; ++i) {
            Holding memory b = previous.reading.parties[i];
            Holding memory a = point.reading.parties[i];
            string memory who = string.concat(vm.toString(parties[i].account), " up to ", point.label);
            assertEq(int256(a.pegged) - int256(b.pegged), pegged[i], string.concat(who, ": pegged, its transfers"));
            assertEq(
                int256(a.leveraged) - int256(b.leveraged),
                leveraged[i],
                string.concat(who, ": leveraged, its transfers")
            );
            assertTrue(
                a.leveragedPoolDeposit == b.leveragedPoolDeposit || leveragedPoolLogged,
                string.concat(who, ": its leveraged pool deposit changed where the pool logged nothing")
            );
            assertTrue(
                a.collateralPoolDeposit == b.collateralPoolDeposit || collateralPoolLogged,
                string.concat(who, ": its collateral pool deposit changed where the pool logged nothing")
            );
        }
    }

    function _partyIndex(address account) internal view returns (uint256) {
        for (uint256 i = 0; i < parties.length; ++i) {
            if (parties[i].account == account) {
                return i;
            }
        }
        return NOT_A_PARTY;
    }

    /// @dev What each party did in each transaction after the exploit's, from the transaction's captured logs.
    function _holderActions(History memory history) internal view returns (HolderAction[] memory actions) {
        HolderAction[] memory found = new HolderAction[](2 * history.logs.length);
        uint256 count;
        uint256 point = 1;
        for (uint256 i = 0; i < history.logs.length; ++i) {
            if (_logKey(history.logs[i]) <= history.points[1].logKey || history.logs[i].blockNumber >= PAUSE_BLOCK) {
                continue;
            }
            while (history.points[point].logKey < _logKey(history.logs[i])) {
                ++point;
            }
            count = _decodeHolderLog(history, i, found, count, point);
        }
        actions = new HolderAction[](count);
        for (uint256 i = 0; i < count; ++i) {
            actions[i] = found[i];
        }
    }

    /// @dev Records what log `index` says each party did in `found`, which holds `count` actions; returns the new count.
    function _decodeHolderLog(
        History memory history,
        uint256 index,
        HolderAction[] memory found,
        uint256 count,
        uint256 point
    ) internal view returns (uint256) {
        LogCaptureLib.CapturedLog memory log = history.logs[index];
        address first = log.topics.length > 1 ? address(uint160(uint256(log.topics[1]))) : address(0);
        address second = log.topics.length > 2 ? address(uint160(uint256(log.topics[2]))) : address(0);
        if (
            (log.emitter == market.pegged || log.emitter == market.leveraged) &&
            log.topics[0] == IERC20.Transfer.selector
        ) {
            // A transfer to the sender itself changes nothing.
            if (first == second) {
                return count;
            }
            count = _transferSide(history, index, found, count, point, first, second);
            return _transferSide(history, index, found, count, point, second, first);
        }
        if (log.emitter == market.minter) {
            return _decodeMinterLog(history, log, found, count, point);
        }
        if (log.emitter == market.leveragedPool || log.emitter == market.collateralPool) {
            return _decodePoolLog(history, log, found, count, point);
        }
        if (log.emitter == history.genesis && log.topics[0] == IGenesis.Claim.selector) {
            return _decodeGenesisClaim(history, log, found, count, point, first, second);
        }
        return count;
    }

    /// @dev A genesis claim: the caller takes its share, to the receiver.
    function _decodeGenesisClaim(
        History memory history,
        LogCaptureLib.CapturedLog memory log,
        HolderAction[] memory found,
        uint256 count,
        uint256 point,
        address caller,
        address receiver
    ) internal view returns (uint256) {
        (uint256 pegged, uint256 leveraged) = abi.decode(log.data, (uint256, uint256));
        string memory phrase = string.concat(
            "claimed its genesis share, ",
            _amount(pegged, history.peggedSymbol),
            " and ",
            _amount(leveraged, history.leveragedSymbol),
            _toOther(history, caller, receiver)
        );
        uint256 at;
        (at, count) = _actionOf(found, count, caller, point, log.transactionHash);
        if (at != NOT_A_PARTY) {
            _addPhrase(found[at], phrase);
        }
        return count;
    }

    /// @dev One side of a pegged or leveraged transfer, log `index`: `account`'s wallet change, and what the transfer
    ///      says it did (`_transferPhrase`).
    function _transferSide(
        History memory history,
        uint256 index,
        HolderAction[] memory found,
        uint256 count,
        uint256 point,
        address account,
        address other
    ) internal view returns (uint256) {
        uint256 at;
        (at, count) = _actionOf(found, count, account, point, history.logs[index].transactionHash);
        if (at == NOT_A_PARTY) {
            return count;
        }
        LogCaptureLib.CapturedLog memory log = history.logs[index];
        bool sent = account == address(uint160(uint256(log.topics[1])));
        int256 change = int256(abi.decode(log.data, (uint256)));
        if (sent) {
            change = -change;
        }
        if (log.emitter == market.pegged) {
            found[at].pegged += change;
        } else {
            found[at].leveraged += change;
        }
        string memory phrase = _transferPhrase(history, index, sent, other);
        if (bytes(phrase).length > 0) {
            _addPhrase(found[at], phrase);
        }
        return count;
    }

    /// @dev What a party's side of transfer `index` says it did: nothing when the other side is the zero address, the
    ///      minter, a pool or the genesis contract, whose own logs say it. A transfer from the manager is the bounty of
    ///      the rebalance or the harvest in the same transaction.
    function _transferPhrase(
        History memory history,
        uint256 index,
        bool sent,
        address other
    ) internal view returns (string memory) {
        if (
            other == address(0) ||
            other == market.minter ||
            other == market.leveragedPool ||
            other == market.collateralPool ||
            other == history.genesis
        ) {
            return "";
        }
        LogCaptureLib.CapturedLog memory log = history.logs[index];
        string memory amount = _amount(
            abi.decode(log.data, (uint256)),
            log.emitter == market.pegged ? history.peggedSymbol : history.leveragedSymbol
        );
        if (other == market.manager && !sent) {
            if (_inTransaction(history, index, IStabilityPoolManager.Rebalanced.selector)) {
                return string.concat("received ", amount, " from the manager, the bounty for its rebalance");
            }
            if (_inTransaction(history, index, IStabilityPoolManager.Harvested.selector)) {
                return string.concat("received ", amount, " from the manager, the bounty for its harvest");
            }
            return string.concat("received ", amount, " from the manager");
        }
        return
            sent
                ? string.concat("sent ", amount, " to ", _label(history, other))
                : string.concat("received ", amount, " from ", _label(history, other));
    }

    /// @dev Whether the transaction of log `index` also has a log of `kind` from the manager.
    function _inTransaction(History memory history, uint256 index, bytes32 kind) internal view returns (bool) {
        bytes32 transactionHash = history.logs[index].transactionHash;
        for (uint256 i = 0; i < history.logs.length; ++i) {
            if (
                history.logs[i].transactionHash == transactionHash &&
                history.logs[i].emitter == market.manager &&
                history.logs[i].topics[0] == kind
            ) {
                return true;
            }
        }
        return false;
    }

    /// @dev A minter log: a party's mint or redemption, with the wrapped collateral it paid or received. A redemption
    ///      of pegged tokens by the manager is a rebalance, which `_marketEvents` shows.
    function _decodeMinterLog(
        History memory history,
        LogCaptureLib.CapturedLog memory log,
        HolderAction[] memory found,
        uint256 count,
        uint256 point
    ) internal view returns (uint256) {
        bytes32 kind = log.topics[0];
        MinterAction memory minted;
        minted.mint = kind == IMinter.MintPeggedToken.selector || kind == IMinter.MintLeveragedToken.selector;
        minted.leveraged =
            kind == IMinter.MintLeveragedToken.selector ||
            kind == IMinter.RedeemLeveragedToken.selector;
        if (!(minted.mint || minted.leveraged || kind == IMinter.RedeemPeggedToken.selector)) {
            return count;
        }
        minted.sender = address(uint160(uint256(log.topics[1])));
        minted.receiver = address(uint160(uint256(log.topics[2])));
        if (kind == IMinter.RedeemPeggedToken.selector && minted.sender == market.manager) {
            return count;
        }
        // Redeeming: the tokens in, then the collateral out. Minting: the collateral in, then the tokens out.
        (minted.tokens, minted.wrapped) = abi.decode(log.data, (uint256, uint256));
        if (minted.mint) {
            (minted.tokens, minted.wrapped) = (minted.wrapped, minted.tokens);
        }
        uint256 at;
        (at, count) = _actionOf(found, count, minted.sender, point, log.transactionHash);
        if (at != NOT_A_PARTY) {
            _addPhrase(
                found[at],
                string.concat(
                    minted.mint ? "minted " : "redeemed ",
                    _amount(minted.tokens, minted.leveraged ? history.leveragedSymbol : history.peggedSymbol),
                    " for ",
                    _amount(minted.wrapped, history.wrappedSymbol),
                    _toOther(history, minted.sender, minted.receiver)
                )
            );
            if (minted.mint) {
                found[at].wrapped -= int256(minted.wrapped);
            }
            if (minted.leveraged) {
                found[at].minterLeveraged += minted.tokens;
                found[at].minterWrapped += minted.wrapped;
            }
        }
        if (!minted.mint) {
            (at, count) = _actionOf(found, count, minted.receiver, point, log.transactionHash);
            if (at != NOT_A_PARTY) {
                found[at].wrapped += int256(minted.wrapped);
            }
        }
        return count;
    }

    /// @dev A pool log: a party's deposit, withdrawal, claim, early-withdrawal fee, withdrawal request or reward
    ///      receiver. A claim of wrapped collateral pays it to the claim's receiver.
    function _decodePoolLog(
        History memory history,
        LogCaptureLib.CapturedLog memory log,
        HolderAction[] memory found,
        uint256 count,
        uint256 point
    ) internal view returns (uint256) {
        (address account, string memory phrase) = _poolPhrase(history, log);
        if (bytes(phrase).length == 0) {
            return count;
        }
        uint256 at;
        (at, count) = _actionOf(found, count, account, point, log.transactionHash);
        if (at != NOT_A_PARTY) {
            _addPhrase(found[at], phrase);
        }
        if (
            log.topics[0] == IClaimReward.Claim.selector &&
            address(uint160(uint256(log.topics[2]))) == market.wrappedCollateral
        ) {
            (at, count) = _actionOf(found, count, address(uint160(uint256(log.topics[3]))), point, log.transactionHash);
            if (at != NOT_A_PARTY) {
                found[at].wrapped += int256(abi.decode(log.data, (uint256)));
            }
        }
        return count;
    }

    /// @dev The party a pool log is about, and what the log says it did; no phrase for any other log.
    function _poolPhrase(
        History memory history,
        LogCaptureLib.CapturedLog memory log
    ) internal view returns (address account, string memory phrase) {
        bytes32 kind = log.topics[0];
        // Every log about a party's own act names it in its first topic after the event's.
        if (log.topics.length < 2) {
            return (address(0), "");
        }
        string memory pool = log.emitter == market.leveragedPool ? "the leveraged pool" : "the collateral pool";
        address first = address(uint160(uint256(log.topics[1])));
        // The party a deposit credits is its receiver; for every other log, its first indexed account.
        account = first;
        if (kind == IStabilityPool.Deposit.selector) {
            address second = address(uint160(uint256(log.topics[2])));
            account = second;
            phrase = string.concat(
                "deposited ",
                _amount(abi.decode(log.data, (uint256)), history.peggedSymbol),
                " in ",
                pool,
                first == second ? "" : string.concat(", paid by ", _label(history, first))
            );
        } else if (kind == IStabilityPool.Withdraw.selector) {
            phrase = string.concat(
                "withdrew ",
                _amount(abi.decode(log.data, (uint256)), history.peggedSymbol),
                " from ",
                pool,
                _toOther(history, first, address(uint160(uint256(log.topics[2]))))
            );
        } else if (kind == IClaimReward.Claim.selector) {
            phrase = string.concat(
                "claimed ",
                _amount(abi.decode(log.data, (uint256)), _symbolOf(history, address(uint160(uint256(log.topics[2]))))),
                " from ",
                pool,
                _toOther(history, first, address(uint160(uint256(log.topics[3]))))
            );
        } else if (kind == IStabilityPool.EarlyWithdrawalFee.selector) {
            phrase = string.concat(
                "paid ",
                pool,
                " an early-withdrawal fee of ",
                _amount(abi.decode(log.data, (uint256)), history.peggedSymbol)
            );
        } else if (kind == IStabilityPool.WithdrawalRequested.selector) {
            phrase = string.concat("requested a withdrawal from ", pool);
        } else if (kind == IStabilityPool.WithdrawalRequestUpdated.selector) {
            phrase = string.concat("renewed its withdrawal request to ", pool);
        } else if (kind == IStabilityPool.WithdrawalRequestCancelled.selector) {
            phrase = string.concat("had its withdrawal request to ", pool, " cancelled");
        } else if (kind == IMultipleRewardAccumulator.UpdateRewardReceiver.selector) {
            phrase = string.concat(
                "set its reward receiver in ",
                pool,
                " to ",
                _label(history, address(uint160(uint256(log.topics[3]))))
            );
        }
    }

    /// @dev The index in `found`, which holds `count` actions, of `account`'s action in `transactionHash`, added if there
    ///      is none yet; `NOT_A_PARTY` if `account` is not a party. Returns the new count.
    function _actionOf(
        HolderAction[] memory found,
        uint256 count,
        address account,
        uint256 point,
        bytes32 transactionHash
    ) internal view returns (uint256, uint256) {
        uint256 party = _partyIndex(account);
        if (party == NOT_A_PARTY) {
            return (NOT_A_PARTY, count);
        }
        // A transaction's logs are consecutive, so its actions are the last ones added.
        for (uint256 j = count; j > 0 && found[j - 1].transactionHash == transactionHash; --j) {
            if (found[j - 1].party == party) {
                return (j - 1, count);
            }
        }
        found[count].party = party;
        found[count].point = point;
        found[count].transactionHash = transactionHash;
        return (count, count + 1);
    }

    /// @dev Adds `phrase` to what `action` did, once.
    function _addPhrase(HolderAction memory action, string memory phrase) internal pure {
        if (bytes(action.what).length == 0) {
            action.what = phrase;
        } else if (!LibString.contains(action.what, phrase)) {
            action.what = string.concat(action.what, "; ", phrase);
        }
    }

    /// @dev ", to <receiver>" when the receiver of an action is not the account that acted.
    function _toOther(History memory history, address account, address receiver) internal pure returns (string memory) {
        return account == receiver ? "" : string.concat(", to ", _label(history, receiver));
    }

    /// @dev An account by its name in the state file, if it has one, otherwise by its address.
    function _label(History memory history, address account) internal pure returns (string memory) {
        if (account == address(0)) {
            return "the zero address";
        }
        for (uint256 c = 0; c < history.contracts.length; ++c) {
            if (history.contracts[c].proxy == account) {
                return history.contracts[c].id;
            }
        }
        return string.concat("`", LibString.toHexStringChecksummed(account), "`");
    }

    function _symbolOf(History memory history, address token) internal view returns (string memory) {
        if (token == market.wrappedCollateral) {
            return history.wrappedSymbol;
        }
        if (token == market.leveraged) {
            return history.leveragedSymbol;
        }
        if (token == market.pegged) {
            return history.peggedSymbol;
        }
        return _symbol(token);
    }

    function _amount(uint256 amount, string memory symbol) internal pure returns (string memory) {
        return string.concat(_exact(amount), " ", symbol);
    }

    function _holdersHeader(History memory history) internal view returns (string memory text) {
        Point memory before = history.points[0];
        Point memory last = history.points[history.points.length - 1];
        string memory exploitCapture = string.concat("holders-", vm.toString(before.blockNumber), "/");
        string memory endCapture = string.concat("holders-", vm.toString(PAUSE_BLOCK), "/");
        text = string.concat(
            "# Holders of ",
            history.name,
            ", from the rebalance dilution exploit of 2026-10-16 to the pause\n\n",
            "Generated by `script/verify/incidents/RebalanceDilutionReport.t.sol`; run ",
            "`script/verify/incidents/run-rebalance-dilution-report` to regenerate. Do not edit by hand. ",
            "The explanation is in [README.md](README.md).\n\n"
        );
        text = string.concat(
            text,
            string.concat(
                "Every party is read on a fork: just before the exploit's transaction `",
                vm.toString(exploitTransaction()),
                "` (block ",
                vm.toString(before.blockNumber),
                ", ",
                BaoTestLib.toUtcString(before.timestamp),
                "), just after it, at the end of every later block in which the market's minter, pools, manager, ",
                "pegged or leveraged token or genesis contract logged anything, and at the end of block "
            ),
            string.concat(
                vm.toString(last.blockNumber),
                ", the last before the minters and the pools were paused in block ",
                vm.toString(PAUSE_BLOCK),
                " (",
                BaoTestLib.toUtcString(history.pausedAt),
                "). What each party did in between comes from those logs, captured from Etherscan in [",
                MARKET_LOG_CAPTURE,
                "](",
                MARKET_LOG_CAPTURE,
                ") and, for the genesis contract, ["
            ),
            string.concat(GENESIS_LOG_CAPTURE, "](", GENESIS_LOG_CAPTURE, ").\n\n")
        );
        text = string.concat(
            text,
            string.concat(
                "The parties are every account in the holder capture at the pause, [",
                endCapture,
                "](",
                endCapture,
                "), with the fee receivers, the reserve pool and the accounts the exploit paid. A party absent from the ",
                "capture at the exploit's block, [",
                exploitCapture,
                "](",
                exploitCapture,
                "), is new since the exploit. "
            ),
            "The genesis contract holds the tokens of the genesis participants who have not claimed them: each such ",
            "participant is a party with its own claim, and the genesis contract's own holdings are those claims ",
            "together.\n\n"
        );
        text = string.concat(
            text,
            string.concat(
                "Every amount and price is printed in full, to all 18 decimals; only the collateral ratio is rounded. ",
                "Values are in ",
                history.wrappedSymbol,
                ", each at its own reading's prices, as in the figures file: an amount of a token times the minter's ",
                "price for it, over the oracle's price for ",
                history.wrappedSymbol,
                ", floored to the wei. A party's holdings count the pegged and leveraged tokens in its wallet, its "
            ),
            string.concat(
                "deposits and rewards in both pools and its genesis claim. They leave out the ",
                history.wrappedSymbol,
                " in its wallet, which also moves for reasons outside the market. The exploit's change counts it, as ",
                "the figures file does. After the exploit, the ",
                history.wrappedSymbol,
                " a party paid or received in its own minting, redemptions and pool claims is shown with each of its ",
                "actions.\n\n"
            )
        );
    }

    function _holdersMarketSection(History memory history) internal view returns (string memory table) {
        string memory pegged = history.peggedSymbol;
        string memory leveraged = history.leveragedSymbol;
        string memory wrapped = history.wrappedSymbol;
        table = string.concat(
            "## The market, reading by reading\n\n| Reading | Time | 1 ",
            string.concat(leveraged, " in ", wrapped, " | 1 ", leveraged, " in pegged units | 1 ", pegged, " in "),
            string.concat(wrapped, " | ", pegged, " outstanding | ", leveraged, " outstanding | "),
            "Collateral ratio | What the market's contracts logged, apart from holders' actions |\n",
            "|---|---|---|---|---|---|---|---|---|\n"
        );
        for (uint256 k = 0; k < history.points.length; ++k) {
            Point memory point = history.points[k];
            string[] memory cells = new string[](9);
            cells[0] = point.label;
            cells[1] = BaoTestLib.toUtcString(point.timestamp);
            cells[2] = _wrappedPer(point.reading.prices.leveraged, point.reading.prices);
            cells[3] = _exact(point.reading.prices.leveraged);
            cells[4] = _wrappedPer(point.reading.prices.pegged, point.reading.prices);
            cells[5] = _exact(point.reading.peggedSupply);
            cells[6] = _exact(point.reading.leveragedSupply);
            cells[7] = _fixed(point.reading.collateralRatio, 4);
            cells[8] = k == 1 ? "the exploit's transaction: see the figures file" : _marketEvents(history, k);
            table = string.concat(table, _row(cells));
        }
        table = string.concat(table, "\n");
    }

    /// @dev What the manager logged between point `k - 1` and point `k` - its rebalances and harvests - and every
    ///      upgrade of the market's contracts.
    function _marketEvents(History memory history, uint256 k) internal pure returns (string memory events) {
        if (k == 0) {
            return "";
        }
        for (uint256 i = 0; i < history.logs.length; ++i) {
            LogCaptureLib.CapturedLog memory log = history.logs[i];
            if (_logKey(log) <= history.points[k - 1].logKey || _logKey(log) > history.points[k].logKey) {
                continue;
            }
            string memory event_;
            if (log.topics[0] == IStabilityPoolManager.Rebalanced.selector) {
                (uint256 liquidated, uint256 wrapped, uint256 leveraged) = abi.decode(
                    log.data,
                    (uint256, uint256, uint256)
                );
                event_ = string.concat(
                    string.concat("a rebalance took ", _amount(liquidated, history.peggedSymbol), " from the pools: "),
                    _amount(wrapped, history.wrappedSymbol),
                    " to the collateral pool and ",
                    _amount(leveraged, history.leveragedSymbol),
                    " to the leveraged pool, after the bounty"
                );
            } else if (log.topics[0] == IStabilityPoolManager.Harvested.selector) {
                event_ = string.concat("a harvest of ", _amount(abi.decode(log.data, (uint256)), history.wrappedSymbol));
            } else if (log.topics[0] == IERC1967.Upgraded.selector) {
                event_ = string.concat(
                    _label(history, log.emitter),
                    " upgraded to `",
                    LibString.toHexStringChecksummed(address(uint160(uint256(log.topics[1])))),
                    "`"
                );
            } else {
                continue;
            }
            events = bytes(events).length == 0 ? event_ : string.concat(events, "; ", event_);
        }
    }

    /// @dev Party `party`'s holdings at point `k`, in wrapped collateral: every position but the wrapped collateral in
    ///      its wallet, and its genesis claim.
    function _holdingValue(History memory history, uint256 k, uint256 party) internal view returns (int256 value) {
        Point memory point = history.points[k];
        Prices memory prices = point.reading.prices;
        uint256[8] memory amounts = _amounts(point.reading.parties[party]);
        for (uint256 position = 1; position < 8; ++position) {
            value += _positionWrappedValue(position, amounts[position], prices);
        }
        value += int256(Math.mulDiv(point.genesisPegged[party], prices.pegged, prices.wrapped));
        value += int256(Math.mulDiv(point.genesisLeveraged[party], prices.leveraged, prices.wrapped));
    }

    /// @dev The exploit's change in party `party`'s holdings and in the wrapped collateral in its wallet.
    function _exploitChange(History memory history, uint256 party) internal view returns (int256) {
        return
            _holdingValue(history, 1, party) -
            _holdingValue(history, 0, party) +
            int256(history.points[1].reading.parties[party].wrapped) -
            int256(history.points[0].reading.parties[party].wrapped);
    }

    /// @dev Whether any of party `party`'s amounts, but the wrapped collateral in its wallet, differs between point
    ///      `k - 1` and point `k`.
    function _holdingChanged(History memory history, uint256 k, uint256 party) internal view returns (bool) {
        uint256[8] memory before = _amounts(history.points[k - 1].reading.parties[party]);
        uint256[8] memory afterwards = _amounts(history.points[k].reading.parties[party]);
        for (uint256 position = 1; position < 8; ++position) {
            if (before[position] != afterwards[position]) {
                return true;
            }
        }
        return
            history.points[k - 1].genesisPegged[party] != history.points[k].genesisPegged[party] ||
            history.points[k - 1].genesisLeveraged[party] != history.points[k].genesisLeveraged[party];
    }

    /// @dev Whether party `party` holds anything at any point, but the wrapped collateral in its wallet, or did
    ///      anything after the exploit, or the exploit changed it.
    function _followed(History memory history, uint256 party) internal view returns (bool) {
        if (_exploitChange(history, party) != 0 || _actionCount(history, party) > 0) {
            return true;
        }
        for (uint256 k = 0; k < history.points.length; ++k) {
            if (_holdingValue(history, k, party) != 0 || (k > 0 && _holdingChanged(history, k, party))) {
                return true;
            }
        }
        return false;
    }

    /// @dev Whether party `party` is a holder the capture at the pause lists and the capture at the exploit's block does
    ///      not.
    function _isNew(History memory history, uint256 party) internal pure returns (bool) {
        return party >= history.atTheExploit && party < history.atThePause;
    }

    function _actionCount(History memory history, uint256 party) internal pure returns (uint256 count) {
        for (uint256 a = 0; a < history.actions.length; ++a) {
            if (history.actions[a].party == party) {
                ++count;
            }
        }
    }

    function _holdersSummarySection(History memory history) internal view returns (string memory table) {
        string memory wrapped = history.wrappedSymbol;
        table = string.concat(
            "## Every holder\n\nIn ",
            wrapped,
            ". Holdings leave out the ",
            wrapped,
            " in a party's wallet; the exploit's change counts it. The last column is the ",
            wrapped,
            " a party paid (negative) or received in its own minting, redemptions and pool claims after the exploit.",
            "\n\n| Holder | Role | New since the exploit | Holdings before the exploit | The exploit's change | ",
            "Actions since | Holdings at the pause | Paid or received since |\n|---|---|---|---|---|---|---|---|\n"
        );
        uint256 last = history.points.length - 1;
        uint256 leftOut;
        for (uint256 i = 0; i < parties.length; ++i) {
            if (!_followed(history, i)) {
                ++leftOut;
                continue;
            }
            int256 since;
            for (uint256 a = 0; a < history.actions.length; ++a) {
                if (history.actions[a].party == i) {
                    since += history.actions[a].wrapped;
                }
            }
            string[] memory cells = new string[](8);
            cells[0] = string.concat("`", vm.toString(parties[i].account), "`");
            cells[1] = parties[i].role;
            cells[2] = _isNew(history, i) ? "new" : "";
            cells[3] = _exact(uint256(_holdingValue(history, 0, i)));
            cells[4] = _exactSigned(_exploitChange(history, i));
            cells[5] = vm.toString(_actionCount(history, i));
            cells[6] = _exact(uint256(_holdingValue(history, last, i)));
            cells[7] = _exactSigned(since);
            table = string.concat(table, _row(cells));
        }
        table = string.concat(
            table,
            "\n",
            vm.toString(leftOut),
            " other parties held nothing in this market at any reading, were not changed by the exploit and did ",
            "nothing after it.\n\n"
        );
    }

    function _holdersRewardsSection(History memory history) internal view returns (string memory table) {
        string memory leveraged = history.leveragedSymbol;
        table = string.concat(
            "## The leveraged pool's ",
            leveraged,
            " rewards\n\nEach leveraged pool depositor's claimable ",
            leveraged,
            ": what the exploit's rebalance added; what it claimed after the exploit; what it could claim at the pause; ",
            "and what the rebalances after the exploit added, which is the rest. A claim does not say which reward it ",
            "takes.\n\n| Depositor | Added by the exploit | Claimed since | Claimable at the pause | Added since |\n",
            "|---|---|---|---|---|\n"
        );
        Point memory before = history.points[0];
        Point memory afterwards = history.points[1];
        Point memory last = history.points[history.points.length - 1];
        for (uint256 i = 0; i < parties.length; ++i) {
            uint256 claimed = _claimedLeveraged(history, parties[i].account);
            uint256 atThePause = last.reading.parties[i].leveragedPoolLeveraged;
            uint256 afterTheExploit = afterwards.reading.parties[i].leveragedPoolLeveraged;
            uint256 beforeTheExploit = before.reading.parties[i].leveragedPoolLeveraged;
            if (claimed == 0 && atThePause == 0 && afterTheExploit == 0 && beforeTheExploit == 0) {
                continue;
            }
            table = string.concat(
                table,
                _row5(
                    _name(i),
                    _exactSigned(int256(afterTheExploit) - int256(beforeTheExploit)),
                    _exact(claimed),
                    _exact(atThePause),
                    _exactSigned(int256(atThePause) - int256(afterTheExploit) + int256(claimed))
                )
            );
        }
        table = string.concat(table, "\n");
    }

    /// @dev The leveraged tokens `account` claimed from the leveraged pool after the exploit.
    function _claimedLeveraged(History memory history, address account) internal view returns (uint256 claimed) {
        for (uint256 i = 0; i < history.logs.length; ++i) {
            LogCaptureLib.CapturedLog memory log = history.logs[i];
            if (
                _logKey(log) > history.points[1].logKey &&
                log.emitter == market.leveragedPool &&
                log.topics[0] == IClaimReward.Claim.selector &&
                address(uint160(uint256(log.topics[1]))) == account &&
                address(uint160(uint256(log.topics[2]))) == market.leveraged
            ) {
                claimed += abi.decode(log.data, (uint256));
            }
        }
    }

    function _holderSections(History memory history) internal view returns (string memory text) {
        text = string.concat(
            "## Holder by holder\n\nEvery party the exploit changed, or that did anything after it, or whose holdings ",
            "changed after it. Its holdings at each reading where they changed or it acted; then what it did, ",
            "transaction by transaction, with the change in its wallet's tokens. A price is the ",
            history.wrappedSymbol,
            " paid or received per leveraged token in its own minting or redemption, the minter's fee taken.\n\n"
        );
        for (uint256 i = 0; i < parties.length; ++i) {
            bool changedSince;
            for (uint256 k = 2; k < history.points.length; ++k) {
                changedSince = changedSince || _holdingChanged(history, k, i);
            }
            if (_exploitChange(history, i) != 0 || _actionCount(history, i) > 0 || changedSince) {
                text = string.concat(text, _holdingsTable(history, i), _actionsTable(history, i));
            }
        }
    }

    /// @dev Party `party`'s holdings at the readings before and after the exploit, at each later one where they changed
    ///      or it acted, and at the pause - in the columns it ever held anything in.
    function _holdingsTable(History memory history, uint256 party) internal view returns (string memory table) {
        string[10] memory titles = [
            string.concat(history.wrappedSymbol, " in its wallet"),
            string.concat(history.peggedSymbol, " in its wallet"),
            string.concat(history.leveragedSymbol, " in its wallet"),
            string.concat(history.peggedSymbol, " in the leveraged pool"),
            string.concat(history.wrappedSymbol, " reward, leveraged pool"),
            string.concat(history.leveragedSymbol, " reward, leveraged pool"),
            string.concat(history.peggedSymbol, " in the collateral pool"),
            string.concat(history.wrappedSymbol, " reward, collateral pool"),
            string.concat(history.peggedSymbol, " genesis claim"),
            string.concat(history.leveragedSymbol, " genesis claim")
        ];
        bool[10] memory shown;
        uint256 columns = 4;
        for (uint256 k = 0; k < history.points.length; ++k) {
            uint256[10] memory amounts = _holdingAmounts(history, k, party);
            for (uint256 c = 0; c < 10; ++c) {
                if (!shown[c] && amounts[c] != 0 && (c != 0 || k < 2)) {
                    shown[c] = true;
                    ++columns;
                }
            }
        }
        string[] memory cells = new string[](columns);
        cells[0] = "Reading";
        cells[1] = "Time";
        uint256 at = 2;
        for (uint256 c = 0; c < 10; ++c) {
            if (shown[c]) {
                cells[at++] = titles[c];
            }
        }
        cells[at++] = string.concat("Holdings, ", history.wrappedSymbol);
        cells[at] = string.concat("1 ", history.leveragedSymbol, " in ", history.wrappedSymbol);
        table = string.concat(
            "### ",
            _name(party),
            _isNew(history, party) ? ", new since the exploit\n\n" : "\n\n",
            _row(cells),
            "|",
            LibString.repeat("---|", columns),
            "\n"
        );
        for (uint256 k = 0; k < history.points.length; ++k) {
            if (k >= 2 && k < history.points.length - 1 && !_holdingChanged(history, k, party) && !_actedAt(history, party, k)) {
                continue;
            }
            uint256[10] memory amounts = _holdingAmounts(history, k, party);
            cells[0] = history.points[k].label;
            cells[1] = BaoTestLib.toUtcString(history.points[k].timestamp);
            at = 2;
            for (uint256 c = 0; c < 10; ++c) {
                if (shown[c]) {
                    cells[at++] = c == 0 && k >= 2 ? "-" : _exact(amounts[c]);
                }
            }
            cells[at++] = _exact(uint256(_holdingValue(history, k, party)));
            cells[at] = _wrappedPer(history.points[k].reading.prices.leveraged, history.points[k].reading.prices);
            table = string.concat(table, _row(cells));
        }
        table = string.concat(table, "\n");
    }

    /// @dev Party `party`'s amounts at point `k`: its eight positions, then its genesis claims.
    function _holdingAmounts(
        History memory history,
        uint256 k,
        uint256 party
    ) internal pure returns (uint256[10] memory amounts) {
        uint256[8] memory positions = _amounts(history.points[k].reading.parties[party]);
        for (uint256 position = 0; position < 8; ++position) {
            amounts[position] = positions[position];
        }
        amounts[8] = history.points[k].genesisPegged[party];
        amounts[9] = history.points[k].genesisLeveraged[party];
    }

    function _actedAt(History memory history, uint256 party, uint256 k) internal pure returns (bool) {
        for (uint256 a = 0; a < history.actions.length; ++a) {
            if (history.actions[a].party == party && history.actions[a].point == k) {
                return true;
            }
        }
        return false;
    }

    /// @dev What party `party` did after the exploit, transaction by transaction.
    function _actionsTable(History memory history, uint256 party) internal view returns (string memory table) {
        if (_actionCount(history, party) == 0) {
            return "Nothing after the exploit.\n\n";
        }
        string memory leveraged = history.leveragedSymbol;
        string memory wrapped = history.wrappedSymbol;
        table = string.concat(
            string.concat("| Block | Time | Transaction | What it did | ", history.peggedSymbol, " | "),
            string.concat(leveraged, " | ", wrapped, " | Price of 1 ", leveraged, ", ", wrapped, " | Price of 1 "),
            string.concat(leveraged, ", pegged units | The minter's price of 1 ", leveraged, ", pegged units |\n"),
            "|---|---|---|---|---|---|---|---|---|---|\n"
        );
        for (uint256 a = 0; a < history.actions.length; ++a) {
            HolderAction memory action = history.actions[a];
            if (action.party != party) {
                continue;
            }
            Point memory point = history.points[action.point];
            string[] memory cells = new string[](10);
            cells[0] = vm.toString(point.blockNumber);
            cells[1] = BaoTestLib.toUtcString(point.timestamp);
            cells[2] = string.concat("`", vm.toString(action.transactionHash), "`");
            cells[3] = action.what;
            cells[4] = action.pegged == 0 ? "" : _exactSigned(action.pegged);
            cells[5] = action.leveraged == 0 ? "" : _exactSigned(action.leveraged);
            cells[6] = action.wrapped == 0 ? "" : _exactSigned(action.wrapped);
            if (action.minterLeveraged > 0) {
                cells[7] = _exact(Math.mulDiv(action.minterWrapped, 1 ether, action.minterLeveraged));
                cells[8] = _exact(Math.mulDiv(action.minterWrapped, point.reading.prices.wrapped, action.minterLeveraged));
                cells[9] = _exact(point.reading.prices.leveraged);
            }
            table = string.concat(table, _row(cells));
        }
        table = string.concat(table, "\n");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Formatting
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A ratio or a rate (1e18) to `places` decimals, rounded half up. Amounts and values are never rounded: see
    ///      `_exact`.
    function _fixed(uint256 value, uint256 places) internal pure returns (string memory) {
        uint256 unit = 10 ** (18 - places);
        return BaoTestLib.toStringScaled((value + unit / 2) / unit, places);
    }

    /// @dev An amount or a value (1e18) in full: every one of its 18 decimals.
    function _exact(uint256 value) internal pure returns (string memory) {
        return BaoTestLib.toStringScaled(value, 18);
    }

    function _exactSigned(int256 value) internal pure returns (string memory) {
        return string.concat(value < 0 ? "-" : "+", _exact(_abs(value)));
    }

    function _signedWrapped(int256 pegged, Prices memory prices) internal pure returns (string memory) {
        return _exactSigned(_inWrapped(pegged, prices));
    }

    function _wrappedPer(uint256 peggedPrice, Prices memory prices) internal pure returns (string memory) {
        return _exact(Math.mulDiv(peggedPrice, 1 ether, prices.wrapped));
    }

    function _abs(int256 value) internal pure returns (uint256) {
        return value < 0 ? uint256(-value) : uint256(value);
    }

    function _symbol(address token) internal view returns (string memory) {
        return IERC20Metadata(token).symbol();
    }

    function _name(uint256 party) internal view returns (string memory) {
        string memory account = string.concat("`", vm.toString(parties[party].account), "`");
        return bytes(parties[party].role).length > 0 ? string.concat(account, " (", parties[party].role, ")") : account;
    }

    function _row(string[] memory cells) internal pure returns (string memory) {
        return string.concat("| ", BaoTestLib.join(cells, " | "), " |\n");
    }

    function _row2(string memory a, string memory b) internal pure returns (string memory) {
        return string.concat("| ", a, " | ", b, " |\n");
    }

    function _row3(string memory a, string memory b, string memory c) internal pure returns (string memory) {
        return string.concat("| ", a, " | ", b, " | ", c, " |\n");
    }

    function _row4(
        string memory a,
        string memory b,
        string memory c,
        string memory d
    ) internal pure returns (string memory) {
        return string.concat("| ", a, " | ", b, " | ", c, " | ", d, " |\n");
    }

    function _row5(
        string memory a,
        string memory b,
        string memory c,
        string memory d,
        string memory e
    ) internal pure returns (string memory) {
        return string.concat("| ", a, " | ", b, " | ", c, " | ", d, " | ", e, " |\n");
    }

    function _actionRow(
        string memory step,
        Action memory action,
        string memory tokenIn,
        string memory tokenOut
    ) internal pure returns (string memory) {
        return _actionRow(step, action.count, action.tokensIn, tokenIn, action.tokensOut, tokenOut, action.fees);
    }

    function _actionRow(
        string memory step,
        uint256 count,
        uint256 amountIn,
        string memory tokenIn,
        uint256 amountOut,
        string memory tokenOut,
        uint256 fee
    ) internal pure returns (string memory) {
        string[] memory cells = new string[](5);
        cells[0] = step;
        cells[1] = vm.toString(count);
        cells[2] = bytes(tokenIn).length > 0 ? string.concat(_exact(amountIn), " ", tokenIn) : "";
        cells[3] = bytes(tokenOut).length > 0 ? string.concat(_exact(amountOut), " ", tokenOut) : "";
        cells[4] = fee > 0 ? _exact(fee) : "";
        return _row(cells);
    }
}

/// @notice The exploit of BTC::stETH.
contract RebalanceDilutionReport_BTC_stETH is RebalanceDilutionReport {
    function exploitTransaction() internal pure override returns (bytes32) {
        return BTC_STETH_EXPLOIT;
    }

    function exploitMarket() internal override returns (Config_MinterMarket) {
        return new ConfigMarket_BTC_stETH_mainnet();
    }
}

/// @notice The exploit of EUR::stETH.
contract RebalanceDilutionReport_EUR_stETH is RebalanceDilutionReport {
    function exploitTransaction() internal pure override returns (bytes32) {
        return EUR_STETH_EXPLOIT;
    }

    function exploitMarket() internal override returns (Config_MinterMarket) {
        return new ConfigMarket_EUR_stETH_mainnet();
    }
}
