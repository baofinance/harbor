// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborDeployment_MinterTokens} from "./HarborDeployment_MinterTokens.sol";
import {HarborDeployment_Minter} from "./HarborDeployment_Minter.sol";
import {HarborDeployment_StabilityPool} from "./HarborDeployment_StabilityPool.sol";
import {HarborDeployment_StabilityPoolManager} from "./HarborDeployment_StabilityPoolManager.sol";
import {HarborDeployment_Genesis} from "./HarborDeployment_Genesis.sol";
import {DeploymentState} from "./DeploymentState.sol";
import {DeploymentTypes} from "./DeploymentTypes.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {ConfigPeg_ETH} from "script/config/pegs/ConfigPeg_ETH.sol";
import {ConfigPeg_BTC} from "script/config/pegs/ConfigPeg_BTC.sol";
import {ConfigPeg_GOLD} from "script/config/pegs/ConfigPeg_GOLD.sol";
import {ConfigPeg_EUR} from "script/config/pegs/ConfigPeg_EUR.sol";
import {ConfigPeg_MCAP} from "script/config/pegs/ConfigPeg_MCAP.sol";
import {ConfigPeg_SILVER} from "script/config/pegs/ConfigPeg_SILVER.sol";
import {ConfigMarket_ETH_fxUSD_mainnet} from "script/config/markets/ConfigMarket_ETH_fxUSD_mainnet.sol";
import {ConfigMarket_BTC_fxUSD_mainnet} from "script/config/markets/ConfigMarket_BTC_fxUSD_mainnet.sol";
import {ConfigMarket_BTC_stETH_mainnet} from "script/config/markets/ConfigMarket_BTC_stETH_mainnet.sol";
import {ConfigMarket_EUR_fxUSD_mainnet} from "script/config/markets/ConfigMarket_EUR_fxUSD_mainnet.sol";
import {ConfigMarket_EUR_stETH_mainnet} from "script/config/markets/ConfigMarket_EUR_stETH_mainnet.sol";
import {ConfigMarket_GOLD_fxUSD_mainnet} from "script/config/markets/ConfigMarket_GOLD_fxUSD_mainnet.sol";
import {ConfigMarket_GOLD_stETH_mainnet} from "script/config/markets/ConfigMarket_GOLD_stETH_mainnet.sol";
import {ConfigMarket_MCAP_fxUSD_mainnet} from "script/config/markets/ConfigMarket_MCAP_fxUSD_mainnet.sol";
import {ConfigMarket_MCAP_stETH_mainnet} from "script/config/markets/ConfigMarket_MCAP_stETH_mainnet.sol";
import {ConfigMarket_SILVER_fxUSD_mainnet} from "script/config/markets/ConfigMarket_SILVER_fxUSD_mainnet.sol";
import {ConfigMarket_SILVER_stETH_mainnet} from "script/config/markets/ConfigMarket_SILVER_stETH_mainnet.sol";
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

/// @notice Configuration for all minter deployment.
/// @dev Created BEFORE startBroadcast() so config contracts are NOT deployed on-chain.
/// @dev Defined at file scope for import/export capability.
struct AllMintersConfig {
    ConfigPeg pegETH;
    ConfigPeg pegBTC;
    ConfigPeg pegGOLD;
    ConfigPeg pegEUR;
    ConfigPeg pegMCAP;
    ConfigPeg pegSILVER;
    Config_MinterMarket[] marketsETH; // Markets using ETH peg
    Config_MinterMarket[] marketsBTC; // Markets using BTC peg
    Config_MinterMarket[] marketsGOLD; // Markets using GOLD peg
    Config_MinterMarket[] marketsEUR; // Markets using EUR peg
    Config_MinterMarket[] marketsMCAP; // Markets using MCAP peg
    Config_MinterMarket[] marketsSILVER; // Markets using SILVER peg
}

/// @notice Orchestration for complete minter deployment (tokens + infrastructure).
/// @dev Deploys: pegged tokens, leveraged tokens, minter, SP, SPM, reserve pool, genesis.
/// @dev Contract-specific deployment logic lives in HarborDeployment_*.sol files.
/// @dev ConfigProtocol inherited via FactoryDeployer → provides baoFactory(), owner(), systemSalt().
abstract contract DeployMintersBase is
    HarborDeployment_MinterTokens,
    HarborDeployment_Minter,
    HarborDeployment_StabilityPool,
    HarborDeployment_StabilityPoolManager,
    HarborDeployment_Genesis
{
    /// @notice Create all config objects - call BEFORE startBroadcast().
    /// @dev Config contracts created here are NOT deployed on-chain.
    /// @dev See deployment2-design.md Section 3.3.4 for pattern.
    function createAllMintersConfig() internal returns (AllMintersConfig memory config) {
        // Peg configs
        config.pegETH = new ConfigPeg_ETH();
        config.pegBTC = new ConfigPeg_BTC();
        config.pegGOLD = new ConfigPeg_GOLD();
        config.pegEUR = new ConfigPeg_EUR();
        config.pegMCAP = new ConfigPeg_MCAP();
        config.pegSILVER = new ConfigPeg_SILVER();

        // ETH peg markets
        config.marketsETH = new Config_MinterMarket[](1);
        config.marketsETH[0] = new ConfigMarket_ETH_fxUSD_mainnet();

        // BTC peg markets
        config.marketsBTC = new Config_MinterMarket[](2);
        config.marketsBTC[0] = new ConfigMarket_BTC_fxUSD_mainnet();
        config.marketsBTC[1] = new ConfigMarket_BTC_stETH_mainnet();

        // GOLD peg markets
        config.marketsGOLD = new Config_MinterMarket[](2);
        config.marketsGOLD[0] = new ConfigMarket_GOLD_fxUSD_mainnet();
        config.marketsGOLD[1] = new ConfigMarket_GOLD_stETH_mainnet();

        // EUR peg markets
        config.marketsEUR = new Config_MinterMarket[](2);
        config.marketsEUR[0] = new ConfigMarket_EUR_fxUSD_mainnet();
        config.marketsEUR[1] = new ConfigMarket_EUR_stETH_mainnet();

        // MCAP peg markets
        config.marketsMCAP = new Config_MinterMarket[](2);
        config.marketsMCAP[0] = new ConfigMarket_MCAP_fxUSD_mainnet();
        config.marketsMCAP[1] = new ConfigMarket_MCAP_stETH_mainnet();

        // SILVER peg markets
        config.marketsSILVER = new Config_MinterMarket[](2);
        config.marketsSILVER[0] = new ConfigMarket_SILVER_fxUSD_mainnet();
        config.marketsSILVER[1] = new ConfigMarket_SILVER_stETH_mainnet();

        return config;
    }

    /// @notice Deploy all Harbor minter contracts: tokens, minter, SP, SPM, reserve pool, genesis.
    /// @dev Call INSIDE startBroadcast(). Config must be created before broadcast.
    /// @param config All minter configs (created by createAllMintersConfig()).
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    /// @param useLocal Whether to read/write state in the local results directory.
    function deployAll(AllMintersConfig memory config, string memory network, bool useLocal) internal {
        // Load existing state to resume partial deployments, or seed fresh if not persisting.
        DeploymentTypes.State memory stateData = _shouldPersistState()
            ? DeploymentState.load(network, systemSalt(), useLocal, _stateDirectoryPrefix())
            : _seedEphemeralState(systemSalt(), network, useLocal);
        stateData.baoFactory = baoFactory();

        console.log("");
        console.log("================================================================================");
        console.log("                          DEPLOYING MINTER CONTRACTS");
        console.log("================================================================================");
        console.log("  Salt:    %s", systemSalt());
        console.log("  Network: %s", network);

        deployAll_ETH(stateData, config);
        deployAll_BTC(stateData, config);
        deployAll_GOLD(stateData, config);
        deployAll_EUR(stateData, config);
        deployAll_MCAP(stateData, config);
        deployAll_SILVER(stateData, config);

        _transferAllOwnerships();

        if (_shouldPersistState()) {
            DeploymentState.save(stateData, _stateDirectoryPrefix());
        }
        console.log("");
        console.log("================================================================================");
        console.log("                          MINTER DEPLOYMENT COMPLETE");
        console.log("================================================================================");
    }

    /// @notice Deploy ETH pegged token and all ETH markets.
    function deployAll_ETH(DeploymentTypes.State memory stateData, AllMintersConfig memory config) private {
        console.log("");
        console.log("--- Deploying ETH Peg and Markets ---");

        deployPeggedTokenWithRoles(stateData, config.pegETH, config.marketsETH, baoFactory(), owner(), systemSalt());

        for (uint256 i = 0; i < config.marketsETH.length; i++) {
            deployLeveragedTokenWithRoles(stateData, config.marketsETH[i], baoFactory(), owner(), systemSalt());
            _deployMinterForMarket(stateData, config.marketsETH[i]);
        }
    }

    /// @notice Deploy BTC pegged token and all BTC markets.
    function deployAll_BTC(DeploymentTypes.State memory stateData, AllMintersConfig memory config) private {
        console.log("");
        console.log("--- Deploying BTC Peg and Markets ---");

        deployPeggedTokenWithRoles(stateData, config.pegBTC, config.marketsBTC, baoFactory(), owner(), systemSalt());

        for (uint256 i = 0; i < config.marketsBTC.length; i++) {
            deployLeveragedTokenWithRoles(stateData, config.marketsBTC[i], baoFactory(), owner(), systemSalt());
            _deployMinterForMarket(stateData, config.marketsBTC[i]);
        }
    }

    /// @notice Deploy GOLD pegged token and all GOLD markets.
    function deployAll_GOLD(DeploymentTypes.State memory stateData, AllMintersConfig memory config) private {
        console.log("");
        console.log("--- Deploying GOLD Peg and Markets ---");

        deployPeggedTokenWithRoles(stateData, config.pegGOLD, config.marketsGOLD, baoFactory(), owner(), systemSalt());

        for (uint256 i = 0; i < config.marketsGOLD.length; i++) {
            deployLeveragedTokenWithRoles(stateData, config.marketsGOLD[i], baoFactory(), owner(), systemSalt());
            _deployMinterForMarket(stateData, config.marketsGOLD[i]);
        }
    }

    /// @notice Deploy SILVER pegged token and all SILVER markets.
    function deployAll_SILVER(DeploymentTypes.State memory stateData, AllMintersConfig memory config) private {
        console.log("");
        console.log("--- Deploying SILVER Peg and Markets ---");

        deployPeggedTokenWithRoles(
            stateData,
            config.pegSILVER,
            config.marketsSILVER,
            baoFactory(),
            owner(),
            systemSalt()
        );

        for (uint256 i = 0; i < config.marketsSILVER.length; i++) {
            deployLeveragedTokenWithRoles(stateData, config.marketsSILVER[i], baoFactory(), owner(), systemSalt());
            _deployMinterForMarket(stateData, config.marketsSILVER[i]);
        }
    }

    /// @notice Deploy EUR pegged token and all EUR markets.
    function deployAll_EUR(DeploymentTypes.State memory stateData, AllMintersConfig memory config) private {
        console.log("");
        console.log("--- Deploying EUR Peg and Markets ---");

        deployPeggedTokenWithRoles(stateData, config.pegEUR, config.marketsEUR, baoFactory(), owner(), systemSalt());

        for (uint256 i = 0; i < config.marketsEUR.length; i++) {
            deployLeveragedTokenWithRoles(stateData, config.marketsEUR[i], baoFactory(), owner(), systemSalt());
            _deployMinterForMarket(stateData, config.marketsEUR[i]);
        }
    }

    /// @notice Deploy MCAP pegged token and all MCAP markets.
    function deployAll_MCAP(DeploymentTypes.State memory stateData, AllMintersConfig memory config) private {
        console.log("");
        console.log("--- Deploying MCAP Peg and Markets ---");

        deployPeggedTokenWithRoles(stateData, config.pegMCAP, config.marketsMCAP, baoFactory(), owner(), systemSalt());

        for (uint256 i = 0; i < config.marketsMCAP.length; i++) {
            deployLeveragedTokenWithRoles(stateData, config.marketsMCAP[i], baoFactory(), owner(), systemSalt());
            _deployMinterForMarket(stateData, config.marketsMCAP[i]);
        }
    }

    // Public wrapper functions for individual peg deployments

    /// @notice Deploy ETH pegged token and all ETH markets (public entry point).
    function deployAll_ETH(AllMintersConfig memory config, string memory network, bool useLocal) internal {
        DeploymentTypes.State memory stateData = _loadOrSeedState(network, useLocal);
        deployAll_ETH(stateData, config);
        _finalizeDeploy(stateData);
    }

    /// @notice Deploy BTC pegged token and all BTC markets (public entry point).
    function deployAll_BTC(AllMintersConfig memory config, string memory network, bool useLocal) internal {
        DeploymentTypes.State memory stateData = _loadOrSeedState(network, useLocal);
        deployAll_BTC(stateData, config);
        _finalizeDeploy(stateData);
    }

    /// @notice Deploy GOLD pegged token and all GOLD markets (public entry point).
    function deployAll_GOLD(AllMintersConfig memory config, string memory network, bool useLocal) internal {
        DeploymentTypes.State memory stateData = _loadOrSeedState(network, useLocal);
        deployAll_GOLD(stateData, config);
        _finalizeDeploy(stateData);
    }

    /// @notice Deploy SILVER pegged token and all SILVER markets (public entry point).
    function deployAll_SILVER(AllMintersConfig memory config, string memory network, bool useLocal) internal {
        DeploymentTypes.State memory stateData = _loadOrSeedState(network, useLocal);
        deployAll_SILVER(stateData, config);
        _finalizeDeploy(stateData);
    }

    /// @notice Deploy EUR pegged token and all EUR markets (public entry point).
    function deployAll_EUR(AllMintersConfig memory config, string memory network, bool useLocal) internal {
        DeploymentTypes.State memory stateData = _loadOrSeedState(network, useLocal);
        deployAll_EUR(stateData, config);
        _finalizeDeploy(stateData);
    }

    /// @notice Deploy MCAP pegged token and all MCAP markets (public entry point).
    function deployAll_MCAP(AllMintersConfig memory config, string memory network, bool useLocal) internal {
        DeploymentTypes.State memory stateData = _loadOrSeedState(network, useLocal);
        deployAll_MCAP(stateData, config);
        _finalizeDeploy(stateData);
    }

    function _loadOrSeedState(
        string memory network,
        bool useLocal
    ) private returns (DeploymentTypes.State memory stateData) {
        stateData = _shouldPersistState()
            ? DeploymentState.load(network, systemSalt(), useLocal, _stateDirectoryPrefix())
            : _seedEphemeralState(systemSalt(), network, useLocal);
        stateData.baoFactory = baoFactory();

        console.log("");
        console.log("================================================================================");
        console.log("                          DEPLOYING MINTER CONTRACTS");
        console.log("================================================================================");
        console.log("  Salt:    %s", systemSalt());
        console.log("  Network: %s", network);
        return stateData;
    }

    function _finalizeDeploy(DeploymentTypes.State memory stateData) private {
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
    function _deployMinterForMarket(DeploymentTypes.State memory stateData, Config_MinterMarket market) private {
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

        // Deploy SPM and Genesis
        _deploySpmAndGenesis(stateData, cfg, marketKey);

        // Configure Minter and grant roles
        _configureMinter(cfg, marketKey);

        console.log("    [complete]");
    }

    function _deployReservePool(DeploymentTypes.State memory stateData, string memory marketKey) private {
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
    ) private {
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
    ) private {
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

    function _deploySpmAndGenesis(
        DeploymentTypes.State memory stateData,
        IFullMinterConfig cfg,
        string memory marketKey
    ) private {
        address minter = _predictAddress(marketKey, "minter");
        address spCollateral = _predictAddress(marketKey, "stabilityPoolCollateral");
        address spLeveraged = _predictAddress(marketKey, "stabilityPoolLeveraged");

        // Stability Pool Manager
        {
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

        // Genesis
        {
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
    }

    function _configureMinter(IFullMinterConfig cfg, string memory marketKey) private {
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
        string memory network,
        bool useLocal
    ) private pure returns (DeploymentTypes.State memory stateData) {
        stateData.network = network;
        stateData.saltPrefix = saltPrefix;
        stateData.useLocal = useLocal;
        return stateData;
    }
}
