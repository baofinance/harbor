// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {BaoTestLib} from "@bao-test/BaoTestLib.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IClaimReward} from "@harbor/interfaces/IClaimReward.sol";
import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IWrappedPriceOracle} from "@harbor/interfaces/IWrappedPriceOracle.sol";

import {Config_MinterMarket, IMarketConfig} from "@harbor-script/config/ConfigBase.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {btcMintersConfig} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {ethMintersConfig} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {eurMintersConfig} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {goldMintersConfig} from "@harbor-script/src/Deploy_GOLD_Minter.sol";
import {mcapMintersConfig} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {silverMintersConfig} from "@harbor-script/src/Deploy_SILVER_Minter.sol";

import {MarketAddresses} from "@harbor-test/harness/MarketAddresses.sol";
import {V3Rule} from "@harbor-test/harness/MarketRule.sol";
import {
    OpenWindowWithdrawer,
    RebalanceDilutionAttacker,
    RebalanceDilutionFork
} from "@harbor-test/deployment/RebalanceDilutionFork.sol";

/// @notice Writes every figure of the report on the exploit of 2026-10-16 into `FIGURES`, from the chain and from the
///         exploit replayed on a fork, so that no figure in the report is copied by hand.
///
/// It finds every account that has held a position in either stability pool or held the leveraged token, reads what
/// each holds, replays the exploit, and reads again. It decodes the transaction's actions, the fees and the caller's
/// flows from the replay's events, runs the mitigation scenarios through the same installers and attacker the tests
/// use, and reads every market's configuration at the exploit's block.
///
/// It checks itself before writing anything: the accounts found hold each pool's whole supply and the whole leveraged
/// supply, before and after; every party's change sums to zero, to within the rounding of the valuation; and the
/// caller's flows sum to its proceeds, to within the rounding of its trades. A failed check leaves the file as it was.
contract RebalanceDilutionReport is RebalanceDilutionFork {
    string internal constant FIGURES = "doc/incidents/2026-10-16-rebalance-dilution-figures.md";
    /// @dev The most blocks the RPC lets one log query span.
    uint256 internal constant LOG_QUERY_BLOCKS = 10_000;
    /// @dev A pause between log queries, in milliseconds, to stay under the RPC's rate limit.
    uint256 internal constant LOG_QUERY_PAUSE = 250;

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
    }

    /// @notice An account the report follows, and why.
    struct Party {
        address account;
        string role;
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
        uint256 proceeds;
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
        _findParties();
        uint256 beforeExploit = vm.snapshotState();

        Reading memory before = _read();
        vm.recordLogs();
        vm.transact(EXPLOIT_TX);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Reading memory afterwards = _read();

        Transaction memory exploit = _decode(logs);
        string memory figures = string.concat(
            _header(),
            _marketSection(before, afterwards),
            _transactionSection(exploit),
            _partiesSections(before, afterwards),
            _callerSection(exploit, before, afterwards)
        );
        figures = string.concat(figures, _mitigationSection(beforeExploit), _marketsSection(beforeExploit));
        vm.writeFile(FIGURES, figures);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Finding the parties
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Every account that has held a position in either pool (each `UserDepositChange` owner), every account the
    ///      leveraged token has been sent to, the fee receivers, the reserve pool and the exploit's sender - less the
    ///      market's own contracts, whose wallets are read separately.
    function _findParties() internal {
        address[] memory found = new address[](0);
        found = _logAddresses(found, market.leveragedPool, IStabilityPool.UserDepositChange.selector, 1);
        found = _logAddresses(found, market.collateralPool, IStabilityPool.UserDepositChange.selector, 1);
        found = _logAddresses(found, market.leveraged, IERC20.Transfer.selector, 2);

        address genesis = productionRun.genesisAddress(btcStEth);
        for (uint256 i = 0; i < found.length; ++i) {
            if (
                found[i] != address(0) &&
                found[i] != market.minter &&
                found[i] != market.leveragedPool &&
                found[i] != market.collateralPool &&
                found[i] != market.manager
            ) {
                _addRole(found[i], found[i] == genesis ? "genesis contract" : "");
            }
        }
        _addRole(IMinter(market.minter).feeReceiver(), "minter fee receiver");
        _addRole(IStabilityPool(market.leveragedPool).getFeeAddress(), "leveraged pool fee address");
        _addRole(IStabilityPool(market.collateralPool).getFeeAddress(), "collateral pool fee address");
        _addRole(IStabilityPoolManager(market.manager).feeReceiver(), "manager fee receiver (harvest cut)");
        _addRole(IMinter(market.minter).reservePool(), "reserve pool");
        _addRole(EXPLOIT_SENDER, "exploit's sender");
    }

    /// @dev Adds `account` to the parties, or adds `role` to its roles if it is there already.
    function _addRole(address account, string memory role) internal {
        for (uint256 i = 0; i < parties.length; ++i) {
            if (parties[i].account == account) {
                if (bytes(role).length > 0) {
                    parties[i].role = bytes(parties[i].role).length > 0
                        ? string.concat(parties[i].role, ", ", role)
                        : role;
                }
                return;
            }
        }
        parties.push(Party(account, role));
    }

    /// @dev `found`, with every address in topic `topicIndex` of `target`'s `selector` events added, from the block
    ///      `target` was deployed in to this one. The RPC answers at most `LOG_QUERY_BLOCKS` blocks a query.
    function _logAddresses(
        address[] memory found,
        address target,
        bytes32 selector,
        uint256 topicIndex
    ) internal returns (address[] memory) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = selector;
        for (uint256 from = _deploymentBlock(target); from <= block.number; from += LOG_QUERY_BLOCKS) {
            Vm.EthGetLogs[] memory logs = vm.eth_getLogs(
                from,
                Math.min(from + LOG_QUERY_BLOCKS - 1, block.number),
                target,
                topics
            );
            for (uint256 i = 0; i < logs.length; ++i) {
                found = _include(found, address(uint160(uint256(logs[i].topics[topicIndex]))));
            }
            vm.sleep(LOG_QUERY_PAUSE);
        }
        return found;
    }

    /// @dev `found` with `account` appended, unless it is there already.
    function _include(address[] memory found, address account) internal pure returns (address[] memory grown) {
        for (uint256 i = 0; i < found.length; ++i) {
            if (found[i] == account) {
                return found;
            }
        }
        grown = new address[](found.length + 1);
        for (uint256 i = 0; i < found.length; ++i) {
            grown[i] = found[i];
        }
        grown[found.length] = account;
    }

    /// @dev The first block at whose end `account` has code, by bisection on `eth_getCode`.
    function _deploymentBlock(address account) internal returns (uint256 withCode) {
        uint256 withoutCode = 0;
        withCode = block.number;
        while (withCode - withoutCode > 1) {
            uint256 middle = (withCode + withoutCode) / 2;
            bytes memory code = vm.rpc(
                "eth_getCode",
                string.concat('["', vm.toString(account), '","', LibString.toMinimalHexString(middle), '"]')
            );
            if (code.length > 0) {
                withCode = middle;
            } else {
                withoutCode = middle;
            }
            vm.sleep(LOG_QUERY_PAUSE);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Reading
    // ---------------------------------------------------------------------------------------------------------------

    function _read() internal view returns (Reading memory reading) {
        (uint256 minPrice, uint256 maxPrice, uint256 minRate, uint256 maxRate) = IWrappedPriceOracle(market.oracle)
            .latestAnswer();
        // The caller's flows are valued at one price; with a spread they would not sum to its proceeds.
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
            reading.parties[i] = _holding(parties[i].account);
        }
        reading.contracts = new Holding[](3);
        reading.contracts[0] = _holding(market.leveragedPool);
        reading.contracts[1] = _holding(market.collateralPool);
        reading.contracts[2] = _holding(market.manager);
        reading.minterSurplus =
            int256(Math.mulDiv(IERC20(market.wrappedCollateral).balanceOf(market.minter), reading.prices.wrapped, 1 ether)) -
            int256(Math.mulDiv(reading.collateralBacking, reading.prices.collateral, 1 ether));

        _assertComplete(reading);
    }

    function _holding(address account) internal view returns (Holding memory holding) {
        holding.wrapped = IERC20(market.wrappedCollateral).balanceOf(account);
        holding.pegged = IERC20(market.pegged).balanceOf(account);
        holding.leveraged = IERC20(market.leveraged).balanceOf(account);
        holding.leveragedPoolDeposit = IStabilityPool(market.leveragedPool).assetBalanceOf(account);
        holding.leveragedPoolWrapped = IMultipleRewardAccumulator(market.leveragedPool).claimable(
            account,
            market.wrappedCollateral
        );
        holding.leveragedPoolLeveraged = IMultipleRewardAccumulator(market.leveragedPool).claimable(
            account,
            market.leveraged
        );
        holding.collateralPoolDeposit = IStabilityPool(market.collateralPool).assetBalanceOf(account);
        holding.collateralPoolWrapped = IMultipleRewardAccumulator(market.collateralPool).claimable(
            account,
            market.wrappedCollateral
        );
    }

    /// @dev The parties found hold each pool's whole supply, and they and the market's contracts hold the whole
    ///      leveraged supply - so no holder is missing from what follows.
    ///
    ///      A pool scales each deposit down by its losses and floors the result, while its supply falls by the exact
    ///      loss. So after a loss the deposits found may fall short of the supply by less than one wei each, and never
    ///      exceed it; a missing depositor would leave the whole of its deposit unaccounted for.
    function _assertComplete(Reading memory reading) internal view {
        uint256 leveragedPoolDeposits;
        uint256 collateralPoolDeposits;
        uint256 leveragedHeld;
        for (uint256 i = 0; i < reading.parties.length; ++i) {
            leveragedPoolDeposits += reading.parties[i].leveragedPoolDeposit;
            collateralPoolDeposits += reading.parties[i].collateralPoolDeposit;
            leveragedHeld += reading.parties[i].leveraged;
        }
        for (uint256 i = 0; i < reading.contracts.length; ++i) {
            leveragedHeld += reading.contracts[i].leveraged;
        }
        uint256 leveragedPoolSupply = IStabilityPool(market.leveragedPool).totalAssetSupply();
        uint256 collateralPoolSupply = IStabilityPool(market.collateralPool).totalAssetSupply();
        assertLe(leveragedPoolDeposits, leveragedPoolSupply, "the depositors found hold no more than the leveraged pool");
        assertLe(
            leveragedPoolSupply - leveragedPoolDeposits,
            parties.length,
            "the depositors found hold the leveraged pool's supply, less a wei each"
        );
        assertLe(collateralPoolDeposits, collateralPoolSupply, "the depositors found hold no more than the collateral pool");
        assertLe(
            collateralPoolSupply - collateralPoolDeposits,
            parties.length,
            "the depositors found hold the collateral pool's supply, less a wei each"
        );
        assertEq(leveragedHeld, IERC20(market.leveraged).totalSupply(), "the holders found hold the leveraged supply");
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
        if (kind == IMinter.MintLeveragedToken.selector) {
            _count(exploit.mintLeveraged, log.data);
        } else if (kind == IMinter.MintPeggedToken.selector) {
            _count(exploit.mintPegged, log.data);
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
        if (from == exploit.caller && to == EXPLOIT_SENDER) {
            exploit.proceeds += amount;
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
        return
            string.concat(
                "# Figures: the rebalance dilution exploit of BTC::stETH, 2026-10-16\n\n",
                "Generated by `script/verify/incidents/RebalanceDilutionReport.t.sol`; run ",
                "`script/verify/incidents/run-rebalance-dilution-report` to regenerate. Do not edit by hand. ",
                "The explanation is in [2026-10-16-rebalance-dilution.md](2026-10-16-rebalance-dilution.md).\n\n",
                "Transaction `",
                vm.toString(EXPLOIT_TX),
                "`, block ",
                vm.toString(block.number),
                " (",
                BaoTestLib.toUtcString(block.timestamp),
                "), replayed on a fork with `vm.transact`. Before is the state the transaction started from; after ",
                "is the state it left. Values are in ",
                _symbol(market.wrappedCollateral),
                " at the oracle's price, which did not move within the block.\n\n"
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
                _fixed(before.prices.leveraged, 6),
                _fixed(afterwards.prices.leveraged, 6)
            )
        );
        table = string.concat(
            table,
            _row3("Collateral backing (underlying)", _fixed(before.collateralBacking, 4), _fixed(afterwards.collateralBacking, 4))
        );
        table = string.concat(
            table,
            _row3(string.concat(pegged, " outstanding"), _fixed(before.peggedSupply, 4), _fixed(afterwards.peggedSupply, 4))
        );
        table = string.concat(
            table,
            _row3(string.concat(leveraged, " outstanding"), _fixed(before.leveragedSupply, 4), _fixed(afterwards.leveragedSupply, 4))
        );
        table = string.concat(
            table,
            _row3("Collateral ratio", _fixed(before.collateralRatio, 4), _fixed(afterwards.collateralRatio, 4))
        );
        return string.concat(table, "\n");
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
        table = string.concat(table, _actionRow(string.concat("Borrowed ", wrapped), 1, exploit.borrowed, wrapped, 0, "", 0));
        table = string.concat(table, _actionRow(string.concat("Minted ", leveraged), exploit.mintLeveraged, wrapped, leveraged));
        table = string.concat(table, _actionRow(string.concat("Minted ", pegged), exploit.mintPegged, wrapped, pegged));
        table = string.concat(table, _actionRow("Deposited in the leveraged pool", 1, exploit.deposited, pegged, 0, "", 0));
        table = string.concat(
            table,
            _actionRow(string.concat("Redeemed ", leveraged, " before the rebalance"), exploit.redeemLeveragedBefore, leveraged, wrapped)
        );
        table = string.concat(
            table,
            _actionRow("Rebalance: pegged redeemed by the manager", 1, exploit.rebalancePegged, pegged, exploit.rebalanceWrapped, wrapped, 0)
        );
        table = string.concat(
            table,
            _actionRow(string.concat("Rebalance: ", leveraged, " minted for it"), 1, 0, "", exploit.rebalanceLeveraged, leveraged, 0)
        );
        table = string.concat(
            table,
            _actionRow("Rebalance: from the collateral pool", 1, exploit.collateralPoolPegged, pegged, exploit.collateralPoolWrapped, wrapped, 0)
        );
        table = string.concat(
            table,
            _actionRow("Rebalance: from the leveraged pool", 1, exploit.leveragedPoolPegged, pegged, exploit.leveragedPoolLeveraged, leveraged, 0)
        );
        table = string.concat(
            table,
            _actionRow(string.concat("Rebalance bounty to the caller, ", wrapped), 1, 0, "", exploit.bountyWrapped, wrapped, 0)
        );
        table = string.concat(
            table,
            _actionRow(string.concat("Rebalance bounty to the caller, ", leveraged), 1, 0, "", exploit.bountyLeveraged, leveraged, 0)
        );
        table = string.concat(
            table,
            _actionRow(string.concat("Claimed ", leveraged, " from the leveraged pool"), 1, 0, "", exploit.claimedLeveraged, leveraged, 0)
        );
        table = string.concat(
            table,
            _actionRow(string.concat("Redeemed ", leveraged, " after the rebalance"), exploit.redeemLeveragedAfter, leveraged, wrapped)
        );
        table = string.concat(
            table,
            _actionRow("Withdrew from the leveraged pool (the early-withdrawal fee in the last column)", 1, 0, "", exploit.withdrawn, pegged, exploit.earlyWithdrawalFee)
        );
        table = string.concat(table, _actionRow(string.concat("Redeemed ", pegged), exploit.redeemPegged, pegged, wrapped));
        table = string.concat(table, _actionRow(string.concat("Repaid ", wrapped), 1, exploit.repaid, wrapped, 0, "", 0));
        table = string.concat(
            table,
            _actionRow(string.concat("Sent to the exploit's sender, ", wrapped), 1, 0, "", exploit.proceeds, wrapped, 0)
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
        int256[6] memory totals; // held, leveraged pool, collateral pool, fee receivers, reserve pool, exploit's sender
        for (uint256 i = 0; i < parties.length; ++i) {
            int256 change = _value(afterwards.parties[i], afterwards.prices) - _value(before.parties[i], before.prices);
            uint256 kind = _kind(parties[i].role);
            if (kind == 0) {
                totals[0] += _walletValue(afterwards.parties[i], afterwards.prices) - _walletValue(before.parties[i], before.prices);
                totals[1] += _leveragedPoolValue(afterwards.parties[i], afterwards.prices) - _leveragedPoolValue(before.parties[i], before.prices);
                totals[2] += _collateralPoolValue(afterwards.parties[i], afterwards.prices) - _collateralPoolValue(before.parties[i], before.prices);
            } else {
                totals[kind + 2] += change;
            }
        }
        int256 contractsChange = _contractsValue(afterwards) - _contractsValue(before);
        int256 surplusChange = afterwards.minterSurplus - before.minterSurplus;
        int256 residual = totals[0] + totals[1] + totals[2] + totals[3] + totals[4] + totals[5] + contractsChange + surplusChange;
        uint256 bound = _booksBound(before, afterwards);
        assertLe(_abs(residual), bound, "every party's change sums to zero, to within the valuation's rounding");

        Prices memory prices = before.prices;
        string memory table = string.concat(
            "## Losses and gains by party\n\n| Party | ",
            _symbol(market.wrappedCollateral),
            " |\n|---|---|\n"
        );
        table = string.concat(table, _row2("Holders: their own wallets", _signedWrapped(totals[0], prices)));
        table = string.concat(table, _row2("Holders: their leveraged pool positions", _signedWrapped(totals[1], prices)));
        table = string.concat(table, _row2("Holders: their collateral pool positions", _signedWrapped(totals[2], prices)));
        table = string.concat(
            table,
            _row2("**All holders**", string.concat("**", _signedWrapped(totals[0] + totals[1] + totals[2], prices), "**"))
        );
        table = string.concat(table, _row2("Fee receivers", _signedWrapped(totals[3], prices)));
        table = string.concat(table, _row2("Reserve pool", _signedWrapped(totals[4], prices)));
        table = string.concat(table, _row2("The exploit's sender", _signedWrapped(totals[5], prices)));
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

    /// @dev The rounding the books can show: every party and contract valued with at most eight floored products, at
    ///      each end; the leveraged price floored to the wei, which undervalues the whole leveraged supply by less than
    ///      its size in 1e18 units at each end; and the backing and the surplus floored once each, at each end.
    function _booksBound(Reading memory before, Reading memory afterwards) internal view returns (uint256) {
        return
            2 * 8 * (parties.length + 3) +
            (before.leveragedSupply + afterwards.leveragedSupply) / 1 ether + 2 + 4;
    }

    /// @dev What the pools and the manager hold beyond what the parties are owed by them.
    function _contractsValue(Reading memory reading) internal pure returns (int256 value) {
        for (uint256 i = 0; i < reading.contracts.length; ++i) {
            value += _walletValue(reading.contracts[i], reading.prices);
        }
        for (uint256 i = 0; i < reading.parties.length; ++i) {
            value -= _leveragedPoolValue(reading.parties[i], reading.prices) + _collateralPoolValue(reading.parties[i], reading.prices);
        }
    }

    /// @dev 0 for a holder, 1 for a fee receiver, 2 for the reserve pool, 3 for the exploit's sender.
    function _kind(string memory role) internal pure returns (uint256) {
        if (LibString.contains(role, "fee")) {
            return 1;
        }
        if (LibString.contains(role, "reserve pool")) {
            return 2;
        }
        if (LibString.contains(role, "exploit's sender")) {
            return 3;
        }
        return 0;
    }

    function _leveragedPoolSection(Reading memory before, Reading memory afterwards) internal view returns (string memory table) {
        table = string.concat(
            "## Leveraged stability pool, depositor by depositor\n\n| Depositor | ",
            _symbol(market.pegged), " deposit | ", _symbol(market.leveraged), " owed | ", _symbol(market.wrappedCollateral),
            " owed | Net ", _symbol(market.wrappedCollateral), " |\n|---|---|---|---|---|\n"
        );
        int256 total;
        for (uint256 i = 0; i < parties.length; ++i) {
            Holding memory b = before.parties[i];
            Holding memory a = afterwards.parties[i];
            int256 change = _leveragedPoolValue(a, afterwards.prices) - _leveragedPoolValue(b, before.prices);
            if (change == 0 && b.leveragedPoolDeposit == a.leveragedPoolDeposit) {
                continue;
            }
            total += change;
            table = string.concat(
                table,
                _row5(_name(i), _signedFixed(int256(a.leveragedPoolDeposit) - int256(b.leveragedPoolDeposit), 4), _signedFixed(int256(a.leveragedPoolLeveraged) - int256(b.leveragedPoolLeveraged), 4), _signedFixed(int256(a.leveragedPoolWrapped) - int256(b.leveragedPoolWrapped), 4), _signedWrapped(change, before.prices))
            );
        }
        table = string.concat(table, _row5("**All depositors found**", "", "", "", string.concat("**", _signedWrapped(total, before.prices), "**")), "\n");
    }

    function _collateralPoolSection(Reading memory before, Reading memory afterwards) internal view returns (string memory table) {
        table = string.concat(
            "## Collateral stability pool, depositor by depositor\n\n| Depositor | ",
            _symbol(market.pegged), " deposit | ", _symbol(market.wrappedCollateral), " owed | Net ",
            _symbol(market.wrappedCollateral), " |\n|---|---|---|---|\n"
        );
        int256 total;
        for (uint256 i = 0; i < parties.length; ++i) {
            Holding memory b = before.parties[i];
            Holding memory a = afterwards.parties[i];
            int256 change = _collateralPoolValue(a, afterwards.prices) - _collateralPoolValue(b, before.prices);
            if (change == 0 && b.collateralPoolDeposit == a.collateralPoolDeposit) {
                continue;
            }
            total += change;
            table = string.concat(
                table,
                _row4(_name(i), _signedFixed(int256(a.collateralPoolDeposit) - int256(b.collateralPoolDeposit), 4), _signedFixed(int256(a.collateralPoolWrapped) - int256(b.collateralPoolWrapped), 4), _signedWrapped(change, before.prices))
            );
        }
        table = string.concat(table, _row4("**All depositors found**", "", "", string.concat("**", _signedWrapped(total, before.prices), "**")), "\n");
    }

    function _heldSection(Reading memory before, Reading memory afterwards) internal view returns (string memory table) {
        table = string.concat(
            "## ", _symbol(market.leveraged), " held outside the pools\n\n| Holder | ", _symbol(market.leveraged),
            " held before | Net ", _symbol(market.wrappedCollateral), " |\n|---|---|---|\n"
        );
        int256 total;
        uint256 held;
        for (uint256 i = 0; i < parties.length; ++i) {
            uint256 leveraged = before.parties[i].leveraged;
            if (leveraged == 0 || _kind(parties[i].role) != 0) {
                continue;
            }
            int256 change = int256(Math.mulDiv(afterwards.parties[i].leveraged, afterwards.prices.leveraged, 1 ether)) -
                int256(Math.mulDiv(leveraged, before.prices.leveraged, 1 ether));
            total += change;
            held += leveraged;
            table = string.concat(table, _row3(_name(i), _fixed(leveraged, 6), _signedWrapped(change, before.prices)));
        }
        table = string.concat(table, _row3("**All holders**", string.concat("**", _fixed(held, 6), "**"), string.concat("**", _signedWrapped(total, before.prices), "**")), "\n");
    }

    function _holderSection(Reading memory before, Reading memory afterwards) internal view returns (string memory table) {
        string memory wrapped = _symbol(market.wrappedCollateral);
        table = string.concat(
            "## Every party, all positions together\n\nIn ", wrapped,
            ". Parties whose holdings did not change are left out.\n\n| Party | Role | Own wallet | Leveraged pool | Collateral pool | Total |\n|---|---|---|---|---|---|\n"
        );
        for (uint256 i = 0; i < parties.length; ++i) {
            Holding memory b = before.parties[i];
            Holding memory a = afterwards.parties[i];
            int256 wallet = _walletValue(a, afterwards.prices) - _walletValue(b, before.prices);
            int256 leveragedPool = _leveragedPoolValue(a, afterwards.prices) - _leveragedPoolValue(b, before.prices);
            int256 collateralPool = _collateralPoolValue(a, afterwards.prices) - _collateralPoolValue(b, before.prices);
            if (wallet == 0 && leveragedPool == 0 && collateralPool == 0) {
                continue;
            }
            string[] memory cells = new string[](6);
            cells[0] = string.concat("`", vm.toString(parties[i].account), "`");
            cells[1] = parties[i].role;
            cells[2] = _signedWrapped(wallet, before.prices);
            cells[3] = _signedWrapped(leveragedPool, before.prices);
            cells[4] = _signedWrapped(collateralPool, before.prices);
            cells[5] = _signedWrapped(wallet + leveragedPool + collateralPool, before.prices);
            table = string.concat(table, _row(cells));
        }
        table = string.concat(table, "\n");
    }

    /// @dev The caller's gain, flow by flow, checked against what it sent to the exploit's sender.
    function _callerSection(
        Transaction memory exploit,
        Reading memory before,
        Reading memory afterwards
    ) internal view returns (string memory) {
        Prices memory b = before.prices;
        Prices memory a = afterwards.prices;
        int256[7] memory flows;
        flows[0] = -int256(Math.mulDiv(exploit.callerPoolLoss, b.pegged, 1 ether));
        flows[1] = int256(Math.mulDiv(exploit.claimedLeveraged, a.leveraged, 1 ether) + Math.mulDiv(exploit.claimedWrapped, a.wrapped, 1 ether));
        flows[2] = int256(Math.mulDiv(exploit.bountyWrapped, a.wrapped, 1 ether) + Math.mulDiv(exploit.bountyLeveraged, a.leveraged, 1 ether));
        flows[3] = -int256(Math.mulDiv(exploit.callerLeveragedAtRebalance, b.leveraged - a.leveraged, 1 ether));
        flows[4] = -int256(Math.mulDiv(exploit.earlyWithdrawalFee, a.pegged, 1 ether));
        flows[5] = -int256(Math.mulDiv(_mintingAndRedemptionFees(exploit), b.wrapped, 1 ether));
        flows[6] = int256(Math.mulDiv(exploit.reservePaid, b.wrapped, 1 ether));
        int256 sum = flows[0] + flows[1] + flows[2] + flows[3] + flows[4] + flows[5] + flows[6];
        int256 proceeds = int256(Math.mulDiv(exploit.proceeds, b.wrapped, 1 ether));
        uint256 bound = _callerBound(exploit);
        assertLe(_abs(sum - proceeds), bound, "the caller's flows sum to its proceeds, to within its trades' rounding");

        string memory leveraged = _symbol(market.leveraged);
        string memory table = string.concat(
            "## The caller's gain, flow by flow\n\n| Flow | ",
            _symbol(market.wrappedCollateral),
            " |\n|---|---|\n"
        );
        table = string.concat(
            table,
            _row2(
                string.concat("Leveraged pool: ", _fixed(exploit.callerPoolLoss, 4), " ", _symbol(market.pegged), " taken by the rebalance"),
                _signedWrapped(flows[0], b)
            )
        );
        table = string.concat(
            table,
            _row2(
                string.concat("Leveraged pool: ", _fixed(exploit.claimedLeveraged, 4), " ", leveraged, " claimed, at the price after"),
                _signedWrapped(flows[1], b)
            )
        );
        table = string.concat(table, _row2("Rebalance bounty", _signedWrapped(flows[2], b)));
        table = string.concat(
            table,
            _row2(
                string.concat("Its own ", _fixed(exploit.callerLeveragedAtRebalance, 4), " ", leveraged, " held through the rebalance"),
                _signedWrapped(flows[3], b)
            )
        );
        table = string.concat(table, _row2("Early-withdrawal fee", _signedWrapped(flows[4], b)));
        table = string.concat(table, _row2("Minting and redemption fees", _signedWrapped(flows[5], b)));
        table = string.concat(table, _row2("Paid by the reserve pool", _signedWrapped(flows[6], b)));
        table = string.concat(table, _row2("**Sum**", string.concat("**", _signedWrapped(sum, b), "**")));
        table = string.concat(
            table,
            _row2("**Sent to the exploit's sender**", string.concat("**", _signedWrapped(proceeds, b), "**"))
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
    ///      each of the seven flows is a floored product, and the leveraged price is floored to the wei, which misprices
    ///      the leveraged tokens it traded, claimed and held by less than their amount in 1e18 units.
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
            exploit.callerLeveragedAtRebalance;
        return 2 * trades + 2 * 7 + leveragedTraded / 1 ether + 1;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Mitigations
    // ---------------------------------------------------------------------------------------------------------------

    function _mitigationSection(uint256 beforeExploit) internal returns (string memory table) {
        vm.revertToState(beforeExploit);
        uint256 deployedFee = IStabilityPool(market.leveragedPool).getEarlyWithdrawalFee();
        uint256 leveragedPriceBefore = IMinter(market.minter).leveragedTokenPrice();
        table = string.concat(
            "## Mitigations\n\nEach row starts from the state before the exploit. The replay runs the exploit's own ",
            "transaction; the rebuilt attacker (`test/deployment/RebalanceDilutionFork.sol`) pursues the same goal ",
            "against the mitigated market. Gains in ", _symbol(market.wrappedCollateral), "; the fair amount is the ",
            "pegged converted over the leveraged price at the rebalance.\n\n",
            "| Mitigation | Replay pays its sender | Attacker's gain | Collateral ratio at the rebalance | Pegged converted | Leveraged minted | Fair amount | Leveraged price after, in pegged units |\n",
            "|---|---|---|---|---|---|---|---|\n"
        );
        int256[5] memory gains;
        for (uint256 m = 0; m <= uint256(Mitigation.WithdrawalFeeOpenWindow); ++m) {
            string memory replay = "not replayed";
            if (m != uint256(Mitigation.MinterV3) && m != uint256(Mitigation.WithdrawalFeeOpenWindow)) {
                vm.revertToState(beforeExploit);
                _install(Mitigation(m));
                replay = _signedFixed(_replay(), 4);
            }
            vm.revertToState(beforeExploit);
            _install(Mitigation(m));
            Outcome memory outcome = _attack(Mitigation(m));
            gains[m] = outcome.attackerGain;
            table = string.concat(table, _mitigationRow(Mitigation(m), replay, outcome));
        }
        vm.revertToState(beforeExploit);
        assertGt(gains[uint256(Mitigation.AsDeployed)], 0, "the attack pays on the market as deployed");
        assertLt(gains[uint256(Mitigation.WithdrawalFee)], gains[uint256(Mitigation.AsDeployed)], "the larger fee costs");
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
            _fixed(leveragedPriceBefore, 6),
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

    function _attack(Mitigation mitigation) internal returns (Outcome memory) {
        address attacker = address(new RebalanceDilutionAttacker(market));
        address poolAccount = attacker;
        if (mitigation == Mitigation.WithdrawalFeeOpenWindow) {
            poolAccount = address(new OpenWindowWithdrawer(market.leveragedPool));
            _openWithdrawalWindow(poolAccount);
        }
        return _runAttack(attacker, poolAccount);
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
        cells[2] = _signedFixed(outcome.attackerGain, 4);
        cells[3] = _fixed(outcome.rebalance.collateralRatio, 4);
        cells[4] = _fixed(outcome.rebalance.peggedConverted, 6);
        cells[5] = _fixed(outcome.rebalance.leveragedMinted, 6);
        cells[6] = _fixed(Math.mulDiv(outcome.rebalance.peggedConverted, 1 ether, outcome.rebalance.leveragedPrice), 6);
        cells[7] = _fixed(outcome.leveragedPriceAfter, 6);
        return _row(cells);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Every market
    // ---------------------------------------------------------------------------------------------------------------

    function _marketsSection(uint256 beforeExploit) internal returns (string memory table) {
        vm.revertToState(beforeExploit);
        table = string.concat(
            "## Every market at the exploit's block\n\nA rebalance at a collateral ratio of 20/19 or below pays the ",
            "leveraged pool ", vm.toString(LEVERAGE_RATIO_CAP), " leveraged tokens per pegged token. That overpays by ",
            vm.toString(LEVERAGE_RATIO_CAP), " times the leveraged price, wherever the price is above 1/",
            vm.toString(LEVERAGE_RATIO_CAP), ". A band refused \"below\" a ratio refuses that action there.\n\n",
            "| Market | Rebalance threshold | Pegged mint refused below | Leveraged redemption refused below | Next leveraged redemption bound | Leveraged price, in pegged units | Leveraged holders' value, in pegged units | Overpayment at 20/19 |\n",
            "|---|---|---|---|---|---|---|---|\n"
        );
        table = string.concat(table, _pegRows(btcMintersConfig), _pegRows(ethMintersConfig), _pegRows(eurMintersConfig));
        table = string.concat(table, _pegRows(goldMintersConfig), _pegRows(mcapMintersConfig), _pegRows(silverMintersConfig), "\n");
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
        cells[0] = string.concat(IMarketConfig(address(config)).peg(), "::", IMarketConfig(address(config)).collateral());
        cells[1] = _fixed(IStabilityPoolManager(addresses.manager).rebalanceThreshold(), 4);
        cells[2] = _refusedBelow(bands.mintPeggedIncentiveConfig);
        cells[3] = _refusedBelow(bands.redeemLeveragedIncentiveConfig);
        cells[4] = bands.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds.length > 1
            ? _fixed(bands.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds[1], 4)
            : "none";
        cells[5] = supply == 0 ? "no leveraged tokens" : _fixed(price, 6);
        cells[6] = _fixed(Math.mulDiv(supply, price, 1 ether), 6);
        cells[7] = supply == 0 || price * LEVERAGE_RATIO_CAP <= 1 ether
            ? "none"
            : string.concat(_fixed(price * LEVERAGE_RATIO_CAP, 2), " times");
        return _row(cells);
    }

    function _refusedBelow(IMinter.IncentiveConfig memory incentive) internal pure returns (string memory) {
        return incentive.incentiveRatios[0] == 1 ether ? _fixed(incentive.collateralRatioBandUpperBounds[0], 4) : "never";
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Formatting
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev `value` (1e18) to `places` decimals, rounded half up.
    function _fixed(uint256 value, uint256 places) internal pure returns (string memory) {
        uint256 unit = 10 ** (18 - places);
        return BaoTestLib.toStringScaled((value + unit / 2) / unit, places);
    }

    function _signedFixed(int256 value, uint256 places) internal pure returns (string memory) {
        return string.concat(value < 0 ? "-" : "+", _fixed(_abs(value), places));
    }

    function _signedWrapped(int256 pegged, Prices memory prices) internal pure returns (string memory) {
        return _signedFixed(_inWrapped(pegged, prices), 4);
    }

    function _wrappedPer(uint256 peggedPrice, Prices memory prices) internal pure returns (string memory) {
        return _fixed(Math.mulDiv(peggedPrice, 1 ether, prices.wrapped), 4);
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

    function _row4(string memory a, string memory b, string memory c, string memory d) internal pure returns (string memory) {
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
        cells[2] = bytes(tokenIn).length > 0 ? string.concat(_fixed(amountIn, 6), " ", tokenIn) : "";
        cells[3] = bytes(tokenOut).length > 0 ? string.concat(_fixed(amountOut, 6), " ", tokenOut) : "";
        cells[4] = fee > 0 ? _fixed(fee, 6) : "";
        return _row(cells);
    }
}
