// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

import {StabilityPool_v1} from "@harbor/minter/StabilityPool_v1.sol";

/// @notice Harbor StabilityPool_v1 deployment logic.
/// @dev Each market has TWO stability pools: Collateral (wrapped collateral) and Leveraged (leveraged token).
/// @dev Both pools grant: REBALANCER_ROLE, REWARD_DEPOSITOR_ROLE to StabilityPoolManager.
abstract contract StabilityPool is HarborFactoryDeployer {
    /// @notice StabilityPool configuration for deployment.
    struct StabilityPoolConfig {
        uint256 earlyWithdrawalFeeRatio;
        uint256 withdrawalDelay;
        uint256 withdrawalPeriod;
        uint256 minTotalAssetSupply;
        address treasury;
    }

    // ========== STABILITY POOL DEPLOYMENT ==========

    /// @notice Deploy StabilityPoolCollateral impl+proxy, record in state.
    function deployStabilityPoolCollateral(
        DeploymentTypes.State memory stateData,
        string memory marketKey,
        address minter,
        address wrappedCollateral,
        StabilityPoolConfig memory config
    ) internal virtual returns (address proxy) {
        string memory spKey = string.concat(marketKey, "::stabilityPoolCollateral");
        console.log("    > %s", spKey);

        address impl = address(
            new StabilityPool_v1(
                minter,
                wrappedCollateral,
                1, // placeholder
                address(0xdeadbeef), // placeholder
                config.withdrawalDelay,
                config.withdrawalPeriod,
                config.minTotalAssetSupply
            )
        );
        console.log("        Impl:  %s", impl);

        bytes memory initData = abi.encodeCall(
            StabilityPool_v1.initialize,
            (owner(), config.earlyWithdrawalFeeRatio, config.treasury)
        );

        proxy = _deployProxyAndRecord(
            stateData,
            spKey,
            impl,
            "@harbor/minter/StabilityPool_v1.sol",
            "StabilityPool_v1",
            initData
        );
    }

    /// @notice Deploy StabilityPoolLeveraged impl+proxy, record in state.
    function deployStabilityPoolLeveraged(
        DeploymentTypes.State memory stateData,
        string memory marketKey,
        address minter,
        address leveragedToken,
        StabilityPoolConfig memory config
    ) internal virtual returns (address proxy) {
        string memory spKey = string.concat(marketKey, "::stabilityPoolLeveraged");
        console.log("    > %s", spKey);

        address impl = address(
            new StabilityPool_v1(
                minter,
                leveragedToken,
                1, // placeholder
                address(0xdeadbeef), // placeholder
                config.withdrawalDelay,
                config.withdrawalPeriod,
                config.minTotalAssetSupply
            )
        );
        console.log("        Impl:  %s", impl);

        bytes memory initData = abi.encodeCall(
            StabilityPool_v1.initialize,
            (owner(), config.earlyWithdrawalFeeRatio, config.treasury)
        );

        proxy = _deployProxyAndRecord(
            stateData,
            spKey,
            impl,
            "@harbor/minter/StabilityPool_v1.sol",
            "StabilityPool_v1",
            initData
        );
    }

    /// @notice Grant StabilityPool roles to StabilityPoolManager.
    function grantStabilityPoolRoles(
        string memory stabilityPoolKey,
        address stabilityPoolProxy,
        address stabilityPoolManager
    ) internal {
        StabilityPool_v1 pool = StabilityPool_v1(stabilityPoolProxy);
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

    // ========== ADDRESS PREDICTION ==========

    /// @notice Predict stability pool collateral contract address from salt.
    function predictStabilityPoolCollateralAddress(
        address baoFactoryAddr,
        string memory saltPrefix,
        string memory marketKey
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(saltPrefix, "::", marketKey, "::stabilityPoolCollateral"));
        return IBaoFactory(baoFactoryAddr).predictAddress(salt);
    }

    /// @notice Predict stability pool leveraged contract address from salt.
    function predictStabilityPoolLeveragedAddress(
        address baoFactoryAddr,
        string memory saltPrefix,
        string memory marketKey
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(saltPrefix, "::", marketKey, "::stabilityPoolLeveraged"));
        return IBaoFactory(baoFactoryAddr).predictAddress(salt);
    }
}
