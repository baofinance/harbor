// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {HarborPauser_v1} from "@bao/HarborPauser_v1.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {MarketAddresses} from "@harbor-script/src/MarketAddresses.sol";
import {Minter} from "@harbor-script/src/contracts/Minter.sol";
import {StabilityPool} from "@harbor-script/src/contracts/StabilityPool.sol";
import {StabilityPoolManager} from "@harbor-script/src/contracts/StabilityPoolManager.sol";
import {FrozenPriceOracle} from "@harbor-script/UpgradeMinter_v2_v3/FrozenPriceOracle.sol";
import {IMinter_v3_Upgrader} from "@harbor-script/UpgradeMinter_v2_v3/IMinter_v3_Upgrader.sol";
import {Minter_v3_Upgrader} from "@harbor-script/UpgradeMinter_v2_v3/Minter_v3_Upgrader.sol";
import {IStabilityPool_v3_Upgrader} from "@harbor-script/UpgradeStabilityPool_v2_v3/IStabilityPool_v3_Upgrader.sol";
import {StabilityPool_v3_Upgrader} from "@harbor-script/UpgradeStabilityPool_v2_v3/StabilityPool_v3_Upgrader.sol";

/// @notice The upgrade of live markets from Minter_v2, StabilityPool_v2 and StabilityPoolManager_v1 to the versions
///         this tree deploys - Minter_v3, StabilityPool_v3 and StabilityPoolManager_v2 - in two steps that the upgrade
///         script and the tests both run: read what each market's upgrade needs from it (`readMarketUpgradeInputs`, or
///         `readFrozenMarketUpgradeInputs` for markets frozen by a pause), then upgrade (`upgradeMarketsToV3`).
/// @dev A market's four proxies move in one batch for the multisig, because none works beside the others' old
///      versions: the old manager calls a minter function Minter_v3 replaced, and the new manager calls a pool function
///      only StabilityPool_v3 has. Each implementation is built by the deploy's own function, from the addresses a fresh
///      deploy predicts, so the upgrade installs what a fresh deploy would.
///
///      The minter's upgrade loads its stored config again through Minter_v3's loader, which refuses configs v2
///      accepted: a config v3 would refuse reverts the market's whole batch rather than leaving the minter on it.
///
///      Each pool goes through `StabilityPool_v3_Upgrader`, never a plain upgrade: v3 keeps the reward streams and
///      each holder's reward snapshot in widened storage, which the upgrader copies across, and divides rewards by what
///      the holders hold, which needs the pool's ledger gap. Both come from a holder capture, read where the pools can
///      no longer change. The read uses the old versions' own functions, so nothing here restates how they compute.
///
///      A market's batch can also put right what a fault left in it, in the same transaction as its upgrade, so nobody
///      acts on the market in between: rewards taken back from holders as their pool is migrated (`deductions`, paid
///      to the owner by the upgrader), then the owner's fee-free operations once the market runs v3
///      (`OwnerOperations`: its pegged and leveraged redeemed, and leveraged minted for named accounts). Neither is read
///      from a market: an input names them, and each is empty for a market with nothing to put right.
///
///      The owner's operations are priced at the oracle reading the operations name - the reading at the block the
///      batch's other inputs were read at - not at the price of the moment the batch executes: the batch points the
///      minter at a `FrozenPriceOracle` answering that reading before the operations and at the oracle proxy the deploy
///      predicts after, in the same transaction. So what each operation moves is fixed when the batch is built, and
///      the batch cannot run short of what a later price would have returned.
abstract contract UpgradeMarketToV3 is Minter, StabilityPool, StabilityPoolManager {
    Vm private constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev What this run does, named once so its opening and closing lines cannot drift apart.
    string private constant _WHAT = "upgrade to Minter_v3, StabilityPool_v3 and StabilityPoolManager_v2";

    /// @notice What one pool's upgrade needs from it: the holders whose reward records the migration copies, the
    ///         ledger gap they leave - the pool's supply less what they hold, either sign - the floor and withdrawal
    ///         window its new implementation must keep, and the rewards the migration takes back from holders, paid to
    ///         the owner: empty for a pool with nothing to take back.
    struct PoolUpgradeInput {
        address[] holders;
        int256 gap;
        uint256 minTotalAssetSupply;
        uint64 withdrawalStartDelay;
        uint64 withdrawalEndWindow;
        IStabilityPool_v3_Upgrader.Deduction[] deductions;
    }

    /// @notice One oracle reading, as `IWrappedPriceOracle.latestAnswer` gives it: the band of the collateral's price
    ///         in pegged units and the band of the wrapped-to-underlying rate, each low then high, 18 decimals.
    struct OracleAnswer {
        uint256 minPrice;
        uint256 maxPrice;
        uint256 minRate;
        uint256 maxRate;
    }

    /// @notice The owner's fee-free operations a market's batch carries once the market runs v3, in this order: its
    ///         pegged redeemed for wrapped collateral, its leveraged redeemed for wrapped collateral, then wrapped
    ///         collateral minted into leveraged for each account named - every one priced by the minter at `answer`,
    ///         the oracle reading the batch points it at for them. Each amount is zero, or empty, where there is none;
    ///         with no operation the answer is not read.
    struct OwnerOperations {
        OracleAnswer answer;
        uint256 peggedRedeemed;
        uint256 leveragedRedeemed;
        address[] accounts;
        uint256[] mints;
    }

    /// @notice What one market's upgrade needs from it: its minter's stored config, the backing it records, the wrapped
    ///         collateral it holds and the price oracle it reads, each pool's input, and the owner's operations after.
    struct MarketUpgradeInput {
        Config_MinterMarket market;
        IMinter.Config minterConfig;
        uint256 recordedBacking;
        uint256 wrappedCollateralHeld;
        address priceOracle;
        PoolUpgradeInput collateralPool;
        PoolUpgradeInput leveragedPool;
        OwnerOperations ownerOperations;
    }

    /// @notice The owner's operations name a different number of accounts and mints.
    error AccountsAndMintsOfDifferentLengths(string market, uint256 accounts, uint256 mints);

    /// @notice Read what upgrading each of `markets` needs, on the fork selected now: each minter's stored config, the
    ///         backing it records, the wrapped collateral it holds and the price oracle it reads, and for each pool the
    ///         holders the capture in `capture` lists, the ledger gap they leave, and its floor and withdrawal window.
    ///         Refuses a capture whose holders leave a gap beyond rounding either way.
    function readMarketUpgradeInputs(
        Config_MinterMarket[] memory markets,
        string memory capture
    ) internal returns (MarketUpgradeInput[] memory inputs) {
        inputs = new MarketUpgradeInput[](markets.length);
        for (uint256 i = 0; i < markets.length; ++i) {
            address minter = minterAddress(markets[i]);
            inputs[i].market = markets[i];
            inputs[i].minterConfig = IMinter(minter).config();
            inputs[i].recordedBacking = IMinter(minter).collateralTokenBalance();
            inputs[i].wrappedCollateralHeld = IERC20(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).balanceOf(minter);
            inputs[i].priceOracle = IMinter(minter).priceOracle();
            inputs[i].collateralPool = _readPoolUpgradeInput(markets[i], StabilityPoolType.Collateral, capture);
            inputs[i].leveragedPool = _readPoolUpgradeInput(markets[i], StabilityPoolType.Leveraged, capture);
        }
    }

    /// @notice `readMarketUpgradeInputs` for markets a pause has frozen, read at the capture's block on `network`,
    ///         selected by `selectFrozenReadBlock`. The fork selected before is selected again after.
    function readFrozenMarketUpgradeInputs(
        Config_MinterMarket[] memory markets,
        string memory capture,
        string memory network
    ) internal returns (MarketUpgradeInput[] memory inputs) {
        uint256 head = selectFrozenReadBlock(markets, capture, network);
        inputs = readMarketUpgradeInputs(markets, capture);
        _vm.selectFork(head);
    }

    /// @notice Select a fork of `network` at the capture's block, where markets a pause has frozen are read, and
    ///         return the fork selected before, for the caller to select again when done. That block must be the last
    ///         before the pause: at the next block every minter and pool of `markets` must revert `Paused`, which is
    ///         checked first. The pause changes only which implementation each proxy runs, so what is read there is
    ///         what the upgrade runs on.
    /// @dev This deployer must be persistent across forks. A script is; a test that holds a deployer makes it so. It
    ///      cannot make itself so: forge refuses a script that uses its own address.
    function selectFrozenReadBlock(
        Config_MinterMarket[] memory markets,
        string memory capture,
        string memory network
    ) internal returns (uint256 head) {
        head = _vm.activeFork();
        // A contract made on one fork is absent from another unless persistent: the market configs.
        for (uint256 i = 0; i < markets.length; ++i) {
            _vm.makePersistent(address(markets[i]));
        }
        uint256 readBlock = HolderCaptureLib.captureBlock(capture);

        _vm.createSelectFork(_vm.rpcUrl(network), readBlock + 1);
        for (uint256 i = 0; i < markets.length; ++i) {
            _requirePaused(minterKey(markets[i]), minterAddress(markets[i]), abi.encodeCall(IMinter.config, ()));
            _requirePaused(
                stabilityPoolKey(markets[i], StabilityPoolType.Collateral),
                stabilityPoolAddress(markets[i], StabilityPoolType.Collateral),
                abi.encodeCall(IStabilityPool.totalAssetSupply, ())
            );
            _requirePaused(
                stabilityPoolKey(markets[i], StabilityPoolType.Leveraged),
                stabilityPoolAddress(markets[i], StabilityPoolType.Leveraged),
                abi.encodeCall(IStabilityPool.totalAssetSupply, ())
            );
        }

        _vm.createSelectFork(_vm.rpcUrl(network), readBlock);
    }

    /// @notice Upgrade each market `inputs` names: deploy its new implementations, from its `marketAddresses`, and save,
    ///         as one batch for the multisig, the upgrade of its minter, loading the config read - through one
    ///         `Minter_v3_Upgrader`, which sets the record to zero, where the minter records backing but holds no
    ///         wrapped collateral - then, where it reads another oracle, its move to the oracle proxy the deploy
    ///         predicts; of its two pools, through one `StabilityPool_v3_Upgrader` for every pool, with the holders,
    ///         gap and deductions its input holds; of its manager; then the owner's operations its input names, in
    ///         that order. A market with operations is moved instead to a `FrozenPriceOracle` answering their reading,
    ///         deployed here, before its pools' migration, and to the oracle proxy after the operations. Every
    ///         contract deployed is recorded in the state returned and saved: the implementations under their proxies,
    ///         the upgraders and frozen oracles under `*`, so every address a batch names can be named from the state.
    ///         Refuses a pool whose new implementation would not keep the floor or withdrawal window read.
    /// @dev The deployment state is made as every deploy run makes it: the state file when the run persists, a fresh
    ///      state when it does not.
    function upgradeMarketsToV3(
        MarketUpgradeInput[] memory inputs,
        string memory network
    ) internal returns (DeploymentTypes.State memory state) {
        state = _shouldPersistState()
            ? DeploymentState.loadOrFresh(_stateFileRead(), saltPrefix(), network)
            : DeploymentState.fresh(saltPrefix(), network);
        state.baoFactory = baoFactory();
        _reportRun(_WHAT, saltPrefix(), network);

        // Each upgrader upgrades a proxy away from itself in the call that runs it, so one serves every pool, and one
        // every minter that records backing it holds none of - deployed only when a minter does. Each is recorded in
        // the state under `*`, a one-shot serving no proxy, so a batch naming it can be read against the state.
        address upgrader = address(new StabilityPool_v3_Upgrader(owner()));
        _recordImplementation(
            state,
            "*",
            "@harbor-script/UpgradeStabilityPool_v2_v3/StabilityPool_v3_Upgrader.sol",
            "StabilityPool_v3_Upgrader",
            upgrader
        );
        address minterUpgrader;
        for (uint256 i = 0; i < inputs.length; ++i) {
            if (_recordsBackingItHoldsNoneOf(inputs[i])) {
                minterUpgrader = address(new Minter_v3_Upgrader(owner()));
                _recordImplementation(
                    state,
                    "*",
                    "@harbor-script/UpgradeMinter_v2_v3/Minter_v3_Upgrader.sol",
                    "Minter_v3_Upgrader",
                    minterUpgrader
                );
                break;
            }
        }

        for (uint256 i = 0; i < inputs.length; ++i) {
            Config_MinterMarket config = inputs[i].market;
            MarketAddresses memory addresses = marketAddresses(config);
            address minterImplementation = deployMinterImplementation(state, minterKey(config), addresses);
            address collateralPoolImplementation = deployStabilityPoolImplementation(
                state,
                stabilityPoolKey(config, StabilityPoolType.Collateral),
                StabilityPoolType.Collateral,
                config,
                addresses
            );
            address leveragedPoolImplementation = deployStabilityPoolImplementation(
                state,
                stabilityPoolKey(config, StabilityPoolType.Leveraged),
                StabilityPoolType.Leveraged,
                config,
                addresses
            );
            address managerImplementation = deployStabilityPoolManagerImplementation(
                state,
                stabilityPoolManagerKey(config),
                addresses
            );

            {
                // The stored config is loaded again, through Minter_v3's own loader, in the call that upgrades: the
                // plain swap would carry the stored encoding across unchecked, and v3 refuses configs v2 accepted.
                address upgradeTo = minterImplementation;
                bytes memory upgradeCall = abi.encodeCall(IMinter.updateConfig, (inputs[i].minterConfig));
                string memory how = "upgrade to Minter_v3, loading its config through v3's loader";
                if (_recordsBackingItHoldsNoneOf(inputs[i])) {
                    // Minter_v3 would halt a minter recording backing it holds none of - a retired market's rounding
                    // dust - as impaired. Nothing held is worth nothing, so the upgrader sets the record to zero on
                    // the way.
                    upgradeTo = minterUpgrader;
                    upgradeCall = abi.encodeCall(
                        IMinter_v3_Upgrader.zeroBackingAndUpgrade,
                        (minterImplementation, upgradeCall)
                    );
                    how = "set the backing it records but does not hold to zero, then upgrade to Minter_v3, loading its config";
                }
                queue(
                    minterKey(config),
                    abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (upgradeTo, upgradeCall)),
                    how
                );
            }
            // A deploy wires the minter to the oracle proxy it predicts; a minter reading another oracle is pointed at
            // it, so every minter reads its price as a fresh deploy's does. A minter whose batch carries the owner's
            // operations reads their reading, held still, until they are done, and the proxy after.
            bool operated = _hasOperations(inputs[i].ownerOperations);
            if (operated) {
                OracleAnswer memory answer = inputs[i].ownerOperations.answer;
                address frozen = address(
                    new FrozenPriceOracle(answer.minPrice, answer.maxPrice, answer.minRate, answer.maxRate)
                );
                _recordImplementation(
                    state,
                    "*",
                    "@harbor-script/UpgradeMinter_v2_v3/FrozenPriceOracle.sol",
                    "FrozenPriceOracle",
                    frozen
                );
                queue(
                    minterKey(config),
                    abi.encodeCall(IMinter.updatePriceOracle, (frozen)),
                    string.concat(
                        "read the price the owner's operations are priced at, held still: ",
                        _scaled(answer.minPrice),
                        " to ",
                        _scaled(answer.maxPrice),
                        " pegged per collateral, at a wrapped rate of ",
                        _scaled(answer.minRate),
                        " to ",
                        _scaled(answer.maxRate)
                    )
                );
            } else if (inputs[i].priceOracle != addresses.oracle) {
                queue(
                    minterKey(config),
                    abi.encodeCall(IMinter.updatePriceOracle, (addresses.oracle)),
                    "read the price from the oracle proxy the deploy predicts"
                );
            }
            _queuePoolMigration(
                config,
                StabilityPoolType.Collateral,
                inputs[i].collateralPool,
                collateralPoolImplementation,
                upgrader
            );
            _queuePoolMigration(
                config,
                StabilityPoolType.Leveraged,
                inputs[i].leveragedPool,
                leveragedPoolImplementation,
                upgrader
            );
            queue(
                stabilityPoolManagerKey(config),
                abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (managerImplementation, "")),
                "upgrade to StabilityPoolManager_v2"
            );

            string memory market = MinterMarketConfigLib.salt(config);
            {
                // The owner's fee-free operations, on the market now running v3 and reading their reading. Each
                // redemption burns from the owner's allowance and each mint takes the wrapped collateral from it, so
                // each is preceded by its approval. The redemptions have no floor on what they return: the minter
                // prices them by a reading fixed here, so there is nothing to slip against.
                OwnerOperations memory operations = inputs[i].ownerOperations;
                if (operations.accounts.length != operations.mints.length) {
                    revert AccountsAndMintsOfDifferentLengths(
                        market,
                        operations.accounts.length,
                        operations.mints.length
                    );
                }
                if (operations.peggedRedeemed > 0) {
                    queue(
                        addresses.pegged,
                        abi.encodeCall(IERC20.approve, (addresses.minter, operations.peggedRedeemed)),
                        string.concat("approve the minter for ", _scaled(operations.peggedRedeemed), " pegged")
                    );
                    queue(
                        minterKey(config),
                        abi.encodeCall(IMinter_v3.freeRedeemPeggedToken, (operations.peggedRedeemed, 0, owner())),
                        string.concat("redeem ", _scaled(operations.peggedRedeemed), " pegged, fee-free")
                    );
                }
                if (operations.leveragedRedeemed > 0) {
                    queue(
                        addresses.leveraged,
                        abi.encodeCall(IERC20.approve, (addresses.minter, operations.leveragedRedeemed)),
                        string.concat("approve the minter for ", _scaled(operations.leveragedRedeemed), " leveraged")
                    );
                    queue(
                        minterKey(config),
                        abi.encodeCall(IMinter_v3.freeRedeemLeveragedToken, (operations.leveragedRedeemed, owner())),
                        string.concat("redeem ", _scaled(operations.leveragedRedeemed), " leveraged, fee-free")
                    );
                }
                uint256 minted;
                for (uint256 a = 0; a < operations.mints.length; ++a) {
                    minted += operations.mints[a];
                }
                if (minted > 0) {
                    queue(
                        addresses.wrappedCollateral,
                        abi.encodeCall(IERC20.approve, (addresses.minter, minted)),
                        string.concat(
                            "approve the minter for the ",
                            _scaled(minted),
                            " wrapped collateral to mint with"
                        )
                    );
                }
                for (uint256 a = 0; a < operations.mints.length; ++a) {
                    if (operations.mints[a] > 0) {
                        queue(
                            minterKey(config),
                            abi.encodeCall(
                                IMinter_v3.freeMintLeveragedToken,
                                (operations.mints[a], operations.accounts[a])
                            ),
                            string.concat(
                                "mint leveraged with ",
                                _scaled(operations.mints[a]),
                                " wrapped collateral, fee-free, for ",
                                LibString.toHexStringChecksummed(operations.accounts[a])
                            )
                        );
                    }
                }
                if (operated) {
                    queue(
                        minterKey(config),
                        abi.encodeCall(IMinter.updatePriceOracle, (addresses.oracle)),
                        "the operations done, read the price from the oracle proxy the deploy predicts"
                    );
                }
            }
            flush(market, string.concat(market, ": ", _WHAT));
        }

        _saveState(state);
        _reportRunComplete(_WHAT);
    }

    /// @dev The `poolType` pool's input: every holder the capture lists, the ledger gap they leave, and its floor and
    ///      withdrawal window, each read from the pool now. Refuses holders that leave a gap beyond rounding either way.
    function _readPoolUpgradeInput(
        Config_MinterMarket config,
        StabilityPoolType poolType,
        string memory capture
    ) private returns (PoolUpgradeInput memory input) {
        string memory key = stabilityPoolKey(config, poolType);
        address pool = stabilityPoolAddress(config, poolType);

        input.holders = HolderCaptureLib.holders(capture, key);
        uint256 held;
        for (uint256 i = 0; i < input.holders.length; ++i) {
            held += IStabilityPool(pool).assetBalanceOf(input.holders[i]);
        }
        uint256 supply = IStabilityPool(pool).totalAssetSupply();
        input.gap = int256(supply) - int256(held);
        require(
            HolderCaptureLib.classify(input.gap, supply) == HolderCaptureLib.Gap.Rounding,
            string.concat(
                key,
                ": the captured holders hold ",
                LibString.toString(held),
                " of a supply of ",
                LibString.toString(supply),
                ", a gap beyond rounding"
            )
        );

        input.minTotalAssetSupply = IStabilityPool(pool).MIN_TOTAL_ASSET_SUPPLY();
        (input.withdrawalStartDelay, input.withdrawalEndWindow) = IStabilityPool(pool).getWithdrawalWindow();
    }

    /// @dev Whether the minter `input` describes records backing but holds no wrapped collateral - a retired market's
    ///      rounding dust.
    function _recordsBackingItHoldsNoneOf(MarketUpgradeInput memory input) private pure returns (bool) {
        return input.recordedBacking > 0 && input.wrappedCollateralHeld == 0;
    }

    /// @dev Whether `operations` has anything for the owner to do: a redemption, or an account to mint for.
    function _hasOperations(OwnerOperations memory operations) private pure returns (bool) {
        return operations.peggedRedeemed > 0 || operations.leveragedRedeemed > 0 || operations.accounts.length > 0;
    }

    /// @dev Queue the `poolType` pool's migration through `upgrader` to `implementation`, its new StabilityPool_v3, with
    ///      the holders, gap and deductions `input` holds. Refuses an implementation whose floor or withdrawal window
    ///      differs from the pool's.
    function _queuePoolMigration(
        Config_MinterMarket config,
        StabilityPoolType poolType,
        PoolUpgradeInput memory input,
        address implementation,
        address upgrader
    ) private {
        string memory key = stabilityPoolKey(config, poolType);

        uint256 floor = IStabilityPool_v3(implementation).MIN_TOTAL_ASSET_SUPPLY();
        require(
            floor == input.minTotalAssetSupply,
            string.concat(
                key,
                ": the pool's floor is ",
                LibString.toString(input.minTotalAssetSupply),
                ", its new implementation's ",
                LibString.toString(floor)
            )
        );
        (uint64 startDelay, uint64 endWindow) = IStabilityPool_v3(implementation).getWithdrawalWindow();
        require(
            startDelay == input.withdrawalStartDelay && endWindow == input.withdrawalEndWindow,
            string.concat(
                key,
                ": the pool's withdrawal window is ",
                LibString.toString(input.withdrawalStartDelay),
                " s then ",
                LibString.toString(input.withdrawalEndWindow),
                " s, its new implementation's ",
                LibString.toString(startDelay),
                " s then ",
                LibString.toString(endWindow),
                " s"
            )
        );

        queue(
            key,
            abi.encodeCall(
                UUPSUpgradeable.upgradeToAndCall,
                (
                    upgrader,
                    abi.encodeCall(
                        IStabilityPool_v3_Upgrader.migrateAndUpgrade,
                        (input.gap, input.holders, input.deductions, implementation)
                    )
                )
            ),
            input.deductions.length == 0
                ? "migrate through StabilityPool_v3_Upgrader to StabilityPool_v3"
                : string.concat(
                    "migrate through StabilityPool_v3_Upgrader to StabilityPool_v3, taking back ",
                    LibString.toString(input.deductions.length),
                    " rewards for the owner"
                )
        );
    }

    /// @dev An 18-decimal amount as "<whole>.<18 digits>", for a batch's descriptions and reports.
    function _scaled(uint256 amount) internal pure returns (string memory) {
        string memory fraction = LibString.toString(amount % 1 ether);
        bytes memory zeros = new bytes(18 - bytes(fraction).length);
        for (uint256 i = 0; i < zeros.length; ++i) {
            zeros[i] = "0";
        }
        return string.concat(LibString.toString(amount / 1 ether), ".", string(zeros), fraction);
    }

    /// @dev Requires the proxy named `key` at `proxy` to revert `call` with the pausers' `Paused` - BaoPauser_v1, which
    ///      froze the live markets, and its successor HarborPauser_v1 revert every call with it.
    function _requirePaused(string memory key, address proxy, bytes memory call) private view {
        (bool answered, bytes memory reason) = proxy.staticcall(call);
        require(
            !answered && reason.length >= 4 && bytes4(reason) == HarborPauser_v1.Paused.selector,
            string.concat(
                key,
                answered ? " answers" : " reverts other than Paused",
                " at block ",
                LibString.toString(block.number),
                ", the block after the capture's: the capture must end at the last block before the pause"
            )
        );
    }
}
