// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {DeploymentJsonScript} from "@bao-script/deployment/DeploymentJsonScript.sol";

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

/**
 * @title HarborDeploymentJson
 * @notice Harbor-specific deployment contract with Stem proxy management
 * @dev Extends Deployment with Harbor-specific features:
 *      - All proxies use Stem_v1 for upgrade control
 *      - Type-safe enum-based API
 *      - Production-focused deployment methods
 *      - Delegates actual deployment to specialized libraries
 */

abstract contract HarborDeploymentJsonScript is DeploymentJsonScript {
    // =========================================================================
    // Contract Keys
    // =========================================================================

    string public constant TREASURY = "treasury";

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
    string public constant STABILITY_POOL_LEVERAGED = "contracts.stabilityPoolLeveraged";
    string public constant STABILITY_POOL_LEVERAGED_LIQUIDATION = "contracts.stabilityPoolLeveraged.liquidation";

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

    string public constant REWARD_MANAGER = "rewardManager";
    string public constant REWARD_DEPOSITOR = "rewardDepositor";
    string public constant REBALANCER = "rebalancer";

    string public constant INITIAL_EXCHANGE_RATE = "contracts.pegged.initialExchangeRate";
    string public constant FEE_PERCENTAGE = "contracts.feeReceiver.percentage";

    // ============================================================================
    // Configuration
    // ============================================================================

    constructor() {
        // TODO: naming
        // - add* -> register
        // - FEE_RECEIVER -> FEE_DISTRIBUTOR
        // - use set/get for data values, including the ones named register*

        addAddressKey(TREASURY);

        addContract(COLLATERAL);
        addStringKey(COLLATERAL_SYMBOL);
        addStringKey(COLLATERAL_NAME);

        addContract(WRAPPED_COLLATERAL);
        addStringKey(WRAPPED_COLLATERAL_SYMBOL);
        addStringKey(WRAPPED_COLLATERAL_NAME);

        addProxy(PEGGED);
        addStringKey(PEGGED_NAME);
        addStringKey(PEGGED_SYMBOL);
        addStringKey(PEGGED_BURN_SIGNATURE);

        addProxy(LEVERAGED);
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

        addProxy(MINTER);
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
        addAddressKey(STABILITY_POOL_COLLATERAL_LIQUIDATION);
        addProxy(STABILITY_POOL_LEVERAGED);
        addAddressKey(STABILITY_POOL_LEVERAGED_LIQUIDATION);

        addProxy(STABILITY_POOL_MANAGER);
        addUintKey(STABILITY_POOL_MANAGER_REBALANCE_THRESHOLD, 16);
        addUintKey(STABILITY_POOL_MANAGER_REBALANCE_BOUNTY_RATIO, 16);
        addUintKey(STABILITY_POOL_MANAGER_HARVEST_BOUNTY_RATIO, 16);
        addUintKey(STABILITY_POOL_MANAGER_HARVEST_CUT_RATIO, 16);
        addAddressKey(STABILITY_POOL_MANAGER_FEE_RECEIVER);

        addProxy(GENESIS);
    }

    // ============================================================================
    // Pegged
    // ============================================================================

    function _deployPegged() internal {
        console2.log("Deploying Pegged...");

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
            _getAddress(SESSION_DEPLOYER)
        );

        _registerRole(PEGGED, "MINTER_ROLE", impl.MINTER_ROLE());
        _registerRole(PEGGED, "BURNER_ROLE", impl.BURNER_ROLE());

        _setString(PEGGED_BURN_SIGNATURE, "burn(uint256)");
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
            _getAddress(SESSION_DEPLOYER)
        );

        _registerRole(LEVERAGED, "MINTER_ROLE", impl.MINTER_ROLE());
        _registerRole(LEVERAGED, "BURNER_ROLE", impl.BURNER_ROLE());
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
    }

    function _smokeFeeReceiver(string memory key) internal view {
        console2.log("Smoke testing %s Fee Receiver...", key);
        TokenDistributor_v1 proxy = TokenDistributor_v1(_get(string.concat(key, "FeeReceiver")));
        _expect(proxy.owner(), OWNER);
        _expect(proxy.name(), string.concat(key, "FeeReceiver.name"));
    }

    // ============================================================================
    // PriceOracle
    // ============================================================================

    function _deployPriceOracle() internal {
        console2.log("Deploying Price Oracle...");
        MockWrappedPriceOracle impl = new MockWrappedPriceOracle();

        registerContract(PRICE_ORACLE, address(impl), type(MockWrappedPriceOracle).name, _getAddress(SESSION_DEPLOYER));
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
            _getAddress(SESSION_DEPLOYER)
        );
        _registerRole(RESERVE_POOL, "REQUESTER_ROLE", impl.REQUESTER_ROLE());
    }

    function _smokeReservePool() internal view {
        console2.log("Smoke testing Reserve Pool...");
        // not much to check here
        ReservePool_v1 proxy = ReservePool_v1(_get(RESERVE_POOL));
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

        deployProxy(MINTER, address(impl), initData, type(Minter_v1).name, _getAddress(SESSION_DEPLOYER));

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
        _registerGrantee(MINTER, PEGGED, "MINTER_ROLE");
        _registerGrantee(MINTER, PEGGED, "BURNER_ROLE");

        MintableBurnableERC20_v1 leveraged = MintableBurnableERC20_v1(_get(LEVERAGED));
        leveraged.grantRoles(
            _get(MINTER),
            _getRoleValue(LEVERAGED, "MINTER_ROLE") | _getRoleValue(LEVERAGED, "BURNER_ROLE")
        );
        _registerGrantee(MINTER, LEVERAGED, "MINTER_ROLE");
        _registerGrantee(MINTER, LEVERAGED, "BURNER_ROLE");

        ReservePool_v1 reservePool = ReservePool_v1(_get(RESERVE_POOL));
        reservePool.grantRoles(address(minter), reservePool.REQUESTER_ROLE());
        _registerGrantee(MINTER, RESERVE_POOL, "REQUESTER_ROLE");

        _registerRole(MINTER, "HARVESTER_ROLE", impl.HARVESTER_ROLE());
        _registerRole(MINTER, "ZERO_FEE_ROLE", impl.ZERO_FEE_ROLE());
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

        // now check it has the roles it needs to perform
        MintableBurnableERC20_v1 pegged = MintableBurnableERC20_v1(_get(PEGGED));
        _expectRolesOf(pegged.rolesOf(_get(MINTER)), PEGGED, _roles("MINTER_ROLE", "BURNER_ROLE"), MINTER);

        MintableBurnableERC20_v1 leveraged = MintableBurnableERC20_v1(_get(LEVERAGED));
        _expectRolesOf(leveraged.rolesOf(_get(MINTER)), LEVERAGED, _roles("MINTER_ROLE", "BURNER_ROLE"), MINTER);

        ReservePool_v1 reservePool = ReservePool_v1(_get(RESERVE_POOL));
        _expectRolesOf(reservePool.rolesOf(_get(MINTER)), RESERVE_POOL, _roles("REQUESTER_ROLE"), MINTER);
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
            _getAddress(SESSION_DEPLOYER)
        );

        _setAddress(string.concat(stabilityPoolKey, ".liquidation"), _get(liquidationKey));
        StabilityPool_v1(_get(stabilityPoolKey)).registerRewardToken(_get(liquidationKey));

        _registerRole(stabilityPoolKey, "REBALANCER_ROLE", impl.REBALANCER_ROLE());
        _registerRole(stabilityPoolKey, "REWARD_DEPOSITOR_ROLE", impl.REWARD_DEPOSITOR_ROLE());
        _registerRole(stabilityPoolKey, "REWARD_MANAGER_ROLE", impl.REWARD_MANAGER_ROLE());
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
        proxy.grantRoles(_get(STABILITY_POOL_MANAGER), _getRoleValue(MINTER, "HARVESTER_ROLE"));
        _registerGrantee(STABILITY_POOL_MANAGER, MINTER, "HARVESTER_ROLE");

        IBaoRoles(_get(STABILITY_POOL_COLLATERAL)).grantRoles(
            _get(STABILITY_POOL_MANAGER),
            _getRoleValue(STABILITY_POOL_COLLATERAL, "REWARD_DEPOSITOR_ROLE") |
                _getRoleValue(STABILITY_POOL_COLLATERAL, "REBALANCER_ROLE")
        );
        _registerGrantee(STABILITY_POOL_MANAGER, STABILITY_POOL_COLLATERAL, "REWARD_DEPOSITOR_ROLE");
        _registerGrantee(STABILITY_POOL_MANAGER, STABILITY_POOL_COLLATERAL, "REBALANCER_ROLE");

        IBaoRoles(_get(STABILITY_POOL_LEVERAGED)).grantRoles(
            _get(STABILITY_POOL_MANAGER),
            _getRoleValue(STABILITY_POOL_LEVERAGED, "REWARD_DEPOSITOR_ROLE") |
                _getRoleValue(STABILITY_POOL_LEVERAGED, "REBALANCER_ROLE")
        );
        _registerGrantee(STABILITY_POOL_MANAGER, STABILITY_POOL_LEVERAGED, "REWARD_DEPOSITOR_ROLE");
        _registerGrantee(STABILITY_POOL_MANAGER, STABILITY_POOL_LEVERAGED, "REBALANCER_ROLE");
    }

    function _smokeStabilityPoolManager() internal view {
        console2.log("Smoke testing StabilityPoolManager...");
        StabilityPoolManager_v1 proxy = StabilityPoolManager_v1(_get(STABILITY_POOL_MANAGER));

        _expect(proxy.owner(), OWNER);
        _expect(proxy.PEGGED_TOKEN(), PEGGED);
        _expect(proxy.LEVERAGED_TOKEN(), LEVERAGED);
        _expect(proxy.WRAPPED_COLLATERAL_TOKEN(), WRAPPED_COLLATERAL);
        _expect(proxy.TREASURY(), TREASURY);

        // now check it has the roles it needs to perform
        MintableBurnableERC20_v1 pegged = MintableBurnableERC20_v1(_get(PEGGED));
        _expectRolesOf(pegged.rolesOf(_get(MINTER)), PEGGED, _roles("MINTER_ROLE", "BURNER_ROLE"), MINTER);

        MintableBurnableERC20_v1 leveraged = MintableBurnableERC20_v1(_get(LEVERAGED));
        _expectRolesOf(leveraged.rolesOf(_get(MINTER)), LEVERAGED, _roles("MINTER_ROLE", "BURNER_ROLE"), MINTER);

        ReservePool_v1 reservePool = ReservePool_v1(_get(RESERVE_POOL));
        _expectRolesOf(reservePool.rolesOf(_get(MINTER)), RESERVE_POOL, _roles("REQUESTER_ROLE"), MINTER);
    }

    function _deployGenesis() internal {
        // Deploy and register proxy
        Genesis_v1 impl = new Genesis_v1(_get(MINTER));

        bytes memory initData = abi.encodeCall(Genesis_v1.initialize, (_getAddress(OWNER)));

        deployProxy(GENESIS, address(impl), initData, type(Genesis_v1).name, _getAddress(SESSION_DEPLOYER));

        IBaoRoles(_get(MINTER)).grantRoles(_get(GENESIS), _getRoleValue(MINTER, "ZERO_FEE_ROLE"));
        _registerGrantee(GENESIS, MINTER, "ZERO_FEE_ROLE");
    }

    function _smokeGenesis() internal view {
        console2.log("Smoke testing Genesis...");

        Genesis_v1 proxy = Genesis_v1(_get(GENESIS));
        _expect(proxy.owner(), OWNER);
        _expect(proxy.MINTER(), MINTER);
        _expect(proxy.PEGGED_TOKEN(), PEGGED);
        _expect(proxy.WRAPPED_COLLATERAL_TOKEN(), WRAPPED_COLLATERAL);
        _expect(proxy.LEVERAGED_TOKEN(), LEVERAGED);
        _expect(proxy.STABILITY_POOL_COLLATERAL(), STABILITY_POOL_COLLATERAL);
        _expect(proxy.STABILITY_POOL_LEVERAGED(), STABILITY_POOL_LEVERAGED);
        require(!proxy.genesisIsEnded());

        Minter_v1 minter = Minter_v1(_get(MINTER));
        _expectRolesOf(minter.rolesOf(_get(GENESIS)), MINTER, _roles("ZERO_FEE_ROLE"), GENESIS);
    }
}
