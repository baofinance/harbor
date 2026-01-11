// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {FactoryDeployer} from "../FactoryDeployer.sol";
import {DeploymentState} from "../DeploymentState.sol";
import {DeploymentTypes} from "../DeploymentTypes.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

import {Minter_v1} from "@harbor/minter/Minter_v1.sol";
import {ReservePool_v1} from "@harbor/minter/ReservePool_v1.sol";
import {TokenDistributor_v1} from "@harbor/minter/TokenDistributor_v1.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";

/// @notice Harbor Minter_v1 deployment logic (including ReservePool and FeeReceiver).
/// @dev File Organization Pattern (see deployment2-design.md Section 3.3.2):
/// @dev - This file: contract-specific deployment for Minter, ReservePool, MinterFeeReceiver
/// @dev - Uses DeploymentOwnership pattern: register deployed contracts, transfer at end
///
/// @dev Minter Ecosystem Dependencies:
/// @dev - Minter needs: wrappedCollateral, peggedToken, leveragedToken, priceOracle, reservePool, feeReceiver
/// @dev - Minter grants: HARVESTER_ROLE to StabilityPoolManager, ZERO_FEE_ROLE to Genesis
/// @dev - ReservePool grants: REQUESTER_ROLE to Minter
abstract contract Minter is FactoryDeployer {
    // ========== MINTER DEPLOYMENT ==========

    /// @notice Deploy Minter_v1 implementation.
    /// @dev Constructor takes immutables: wrappedCollateral, peggedToken, leveragedToken, burnSignature.
    function deployMinterImpl(
        address wrappedCollateral,
        address peggedToken,
        address leveragedToken
    ) internal returns (address impl, DeploymentTypes.ImplementationRecord memory implRecord) {
        impl = address(new Minter_v1(wrappedCollateral, peggedToken, leveragedToken, "burn(uint256)"));

        implRecord = DeploymentTypes.ImplementationRecord({
            proxy: "", // Will be set by caller when associating with a proxy
            contractSource: "@harbor/minter/Minter_v1.sol",
            contractType: "Minter_v1",
            implementation: impl,
            deploymentTime: uint64(block.timestamp)
        });
    }

    /// @notice Deploy Minter_v1 proxy.
    function deployMinterProxy(
        address baoFactoryAddr,
        string memory marketKey,
        address implementation,
        address tokenOwner,
        string memory systemSalt
    ) internal returns (address proxy, DeploymentTypes.ProxyRecord memory proxyRecord) {
        string memory minterKey = string.concat(marketKey, "::minter");

        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", minterKey));
        bytes memory initData = abi.encodeCall(Minter_v1.initialize, (tokenOwner));

        proxy = deployProxy(baoFactoryAddr, salt, implementation, initData);
        console.log("        Proxy: %s", proxy);

        proxyRecord = DeploymentTypes.ProxyRecord({
            id: minterKey,
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

    /// @notice Configure a deployed Minter with its operational parameters.
    /// @dev Separated from deployment for clarity and potential reuse in upgrades.
    function configureMinter(
        address minterProxy,
        IMinter.Config memory config,
        address feeReceiver,
        address priceOracle,
        address reservePool
    ) internal {
        Minter_v1 minter = Minter_v1(minterProxy);
        minter.updateConfig(config);
        minter.updateFeeReceiver(feeReceiver);
        minter.updatePriceOracle(priceOracle);
        minter.updateReservePool(reservePool);
    }

    /// @notice Grant Minter roles to downstream contracts.
    /// @dev HARVESTER_ROLE to StabilityPoolManager, ZERO_FEE_ROLE to Genesis.
    function grantMinterRoles(address minterProxy, address stabilityPoolManager, address genesis) internal {
        Minter_v1 minter = Minter_v1(minterProxy);
        minter.grantRoles(stabilityPoolManager, minter.HARVESTER_ROLE());
        minter.grantRoles(genesis, minter.ZERO_FEE_ROLE());
    }

    // ========== RESERVE POOL DEPLOYMENT ==========

    /// @notice Deploy ReservePool_v1 implementation.
    function deployReservePoolImpl()
        internal
        returns (address impl, DeploymentTypes.ImplementationRecord memory implRecord)
    {
        impl = address(new ReservePool_v1());

        implRecord = DeploymentTypes.ImplementationRecord({
            proxy: "",
            contractSource: "@harbor/minter/ReservePool_v1.sol",
            contractType: "ReservePool_v1",
            implementation: impl,
            deploymentTime: uint64(block.timestamp)
        });
    }

    /// @notice Deploy ReservePool_v1 proxy.
    function deployReservePoolProxy(
        address baoFactoryAddr,
        string memory marketKey,
        address implementation,
        address tokenOwner,
        string memory systemSalt
    ) internal returns (address proxy, DeploymentTypes.ProxyRecord memory proxyRecord) {
        string memory reservePoolKey = string.concat(marketKey, "::reservePool");

        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", reservePoolKey));
        bytes memory initData = abi.encodeCall(ReservePool_v1.initialize, (tokenOwner));

        proxy = deployProxy(baoFactoryAddr, salt, implementation, initData);
        console.log("        Proxy: %s", proxy);

        proxyRecord = DeploymentTypes.ProxyRecord({
            id: reservePoolKey,
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

    /// @notice Grant ReservePool REQUESTER_ROLE to Minter.
    function grantReservePoolRoles(address reservePoolProxy, address minter) internal {
        ReservePool_v1 reservePool = ReservePool_v1(reservePoolProxy);
        reservePool.grantRoles(minter, reservePool.REQUESTER_ROLE());
    }

    // ========== FEE RECEIVER (TOKEN DISTRIBUTOR) DEPLOYMENT ==========

    /// @notice Deploy TokenDistributor_v1 implementation (used as MinterFeeReceiver).
    function deployFeeReceiverImpl()
        internal
        returns (address impl, DeploymentTypes.ImplementationRecord memory implRecord)
    {
        impl = address(new TokenDistributor_v1());

        implRecord = DeploymentTypes.ImplementationRecord({
            proxy: "",
            contractSource: "@harbor/minter/TokenDistributor_v1.sol",
            contractType: "TokenDistributor_v1",
            implementation: impl,
            deploymentTime: uint64(block.timestamp)
        });
    }

    /// @notice Deploy TokenDistributor_v1 proxy for Minter fee receiver.
    function deployMinterFeeReceiverProxy(
        address baoFactoryAddr,
        string memory marketKey,
        address implementation,
        address tokenOwner,
        string memory name,
        string memory systemSalt
    ) internal returns (address proxy, DeploymentTypes.ProxyRecord memory proxyRecord) {
        string memory feeReceiverKey = string.concat(marketKey, "::minterFeeReceiver");
        console.log("    > %s", feeReceiverKey);

        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", feeReceiverKey));
        bytes memory initData = abi.encodeCall(TokenDistributor_v1.initialize, (tokenOwner, name));

        proxy = deployProxy(baoFactoryAddr, salt, implementation, initData);
        console.log("        Proxy: %s", proxy);

        proxyRecord = DeploymentTypes.ProxyRecord({
            id: feeReceiverKey,
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

    /// @notice Configure TokenDistributor with tokens and distribution.
    function configureFeeReceiver(
        address feeReceiverProxy,
        address[] memory tokens,
        address[] memory recipients,
        uint256[] memory shares
    ) internal {
        TokenDistributor_v1 distributor = TokenDistributor_v1(feeReceiverProxy);

        for (uint256 i = 0; i < tokens.length; i++) {
            distributor.addToken(tokens[i]);
        }

        distributor.setDistribution(recipients, shares);
    }

    // ========== ADDRESS PREDICTION ==========

    /// @notice Predict minter contract address from salt.
    function predictMinterAddress(
        address baoFactoryAddr,
        string memory systemSalt,
        string memory marketKey
    ) internal view returns (address) {
        bytes32 minterSalt = keccak256(abi.encodePacked(systemSalt, "::", marketKey, "::minter"));
        return IBaoFactory(baoFactoryAddr).predictAddress(minterSalt);
    }

    /// @notice Predict reserve pool contract address from salt.
    function predictReservePoolAddress(
        address baoFactoryAddr,
        string memory systemSalt,
        string memory marketKey
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", marketKey, "::reservePool"));
        return IBaoFactory(baoFactoryAddr).predictAddress(salt);
    }

    /// @notice Predict minter fee receiver contract address from salt.
    function predictMinterFeeReceiverAddress(
        address baoFactoryAddr,
        string memory systemSalt,
        string memory marketKey
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(systemSalt, "::", marketKey, "::minterFeeReceiver"));
        return IBaoFactory(baoFactoryAddr).predictAddress(salt);
    }
}
