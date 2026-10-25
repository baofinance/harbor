// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {HarborPauser_v1} from "@bao/HarborPauser_v1.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {MarketAddresses} from "@harbor-script/src/MarketAddresses.sol";
import {MarketVerification} from "@harbor-script/src/MarketVerification.sol";
import {Minter} from "@harbor-script/src/contracts/Minter.sol";
import {StabilityPool} from "@harbor-script/src/contracts/StabilityPool.sol";
import {StabilityPoolManager} from "@harbor-script/src/contracts/StabilityPoolManager.sol";
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
abstract contract UpgradeMarketToV3 is Minter, StabilityPool, StabilityPoolManager, MarketVerification {
    Vm private constant _vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev What this run does, named once so its opening and closing lines cannot drift apart.
    string private constant _WHAT = "upgrade to Minter_v3, StabilityPool_v3 and StabilityPoolManager_v2";

    /// @notice What one pool's upgrade needs from it: the holders whose reward records the migration copies, the
    ///         ledger gap they leave - the pool's supply less what they hold, either sign - and the floor and withdrawal
    ///         window its new implementation must keep.
    struct PoolUpgradeInput {
        address[] holders;
        int256 gap;
        uint256 minTotalAssetSupply;
        uint64 withdrawalStartDelay;
        uint64 withdrawalEndWindow;
    }

    /// @notice What one market's upgrade needs from it: its minter's stored config and each pool's input.
    struct MarketUpgradeInput {
        Config_MinterMarket market;
        IMinter.Config minterConfig;
        PoolUpgradeInput collateralPool;
        PoolUpgradeInput leveragedPool;
    }

    /// @notice Read what upgrading each of `markets` needs, on the fork selected now: each minter's stored config, and
    ///         for each pool the holders the capture in `capture` lists, the ledger gap they leave, and its floor and
    ///         withdrawal window. Refuses a capture whose holders leave a gap beyond rounding either way.
    function readMarketUpgradeInputs(
        Config_MinterMarket[] memory markets,
        string memory capture
    ) internal returns (MarketUpgradeInput[] memory inputs) {
        inputs = new MarketUpgradeInput[](markets.length);
        for (uint256 i = 0; i < markets.length; ++i) {
            inputs[i].market = markets[i];
            inputs[i].minterConfig = IMinter(minterAddress(markets[i])).config();
            inputs[i].collateralPool = _readPoolUpgradeInput(markets[i], StabilityPoolType.Collateral, capture);
            inputs[i].leveragedPool = _readPoolUpgradeInput(markets[i], StabilityPoolType.Leveraged, capture);
        }
    }

    /// @notice `readMarketUpgradeInputs` for markets a pause has frozen, read at the capture's block on `network`. That
    ///         block must be the last before the pause: at the next block every minter and pool reverts `Paused`. The
    ///         pause changes only which implementation each proxy runs, so what is read there is what the upgrade runs
    ///         on. The fork selected before is selected again after.
    function readFrozenMarketUpgradeInputs(
        Config_MinterMarket[] memory markets,
        string memory capture,
        string memory network
    ) internal returns (MarketUpgradeInput[] memory inputs) {
        uint256 head = _vm.activeFork();
        // A contract made on one fork is absent from another unless persistent: this deployer, and the market configs.
        _vm.makePersistent(address(this));
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
        inputs = readMarketUpgradeInputs(markets, capture);
        _vm.selectFork(head);
    }

    /// @notice Upgrade each market `inputs` names: deploy its new implementations, check they name its tokens and each
    ///         other (`verifyMarket`), and save, as one batch for the multisig, the upgrade of its minter, loading the
    ///         config read; of its two pools, through one `StabilityPool_v3_Upgrader` for every pool, with the holders
    ///         and gap read; and of its manager, in that order. Refuses a pool whose new implementation would not keep
    ///         the floor or withdrawal window read.
    /// @dev The deployment state is made as every deploy run makes it: the state file when the run persists, a fresh
    ///      state when it does not.
    function upgradeMarketsToV3(MarketUpgradeInput[] memory inputs, string memory network) internal {
        DeploymentTypes.State memory state = _shouldPersistState()
            ? DeploymentState.load(_stateFileRead())
            : DeploymentState.fresh(saltPrefix(), network);
        state.baoFactory = baoFactory();
        _reportRun(_WHAT, saltPrefix(), network);

        // The upgrader upgrades each pool away from itself in the call that runs it, so one serves every pool.
        address upgrader = address(new StabilityPool_v3_Upgrader(owner()));

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
            verifyMarket(
                config,
                addresses,
                minterImplementation,
                collateralPoolImplementation,
                leveragedPoolImplementation,
                managerImplementation
            );

            // The stored config is loaded again, through Minter_v3's own loader, in the call that upgrades: the plain
            // swap would carry the stored encoding across unchecked, and v3 refuses configs v2 accepted.
            queue(
                minterKey(config),
                abi.encodeCall(
                    UUPSUpgradeable.upgradeToAndCall,
                    (minterImplementation, abi.encodeCall(IMinter.updateConfig, (inputs[i].minterConfig)))
                ),
                "upgrade to Minter_v3, loading its config through v3's loader"
            );
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

    /// @dev Queue the `poolType` pool's migration through `upgrader` to `implementation`, its new StabilityPool_v3, with
    ///      the holders and gap `input` holds. Refuses an implementation whose floor or withdrawal window differs from
    ///      the pool's.
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
                        StabilityPool_v3_Upgrader.migrateAndUpgrade,
                        (input.gap, input.holders, implementation)
                    )
                )
            ),
            "migrate through StabilityPool_v3_Upgrader to StabilityPool_v3"
        );
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
