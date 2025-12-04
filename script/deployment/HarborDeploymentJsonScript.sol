// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

import {DeploymentJsonScript} from "@bao-script/deployment/DeploymentJsonScript.sol";

// import {MinterDeployer} from "@harbor-script/deployment/deployers/MinterDeployer.sol";
// import {StabilityPoolCollateralDeployer} from "@harbor-script/deployment/deployers/StabilityPoolCollateralDeployer.sol";
// import {StabilityPoolLeveragedDeployer} from "@harbor-script/deployment/deployers/StabilityPoolLeveragedDeployer.sol";
// import {StabilityPoolManagerDeployer} from "@harbor-script/deployment/deployers/StabilityPoolManagerDeployer.sol";
// import {GenesisDeployer} from "@harbor-script/deployment/deployers/GenesisDeployer.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {ReservePool_v1} from "@harbor/minter/ReservePool_v1.sol";
import {TokenDistributor_v1} from "@harbor/minter/TokenDistributor_v1.sol";
import {MockWrappedPriceOracle} from "test/mocks/MockWrappedPriceOracle.sol";
import {Minter_v1} from "@harbor/minter/Minter_v1.sol";

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

    string public constant LEVERAGED = "contracts.leveraged";
    string public constant LEVERAGED_NAME = "contracts.leveraged.name";
    string public constant LEVERAGED_SYMBOL = "contracts.leveraged.symbol";

    string public constant FEE_RECEIVER = "contracts.feeReceiver";
    string public constant FEE_RECEIVER_NAME = "contracts.feeReceiver.name";

    string public constant PRICE_ORACLE = "contracts.priceOracle";

    string public constant RESERVE_POOL = "contracts.reservePool";

    string public constant MINTER = "contracts.minter";

    string public constant STABILITY_POOL_COLLATERAL = "contracts.stabilityPoolCollateral";
    string public constant STABILITY_POOL_COLLATERAL_EARLY_WITHDRAWAL_FEE =
        "contracts.stabilityPoolCollateral.earlyWithdrawalFee";
    string public constant STABILITY_POOL_COLLATERAL_MIN_DEPOSIT = "contracts.stabilityPoolCollateral.minDeposit";

    string public constant STABILITY_POOL_LEVERAGED = "contracts.stabilityPoolLeveraged";
    string public constant STABILITY_POOL_LEVERAGED_EARLY_WITHDRAWAL_FEE =
        "contracts.stabilityPoolLeveraged.earlyWithdrawalFee";
    string public constant STABILITY_POOL_LEVERAGED_MIN_DEPOSIT = "contracts.stabilityPoolLeveraged.minDeposit";

    string public constant STABILITY_POOL_MANAGER = "contracts.stabilityPoolManager";

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
        addContract(COLLATERAL);
        addStringKey(COLLATERAL_SYMBOL);
        addStringKey(COLLATERAL_NAME);

        addContract(WRAPPED_COLLATERAL);
        addStringKey(WRAPPED_COLLATERAL_SYMBOL);
        addStringKey(WRAPPED_COLLATERAL_NAME);

        addProxy(PEGGED);
        addStringKey(PEGGED_NAME);
        addStringKey(PEGGED_SYMBOL);

        addProxy(LEVERAGED);
        addStringKey(LEVERAGED_NAME);
        addStringKey(LEVERAGED_SYMBOL);

        addProxy(MINTER);

        addProxy(FEE_RECEIVER);
        addStringKey(FEE_RECEIVER_NAME);

        addContract(PRICE_ORACLE);
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
    }

    function _smokePegged() internal view {
        console2.log("Smoke testing Pegged...");
        MintableBurnableERC20_v1 proxy = MintableBurnableERC20_v1(_get(PEGGED));
        _expect(proxy.owner(), OWNER);
        _expect(proxy.symbol(), PEGGED_SYMBOL);
        _expect(proxy.name(), PEGGED_NAME);
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
    }

    function _smokeLeveraged() internal view {
        console2.log("Smoke testing Leveraged...");
        MintableBurnableERC20_v1 proxy = MintableBurnableERC20_v1(_get(LEVERAGED));
        _expect(proxy.owner(), OWNER);
        _expect(proxy.symbol(), LEVERAGED_SYMBOL);
        _expect(proxy.name(), LEVERAGED_NAME);
    }

    // ============================================================================
    // Fee Receiver
    // ============================================================================

    function _deployFeeReceiver() internal {
        console2.log("Deploying Fee Receiver...");
        TokenDistributor_v1 impl = new TokenDistributor_v1();

        bytes memory initData = abi.encodeCall(
            TokenDistributor_v1.initialize,
            (_getAddress(OWNER), _getString(FEE_RECEIVER_NAME))
        );

        deployProxy(
            FEE_RECEIVER,
            address(impl),
            initData,
            type(TokenDistributor_v1).name,
            _getAddress(SESSION_DEPLOYER)
        );
    }

    function _smokeFeeReceiver() internal view {
        console2.log("Smoke testing Fee Receiver...");
        TokenDistributor_v1 proxy = TokenDistributor_v1(_get(FEE_RECEIVER));
        _expect(proxy.owner(), OWNER);
        _expect(proxy.name(), FEE_RECEIVER_NAME);
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

    function deployReservePool() internal {
        ReservePool_v1 impl = new ReservePool_v1();

        deployProxy(
            RESERVE_POOL,
            address(impl),
            abi.encodeCall(ReservePool_v1.initialize, (_getAddress(OWNER))),
            type(ReservePool_v1).name,
            _getAddress(SESSION_DEPLOYER)
        );
    }

    function _smokeReservePool() internal view {
        console2.log("Smoke testing Reserve Pool...");
        // not much to check here
        address impl = _get(RESERVE_POOL);
        _expectCode(impl);
    }

    // ============================================================================
    // Minter
    // ============================================================================

    function _deployMinter() internal {
        console2.log("Deploying Minter...");
        // Deploy implementation
        Minter_v1 impl = new Minter_v1(_get(WRAPPED_COLLATERAL), _get(PEGGED), _get(LEVERAGED), "burn(uint256)");

        // Deploy and register proxy
        bytes memory initData = abi.encodeCall(Minter_v1.initialize, (_getAddress(OWNER)));

        deployProxy(MINTER, address(impl), initData, type(Minter_v1).name, _getAddress(SESSION_DEPLOYER));

        // Get the proxy and configure it
        Minter_v1 minter = Minter_v1(_get(MINTER));

        // minter config is:
        // four of (uint[], int[]),
        // ((uint256[],int256[]),(uint256[],int256[]),(uint256[],int256[]),(uint256[],int256[]))

        // _getUintArray()

        // minter.updateConfig

        minter.updateFeeReceiver(_get(FEE_RECEIVER));
        minter.updatePriceOracle(_get(PRICE_ORACLE));
    }

    function _smokeMinter() internal view {
        console2.log("Smoke testing Minter...");
        Minter_v1 proxy = Minter_v1(_get(MINTER));

        _expect(proxy.owner(), OWNER);
        _expect(proxy.PEGGED_TOKEN(), PEGGED);
        _expect(proxy.LEVERAGED_TOKEN(), LEVERAGED);
        _expect(proxy.WRAPPED_COLLATERAL_TOKEN(), WRAPPED_COLLATERAL);

        _expect(proxy.feeReceiver(), FEE_RECEIVER);
        _expect(proxy.priceOracle(), PRICE_ORACLE);
    }
}
