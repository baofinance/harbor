// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

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
abstract contract Minter is HarborFactoryDeployer {
    // ========== MINTER DEPLOYMENT ==========

    /// @notice Deploy Minter impl+proxy, record both in state, register for ownership transfer.
    function deployMinter(
        DeploymentTypes.State memory stateData,
        string memory marketKey,
        address wrappedCollateral,
        address peggedToken,
        address leveragedToken
    ) internal virtual returns (address proxy) {
        string memory minterKey = string.concat(marketKey, "::minter");
        console.log("    > %s", minterKey);

        address impl = address(new Minter_v1(wrappedCollateral, peggedToken, leveragedToken, "burn(uint256)"));
        console.log("        Impl:  %s", impl);

        bytes memory initData = abi.encodeCall(Minter_v1.initialize, (owner()));

        proxy = _deployProxyAndRecord(
            stateData,
            minterKey,
            impl,
            "@harbor/minter/Minter_v1.sol",
            "Minter_v1",
            initData
        );
    }

    /// @notice Configure a deployed Minter with its operational parameters.
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
    function grantMinterRoles(
        string memory minterKey,
        address minterProxy,
        address stabilityPoolManager,
        address genesis
    ) internal {
        Minter_v1 minter = Minter_v1(minterProxy);
        _grantRoles(
            minterKey,
            minterProxy,
            stabilityPoolManager,
            "stabilityPoolManager",
            minter.HARVESTER_ROLE(),
            "HARVESTER"
        );
        _grantRoles(minterKey, minterProxy, genesis, "genesis", minter.ZERO_FEE_ROLE(), "ZERO_FEE");
    }

    // ========== RESERVE POOL DEPLOYMENT ==========

    /// @notice Deploy ReservePool impl+proxy, record both in state, register for ownership transfer.
    function deployReservePool(
        DeploymentTypes.State memory stateData,
        string memory marketKey
    ) internal returns (address proxy) {
        string memory reservePoolKey = string.concat(marketKey, "::reservePool");
        console.log("    > %s", reservePoolKey);

        address impl = address(new ReservePool_v1());
        console.log("        Impl:  %s", impl);

        bytes memory initData = abi.encodeCall(ReservePool_v1.initialize, (owner()));

        proxy = _deployProxyAndRecord(
            stateData,
            reservePoolKey,
            impl,
            "@harbor/minter/ReservePool_v1.sol",
            "ReservePool_v1",
            initData
        );
    }

    /// @notice Grant ReservePool REQUESTER_ROLE to Minter.
    function grantReservePoolRoles(string memory reservePoolKey, address reservePoolProxy, address minter) internal {
        ReservePool_v1 reservePool = ReservePool_v1(reservePoolProxy);
        _grantRoles(reservePoolKey, reservePoolProxy, minter, "minter", reservePool.REQUESTER_ROLE(), "REQUESTER");
    }

    // ========== FEE RECEIVER (TOKEN DISTRIBUTOR) DEPLOYMENT ==========

    /// @notice Deploy TokenDistributor_v1 as Minter fee receiver.
    function deployMinterFeeReceiver(
        DeploymentTypes.State memory stateData,
        string memory marketKey,
        string memory name
    ) internal returns (address proxy) {
        string memory feeReceiverKey = string.concat(marketKey, "::minterFeeReceiver");
        console.log("    > %s", feeReceiverKey);

        address impl = address(new TokenDistributor_v1());
        console.log("        Impl:  %s", impl);

        bytes memory initData = abi.encodeCall(TokenDistributor_v1.initialize, (owner(), name));

        proxy = _deployProxyAndRecord(
            stateData,
            feeReceiverKey,
            impl,
            "@harbor/minter/TokenDistributor_v1.sol",
            "TokenDistributor_v1",
            initData
        );
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
}
