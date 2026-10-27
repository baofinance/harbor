// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IStabilityPoolManager_v2} from "@harbor/interfaces/IStabilityPoolManager_v2.sol";
import {IStabilityPool_v3} from "@harbor/interfaces/IStabilityPool_v3.sol";
import {IYieldVaultManager} from "@harbor/interfaces/IYieldVaultManager.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";

/// @title MarketSettings - the settings of a market's contracts
/// @notice What a deploy writes to a market's contracts - their config, owners and roles, the addresses each names, its
///         limits and windows, the reward tokens a pool distributes - as against what holders' actions write, its
///         holdings. Each value is serialized as a string into the JSON object the caller names, under the key the v3
///         upgrade's records use, and the object is returned.
/// @dev Held by `MarketsCapture`, whose records add each contract's holdings to its settings, and by
///      `UpgradedMarketsMatchANativeDeploy`, which compares an upgraded market's settings with a native deploy's. The one
///      list serves both, so a setting added here is recorded by the rehearsal and compared with a native deploy alike.
///      A market's contracts are found by the deploy's own address functions on `deployment`, the run that deployed or
///      upgraded it, and by what those contracts name.
contract MarketSettings {
    // The well-known forge cheatcode address, referenced directly: this is not a test contract.
    Vm private constant _vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /// @notice The minter's settings: its owner and config; the wrapped collateral, oracle and fee receiver it names;
    ///         the roles the manager and genesis hold on it; and the reserve pool and each token it names, with the
    ///         owner of each and the roles the minter holds on it.
    function serializeMinter(
        string memory objectKey,
        HarborDeployer deployment,
        Config_MinterMarket market
    ) external returns (string memory json) {
        address minter = deployment.minterAddress(market);
        _vm.serializeString(objectKey, "minter_owner", _vm.toString(IBaoOwnable(minter).owner()));
        _vm.serializeString(objectKey, "minter_config", _vm.toString(abi.encode(IMinter(minter).config())));
        _vm.serializeString(
            objectKey,
            "minter_wrappedCollateralToken",
            _vm.toString(IMinter(minter).WRAPPED_COLLATERAL_TOKEN())
        );
        _vm.serializeString(objectKey, "minter_priceOracle", _vm.toString(IMinter(minter).priceOracle()));
        _vm.serializeString(objectKey, "minter_feeReceiver", _vm.toString(IMinter(minter).feeReceiver()));
        _vm.serializeString(
            objectKey,
            "minter_rolesOf_manager",
            _vm.toString(IBaoRoles(minter).rolesOf(deployment.stabilityPoolManagerAddress(market)))
        );
        _vm.serializeString(
            objectKey,
            "minter_rolesOf_genesis",
            _vm.toString(IBaoRoles(minter).rolesOf(deployment.genesisAddress(market)))
        );
        _serializeNamedByTheMinter(objectKey, "minter_reservePool", IMinter(minter).reservePool(), minter);
        _serializeNamedByTheMinter(objectKey, "minter_peggedToken", IMinter(minter).PEGGED_TOKEN(), minter);
        json = _serializeNamedByTheMinter(
            objectKey,
            "minter_leveragedToken",
            IMinter(minter).LEVERAGED_TOKEN(),
            minter
        );
    }

    /// @notice A stability pool's settings, through `IStabilityPool_v3` where both versions share a view's selector: its
    ///         owner; its early-withdrawal fee and where the fee goes; its withdrawal window, floor and asset; its reward
    ///         period; the reward tokens it distributes and those it no longer does; and the roles the manager holds on
    ///         it.
    function serializePool(
        string memory objectKey,
        HarborDeployer deployment,
        Config_MinterMarket market,
        HarborDeployer.StabilityPoolType poolType
    ) external returns (string memory json) {
        address pool = deployment.stabilityPoolAddress(market, poolType);
        _vm.serializeString(objectKey, "state_owner", _vm.toString(IBaoOwnable(pool).owner()));
        _vm.serializeString(
            objectKey,
            "state_earlyWithdrawalFee",
            _vm.toString(IStabilityPool_v3(pool).getEarlyWithdrawalFee())
        );
        _vm.serializeString(objectKey, "state_feeAddress", _vm.toString(IStabilityPool_v3(pool).getFeeAddress()));
        {
            (uint64 startDelay, uint64 endWindow) = IStabilityPool_v3(pool).getWithdrawalWindow();
            _vm.serializeString(objectKey, "state_withdrawalStartDelay", _vm.toString(uint256(startDelay)));
            _vm.serializeString(objectKey, "state_withdrawalEndWindow", _vm.toString(uint256(endWindow)));
        }
        _vm.serializeString(
            objectKey,
            "state_minTotalAssetSupply",
            _vm.toString(IStabilityPool_v3(pool).MIN_TOTAL_ASSET_SUPPLY())
        );
        _vm.serializeString(objectKey, "state_assetToken", _vm.toString(IStabilityPool_v3(pool).ASSET_TOKEN()));
        _vm.serializeString(
            objectKey,
            "state_rewardPeriodLength",
            _vm.toString(uint256(IMultipleRewardDistributor(pool).REWARD_PERIOD_LENGTH()))
        );
        {
            address[] memory activeTokens = IMultipleRewardDistributor(pool).activeRewardTokens();
            _vm.serializeString(objectKey, "state_activeRewardTokenCount", _vm.toString(activeTokens.length));
            for (uint256 i = 0; i < activeTokens.length; ++i) {
                _vm.serializeString(
                    objectKey,
                    string.concat("state_reward_", _vm.toString(i), "_token"),
                    _vm.toString(activeTokens[i])
                );
            }
        }
        {
            address[] memory historicalTokens = IMultipleRewardDistributor(pool).historicalRewardTokens();
            _vm.serializeString(objectKey, "state_historicalRewardTokenCount", _vm.toString(historicalTokens.length));
            for (uint256 i = 0; i < historicalTokens.length; ++i) {
                _vm.serializeString(
                    objectKey,
                    string.concat("state_historicalRewardToken_", _vm.toString(i)),
                    _vm.toString(historicalTokens[i])
                );
            }
        }
        json = _vm.serializeString(
            objectKey,
            "state_rolesOf_manager",
            _vm.toString(IBaoRoles(pool).rolesOf(deployment.stabilityPoolManagerAddress(market)))
        );
    }

    /// @notice StabilityPool_v2's own settings: the token it is paid in at a liquidation, which v3 does not name, and its
    ///         minimum deposit, which v3 calls the floor.
    function serializePoolV2(
        string memory objectKey,
        HarborDeployer deployment,
        Config_MinterMarket market,
        HarborDeployer.StabilityPoolType poolType
    ) external returns (string memory json) {
        address pool = deployment.stabilityPoolAddress(market, poolType);
        _vm.serializeString(
            objectKey,
            "state_liquidationToken",
            _vm.toString(IStabilityPool(pool).LIQUIDATION_TOKEN())
        );
        json = _vm.serializeString(objectKey, "state_minDeposit", _vm.toString(IStabilityPool(pool).MIN_DEPOSIT()));
    }

    /// @notice StabilityPool_v3's own settings: the minter it names, which v2 does not.
    function serializePoolV3(
        string memory objectKey,
        HarborDeployer deployment,
        Config_MinterMarket market,
        HarborDeployer.StabilityPoolType poolType
    ) external returns (string memory json) {
        address pool = deployment.stabilityPoolAddress(market, poolType);
        json = _vm.serializeString(objectKey, "state_minter", _vm.toString(IStabilityPool_v3(pool).MINTER()));
    }

    /// @notice The manager's settings: its owner, its pools, its harvest and rebalance ratios and threshold, whom it
    ///         pays, and the minter and tokens it names.
    function serializeManager(
        string memory objectKey,
        HarborDeployer deployment,
        Config_MinterMarket market
    ) external returns (string memory json) {
        address manager = deployment.stabilityPoolManagerAddress(market);
        _vm.serializeString(objectKey, "manager_owner", _vm.toString(IBaoOwnable(manager).owner()));
        {
            address[] memory pools = IStabilityPoolManager(manager).stabilityPools();
            for (uint256 i = 0; i < pools.length; ++i) {
                _vm.serializeString(
                    objectKey,
                    string.concat("manager_stabilityPool_", _vm.toString(i)),
                    _vm.toString(pools[i])
                );
            }
        }
        _vm.serializeString(
            objectKey,
            "manager_harvestBountyRatio",
            _vm.toString(IStabilityPoolManager(manager).harvestBountyRatio())
        );
        _vm.serializeString(
            objectKey,
            "manager_harvestCutRatio",
            _vm.toString(IStabilityPoolManager(manager).harvestCutRatio())
        );
        _vm.serializeString(
            objectKey,
            "manager_rebalanceBountyRatio",
            _vm.toString(IStabilityPoolManager(manager).rebalanceBountyRatio())
        );
        _vm.serializeString(
            objectKey,
            "manager_rebalanceThreshold",
            _vm.toString(IStabilityPoolManager(manager).rebalanceThreshold())
        );
        _vm.serializeString(
            objectKey,
            "manager_feeReceiver",
            _vm.toString(IStabilityPoolManager(manager).feeReceiver())
        );
        // StabilityPoolManager_v1 keeps these as public immutables too; v2's interface declares them.
        IStabilityPoolManager_v2 named = IStabilityPoolManager_v2(manager);
        _vm.serializeString(objectKey, "manager_minter", _vm.toString(named.MINTER()));
        _vm.serializeString(
            objectKey,
            "manager_wrappedCollateralToken",
            _vm.toString(named.WRAPPED_COLLATERAL_TOKEN())
        );
        _vm.serializeString(objectKey, "manager_peggedToken", _vm.toString(named.PEGGED_TOKEN()));
        json = _vm.serializeString(objectKey, "manager_leveragedToken", _vm.toString(named.LEVERAGED_TOKEN()));
    }

    /// @notice StabilityPoolManager_v2's own settings: the interface it reports, and how many yield vaults it compounds.
    function serializeManagerV2(
        string memory objectKey,
        HarborDeployer deployment,
        Config_MinterMarket market
    ) external returns (string memory json) {
        address manager = deployment.stabilityPoolManagerAddress(market);
        _vm.serializeString(
            objectKey,
            "manager_reportsStabilityPoolManager_v2",
            _vm.toString(IERC165(manager).supportsInterface(type(IStabilityPoolManager_v2).interfaceId))
        );
        json = _vm.serializeString(
            objectKey,
            "manager_yieldVaultCount",
            _vm.toString(IYieldVaultManager(manager).yieldVaultCount())
        );
    }

    /// @dev Serialize `key` as `target`, a contract the minter names; `key`_owner as its owner; and `key`_rolesOf_minter
    ///      as the roles `minter` holds on it.
    function _serializeNamedByTheMinter(
        string memory objectKey,
        string memory key,
        address target,
        address minter
    ) private returns (string memory json) {
        _vm.serializeString(objectKey, key, _vm.toString(target));
        _vm.serializeString(objectKey, string.concat(key, "_owner"), _vm.toString(IBaoOwnable(target).owner()));
        json = _vm.serializeString(
            objectKey,
            string.concat(key, "_rolesOf_minter"),
            _vm.toString(IBaoRoles(target).rolesOf(minter))
        );
    }
}
