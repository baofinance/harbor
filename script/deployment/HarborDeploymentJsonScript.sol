// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Vm} from "forge-std/Vm.sol";
import {DeploymentJsonScript} from "@bao-script/deployment/DeploymentJsonScript.sol";
// import {PeggedTokenDeployer} from "@harbor-script/deployment/deployers/PeggedTokenDeployer.sol";
// TODO: Re-enable as deployers are migrated
// import {FeeReceiverDeployer} from "@harbor-script/deployment/deployers/FeeReceiverDeployer.sol";
// import {LeveragedTokenDeployer} from "@harbor-script/deployment/deployers/LeveragedTokenDeployer.sol";
// import {ReservePoolDeployer} from "@harbor-script/deployment/deployers/ReservePoolDeployer.sol";
// import {MinterDeployer} from "@harbor-script/deployment/deployers/MinterDeployer.sol";
// import {StabilityPoolCollateralDeployer} from "@harbor-script/deployment/deployers/StabilityPoolCollateralDeployer.sol";
// import {StabilityPoolLeveragedDeployer} from "@harbor-script/deployment/deployers/StabilityPoolLeveragedDeployer.sol";
// import {StabilityPoolManagerDeployer} from "@harbor-script/deployment/deployers/StabilityPoolManagerDeployer.sol";
// import {GenesisDeployer} from "@harbor-script/deployment/deployers/GenesisDeployer.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";

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

    string public constant FEE_RECEIVER = "contracts.feeReceiver";
    string public constant TREASURY = "treasury";
    string public constant WRAPPED_COLLATERAL = "wrappedCollateral";
    string public constant PEGGED = "contracts.pegged";
    string public constant LEVERAGED = "leveraged";
    string public constant ORACLE = "contracts.oracle";
    string public constant MINTER = "contracts.minter";
    string public constant RESERVE_POOL = "reservePool";
    string public constant STABILITY_POOL_MANAGER = "contracts.stabilityPoolManager";
    string public constant STABILITY_POOL_COLLATERAL = "contracts.stabilityPoolCollateral";
    string public constant STABILITY_POOL_LEVERAGED = "contracts.stabilityPoolLeveraged";
    string public constant GENESIS = "contracts.genesis";
    string public constant REWARD_MANAGER = "rewardManager";
    string public constant REWARD_DEPOSITOR = "rewardDepositor";
    string public constant REBALANCER = "rebalancer";

    // =========================================================================
    // Parameter Keys
    // =========================================================================

    string public constant PEGGED_NAME = "contracts.pegged.name";
    string public constant PEGGED_SYMBOL = "contracts.pegged.symbol";
    string public constant LEVERAGED_NAME = "contracts.leveraged.name";
    string public constant LEVERAGED_SYMBOL = "contracts.leveraged.symbol";
    string public constant LEVERAGED_DECIMALS = "contracts.leveraged.decimals";
    string public constant COLLATERAL_DECIMALS = "contracts.collateral.decimals";

    string public constant FEE_RECEIVER_NAME = "contracts.feeReceiver.name";

    string public constant STABILITY_POOL_EARLY_WITHDRAWAL_FEE = "contracts.stabilityPool.earlyWithdrawalFee";
    string public constant STABILITY_POOL_MIN_DEPOSIT = "contracts.stabilityPool.minDeposit";

    string public constant INITIAL_EXCHANGE_RATE = "contracts.pegged.initialExchangeRate";
    string public constant FEE_PERCENTAGE = "contracts.feeReceiver.percentage";

    // ============================================================================
    // Configuration
    // ============================================================================

    constructor() {
        addProxy(PEGGED);
        addStringKey(PEGGED_NAME);
        addStringKey(PEGGED_SYMBOL);
    }

    function _deployPegged() internal {
        // Read parameters directly from registry (populated from config)
        address owner = _getAddress(OWNER);
        string memory name = _getString(PEGGED_NAME);
        string memory symbol = _getString(PEGGED_SYMBOL);

        // Deploy implementation
        MintableBurnableERC20_v1 impl = new MintableBurnableERC20_v1();

        string memory contractType = type(MintableBurnableERC20_v1).name;

        string memory json = vm.readFile(
            string.concat(vm.projectRoot(), "/out/", contractType, ".sol/", contractType, ".json")
        );
        // Get the compilationTarget object keys (there's only one)
        string[] memory keys = vm.parseJsonKeys(json, ".metadata.settings.compilationTarget");
        string memory contractPath = keys[0]; // e.g., "lib/bao-base-audit-2025-07/src/MintableBurnableERC20_v1.sol"

        // Get the contract name from that key
        // string memory contractName = vm.parseJsonString(json, string.concat(".metadata.settings.compilationTarget.", contractPath));
        // Or use the key with quotes for JSON pointer:
        // string memory contractName = vm.parseJsonString(json, string.concat(".metadata.settings.compilationTarget[\"", contractPath, "\"]"));

        // Deploy and register proxy
        bytes memory initData = abi.encodeCall(MintableBurnableERC20_v1.initialize, (owner, name, symbol));
        deployProxy(PEGGED, address(impl), initData, contractType, contractPath, _getAddress(SESSION_DEPLOYER));

        // // Register implementation with derived key (proxyKey:contractType)
        // string memory implKey = registerImplementation(
        //     PEGGED,
        //     address(impl),
        //     "MintableBurnableERC20_v1",
        //     "src/bao/MintableBurnableERC20_v1.sol"
        // );
    }
}
