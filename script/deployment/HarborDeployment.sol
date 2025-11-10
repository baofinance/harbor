// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Deployment} from "@bao-script/deployment/Deployment.sol";
import {CREATE3} from "@solady/utils/CREATE3.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {HarborKeys} from "@harbor-script/deployment/HarborKeys.sol";
import {DeploymentConfig} from "@bao-script/deployment/DeploymentConfig.sol";
import {FeeReceiverDeployer} from "@harbor-script/deployment/deployers/FeeReceiverDeployer.sol";
import {PeggedTokenDeployer} from "@harbor-script/deployment/deployers/PeggedTokenDeployer.sol";
// TODO: Re-enable as deployers are migrated
// import {LeveragedTokenDeployer} from "@harbor-script/deployment/deployers/LeveragedTokenDeployer.sol";
// import {ReservePoolDeployer} from "@harbor-script/deployment/deployers/ReservePoolDeployer.sol";
// import {MinterDeployer} from "@harbor-script/deployment/deployers/MinterDeployer.sol";
// import {StabilityPoolCollateralDeployer} from "@harbor-script/deployment/deployers/StabilityPoolCollateralDeployer.sol";
// import {StabilityPoolLeveragedDeployer} from "@harbor-script/deployment/deployers/StabilityPoolLeveragedDeployer.sol";
// import {StabilityPoolManagerDeployer} from "@harbor-script/deployment/deployers/StabilityPoolManagerDeployer.sol";
// import {GenesisDeployer} from "@harbor-script/deployment/deployers/GenesisDeployer.sol";

/**
 * @title HarborDeployment
 * @notice Harbor-specific deployment contract with Stem proxy management
 * @dev Extends Deployment with Harbor-specific features:
 *      - All proxies use Stem_v1 for upgrade control
 *      - Type-safe enum-based API
 *      - Production-focused deployment methods
 *      - Delegates actual deployment to specialized libraries
 */

abstract contract HarborDeployment is Deployment {
    // ============================================================================
    // Harbor-Specific Storage
    // ============================================================================

    /// @notice Shared Stem_v1 implementation (deployed once, reused for all proxies)
    address private _stemImplementation;

    // ============================================================================
    // Errors
    // ============================================================================

    error ConfigVersionMismatch(string configVersion, string registryVersion);
    error ConfigMissingField(string field);

    // ============================================================================
    // Lifecycle Overrides
    // ============================================================================

    /// @notice Start a fresh deployment session from JSON config
    /// @param jsonConfig JSON configuration string
    function start(string memory jsonConfig) public virtual {
        DeploymentConfig.SourceJson memory config = DeploymentConfig.fromJson(jsonConfig);

        // Extract required fields
        address owner = DeploymentConfig.get(config, "", "owner");
        string memory version = DeploymentConfig.getString(config, "", "version");

        // Derive system salt from pegged and collateral registry keys
        string memory peggedKey = DeploymentConfig.getString(config, "pegged", "registryKey");
        string memory collateralKey = DeploymentConfig.getString(config, "collateral", "registryKey");
        string memory systemSaltString = string.concat(peggedKey, ":", collateralKey, ":");

        // Call base start with empty network
        Deployment.start(owner, "", version, systemSaltString, false);

        // Apply configuration
        _applyDeploymentConfig(config);
    }

    /// @notice Resume deployment from JSON config
    /// @param jsonConfig JSON configuration string
    function resume(string memory jsonConfig) public virtual {
        DeploymentConfig.SourceJson memory config = DeploymentConfig.fromJson(jsonConfig);

        // Extract required fields
        string memory version = DeploymentConfig.getString(config, "", "version");

        // Derive system salt from pegged and collateral registry keys
        string memory peggedKey = DeploymentConfig.getString(config, "pegged", "registryKey");
        string memory collateralKey = DeploymentConfig.getString(config, "collateral", "registryKey");
        string memory systemSaltString = string.concat(peggedKey, ":", collateralKey, ":");

        // Call base resume with empty network
        Deployment.resume("", systemSaltString, false);

        // Validate version matches
        if (keccak256(bytes(_metadata.version)) != keccak256(bytes(version))) {
            revert ConfigVersionMismatch(version, _metadata.version);
        }

        // Apply configuration
        _applyDeploymentConfig(config);
    }

    // ============================================================================
    // Configuration
    // ============================================================================

    function _applyDeploymentConfig(DeploymentConfig.SourceJson memory config) internal virtual {
        _applyTreasuryConfig(config);
        _applyPeggedConfig(config);
        _applyCollateralConfig(config);
    }

    function _applyTreasuryConfig(DeploymentConfig.SourceJson memory config) internal {
        if (!hasTreasury() && DeploymentConfig.has(config, "", "treasury")) {
            useTreasury(DeploymentConfig.get(config, "", "treasury"));
        }
    }

    function _applyPeggedConfig(DeploymentConfig.SourceJson memory config) internal {
        if (!hasPeggedName() && DeploymentConfig.has(config, "pegged", "name")) {
            setPeggedName(DeploymentConfig.getString(config, "pegged", "name"));
        }
        if (!hasPeggedSymbol() && DeploymentConfig.has(config, "pegged", "symbol")) {
            setPeggedSymbol(DeploymentConfig.getString(config, "pegged", "symbol"));
        }
        if (!hasPeggedDecimals() && DeploymentConfig.has(config, "pegged", "decimals")) {
            setPeggedDecimals(DeploymentConfig.getUint(config, "pegged", "decimals"));
        }
    }

    function _applyCollateralConfig(DeploymentConfig.SourceJson memory config) internal {
        if (!hasCollateralToken() && DeploymentConfig.has(config, "collateral", "address")) {
            address collateralAddr = DeploymentConfig.get(config, "collateral", "address");
            useCollateralToken(collateralAddr);
        }
    }

    // ============================================================================
    // Parameter Helpers
    // ============================================================================

    function hasFeeReceiverName() public view returns (bool) {
        return has(HarborKeys.FEE_RECEIVER_NAME);
    }

    function setFeeReceiverName(string memory value) public {
        setString(HarborKeys.FEE_RECEIVER_NAME, value);
    }

    function getFeeReceiverName() public view virtual returns (string memory) {
        return getString(HarborKeys.FEE_RECEIVER_NAME);
    }

    function hasPeggedName() public view returns (bool) {
        return has(HarborKeys.PEGGED_NAME);
    }

    function setPeggedName(string memory value) public {
        setString(HarborKeys.PEGGED_NAME, value);
    }

    function getPeggedName() public view virtual returns (string memory) {
        return getString(HarborKeys.PEGGED_NAME);
    }

    function hasPeggedSymbol() public view returns (bool) {
        return has(HarborKeys.PEGGED_SYMBOL);
    }

    function setPeggedSymbol(string memory value) public {
        setString(HarborKeys.PEGGED_SYMBOL, value);
    }

    function getPeggedSymbol() public view virtual returns (string memory) {
        return getString(HarborKeys.PEGGED_SYMBOL);
    }

    function hasPeggedDecimals() public view returns (bool) {
        return has(HarborKeys.PEGGED_DECIMALS);
    }

    function setPeggedDecimals(uint256 value) public {
        setUint(HarborKeys.PEGGED_DECIMALS, value);
    }

    function getPeggedDecimals() public view returns (uint256) {
        return getUint(HarborKeys.PEGGED_DECIMALS);
    }

    function setCollateralDecimals(uint256 value) public {
        setUint(HarborKeys.COLLATERAL_DECIMALS, value);
    }

    function getCollateralDecimals() public view returns (uint256) {
        return getUint(HarborKeys.COLLATERAL_DECIMALS);
    }

    function hasLeveragedName() public view returns (bool) {
        return has(HarborKeys.LEVERAGED_NAME);
    }

    function setLeveragedName(string memory value) public {
        setString(HarborKeys.LEVERAGED_NAME, value);
    }

    function getLeveragedName() public view virtual returns (string memory) {
        return getString(HarborKeys.LEVERAGED_NAME);
    }

    function hasLeveragedSymbol() public view returns (bool) {
        return has(HarborKeys.LEVERAGED_SYMBOL);
    }

    function setLeveragedSymbol(string memory value) public {
        setString(HarborKeys.LEVERAGED_SYMBOL, value);
    }

    function getLeveragedSymbol() public view virtual returns (string memory) {
        return getString(HarborKeys.LEVERAGED_SYMBOL);
    }

    function setLeveragedDecimals(uint256 value) public {
        setUint(HarborKeys.LEVERAGED_DECIMALS, value);
    }

    function getLeveragedDecimals() public view returns (uint256) {
        return getUint(HarborKeys.LEVERAGED_DECIMALS);
    }

    function setStabilityPoolEarlyWithdrawalFee(uint256 value) public {
        setUint(HarborKeys.STABILITY_POOL_EARLY_WITHDRAWAL_FEE, value);
    }

    function getStabilityPoolEarlyWithdrawalFee() public view virtual returns (uint256) {
        return getUint(HarborKeys.STABILITY_POOL_EARLY_WITHDRAWAL_FEE);
    }

    function setStabilityPoolMinDeposit(uint256 value) public {
        setUint(HarborKeys.STABILITY_POOL_MIN_DEPOSIT, value);
    }

    function getStabilityPoolMinDeposit() public view returns (uint256) {
        return getUint(HarborKeys.STABILITY_POOL_MIN_DEPOSIT);
    }

    function setInitialExchangeRate(uint256 value) public {
        setUint(HarborKeys.INITIAL_EXCHANGE_RATE, value);
    }

    function getInitialExchangeRate() public view returns (uint256) {
        return getUint(HarborKeys.INITIAL_EXCHANGE_RATE);
    }

    function setFeePercentage(uint256 value) public {
        setUint(HarborKeys.FEE_PERCENTAGE, value);
    }

    function getFeePercentage() public view returns (uint256) {
        return getUint(HarborKeys.FEE_PERCENTAGE);
    }

    // ============================================================================
    // Harbor Deployment Methods
    // ============================================================================

    // ============================================================================
    // Owner
    // ============================================================================

    function getOwner() public view virtual returns (address) {
        return get(HarborKeys.OWNER);
    }

    function hasOwner() public view returns (bool) {
        return has(HarborKeys.OWNER);
    }

    function useOwner(address admin) public virtual {
        useExisting(HarborKeys.OWNER, admin);
    }

    // ============================================================================
    // Fee Receiver (TokenDistributor)
    // ============================================================================

    /**
     * @notice Deploy TokenDistributor fee receiver from config
     * @return Address of deployed fee receiver proxy
     */
    function getFeeReceiver() public view virtual returns (address) {
        return get(HarborKeys.FEE_RECEIVER);
    }

    function hasFeeReceiver() public view returns (bool) {
        return has(HarborKeys.FEE_RECEIVER);
    }

    function deployFeeReceiverFromConfig() public virtual returns (address) {
        string memory name = getFeeReceiverName();
        address admin = getOwner();

        return FeeReceiverDeployer.deploy(this, admin, name);
    }

    function useFeeReceiver(address feeReceiver) public virtual {
        useExisting(HarborKeys.FEE_RECEIVER, feeReceiver);
    }

    // ============================================================================
    // Treasury
    // ============================================================================

    /**
     * @notice Get the registered treasury address
     * @return Address currently registered as treasury
     */
    function getTreasury() public view virtual returns (address) {
        return get(HarborKeys.TREASURY);
    }

    function hasTreasury() public view returns (bool) {
        return has(HarborKeys.TREASURY);
    }

    function useTreasury(address treasury) public virtual {
        useExisting(HarborKeys.TREASURY, treasury);
    }

    // ============================================================================
    // Collateral Token (wrappedCollateral)
    // ============================================================================

    /**
     * @notice Get the registered collateral token address
     * @return Address of the wrapped collateral token
     */
    function getCollateralToken() public view virtual returns (address) {
        return get(HarborKeys.WRAPPED_COLLATERAL);
    }

    function hasCollateralToken() public view returns (bool) {
        return has(HarborKeys.WRAPPED_COLLATERAL);
    }

    function useCollateralToken(address wrappedCollateral) public virtual {
        useExisting(HarborKeys.WRAPPED_COLLATERAL, wrappedCollateral);
    }

    // ============================================================================
    // Pegged Token (baoUSD)
    // ============================================================================

    /**
     * @notice Deploy MintableBurnableERC20 pegged token from config
     * @return Address of deployed pegged token proxy
     */
    function getPeggedToken() public view virtual returns (address) {
        return get(HarborKeys.PEGGED);
    }

    function hasPeggedToken() public view returns (bool) {
        return has(HarborKeys.PEGGED);
    }

    function usePeggedToken(address token) public virtual {
        useExisting(HarborKeys.PEGGED, token);
    }

    // ============================================================================
    // Leveraged Token (baoUSD-L)
    // ============================================================================

    /**
     * @notice Deploy MintableBurnableERC20 leveraged token from config
     * @return Address of deployed leveraged token proxy
     */
    function getLeveragedToken() public view virtual returns (address) {
        return get(HarborKeys.LEVERAGED);
    }

    function hasLeveragedToken() public view returns (bool) {
        return has(HarborKeys.LEVERAGED);
    }

    function deployLeveragedTokenFromConfig() public virtual returns (address) {
        // address admin = _resolveAdmin();
        // return LeveragedTokenDeployer.deploy(this, admin, name, symbol);
    }

    function useLeveragedToken(address token) public virtual {
        useExisting(HarborKeys.LEVERAGED, token);
    }

    // ============================================================================
    // Oracle
    // ============================================================================

    /**
     * @notice Get the registered price oracle address
     * @return Address of the oracle contract
     */
    function getOracle() public view returns (address) {
        return get(HarborKeys.ORACLE);
    }

    function hasOracle() public view returns (bool) {
        return has(HarborKeys.ORACLE);
    }

    function useOracle(address oracle) public {
        useExisting(HarborKeys.ORACLE, oracle);
    }

    // ============================================================================
    // Reserve Pool
    // ============================================================================

    /**
     * @notice Deploy ReservePool from config
     * @return Address of deployed reserve pool proxy
     */
    function getReservePool() public view virtual returns (address) {
        return get(HarborKeys.RESERVE_POOL);
    }

    function hasReservePool() public view returns (bool) {
        return has(HarborKeys.RESERVE_POOL);
    }

    function deployReservePoolFromConfig() public virtual returns (address) {
        // TODO: Re-enable when ReservePoolDeployer is migrated
        revert("deployReservePoolFromConfig: not yet migrated");
        // address admin = _resolveAdmin();
        // return ReservePoolDeployer.deploy(this, admin);
    }

    function useReservePool(address pool) public virtual {
        useExisting(HarborKeys.RESERVE_POOL, pool);
    }

    // ============================================================================
    // Minter
    // ============================================================================

    /**
     * @notice Deploy Minter from config
     * @return Address of deployed minter proxy
     * @dev Minter requires WRAPPED_COLLATERAL, PEGGED, LEVERAGED, RESERVE_POOL, FEE_RECEIVER, and ORACLE to be deployed first
     *      Note: Config_v1 library is automatically deployed and linked by Foundry
     *      For Wake tests, deploy Config_v1 manually before calling this function
     */
    function getMinter() public view virtual returns (address) {
        return get(HarborKeys.MINTER);
    }

    function hasMinter() public view returns (bool) {
        return has(HarborKeys.MINTER);
    }

    function deployMinterFromConfig() public virtual returns (address) {
        // TODO: Re-enable when MinterDeployer is migrated
        revert("deployMinterFromConfig: not yet migrated");
        // address admin = _resolveAdmin();
        // address wrappedCollateral = _resolveCollateralToken();
        // address pegged = _resolvePeggedToken();
        // address leveraged = _resolveLeveragedToken();
        // address reservePool = _resolveReservePool();
        // address feeReceiver = _resolveFeeReceiver();
        // address oracle = _resolveOracle();
        // return MinterDeployer.deploy(this, admin, wrappedCollateral, pegged, leveraged, reservePool, feeReceiver, oracle);
    }

    function useMinter(address minter) public virtual {
        useExisting(HarborKeys.MINTER, minter);
    }

    // ============================================================================
    // Stability Pools
    // ============================================================================

    /**
     * @notice Deploy collateral stability pool from config
     * @return Address of deployed stability pool
     */
    function deployStabilityPoolCollateralFromConfig() public virtual returns (address) {
        // TODO: Re-enable when StabilityPoolCollateralDeployer is migrated
        revert("deployStabilityPoolCollateralFromConfig: not yet migrated");
        // uint256 earlyWithdrawalFee = getStabilityPoolEarlyWithdrawalFee();
        // address admin = _resolveAdmin();
        // address minter = _resolveMinter();
        // address wrappedCollateral = _resolveCollateralToken();
        // address feeReceiver = _resolveFeeReceiver();
        // address rewardManager = _resolveRewardManager();
        // address rewardDepositor = _resolveRewardDepositor();
        // address rebalancer = _resolveRebalancer();
        // return StabilityPoolCollateralDeployer.deploy(
        //     this, admin, minter, wrappedCollateral, earlyWithdrawalFee,
        //     feeReceiver, rewardManager, rewardDepositor, rebalancer
        // );
    }

    /**
     * @notice Deploy leveraged stability pool from config
     * @return Address of deployed stability pool
     */
    function deployStabilityPoolLeveragedFromConfig() public virtual returns (address) {
        // TODO: Re-enable when StabilityPoolLeveragedDeployer is migrated
        revert("deployStabilityPoolLeveragedFromConfig: not yet migrated");
        // uint256 earlyWithdrawalFee = getStabilityPoolEarlyWithdrawalFee();
        // address admin = _resolveAdmin();
        // address minter = _resolveMinter();
        // address wrappedCollateral = _resolveCollateralToken();
        // address leveraged = _resolveLeveragedToken();
        // address feeReceiver = _resolveFeeReceiver();
        // address rewardManager = _resolveRewardManager();
        // address rewardDepositor = _resolveRewardDepositor();
        // address rebalancer = _resolveRebalancer();
        // return StabilityPoolLeveragedDeployer.deploy(
        //     this, admin, minter, wrappedCollateral, leveraged, earlyWithdrawalFee,
        //     feeReceiver, rewardManager, rewardDepositor, rebalancer
        // );
    }

    /**
     * @notice Get the registered collateral stability pool address
     * @return Address of the collateral stability pool
     */
    function getStabilityPoolCollateral() public view virtual returns (address) {
        return get(HarborKeys.STABILITY_POOL_COLLATERAL);
    }

    function hasStabilityPoolCollateral() public view returns (bool) {
        return has(HarborKeys.STABILITY_POOL_COLLATERAL);
    }

    function useStabilityPoolCollateral(address stabilityPool) public virtual {
        useExisting(HarborKeys.STABILITY_POOL_COLLATERAL, stabilityPool);
    }

    /**
     * @notice Get the registered leveraged stability pool address
     * @return Address of the leveraged stability pool
     */
    function getStabilityPoolLeveraged() public view virtual returns (address) {
        return get(HarborKeys.STABILITY_POOL_LEVERAGED);
    }

    function hasStabilityPoolLeveraged() public view returns (bool) {
        return has(HarborKeys.STABILITY_POOL_LEVERAGED);
    }

    function useStabilityPoolLeveraged(address stabilityPool) public virtual {
        useExisting(HarborKeys.STABILITY_POOL_LEVERAGED, stabilityPool);
    }

    // ============================================================================
    // Stability Pool Manager
    // ============================================================================

    /**
     * @notice Deploy StabilityPoolManager from config
     * @return Address of deployed stability pool manager proxy
     */
    function getStabilityPoolManager() public view virtual returns (address) {
        return get(HarborKeys.STABILITY_POOL_MANAGER);
    }

    function hasStabilityPoolManager() public view returns (bool) {
        return has(HarborKeys.STABILITY_POOL_MANAGER);
    }

    function deployStabilityPoolManagerFromConfig() public virtual returns (address) {
        // TODO: Re-enable when StabilityPoolManagerDeployer is migrated
        revert("deployStabilityPoolManagerFromConfig: not yet migrated");
        // address admin = _resolveAdmin();
        // address minter = _resolveMinter();
        // address treasury = _resolveTreasury();
        // address stabilityPoolCollateral = _resolveStabilityPoolCollateral();
        // address stabilityPoolLeveraged = _resolveStabilityPoolLeveraged();
        // address feeReceiver = _resolveFeeReceiver();
        // return StabilityPoolManagerDeployer.deploy(
        //     this, admin, minter, treasury, stabilityPoolCollateral,
        //     stabilityPoolLeveraged, feeReceiver
        // );
    }

    function useStabilityPoolManager(address stabilityPoolManager) public virtual {
        useExisting(HarborKeys.STABILITY_POOL_MANAGER, stabilityPoolManager);
    }

    // ============================================================================
    // Genesis
    // ============================================================================

    /**
     * @notice Deploy Genesis contract from config
     * @return Address of deployed genesis proxy
     */
    function getGenesis() public view virtual returns (address) {
        return get(HarborKeys.GENESIS);
    }

    function hasGenesis() public view returns (bool) {
        return has(HarborKeys.GENESIS);
    }

    function deployGenesisFromConfig() public virtual returns (address) {
        // TODO: Re-enable when GenesisDeployer is migrated
        revert("deployGenesisFromConfig: not yet migrated");
        // address admin = _resolveAdmin();
        // address minter = _resolveMinter();
        // return GenesisDeployer.deploy(this, admin, minter);
    }

    function useGenesis(address genesis) public virtual {
        useExisting(HarborKeys.GENESIS, genesis);
    }

    // ============================================================================
    // Role Addresses (for stability pools)
    // ============================================================================

    /**
     * @notice Get the registered reward manager address
     * @return Address used as reward manager
     */
    function getRewardManager() public view returns (address) {
        return get(HarborKeys.REWARD_MANAGER);
    }

    function hasRewardManager() public view returns (bool) {
        return has(HarborKeys.REWARD_MANAGER);
    }

    function useRewardManager(address rewardManager) public {
        useExisting(HarborKeys.REWARD_MANAGER, rewardManager);
    }

    /**
     * @notice Get the registered reward depositor address
     * @return Address used as reward depositor
     */
    function getRewardDepositor() public view returns (address) {
        return get(HarborKeys.REWARD_DEPOSITOR);
    }

    function hasRewardDepositor() public view returns (bool) {
        return has(HarborKeys.REWARD_DEPOSITOR);
    }

    function useRewardDepositor(address rewardDepositor) public {
        useExisting(HarborKeys.REWARD_DEPOSITOR, rewardDepositor);
    }

    /**
     * @notice Get the registered rebalancer address
     * @return Address used as rebalancer
     */
    function getRebalancer() public view returns (address) {
        return get(HarborKeys.REBALANCER);
    }

    function hasRebalancer() public view returns (bool) {
        return has(HarborKeys.REBALANCER);
    }

    function useRebalancer(address rebalancer) public {
        useExisting(HarborKeys.REBALANCER, rebalancer);
    }
}
