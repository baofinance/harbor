// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {PeggedToken} from "./contracts/PeggedToken.sol";
import {LeveragedToken} from "./contracts/LeveragedToken.sol";
import {Minter} from "./contracts/Minter.sol";
import {StabilityPool} from "./contracts/StabilityPool.sol";
import {StabilityPoolManager} from "./contracts/StabilityPoolManager.sol";
import {Genesis} from "./contracts/Genesis.sol";
import {DeploymentState} from "./DeploymentState.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {Minter_v1} from "@harbor/minter/Minter_v1.sol";
import {StabilityPool_v1} from "@harbor/minter/StabilityPool_v1.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

/// @notice Extended market config interface with methods from collateral and chain configs.
interface IFullMinterConfig {
    function peg() external view returns (string memory);
    function collateral() external view returns (string memory);
    function wrappedCollateralToken() external view returns (address);
    function treasury() external view returns (address);
    function minterConfig() external pure returns (IMinter.Config memory);
    // Peg config
    function minTotalSupply() external view returns (uint256);
    // Stability pool config
    function stabilityPoolWithdrawalDelay() external pure returns (uint256);
    function stabilityPoolWithdrawalPeriod() external pure returns (uint256);
    function stabilityPoolEarlyWithdrawalFeeRatio() external pure returns (uint256);
    // StabilityPoolManager config (rebalanceThreshold comes from volatility config)
    function rebalanceThreshold() external pure returns (uint256);
    function rebalanceBountyRatio() external pure returns (uint256);
    function harvestBountyRatio() external pure returns (uint256);
    function harvestCutRatio() external pure returns (uint256);
}

/// @notice Shared functionality for all minter deployment contracts.
/// @dev Provides common infrastructure and deployment primitives.
/// @dev ConfigProtocol inherited via FactoryDeployer → provides baoFactory(), owner(), systemSalt().
abstract contract DeployMintersShared is
    PeggedToken,
    LeveragedToken,
    Minter,
    StabilityPool,
    StabilityPoolManager,
    Genesis
{
    // Shared helper functions for state management

    function _loadOrSeedState(string memory network) internal returns (DeploymentTypes.State memory stateData) {
        stateData = _shouldPersistState()
            ? DeploymentState.load(network, systemSalt(), _stateDirectoryPrefix())
            : _seedEphemeralState(systemSalt(), network);
        stateData.baoFactory = baoFactory();

        console.log("");
        console.log("================================================================================");
        console.log("                          DEPLOYING MINTER CONTRACTS");
        console.log("================================================================================");
        console.log("  Salt:    %s", systemSalt());
        console.log("  Network: %s", network);
        return stateData;
    }

    function _finalizeDeploy(DeploymentTypes.State memory stateData) internal {
        _transferAllOwnerships();

        if (_shouldPersistState()) {
            DeploymentState.save(stateData, _stateDirectoryPrefix());
        }
        console.log("");
        console.log("================================================================================");
        console.log("                          MINTER DEPLOYMENT COMPLETE");
        console.log("================================================================================");
    }

    /// @notice Deploy complete minter infrastructure for a single market.
    function _deployMinterForMarket(DeploymentTypes.State memory stateData, Config_MinterMarket market) internal {
        IFullMinterConfig cfg = IFullMinterConfig(address(market));
        string memory marketKey = MinterMarketConfigLib.salt(market);

        console.log("");
        console.log("  > Market: %s", marketKey);

        // Deploy ReservePool
        _deployReservePool(stateData, marketKey);

        // Deploy Minter
        _deployMinter(stateData, cfg, marketKey);

        // Deploy Stability Pools
        _deployStabilityPools(stateData, cfg, marketKey);

        // Deploy StabilityPoolManager
        _deployStabilityPoolManager(stateData, cfg, marketKey);

        // Deploy Genesis
        _deployGenesis(stateData, cfg, marketKey);

        // Configure Minter and grant roles
        _configureMinter(cfg, marketKey);

        console.log("    [complete]");
    }

    function _deployReservePool(DeploymentTypes.State memory stateData, string memory marketKey) internal {
        console.log("    > %s::reservePool", marketKey);
        (address reservePoolImpl, ) = deployReservePoolImpl();
        console.log("        Impl:  %s", reservePoolImpl);
        (address reservePool, DeploymentTypes.ProxyRecord memory record) = deployReservePoolProxy(
            baoFactory(),
            marketKey,
            reservePoolImpl,
            owner(),
            systemSalt()
        );
        DeploymentState.recordProxy(stateData, record);
        _registerForOwnershipTransfer(reservePool, _saltString(record.id));
    }

    function _deployMinter(
        DeploymentTypes.State memory stateData,
        IFullMinterConfig cfg,
        string memory marketKey
    ) internal {
        address peggedToken = _predictAddress(string.concat(cfg.peg(), "::pegged"));
        address leveragedToken = _predictAddress(marketKey, "leveraged");

        console.log("    > %s::minter", marketKey);
        (address minterImpl, ) = deployMinterImpl(cfg.wrappedCollateralToken(), peggedToken, leveragedToken);
        console.log("        Impl:  %s", minterImpl);
        (address minter, DeploymentTypes.ProxyRecord memory record) = deployMinterProxy(
            baoFactory(),
            marketKey,
            minterImpl,
            owner(),
            systemSalt()
        );
        DeploymentState.recordProxy(stateData, record);
        _registerForOwnershipTransfer(minter, _saltString(record.id));
    }

    function _deployStabilityPools(
        DeploymentTypes.State memory stateData,
        IFullMinterConfig cfg,
        string memory marketKey
    ) internal {
        address minter = _predictAddress(marketKey, "minter");
        address leveragedToken = _predictAddress(marketKey, "leveraged");

        // Stability Pool Collateral
        {
            console.log("    > %s::stabilityPoolCollateral", marketKey);
            (address impl, ) = deployStabilityPoolImpl(
                minter,
                cfg.wrappedCollateralToken(),
                cfg.stabilityPoolWithdrawalDelay(),
                cfg.stabilityPoolWithdrawalPeriod(),
                cfg.minTotalSupply()
            );
            console.log("        Impl:  %s", impl);
            (address proxy, DeploymentTypes.ProxyRecord memory record) = deployStabilityPoolCollateralProxy(
                baoFactory(),
                marketKey,
                impl,
                owner(),
                cfg.stabilityPoolEarlyWithdrawalFeeRatio(),
                cfg.treasury(),
                systemSalt()
            );
            DeploymentState.recordProxy(stateData, record);
            _registerForOwnershipTransfer(proxy, _saltString(record.id));
        }

        // Stability Pool Leveraged
        {
            console.log("    > %s::stabilityPoolLeveraged", marketKey);
            (address impl, ) = deployStabilityPoolImpl(
                minter,
                leveragedToken,
                cfg.stabilityPoolWithdrawalDelay(),
                cfg.stabilityPoolWithdrawalPeriod(),
                cfg.minTotalSupply()
            );
            console.log("        Impl:  %s", impl);
            (address proxy, DeploymentTypes.ProxyRecord memory record) = deployStabilityPoolLeveragedProxy(
                baoFactory(),
                marketKey,
                impl,
                owner(),
                cfg.stabilityPoolEarlyWithdrawalFeeRatio(),
                cfg.treasury(),
                systemSalt()
            );
            DeploymentState.recordProxy(stateData, record);
            _registerForOwnershipTransfer(proxy, _saltString(record.id));
        }
    }

    function _deployStabilityPoolManager(
        DeploymentTypes.State memory stateData,
        IFullMinterConfig cfg,
        string memory marketKey
    ) internal {
        address minter = _predictAddress(marketKey, "minter");
        address spCollateral = _predictAddress(marketKey, "stabilityPoolCollateral");
        address spLeveraged = _predictAddress(marketKey, "stabilityPoolLeveraged");

        console.log("    > %s::stabilityPoolManager", marketKey);
        (address impl, ) = deployStabilityPoolManagerImpl(minter, cfg.treasury(), spCollateral, spLeveraged);
        console.log("        Impl:  %s", impl);
        (address proxy, DeploymentTypes.ProxyRecord memory record) = deployStabilityPoolManagerProxy(
            baoFactory(),
            marketKey,
            impl,
            owner(),
            systemSalt()
        );
        DeploymentState.recordProxy(stateData, record);
        _registerForOwnershipTransfer(proxy, _saltString(record.id));
    }

    function _deployGenesis(
        DeploymentTypes.State memory stateData,
        IFullMinterConfig cfg,
        string memory marketKey
    ) internal {
        cfg;

        address minter = _predictAddress(marketKey, "minter");

        console.log("    > %s::genesis", marketKey);
        (address impl, ) = deployGenesisImpl(minter);
        console.log("        Impl:  %s", impl);
        (address proxy, DeploymentTypes.ProxyRecord memory record) = deployGenesisProxy(
            baoFactory(),
            marketKey,
            impl,
            owner(),
            systemSalt()
        );
        DeploymentState.recordProxy(stateData, record);
        _registerForOwnershipTransfer(proxy, _saltString(record.id));
    }

    function _configureMinter(IFullMinterConfig cfg, string memory marketKey) internal {
        address minter = _predictAddress(marketKey, "minter");
        address reservePool = _predictAddress(marketKey, "reservePool");
        address spCollateral = _predictAddress(marketKey, "stabilityPoolCollateral");
        address spLeveraged = _predictAddress(marketKey, "stabilityPoolLeveraged");
        address spm = _predictAddress(marketKey, "stabilityPoolManager");
        address genesis = _predictAddress(marketKey, "genesis");
        address leveragedToken = _predictAddress(marketKey, "leveraged");
        address priceOracle = _predictAddress(marketKey, "wrappedPriceAggregator");

        // Update minter configuration (incentive ratios)
        Minter_v1(minter).updateConfig(cfg.minterConfig());
        Minter_v1(minter).updateReservePool(reservePool);
        Minter_v1(minter).updateFeeReceiver(cfg.treasury());
        Minter_v1(minter).updatePriceOracle(priceOracle);

        // Grant roles
        grantReservePoolRoles(reservePool, minter);
        grantMinterRoles(minter, spm, genesis);
        grantStabilityPoolRoles(spCollateral, spm);
        grantStabilityPoolRoles(spLeveraged, spm);

        // Register reward tokens
        StabilityPool_v1(spCollateral).registerRewardToken(cfg.wrappedCollateralToken());
        StabilityPool_v1(spLeveraged).registerRewardToken(cfg.wrappedCollateralToken());
        StabilityPool_v1(spLeveraged).registerRewardToken(leveragedToken);

        // Configure StabilityPoolManager
        configureStabilityPoolManager(
            spm,
            SPMConfig({
                rebalanceThreshold: cfg.rebalanceThreshold(),
                rebalanceBountyRatio: cfg.rebalanceBountyRatio(),
                harvestBountyRatio: cfg.harvestBountyRatio(),
                harvestCutRatio: cfg.harvestCutRatio(),
                feeReceiver: cfg.treasury()
            })
        );
    }

    function _shouldPersistState() internal pure virtual returns (bool) {
        return true;
    }

    function _stateDirectoryPrefix() internal view virtual returns (string memory) {
        return "";
    }

    function _seedEphemeralState(
        string memory saltPrefix,
        string memory network
    ) internal pure returns (DeploymentTypes.State memory stateData) {
        stateData.network = network;
        stateData.saltPrefix = saltPrefix;
        return stateData;
    }
}
