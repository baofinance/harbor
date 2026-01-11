// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {FactoryDeployer} from "../FactoryDeployer.sol";
import {DeploymentState} from "../DeploymentState.sol";
import {DeploymentTypes} from "../DeploymentTypes.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

import {StabilityPool_v1} from "@harbor/minter/StabilityPool_v1.sol";

/// @notice Harbor StabilityPool_v1 deployment logic.
/// @dev File Organization Pattern (see deployment2-design.md Section 3.3.2):
/// @dev - This file: contract-specific deployment for StabilityPool (Collateral and Leveraged variants)
/// @dev - Uses DeploymentOwnership pattern: register deployed contracts, transfer at end
///
/// @dev StabilityPool Ecosystem:
/// @dev - Each market has TWO stability pools: Collateral (wrapped collateral) and Leveraged (leveraged token)
/// @dev - Both pools grant: REBALANCER_ROLE, REWARD_DEPOSITOR_ROLE to StabilityPoolManager
abstract contract StabilityPool is FactoryDeployer {
    /// @notice StabilityPool configuration for deployment.
    struct StabilityPoolConfig {
        uint256 earlyWithdrawalFeeRatio;
        uint256 withdrawalDelay;
        uint256 withdrawalPeriod;
        uint256 minTotalAssetSupply;
        address treasury;
    }

    // ========== STABILITY POOL DEPLOYMENT ==========

    /// @notice Deploy StabilityPool_v1 implementation.
    /// @dev Constructor takes immutables specific to this pool's liquidation token.
    function deployStabilityPoolImpl(
        address minter,
        address liquidationToken,
        uint256 withdrawalDelay,
        uint256 withdrawalPeriod,
        uint256 minTotalAssetSupply
    ) internal returns (address impl, DeploymentTypes.ImplementationRecord memory implRecord) {
        impl = address(
            new StabilityPool_v1(
                minter,
                liquidationToken,
                1, // placeholder: not used but must be > 0
                address(0xdeadbeef), // placeholder: not used but must be non-zero
                withdrawalDelay,
                withdrawalPeriod,
                minTotalAssetSupply
            )
        );

        implRecord = DeploymentTypes.ImplementationRecord({
            proxy: "",
            contractSource: "@harbor/minter/StabilityPool_v1.sol",
            contractType: "StabilityPool_v1",
            implementation: impl,
            deploymentTime: uint64(block.timestamp)
        });
    }

    /// @notice Deploy StabilityPool_v1 proxy for collateral stability pool.
    function deployStabilityPoolCollateralProxy(
        address baoFactoryAddr,
        string memory marketKey,
        address implementation,
        address tokenOwner,
        uint256 earlyWithdrawalFeeRatio,
        address treasury,
        string memory systemSalt
    ) internal returns (address proxy, DeploymentTypes.ProxyRecord memory proxyRecord) {
        string memory spKey = string.concat(marketKey, "::stabilityPoolCollateral");

        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", spKey));
        bytes memory initData = abi.encodeCall(
            StabilityPool_v1.initialize,
            (tokenOwner, earlyWithdrawalFeeRatio, treasury)
        );

        proxy = deployProxy(baoFactoryAddr, salt, implementation, initData);
        console.log("        Proxy: %s", proxy);

        proxyRecord = DeploymentTypes.ProxyRecord({
            id: spKey,
            fragment: DeploymentTypes.FragmentDescriptor({
                key: marketKey,
                kind: DeploymentTypes.FragmentKind.MinterMarket
            }),
            proxy: proxy,
            implementation: implementation,
            salt: systemSalt,
            deploymentTime: uint64(block.timestamp)
        });
    }

    /// @notice Deploy StabilityPool_v1 proxy for leveraged stability pool.
    function deployStabilityPoolLeveragedProxy(
        address baoFactoryAddr,
        string memory marketKey,
        address implementation,
        address tokenOwner,
        uint256 earlyWithdrawalFeeRatio,
        address treasury,
        string memory systemSalt
    ) internal returns (address proxy, DeploymentTypes.ProxyRecord memory proxyRecord) {
        string memory spKey = string.concat(marketKey, "::stabilityPoolLeveraged");

        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", spKey));
        bytes memory initData = abi.encodeCall(
            StabilityPool_v1.initialize,
            (tokenOwner, earlyWithdrawalFeeRatio, treasury)
        );

        proxy = deployProxy(baoFactoryAddr, salt, implementation, initData);
        console.log("        Proxy: %s", proxy);

        proxyRecord = DeploymentTypes.ProxyRecord({
            id: spKey,
            fragment: DeploymentTypes.FragmentDescriptor({
                key: marketKey,
                kind: DeploymentTypes.FragmentKind.MinterMarket
            }),
            proxy: proxy,
            implementation: implementation,
            salt: systemSalt,
            deploymentTime: uint64(block.timestamp)
        });
    }

    /// @notice Configure a stability pool with reward tokens.
    /// @dev Reward tokens are registered for liquidation rewards distribution.
    function configureStabilityPool(address stabilityPoolProxy, address[] memory rewardTokens) internal {
        StabilityPool_v1 pool = StabilityPool_v1(stabilityPoolProxy);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            pool.registerRewardToken(rewardTokens[i]);
        }
    }

    /// @notice Grant StabilityPool roles to StabilityPoolManager.
    /// @dev REBALANCER_ROLE and REWARD_DEPOSITOR_ROLE.
    function grantStabilityPoolRoles(address stabilityPoolProxy, address stabilityPoolManager) internal {
        StabilityPool_v1 pool = StabilityPool_v1(stabilityPoolProxy);
        pool.grantRoles(stabilityPoolManager, pool.REBALANCER_ROLE() | pool.REWARD_DEPOSITOR_ROLE());
    }

    // ========== ADDRESS PREDICTION ==========

    /// @notice Predict stability pool collateral contract address from salt.
    function predictStabilityPoolCollateralAddress(
        address baoFactoryAddr,
        string memory systemSalt,
        string memory marketKey
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", marketKey, "::stabilityPoolCollateral"));
        return IBaoFactory(baoFactoryAddr).predictAddress(salt);
    }

    /// @notice Predict stability pool leveraged contract address from salt.
    function predictStabilityPoolLeveragedAddress(
        address baoFactoryAddr,
        string memory systemSalt,
        string memory marketKey
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", marketKey, "::stabilityPoolLeveraged"));
        return IBaoFactory(baoFactoryAddr).predictAddress(salt);
    }
}
