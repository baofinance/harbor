// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {DeploymentBase} from "@bao-script/deployment/DeploymentBase.sol";
import {DeploymentDataMemory} from "@bao-script/deployment/DeploymentDataMemory.sol";
import {DeploymentJson} from "@bao-script/deployment/DeploymentJson.sol";
import {DeploymentJsonScript} from "@bao-script/deployment/DeploymentJsonScript.sol";
import {DeploymentVariant} from "@bao-script/deployment/DeploymentVariant.sol";
import {LibString} from "@solady/utils/LibString.sol";

import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {ReservePool_v1} from "@harbor/minter/ReservePool_v1.sol";
import {TokenDistributor_v1} from "@harbor/minter/TokenDistributor_v1.sol";
import {MockWrappedPriceOracle} from "test/mocks/MockWrappedPriceOracle.sol";
import {Minter_v1} from "@harbor/minter/Minter_v1.sol";
import {StabilityPool_v1} from "@harbor/minter/StabilityPool_v1.sol";
import {StabilityPoolManager_v1} from "@harbor/minter/StabilityPoolManager_v1.sol";
import {Genesis_v1} from "@harbor/minter/Genesis_v1.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

interface IERC20Minimal {
    function symbol() external view returns (string memory);
}

/**
 * @title HarborDeploymentJsonScript
 * @notice Harbor-specific deployment contract with Stem proxy management
 * @dev Combines DeploymentJsonScript (JSON + broadcast) with DeploymentVariant (env var BaoFactory selection).
 *
 *      Features:
 *      - All proxies use Stem_v1 for upgrade control
 *      - Type-safe enum-based API
 *      - Production-focused deployment methods
 *      - Delegates actual deployment to specialized libraries
 *      - BaoFactory variant selection via BAO_FACTORY_VARIANT env var (from DeploymentVariant)
 */

abstract contract HarborDeploymentJsonScript is DeploymentJsonScript, DeploymentVariant {
    using LibString for string;

    // =========================================================================
    // Inheritance Resolution
    // =========================================================================

    // TODO: resolve this diamond
    /// @dev Resolve _afterValueChanged - use DeploymentJson's implementation for JSON persistence
    function _afterValueChanged(string memory key) internal virtual override(DeploymentDataMemory, DeploymentJson) {
        DeploymentJson._afterValueChanged(key);
    }

    // =========================================================================
    // Errors
    // =========================================================================

    error ChainIdMismatch(uint256 expected, uint256 actual);
    error SaltMismatch(string expected, string actual);

    // =========================================================================
    // Contract Keys
    // =========================================================================

    string public constant TREASURY = "treasury";

    string public constant COLLATERAL_INPUT = "collateral";
    string public constant WRAPPED_COLLATERAL_INPUT = "wrappedCollateral";
    string public constant PREFIX = "prefix";
    string public constant NETWORKS = "networks";
    string public constant PEGGED_TICKER = "peggedTicker";

    string public constant COLLATERAL = "contracts.collateral";
    string public constant COLLATERAL_NAME = "contracts.collateral.name";
    string public constant COLLATERAL_SYMBOL = "contracts.collateral.symbol";

    string public constant WRAPPED_COLLATERAL = "contracts.wrappedCollateral";
    string public constant WRAPPED_COLLATERAL_NAME = "contracts.wrappedCollateral.name";
    string public constant WRAPPED_COLLATERAL_SYMBOL = "contracts.wrappedCollateral.symbol";

    string public constant PEGGED = "contracts.pegged";
    string public constant PEGGED_NAME = "contracts.pegged.name";
    string public constant PEGGED_SYMBOL = "contracts.pegged.symbol";
    string public constant PEGGED_BURN_SIGNATURE = "contracts.pegged.burnSignature";

    string public constant LEVERAGED = "contracts.leveraged";
    string public constant LEVERAGED_NAME = "contracts.leveraged.name";
    string public constant LEVERAGED_SYMBOL = "contracts.leveraged.symbol";

    string public constant MINTER_FEE_RECEIVER_CONTRACT = "contracts.minterFeeReceiver";
    string public constant MINTER_FEE_RECEIVER_NAME = "contracts.minterFeeReceiver.name";
    string public constant MINTER_FEE_RECEIVER_TOKENS = "contracts.minterFeeReceiver.tokens";
    string public constant MINTER_FEE_RECEIVER_RECIPIENTS = "contracts.minterFeeReceiver.recipients";
    string public constant MINTER_FEE_RECEIVER_SHARES = "contracts.minterFeeReceiver.shares";

    string public constant PRICE_ORACLE = "contracts.priceOracle";

    string public constant RESERVE_POOL = "contracts.reservePool";

    string public constant MINTER = "contracts.minter";
    // Minter config keys
    string public constant MINTER_MINT_PEGGED_BOUNDS =
        "contracts.minter.config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds";
    string public constant MINTER_MINT_PEGGED_RATIOS =
        "contracts.minter.config.mintPeggedIncentiveConfig.incentiveRatios";
    string public constant MINTER_REDEEM_PEGGED_BOUNDS =
        "contracts.minter.config.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds";
    string public constant MINTER_REDEEM_PEGGED_RATIOS =
        "contracts.minter.config.redeemPeggedIncentiveConfig.incentiveRatios";
    string public constant MINTER_MINT_LEVERAGED_BOUNDS =
        "contracts.minter.config.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds";
    string public constant MINTER_MINT_LEVERAGED_RATIOS =
        "contracts.minter.config.mintLeveragedIncentiveConfig.incentiveRatios";
    string public constant MINTER_REDEEM_LEVERAGED_BOUNDS =
        "contracts.minter.config.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds";
    string public constant MINTER_REDEEM_LEVERAGED_RATIOS =
        "contracts.minter.config.redeemLeveragedIncentiveConfig.incentiveRatios";
    string public constant MINTER_FEE_RECEIVER = "contracts.minter.feeReceiver";

    string public constant STABILITY_POOL_EARLY_WITHDRAWAL_FEE_RATIO = "stabilityPoolEarlyWithdrawalFeeRatio";
    string public constant STABILITY_POOL_WITHDRAWAL_DELAY = "stabilityPoolWithdrawalDelay";
    string public constant STABILITY_POOL_WITHDRAWAL_PERIOD = "stabilityPoolWithdrawalPeriod";
    string public constant STABILITY_POOL_MIN_TOTAL_ASSET_SUPPLY = "stabilityPoolMinTotalAssetSupply";

    string public constant STABILITY_POOL_COLLATERAL = "contracts.stabilityPoolCollateral";
    string public constant STABILITY_POOL_COLLATERAL_LIQUIDATION = "contracts.stabilityPoolCollateral.liquidation";
    string public constant STABILITY_POOL_COLLATERAL_REWARD_TOKENS = "contracts.stabilityPoolCollateral.rewardTokens";
    string public constant STABILITY_POOL_LEVERAGED = "contracts.stabilityPoolLeveraged";
    string public constant STABILITY_POOL_LEVERAGED_LIQUIDATION = "contracts.stabilityPoolLeveraged.liquidation";
    string public constant STABILITY_POOL_LEVERAGED_REWARD_TOKENS = "contracts.stabilityPoolLeveraged.rewardTokens";

    string public constant STABILITY_POOL_MANAGER = "contracts.stabilityPoolManager";
    string public constant STABILITY_POOL_MANAGER_REBALANCE_THRESHOLD =
        "contracts.stabilityPoolManager.rebalanceThreshold";
    string public constant STABILITY_POOL_MANAGER_REBALANCE_BOUNTY_RATIO =
        "contracts.stabilityPoolManager.rebalanceBountyRatio";
    string public constant STABILITY_POOL_MANAGER_HARVEST_BOUNTY_RATIO =
        "contracts.stabilityPoolManager.harvestBountyRatio";
    string public constant STABILITY_POOL_MANAGER_HARVEST_CUT_RATIO = "contracts.stabilityPoolManager.harvestCutRatio";
    string public constant STABILITY_POOL_MANAGER_FEE_RECEIVER = "contracts.stabilityPoolManager.feeReceiver";

    string public constant STABILITY_POOL_MANAGER_FEE_RECEIVER_CONTRACT = "contracts.stabilityPoolManagerFeeReceiver";
    string public constant STABILITY_POOL_MANAGER_FEE_RECEIVER_NAME = "contracts.stabilityPoolManagerFeeReceiver.name";
    string public constant STABILITY_POOL_MANAGER_FEE_RECEIVER_TOKENS =
        "contracts.stabilityPoolManagerFeeReceiver.tokens";
    string public constant STABILITY_POOL_MANAGER_FEE_RECEIVER_RECIPIENTS =
        "contracts.stabilityPoolManagerFeeReceiver.recipients";
    string public constant STABILITY_POOL_MANAGER_FEE_RECEIVER_SHARES =
        "contracts.stabilityPoolManagerFeeReceiver.shares";

    string public constant GENESIS = "contracts.genesis";

    // ============================================================================
    // Configuration
    // ============================================================================

    constructor() {
        // TODO: naming
        // - add* -> register
        // - FEE_RECEIVER -> FEE_DISTRIBUTOR
        // - use set/get for data values, including the ones named register*

        addStringKey(PREFIX);
        addStringKey(PEGGED_TICKER);

        addKey(NETWORKS);
        addAddressKey(COLLATERAL_INPUT);
        addAddressKey(WRAPPED_COLLATERAL_INPUT);

        addAddressKey(TREASURY);

        addContract(COLLATERAL);
        addStringKey(COLLATERAL_SYMBOL);
        addStringKey(COLLATERAL_NAME);

        addContract(WRAPPED_COLLATERAL);
        addStringKey(WRAPPED_COLLATERAL_SYMBOL);
        addStringKey(WRAPPED_COLLATERAL_NAME);

        addProxy(PEGGED);
        addRoles(PEGGED, sa("MINTER_ROLE", "BURNER_ROLE"));
        addStringKey(PEGGED_NAME);
        addStringKey(PEGGED_SYMBOL);
        addStringKey(PEGGED_BURN_SIGNATURE);

        addProxy(LEVERAGED);
        addRoles(LEVERAGED, sa("MINTER_ROLE", "BURNER_ROLE"));
        addStringKey(LEVERAGED_NAME);
        addStringKey(LEVERAGED_SYMBOL);

        // TODO: rationalise the naming for contracts: have _CONTRACT or not?
        // TODO: make a function for fee receivers
        addProxy(MINTER_FEE_RECEIVER_CONTRACT);
        addStringKey(MINTER_FEE_RECEIVER_NAME);
        addAddressArrayKey(MINTER_FEE_RECEIVER_TOKENS);
        addAddressArrayKey(MINTER_FEE_RECEIVER_RECIPIENTS);
        addUintArrayKey(MINTER_FEE_RECEIVER_SHARES, 16);

        addProxy(STABILITY_POOL_MANAGER_FEE_RECEIVER_CONTRACT);
        addStringKey(STABILITY_POOL_MANAGER_FEE_RECEIVER_NAME);
        addAddressArrayKey(STABILITY_POOL_MANAGER_FEE_RECEIVER_TOKENS);
        addAddressArrayKey(STABILITY_POOL_MANAGER_FEE_RECEIVER_RECIPIENTS);
        addUintArrayKey(STABILITY_POOL_MANAGER_FEE_RECEIVER_SHARES, 16);

        addContract(PRICE_ORACLE);

        addProxy(RESERVE_POOL);
        addRoles(RESERVE_POOL, sa("REQUESTER_ROLE"));

        addProxy(MINTER);
        addRoles(MINTER, sa("HARVESTER_ROLE", "ZERO_FEE_ROLE"));
        addUintArrayKey(MINTER_MINT_PEGGED_BOUNDS, 16);
        addIntArrayKey(MINTER_MINT_PEGGED_RATIOS, 16);
        addUintArrayKey(MINTER_REDEEM_PEGGED_BOUNDS, 16);
        addIntArrayKey(MINTER_REDEEM_PEGGED_RATIOS, 16);
        addUintArrayKey(MINTER_MINT_LEVERAGED_BOUNDS, 16);
        addIntArrayKey(MINTER_MINT_LEVERAGED_RATIOS, 16);
        addUintArrayKey(MINTER_REDEEM_LEVERAGED_BOUNDS, 16);
        addIntArrayKey(MINTER_REDEEM_LEVERAGED_RATIOS, 16);
        addAddressKey(MINTER_FEE_RECEIVER);

        addUintKey(STABILITY_POOL_EARLY_WITHDRAWAL_FEE_RATIO, 16);
        addUintKey(STABILITY_POOL_WITHDRAWAL_DELAY);
        addUintKey(STABILITY_POOL_WITHDRAWAL_PERIOD);
        addUintKey(STABILITY_POOL_MIN_TOTAL_ASSET_SUPPLY, 18);

        addProxy(STABILITY_POOL_COLLATERAL);
        addRoles(STABILITY_POOL_COLLATERAL, sa("REBALANCER_ROLE", "REWARD_DEPOSITOR_ROLE", "REWARD_MANAGER_ROLE"));
        addAddressKey(STABILITY_POOL_COLLATERAL_LIQUIDATION);
        addAddressArrayKey(STABILITY_POOL_COLLATERAL_REWARD_TOKENS);
        addProxy(STABILITY_POOL_LEVERAGED);
        addRoles(STABILITY_POOL_LEVERAGED, sa("REBALANCER_ROLE", "REWARD_DEPOSITOR_ROLE", "REWARD_MANAGER_ROLE"));
        addAddressKey(STABILITY_POOL_LEVERAGED_LIQUIDATION);
        addAddressArrayKey(STABILITY_POOL_LEVERAGED_REWARD_TOKENS);

        addProxy(STABILITY_POOL_MANAGER);
        addUintKey(STABILITY_POOL_MANAGER_REBALANCE_THRESHOLD, 16);
        addUintKey(STABILITY_POOL_MANAGER_REBALANCE_BOUNTY_RATIO, 16);
        addUintKey(STABILITY_POOL_MANAGER_HARVEST_BOUNTY_RATIO, 16);
        addUintKey(STABILITY_POOL_MANAGER_HARVEST_CUT_RATIO, 16);
        addAddressKey(STABILITY_POOL_MANAGER_FEE_RECEIVER);

        addProxy(GENESIS);
    }

    /// @notice Override start to register network-specific schema keys, then copy network inputs to standard slots
    function start(
        string memory network,
        string memory systemSaltString,
        string memory startPoint
    ) public virtual override {
        // Register keys for the specific network so JSON loader knows about them
        string memory networkPrefix = string.concat(NETWORKS, ".", network);
        addUintKey(string.concat(networkPrefix, ".chainId"));
        addAddressKey(string.concat(networkPrefix, ".collateral"));
        addAddressKey(string.concat(networkPrefix, ".wrappedCollateral"));

        super.start(network, systemSaltString, startPoint);

        // Copy network-specific inputs to standard slots
        _setAddress(COLLATERAL_INPUT, _getAddress(string.concat(networkPrefix, ".collateral")));
        _setAddress(WRAPPED_COLLATERAL_INPUT, _getAddress(string.concat(networkPrefix, ".wrappedCollateral")));

        // Read collateral symbol from chain and store in deployment data
        string memory collateralSymbol = IERC20Minimal(_getAddress(COLLATERAL_INPUT)).symbol();
        _setString(COLLATERAL_SYMBOL, collateralSymbol);

        // Validate chain ID
        uint256 expectedChainId = _getUint(string.concat(networkPrefix, ".chainId"));
        if (block.chainid != expectedChainId) {
            revert ChainIdMismatch(expectedChainId, block.chainid);
        }

        // Validate salt matches config
        string memory expectedSalt = string.concat(
            _getString(PREFIX),
            "-",
            _getString(PEGGED_TICKER),
            "-",
            collateralSymbol
        );
        if (!systemSaltString.eq(expectedSalt)) {
            revert SaltMismatch(expectedSalt, systemSaltString);
        }
    }

    // ============================================================================
    // Token Naming
    // ============================================================================

    /// @notice Derive token symbol and name from deployment config
    /// @param prefix Symbol prefix (e.g., "ha" for pegged, "hs" for leveraged)
    /// @param description Name description (e.g., "anchored" or "sail")
    /// @return symbol The derived symbol (e.g., "haUSD-stETH")
    /// @return name The derived name (e.g., "Harbor anchored USD for stETH")
    function _deriveTokenIdentity(
        string memory prefix,
        string memory description
    ) internal view returns (string memory symbol, string memory name) {
        string memory ticker = _getString(PEGGED_TICKER);
        string memory collateral = _getString(COLLATERAL_SYMBOL);
        symbol = string.concat(prefix, ticker, "-", collateral);
        name = string.concat("Harbor ", description, " ", ticker, " for ", collateral);
    }

    // ============================================================================
    // Pegged
    // ============================================================================

    function _deployPegged() internal {
        console2.log("Deploying Pegged...");

        // Derive symbol and name from deployment config
        (string memory symbol, string memory name) = _deriveTokenIdentity("ha", "anchored");
        _setString(PEGGED_SYMBOL, symbol);
        _setString(PEGGED_NAME, name);

        // Deploy implementation
        MintableBurnableERC20_v1 impl = new MintableBurnableERC20_v1();

        // Deploy and register proxy
        bytes memory initData = abi.encodeCall(
            MintableBurnableERC20_v1.initialize,
            (_getAddress(OWNER), _getString(PEGGED_NAME), _getString(PEGGED_SYMBOL))
        );

        deployProxy(
            PEGGED,
            address(impl),
            initData,
            type(MintableBurnableERC20_v1).name,
            type(MintableBurnableERC20_v1).creationCode,
            _getAddress(SESSION_DEPLOYER)
        );

        _setRole(PEGGED, "MINTER_ROLE", impl.MINTER_ROLE());
        _setRole(PEGGED, "BURNER_ROLE", impl.BURNER_ROLE());

        _setString(PEGGED_BURN_SIGNATURE, "burn(uint256)");
        _saveDeployment();
    }

    function _smokePegged() internal view {
        console2.log("Smoke testing Pegged...");
        MintableBurnableERC20_v1 proxy = MintableBurnableERC20_v1(_get(PEGGED));
        _expect(proxy.owner(), OWNER);
        _expect(proxy.symbol(), PEGGED_SYMBOL);
        _expect(proxy.name(), PEGGED_NAME);

        _expectRoleValue(proxy.MINTER_ROLE(), PEGGED, "MINTER_ROLE");
        _expectRoleValue(proxy.BURNER_ROLE(), PEGGED, "BURNER_ROLE");
    }

    // ============================================================================
    // Leveraged
    // ============================================================================

    function _deployLeveraged() internal {
        console2.log("Deploying Leveraged...");

        // Derive symbol and name from deployment config
        (string memory symbol, string memory name) = _deriveTokenIdentity("hs", "sail");
        _setString(LEVERAGED_SYMBOL, symbol);
        _setString(LEVERAGED_NAME, name);

        // Deploy implementation
        MintableBurnableERC20_v1 impl = new MintableBurnableERC20_v1();

        // Deploy and register proxy
        bytes memory initData = abi.encodeCall(
            MintableBurnableERC20_v1.initialize,
            (_getAddress(OWNER), _getString(LEVERAGED_NAME), _getString(LEVERAGED_SYMBOL))
        );

        deployProxy(
            LEVERAGED,
            address(impl),
            initData,
            type(MintableBurnableERC20_v1).name,
            type(MintableBurnableERC20_v1).creationCode,
            _getAddress(SESSION_DEPLOYER)
        );

        _setRole(LEVERAGED, "MINTER_ROLE", impl.MINTER_ROLE());
        _setRole(LEVERAGED, "BURNER_ROLE", impl.BURNER_ROLE());
        _saveDeployment();
    }

    function _smokeLeveraged() internal view {
        console2.log("Smoke testing Leveraged...");
        MintableBurnableERC20_v1 proxy = MintableBurnableERC20_v1(_get(LEVERAGED));
        _expect(proxy.owner(), OWNER);
        _expect(proxy.symbol(), LEVERAGED_SYMBOL);
        _expect(proxy.name(), LEVERAGED_NAME);

        _expectRoleValue(proxy.MINTER_ROLE(), LEVERAGED, "MINTER_ROLE");
        _expectRoleValue(proxy.BURNER_ROLE(), LEVERAGED, "BURNER_ROLE");
    }

    // ============================================================================
    // Fee Receiver
    // ============================================================================

    function _deployFeeReceiver(string memory key) internal {
        console2.log("Deploying %s Fee Receiver...", key);
        TokenDistributor_v1 impl = new TokenDistributor_v1();

        bytes memory initData = abi.encodeCall(
            TokenDistributor_v1.initialize,
            (_getAddress(OWNER), _getString(string.concat(key, "FeeReceiver.name")))
        );

        deployProxy(
            string.concat(key, "FeeReceiver"),
            address(impl),
            initData,
            type(TokenDistributor_v1).name,
            type(TokenDistributor_v1).creationCode,
            _getAddress(SESSION_DEPLOYER)
        );

        TokenDistributor_v1 proxy = TokenDistributor_v1(_get(string.concat(key, "FeeReceiver")));

        address[] memory tokenKeys = _getAddressArray(string.concat(key, "FeeReceiver.tokens"));
        for (uint i = 0; i < tokenKeys.length; i++) {
            proxy.addToken(tokenKeys[i]);
        }

        // string[] memory receiverKeys = _getStringArray(string.concat(key, "FeeReceiver.recipients"));
        uint[] memory shares = _getUintArray(string.concat(key, "FeeReceiver.shares"));
        // require(receiverKeys.length == shares.length, "receiver and shares count must match");
        // address[] memory recipients = new address[](receiverKeys.length);
        address[] memory recipients = _getAddressArray(string.concat(key, "FeeReceiver.recipients"));
        // for (uint i = 0; i < receiverKeys.length; i++) {
        //     recipients[i] = _get(receiverKeys[i]);
        // }
        proxy.setDistribution(recipients, shares);
        _saveDeployment();
    }

    function _smokeFeeReceiver(string memory key) internal view {
        console2.log("Smoke testing %s Fee Receiver...", key);
        TokenDistributor_v1 proxy = TokenDistributor_v1(_get(string.concat(key, "FeeReceiver")));
        _expect(proxy.owner(), OWNER);
        _expect(proxy.name(), string.concat(key, "FeeReceiver.name"));

        // Check tokens
        _expect(proxy.tokens(), string.concat(key, "FeeReceiver.tokens"));

        // Check distribution
        (address[] memory recipients, uint256[] memory shares, ) = proxy.distribution();
        _expect(recipients, string.concat(key, "FeeReceiver.recipients"));
        _expect(shares, string.concat(key, "FeeReceiver.shares"));
    }

    // ============================================================================
    // PriceOracle
    // ============================================================================

    function _deployPriceOracle() internal {
        console2.log("Deploying Price Oracle...");
        MockWrappedPriceOracle impl = new MockWrappedPriceOracle();

        registerContract(
            PRICE_ORACLE,
            address(impl),
            type(MockWrappedPriceOracle).name,
            type(MockWrappedPriceOracle).creationCode,
            _getAddress(SESSION_DEPLOYER)
        );
        _saveDeployment();
    }

    function _smokePriceOracle() internal view {
        console2.log("Smoke testing Price Oracle...");
        // not much to check here
        address impl = _get(PRICE_ORACLE);
        _expectCode(impl);
    }

    // ============================================================================
    // ReservePool
    // ============================================================================

    function _deployReservePool() internal {
        ReservePool_v1 impl = new ReservePool_v1();

        deployProxy(
            RESERVE_POOL,
            address(impl),
            abi.encodeCall(ReservePool_v1.initialize, (_getAddress(OWNER))),
            type(ReservePool_v1).name,
            type(ReservePool_v1).creationCode,
            _getAddress(SESSION_DEPLOYER)
        );
        _setRole(RESERVE_POOL, "REQUESTER_ROLE", impl.REQUESTER_ROLE());
        _saveDeployment();
    }

    function _smokeReservePool() internal view {
        console2.log("Smoke testing Reserve Pool...");
        // not much to check here
        ReservePool_v1 proxy = ReservePool_v1(_get(RESERVE_POOL));
        _expect(proxy.owner(), OWNER);
        _expectRoleValue(proxy.REQUESTER_ROLE(), RESERVE_POOL, "REQUESTER_ROLE");
    }

    // ============================================================================
    // Minter
    // ============================================================================

    function _deployMinter() internal {
        console2.log("Deploying Minter...");
        // Deploy implementation
        Minter_v1 impl = new Minter_v1(
            _get(WRAPPED_COLLATERAL),
            _get(PEGGED),
            _get(LEVERAGED),
            _getString(PEGGED_BURN_SIGNATURE)
        );

        // Deploy and register proxy
        bytes memory initData = abi.encodeCall(Minter_v1.initialize, (_getAddress(OWNER)));

        deployProxy(
            MINTER,
            address(impl),
            initData,
            type(Minter_v1).name,
            type(Minter_v1).creationCode,
            _getAddress(SESSION_DEPLOYER)
        );

        // Get the proxy and configure it
        Minter_v1 minter = Minter_v1(_get(MINTER));
        minter.updateConfig(
            IMinter.Config({
                mintPeggedIncentiveConfig: IMinter.IncentiveConfig({
                    collateralRatioBandUpperBounds: _getUintArray(MINTER_MINT_PEGGED_BOUNDS),
                    incentiveRatios: _getIntArray(MINTER_MINT_PEGGED_RATIOS)
                }),
                redeemPeggedIncentiveConfig: IMinter.IncentiveConfig({
                    collateralRatioBandUpperBounds: _getUintArray(MINTER_REDEEM_PEGGED_BOUNDS),
                    incentiveRatios: _getIntArray(MINTER_REDEEM_PEGGED_RATIOS)
                }),
                mintLeveragedIncentiveConfig: IMinter.IncentiveConfig({
                    collateralRatioBandUpperBounds: _getUintArray(MINTER_MINT_LEVERAGED_BOUNDS),
                    incentiveRatios: _getIntArray(MINTER_MINT_LEVERAGED_RATIOS)
                }),
                redeemLeveragedIncentiveConfig: IMinter.IncentiveConfig({
                    collateralRatioBandUpperBounds: _getUintArray(MINTER_REDEEM_LEVERAGED_BOUNDS),
                    incentiveRatios: _getIntArray(MINTER_REDEEM_LEVERAGED_RATIOS)
                })
            })
        );

        minter.updateFeeReceiver(_getAddress(MINTER_FEE_RECEIVER));
        minter.updatePriceOracle(_get(PRICE_ORACLE));
        minter.updateReservePool(_get(RESERVE_POOL));

        // now add it to the roles it needs to perform
        MintableBurnableERC20_v1 pegged = MintableBurnableERC20_v1(_get(PEGGED));
        pegged.grantRoles(_get(MINTER), _getRoleValue(PEGGED, "MINTER_ROLE") | _getRoleValue(PEGGED, "BURNER_ROLE"));
        _setGrantee(MINTER, PEGGED, "MINTER_ROLE");
        _setGrantee(MINTER, PEGGED, "BURNER_ROLE");

        MintableBurnableERC20_v1 leveraged = MintableBurnableERC20_v1(_get(LEVERAGED));
        leveraged.grantRoles(
            _get(MINTER),
            _getRoleValue(LEVERAGED, "MINTER_ROLE") | _getRoleValue(LEVERAGED, "BURNER_ROLE")
        );
        _setGrantee(MINTER, LEVERAGED, "MINTER_ROLE");
        _setGrantee(MINTER, LEVERAGED, "BURNER_ROLE");

        ReservePool_v1 reservePool = ReservePool_v1(_get(RESERVE_POOL));
        reservePool.grantRoles(address(minter), reservePool.REQUESTER_ROLE());
        _setGrantee(MINTER, RESERVE_POOL, "REQUESTER_ROLE");

        _setRole(MINTER, "HARVESTER_ROLE", impl.HARVESTER_ROLE());
        _setRole(MINTER, "ZERO_FEE_ROLE", impl.ZERO_FEE_ROLE());
        _saveDeployment();
    }

    function _smokeMinter() internal view {
        console2.log("Smoke testing Minter...");
        Minter_v1 proxy = Minter_v1(_get(MINTER));

        _expect(proxy.owner(), OWNER);
        _expect(proxy.PEGGED_TOKEN(), PEGGED);
        _expect(proxy.LEVERAGED_TOKEN(), LEVERAGED);
        _expect(proxy.WRAPPED_COLLATERAL_TOKEN(), WRAPPED_COLLATERAL);

        _expect(proxy.feeReceiver(), MINTER_FEE_RECEIVER);
        _expect(proxy.priceOracle(), PRICE_ORACLE);
        _expect(proxy.reservePool(), RESERVE_POOL);

        IMinter.Config memory config = proxy.config();
        _expect(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds, MINTER_MINT_PEGGED_BOUNDS);
        _expect(config.mintPeggedIncentiveConfig.incentiveRatios, MINTER_MINT_PEGGED_RATIOS);
        _expect(config.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds, MINTER_REDEEM_PEGGED_BOUNDS);
        _expect(config.redeemPeggedIncentiveConfig.incentiveRatios, MINTER_REDEEM_PEGGED_RATIOS);
        _expect(config.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds, MINTER_MINT_LEVERAGED_BOUNDS);
        _expect(config.mintLeveragedIncentiveConfig.incentiveRatios, MINTER_MINT_LEVERAGED_RATIOS);
        _expect(config.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds, MINTER_REDEEM_LEVERAGED_BOUNDS);
        _expect(config.redeemLeveragedIncentiveConfig.incentiveRatios, MINTER_REDEEM_LEVERAGED_RATIOS);

        _expectRoleValue(proxy.HARVESTER_ROLE(), MINTER, "HARVESTER_ROLE");
        _expectRoleValue(proxy.ZERO_FEE_ROLE(), MINTER, "ZERO_FEE_ROLE");

        // now check it has the roles it needs to perform
        MintableBurnableERC20_v1 pegged = MintableBurnableERC20_v1(_get(PEGGED));
        _expectRolesOf(pegged.rolesOf(_get(MINTER)), PEGGED, sa("MINTER_ROLE", "BURNER_ROLE"), MINTER);

        MintableBurnableERC20_v1 leveraged = MintableBurnableERC20_v1(_get(LEVERAGED));
        _expectRolesOf(leveraged.rolesOf(_get(MINTER)), LEVERAGED, sa("MINTER_ROLE", "BURNER_ROLE"), MINTER);

        ReservePool_v1 reservePool = ReservePool_v1(_get(RESERVE_POOL));
        _expectRolesOf(reservePool.rolesOf(_get(MINTER)), RESERVE_POOL, sa("REQUESTER_ROLE"), MINTER);
    }

    // ============================================================================
    // Stability Pool
    // ============================================================================

    function _deployStabilityPool(string memory stabilityPoolKey, string memory liquidationKey) internal {
        console2.log("Deploying Stability Pool %s ...", liquidationKey);

        // Deploy implementation
        StabilityPool_v1 impl = new StabilityPool_v1(
            _get(MINTER),
            _get(liquidationKey),
            1, // TODO: this value is not used but must be > 0
            address(0xdeadbeef), // TODO: this address is not used but must be non-zero
            _getUint(STABILITY_POOL_WITHDRAWAL_DELAY),
            _getUint(STABILITY_POOL_WITHDRAWAL_PERIOD),
            _getUint(STABILITY_POOL_MIN_TOTAL_ASSET_SUPPLY)
        );

        // Deploy and register proxy
        bytes memory initData = abi.encodeCall(
            StabilityPool_v1.initialize,
            (_getAddress(OWNER), _getUint(STABILITY_POOL_EARLY_WITHDRAWAL_FEE_RATIO), _getAddress(TREASURY))
        );

        deployProxy(
            stabilityPoolKey,
            address(impl),
            initData,
            type(StabilityPool_v1).name,
            type(StabilityPool_v1).creationCode,
            _getAddress(SESSION_DEPLOYER)
        );

        _setAddress(string.concat(stabilityPoolKey, ".liquidation"), _get(liquidationKey));
        StabilityPool_v1(_get(stabilityPoolKey)).registerRewardToken(_get(WRAPPED_COLLATERAL));
        address[] memory rewardTokens = aa(_get(WRAPPED_COLLATERAL));
        if (_get(liquidationKey) != _get(WRAPPED_COLLATERAL)) {
            StabilityPool_v1(_get(stabilityPoolKey)).registerRewardToken(_get(liquidationKey));
            rewardTokens = cons(_get(liquidationKey), rewardTokens);
        }
        _setAddressArray(string.concat(stabilityPoolKey, ".rewardTokens"), rewardTokens);

        _setRole(stabilityPoolKey, "REBALANCER_ROLE", impl.REBALANCER_ROLE());
        _setRole(stabilityPoolKey, "REWARD_DEPOSITOR_ROLE", impl.REWARD_DEPOSITOR_ROLE());
        _setRole(stabilityPoolKey, "REWARD_MANAGER_ROLE", impl.REWARD_MANAGER_ROLE());
        _saveDeployment();
    }

    function _smokeStabilityPool(string memory stabilityPoolKey, string memory liquidationKey) internal view {
        console2.log("Smoke Testing Stability Pool %s ...", liquidationKey);
        // get proxy
        StabilityPool_v1 proxy = StabilityPool_v1(_get(stabilityPoolKey));

        // constructor settings
        _expect(proxy.ASSET_TOKEN(), PEGGED);
        _expect(proxy.LIQUIDATION_TOKEN(), liquidationKey);
        _expect(uint256(proxy.WITHDRAWAL_START_DELAY()), STABILITY_POOL_WITHDRAWAL_DELAY);
        _expect(uint256(proxy.WITHDRAWAL_END_WINDOW()), STABILITY_POOL_WITHDRAWAL_PERIOD);
        _expect(uint256(proxy.MIN_TOTAL_ASSET_SUPPLY()), STABILITY_POOL_MIN_TOTAL_ASSET_SUPPLY);
        // intialize settings
        _expect(proxy.owner(), OWNER);
        _expect(proxy.getEarlyWithdrawalFee(), STABILITY_POOL_EARLY_WITHDRAWAL_FEE_RATIO);
        _expect(proxy.getFeeAddress(), TREASURY);

        // TODO: see above
        // _expect(proxy.activeRewardTokens(), string.concat(stabilityPoolKey, ".rewardTokens"));

        // roles
        _expectRoleValue(proxy.REBALANCER_ROLE(), stabilityPoolKey, "REBALANCER_ROLE");
        _expectRoleValue(proxy.REWARD_DEPOSITOR_ROLE(), stabilityPoolKey, "REWARD_DEPOSITOR_ROLE");
        _expectRoleValue(proxy.REWARD_MANAGER_ROLE(), stabilityPoolKey, "REWARD_MANAGER_ROLE");
    }

    // ============================================================================
    // Minter
    // ============================================================================

    function _deployStabilityPoolManager() internal {
        console2.log("Deploying StabilityPoolManagerMinter...");
        // Deploy implementation
        StabilityPoolManager_v1 impl = new StabilityPoolManager_v1(
            _get(MINTER),
            _get(TREASURY),
            _get(STABILITY_POOL_COLLATERAL),
            _get(STABILITY_POOL_LEVERAGED)
        );

        // Deploy and register proxy
        bytes memory initData = abi.encodeCall(StabilityPoolManager_v1.initialize, (_getAddress(OWNER)));

        deployProxy(
            STABILITY_POOL_MANAGER,
            address(impl),
            initData,
            type(StabilityPoolManager_v1).name,
            type(StabilityPoolManager_v1).creationCode,
            _getAddress(SESSION_DEPLOYER)
        );

        // Get the proxy and configure it
        StabilityPoolManager_v1 proxy = StabilityPoolManager_v1(_get(STABILITY_POOL_MANAGER));
        proxy.updateRebalanceThreshold(_getUint(STABILITY_POOL_MANAGER_REBALANCE_THRESHOLD));
        proxy.updateRebalanceBountyRatio(_getUint(STABILITY_POOL_MANAGER_REBALANCE_BOUNTY_RATIO));
        proxy.updateHarvestBountyRatio(_getUint(STABILITY_POOL_MANAGER_HARVEST_BOUNTY_RATIO));
        proxy.updateHarvestCutRatio(_getUint(STABILITY_POOL_MANAGER_HARVEST_CUT_RATIO));
        proxy.updateFeeReceiver(_get(STABILITY_POOL_MANAGER_FEE_RECEIVER));

        // now add it to the roles it needs to perform
        IBaoRoles(_get(MINTER)).grantRoles(_get(STABILITY_POOL_MANAGER), _getRoleValue(MINTER, "HARVESTER_ROLE"));
        _setGrantee(STABILITY_POOL_MANAGER, MINTER, "HARVESTER_ROLE");

        IBaoRoles(_get(STABILITY_POOL_COLLATERAL)).grantRoles(
            _get(STABILITY_POOL_MANAGER),
            _getRoleValue(STABILITY_POOL_COLLATERAL, "REWARD_DEPOSITOR_ROLE") |
                _getRoleValue(STABILITY_POOL_COLLATERAL, "REBALANCER_ROLE")
        );
        _setGrantee(STABILITY_POOL_MANAGER, STABILITY_POOL_COLLATERAL, "REWARD_DEPOSITOR_ROLE");
        _setGrantee(STABILITY_POOL_MANAGER, STABILITY_POOL_COLLATERAL, "REBALANCER_ROLE");

        IBaoRoles(_get(STABILITY_POOL_LEVERAGED)).grantRoles(
            _get(STABILITY_POOL_MANAGER),
            _getRoleValue(STABILITY_POOL_LEVERAGED, "REWARD_DEPOSITOR_ROLE") |
                _getRoleValue(STABILITY_POOL_LEVERAGED, "REBALANCER_ROLE")
        );
        _setGrantee(STABILITY_POOL_MANAGER, STABILITY_POOL_LEVERAGED, "REWARD_DEPOSITOR_ROLE");
        _setGrantee(STABILITY_POOL_MANAGER, STABILITY_POOL_LEVERAGED, "REBALANCER_ROLE");
        _saveDeployment();
    }

    function _smokeStabilityPoolManager() internal view {
        console2.log("Smoke testing StabilityPoolManager...");
        StabilityPoolManager_v1 proxy = StabilityPoolManager_v1(_get(STABILITY_POOL_MANAGER));

        // Constructor immutables
        _expect(proxy.owner(), OWNER);
        _expect(proxy.MINTER(), MINTER);
        _expect(proxy.PEGGED_TOKEN(), PEGGED);
        _expect(proxy.LEVERAGED_TOKEN(), LEVERAGED);
        _expect(proxy.WRAPPED_COLLATERAL_TOKEN(), WRAPPED_COLLATERAL);
        _expect(proxy.TREASURY(), TREASURY);

        // Stability pools
        address[] memory pools = proxy.stabilityPools();
        require(pools.length == 2, "Expected 2 stability pools");
        _expect(pools[0], STABILITY_POOL_COLLATERAL);
        _expect(pools[1], STABILITY_POOL_LEVERAGED);

        // Configuration
        _expect(proxy.rebalanceThreshold(), STABILITY_POOL_MANAGER_REBALANCE_THRESHOLD);
        _expect(proxy.rebalanceBountyRatio(), STABILITY_POOL_MANAGER_REBALANCE_BOUNTY_RATIO);
        _expect(proxy.harvestBountyRatio(), STABILITY_POOL_MANAGER_HARVEST_BOUNTY_RATIO);
        _expect(proxy.harvestCutRatio(), STABILITY_POOL_MANAGER_HARVEST_CUT_RATIO);
        _expect(proxy.feeReceiver(), STABILITY_POOL_MANAGER_FEE_RECEIVER);

        // HARVESTER_ROLE grant on Minter
        Minter_v1 minter = Minter_v1(_get(MINTER));
        _expectRolesOf(
            minter.rolesOf(_get(STABILITY_POOL_MANAGER)),
            MINTER,
            sa("HARVESTER_ROLE"),
            STABILITY_POOL_MANAGER
        );

        // Roles on stability pools
        StabilityPool_v1 spCollateral = StabilityPool_v1(_get(STABILITY_POOL_COLLATERAL));
        _expectRolesOf(
            spCollateral.rolesOf(_get(STABILITY_POOL_MANAGER)),
            STABILITY_POOL_COLLATERAL,
            sa("REWARD_DEPOSITOR_ROLE", "REBALANCER_ROLE"),
            STABILITY_POOL_MANAGER
        );

        StabilityPool_v1 spLeveraged = StabilityPool_v1(_get(STABILITY_POOL_LEVERAGED));
        _expectRolesOf(
            spLeveraged.rolesOf(_get(STABILITY_POOL_MANAGER)),
            STABILITY_POOL_LEVERAGED,
            sa("REWARD_DEPOSITOR_ROLE", "REBALANCER_ROLE"),
            STABILITY_POOL_MANAGER
        );
    }

    function _deployGenesis() internal {
        // Deploy and register proxy
        Genesis_v1 impl = new Genesis_v1(_get(MINTER));

        bytes memory initData = abi.encodeCall(Genesis_v1.initialize, (_getAddress(OWNER)));

        deployProxy(
            GENESIS,
            address(impl),
            initData,
            type(Genesis_v1).name,
            type(Genesis_v1).creationCode,
            _getAddress(SESSION_DEPLOYER)
        );

        IBaoRoles(_get(MINTER)).grantRoles(_get(GENESIS), _getRoleValue(MINTER, "ZERO_FEE_ROLE"));
        _setGrantee(GENESIS, MINTER, "ZERO_FEE_ROLE");
        _saveDeployment();
    }

    function finish() public virtual override returns (uint256 transferred) {
        transferred = super.finish();
        _saveDeployment();
    }

    function _smokeGenesis() internal view {
        console2.log("Smoke testing Genesis...");

        Genesis_v1 proxy = Genesis_v1(_get(GENESIS));
        _expect(proxy.owner(), OWNER);
        _expect(proxy.MINTER(), MINTER);
        _expect(proxy.PEGGED_TOKEN(), PEGGED);
        _expect(proxy.WRAPPED_COLLATERAL_TOKEN(), WRAPPED_COLLATERAL);
        _expect(proxy.LEVERAGED_TOKEN(), LEVERAGED);
        // stability pools are not used
        // _expect(proxy.STABILITY_POOL_COLLATERAL(), STABILITY_POOL_COLLATERAL);
        // _expect(proxy.STABILITY_POOL_LEVERAGED(), STABILITY_POOL_LEVERAGED);
        require(!proxy.genesisIsEnded());

        Minter_v1 minter = Minter_v1(_get(MINTER));
        _expectRolesOf(minter.rolesOf(_get(GENESIS)), MINTER, sa("ZERO_FEE_ROLE"), GENESIS);
    }
}
