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

        console.log("=== Deploying Minter Contracts ===");
        console.log("  Salt:    %s", systemSalt());
        console.log("  Network: %s", network);
        return stateData;
    }

    function _finalizeDeploy(DeploymentTypes.State memory stateData) internal {
        _transferAllOwnerships();

        if (_shouldPersistState()) {
            DeploymentState.save(stateData, _stateDirectoryPrefix());
        }
        console.log("=== Minter Deployment Done ===");
    }

    /// @notice Deploy pegged token and all markets for a peg (public entry point).
    function deployAllForPeg(ConfigPeg peg, Config_MinterMarket[] memory markets, string memory network) internal {
        DeploymentTypes.State memory stateData = _loadOrSeedState(network);
        _deployPegAndMarkets(stateData, peg, markets);
        _finalizeDeploy(stateData);
    }

    /// @notice Deploy pegged token and all markets for a peg.
    function _deployPegAndMarkets(
        DeploymentTypes.State memory stateData,
        ConfigPeg peg,
        Config_MinterMarket[] memory markets
    ) internal {
        console.log("");
        console.log("--- Deploying %s Peg and Markets ---", peg.key());

        deployPeggedTokenWithRoles(stateData, peg, markets);

        for (uint256 i = 0; i < markets.length; i++) {
            _deployMinterForMarket(stateData, markets[i]);
        }
    }

    /// @notice Deploy complete minter infrastructure for a single market.
    function _deployMinterForMarket(DeploymentTypes.State memory stateData, Config_MinterMarket market) internal {
        IFullMinterConfig cfg = IFullMinterConfig(address(market));
        string memory marketKey = MinterMarketConfigLib.salt(market);

        console.log("");
        console.log("  > Market: %s", marketKey);

        // Deploy LeveragedToken
        deployLeveragedTokenWithRoles(stateData, market);

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
        deployReservePool(stateData, marketKey);
    }

    function _deployMinter(
        DeploymentTypes.State memory stateData,
        IFullMinterConfig cfg,
        string memory marketKey
    ) internal {
        address wrappedCollateral = cfg.wrappedCollateralToken();
        address peggedToken = _predictAddress(string.concat(cfg.peg(), "::pegged"));
        address leveragedToken = _predictAddress(marketKey, "leveraged");

        deployMinter(stateData, marketKey, wrappedCollateral, peggedToken, leveragedToken);
    }

    function _deployStabilityPools(
        DeploymentTypes.State memory stateData,
        IFullMinterConfig cfg,
        string memory marketKey
    ) internal {
        address minter = _predictAddress(marketKey, "minter");
        address leveragedToken = _predictAddress(marketKey, "leveraged");

        StabilityPoolConfig memory spConfig = StabilityPoolConfig({
            earlyWithdrawalFeeRatio: cfg.stabilityPoolEarlyWithdrawalFeeRatio(),
            withdrawalDelay: cfg.stabilityPoolWithdrawalDelay(),
            withdrawalPeriod: cfg.stabilityPoolWithdrawalPeriod(),
            minTotalAssetSupply: cfg.minTotalSupply(),
            treasury: cfg.treasury()
        });

        deployStabilityPoolCollateral(stateData, marketKey, minter, cfg.wrappedCollateralToken(), spConfig);

        deployStabilityPoolLeveraged(stateData, marketKey, minter, leveragedToken, spConfig);
    }

    function _deployStabilityPoolManager(
        DeploymentTypes.State memory stateData,
        IFullMinterConfig cfg,
        string memory marketKey
    ) internal {
        address minter = _predictAddress(marketKey, "minter");
        address spCollateral = _predictAddress(marketKey, "stabilityPoolCollateral");
        address spLeveraged = _predictAddress(marketKey, "stabilityPoolLeveraged");

        deployStabilityPoolManager(stateData, marketKey, minter, cfg.treasury(), spCollateral, spLeveraged);
    }

    function _deployGenesis(
        DeploymentTypes.State memory stateData,
        IFullMinterConfig cfg,
        string memory marketKey
    ) internal {
        cfg;
        address minter = _predictAddress(marketKey, "minter");
        deployGenesis(stateData, marketKey, minter);
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

    function _stateDirectoryPrefix() internal pure virtual returns (string memory) {
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
