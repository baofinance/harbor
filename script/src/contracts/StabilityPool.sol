// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";

import {StabilityPool_v2} from "@harbor/minter/StabilityPool_v2.sol";

/// @notice Config interface for stability pool deployment parameters.
interface IStabilityPoolMarketConfig {
    function stabilityPoolWithdrawalDelay() external pure returns (uint256);
    function stabilityPoolWithdrawalPeriod() external pure returns (uint256);
    function stabilityPoolEarlyWithdrawalFeeRatio() external pure returns (uint256);
    function minTotalSupply() external view returns (uint256);
}

/// @notice Harbor StabilityPool_v2 deployment logic.
/// @dev Each market has TWO stability pools: Collateral (wrapped collateral) and Leveraged (leveraged token).
/// @dev Both pools grant: REBALANCER_ROLE, REWARD_DEPOSITOR_ROLE to StabilityPoolManager.
abstract contract StabilityPool is HarborFactoryDeployer {
    string StabilityPoolCollateral = "stabilityPoolCollateral";
    string StabilityPoolLeveraged = "stabilityPoolLeveraged";

    // ========== STABILITY POOL DEPLOYMENT ==========

    /// @notice Deploy StabilityPool impl only, record in state.
    function deployStabilityPoolImplementation(
        string memory spType,
        DeploymentTypes.State memory stateData,
        string memory marketKey,
        address minter,
        address liquidationToken,
        address configContract
    ) internal virtual returns (address impl) {
        string memory spKey = string.concat(marketKey, "::", spType);
        console.log("    > %s", spKey);

        IStabilityPoolMarketConfig cfg = IStabilityPoolMarketConfig(configContract);
        impl = address(
            new StabilityPool_v2(
                minter,
                liquidationToken,
                cfg.stabilityPoolWithdrawalDelay(),
                cfg.stabilityPoolWithdrawalPeriod(),
                cfg.minTotalSupply()
            )
        );
        console.log("        Impl:  %s", impl);

        DeploymentState.recordImplementation(
            stateData,
            DeploymentTypes.ImplementationRecord({
                proxy: spKey,
                contractSource: "@harbor/minter/StabilityPool_v2.sol",
                contractType: "StabilityPool_v2",
                implementation: impl,
                deploymentTime: uint64(block.timestamp)
            })
        );
    }

    /// @notice Deploy StabilityPool impl+proxy, record in state.
    function deployStabilityPool(
        string memory spType,
        DeploymentTypes.State memory stateData,
        string memory marketKey,
        address minter,
        address liquidationToken,
        address configContract
    ) internal returns (address proxy) {
        string memory spKey = string.concat(marketKey, "::", spType);
        console.log("    > %s", spKey);

        address impl = deployStabilityPoolImplementation(
            spType,
            stateData,
            marketKey,
            minter,
            liquidationToken,
            configContract
        );

        IStabilityPoolMarketConfig cfg = IStabilityPoolMarketConfig(configContract);
        bytes memory initData = abi.encodeCall(
            StabilityPool_v2.initialize,
            (owner(), cfg.stabilityPoolEarlyWithdrawalFeeRatio(), treasury())
        );

        proxy = _deployProxyAndRecord(stateData, spKey, impl, initData);
    }

    /// @notice Grant StabilityPool roles to StabilityPoolManager.
    function grantStabilityPoolRoles(
        string memory stabilityPoolKey,
        address stabilityPoolProxy,
        address stabilityPoolManager
    ) internal {
        StabilityPool_v2 pool = StabilityPool_v2(stabilityPoolProxy);
        uint256 roles = pool.REBALANCER_ROLE() | pool.REWARD_DEPOSITOR_ROLE();
        _grantRoles(
            stabilityPoolKey,
            stabilityPoolProxy,
            stabilityPoolManager,
            "stabilityPoolManager",
            roles,
            "REBALANCER | REWARD_DEPOSITOR"
        );
    }
}
