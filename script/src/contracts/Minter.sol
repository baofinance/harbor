// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;
import {SaltString} from "@bao-script/deployment/SaltString.sol";

import {console2 as console} from "forge-std/console2.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

import {Minter_v3} from "@harbor/minter/Minter_v3.sol";
import {ReservePool_v1} from "@harbor/minter/ReservePool_v1.sol";
import {TokenDistributor_v1} from "@harbor/minter/TokenDistributor_v1.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";

/// @notice Harbor Minter_v3 deployment logic (including ReservePool and FeeReceiver).
/// @dev File Organization Pattern (see deployment2-design.md Section 3.3.2):
/// @dev - This file: contract-specific deployment for Minter, ReservePool, MinterFeeReceiver
/// @dev - Uses DeploymentOwnership pattern: register deployed contracts, transfer at end
///
/// @dev Minter Ecosystem Dependencies:
/// @dev - Minter needs: wrappedCollateral, peggedToken, leveragedToken, priceOracle, reservePool, feeReceiver
/// @dev - Minter grants: HARVESTER_ROLE to StabilityPoolManager, ZERO_FEE_ROLE to Genesis
/// @dev - ReservePool grants: REQUESTER_ROLE to Minter
abstract contract Minter is HarborDeployer {
    // ========== MINTER DEPLOYMENT ==========

    function deployMinterImplementation(
        DeploymentTypes.State memory stateData,
        string memory marketKey,
        address wrappedCollateral,
        address peggedToken,
        address leveragedToken
    ) internal virtual returns (address impl, string memory minterKey) {
        minterKey = SaltString.key(marketKey, "minter");
        console.log("    > %s", minterKey);

        impl = address(new Minter_v3(wrappedCollateral, peggedToken, leveragedToken, "burn(uint256)"));
        console.log("        Impl:  %s", impl);

        _recordImplementation(stateData, minterKey, "@harbor/minter/Minter_v3.sol", "Minter_v3", impl);
    }

    /// @notice Deploy Minter impl+proxy, record both in state, register for ownership transfer.
    function deployMinter(
        DeploymentTypes.State memory stateData,
        string memory marketKey,
        address wrappedCollateral,
        address peggedToken,
        address leveragedToken
    ) internal virtual returns (address proxy) {
        (address impl, string memory minterKey) = deployMinterImplementation(
            stateData,
            marketKey,
            wrappedCollateral,
            peggedToken,
            leveragedToken
        );

        bytes memory initData = abi.encodeCall(Minter_v3.initialize, (owner()));

        proxy = _deployProxyViaStubAndRecord(stateData, minterKey, impl, initData);
    }

    /// @notice Configure a deployed Minter with its operational parameters.
    function configureMinter(
        address minterProxy,
        IMinter.Config memory config,
        address feeReceiver,
        address priceOracle,
        address reservePool
    ) internal {
        IMinter(minterProxy).updateConfig(config);
        IMinter(minterProxy).updateFeeReceiver(feeReceiver);
        IMinter(minterProxy).updatePriceOracle(priceOracle);
        IMinter(minterProxy).updateReservePool(reservePool);
    }

    /// @notice Grant Minter roles to downstream contracts.
    /// @param marketKey The market salt key (e.g., "ETH::fxUSD").
    function grantMinterRoles(string memory marketKey) internal {
        string memory minterKey = SaltString.key(marketKey, "minter");
        address minterProxy = _predictAddress(minterKey);
        address spm = _predictAddress(SaltString.key(marketKey, "stabilityPoolManager"));
        address genesis = _predictAddress(SaltString.key(marketKey, "genesis"));
        _grantRoles(
            minterKey,
            minterProxy,
            spm,
            "stabilityPoolManager",
            IMinter(minterProxy).HARVESTER_ROLE() | IMinter(minterProxy).ZERO_FEE_ROLE(),
            "HARVESTER | ZERO_FEE"
        );
        _grantRoles(minterKey, minterProxy, genesis, "genesis", IMinter(minterProxy).ZERO_FEE_ROLE(), "ZERO_FEE");
    }

    // ========== RESERVE POOL DEPLOYMENT ==========

    /// @notice Deploy ReservePool_v1 impl only, record in state.
    function deployReservePoolImplementation(
        DeploymentTypes.State memory stateData,
        string memory reservePoolKey
    ) internal virtual returns (address impl) {
        impl = address(new ReservePool_v1());
        console.log("        Impl:  %s", impl);

        _recordImplementation(stateData, reservePoolKey, "@harbor/minter/ReservePool_v1.sol", "ReservePool_v1", impl);
    }

    /// @notice Deploy ReservePool impl+proxy, record both in state, register for ownership transfer.
    function deployReservePool(
        DeploymentTypes.State memory stateData,
        string memory marketKey
    ) internal returns (address proxy) {
        string memory reservePoolKey = SaltString.key(marketKey, "reservePool");
        console.log("    > %s", reservePoolKey);

        address impl = deployReservePoolImplementation(stateData, reservePoolKey);

        bytes memory initData = abi.encodeCall(ReservePool_v1.initialize, (owner()));

        proxy = _deployProxyViaStubAndRecord(stateData, reservePoolKey, impl, initData);
    }

    /// @notice Grant ReservePool REQUESTER_ROLE to Minter.
    /// @param marketKey The market salt key (e.g., "ETH::fxUSD").
    function grantReservePoolRoles(string memory marketKey) internal {
        string memory rpKey = SaltString.key(marketKey, "reservePool");
        address rp = _predictAddress(rpKey);
        address minter = _predictAddress(SaltString.key(marketKey, "minter"));
        _grantRoles(rpKey, rp, minter, "minter", ReservePool_v1(rp).REQUESTER_ROLE(), "REQUESTER");
    }

    // ========== FEE RECEIVER (TOKEN DISTRIBUTOR) DEPLOYMENT ==========

    /// @notice Deploy TokenDistributor_v1 impl only, record in state.
    function deployMinterFeeReceiverImplementation(
        DeploymentTypes.State memory stateData,
        string memory feeReceiverKey
    ) internal virtual returns (address impl) {
        impl = address(new TokenDistributor_v1());
        console.log("        Impl:  %s", impl);

        _recordImplementation(
            stateData,
            feeReceiverKey,
            "@harbor/minter/TokenDistributor_v1.sol",
            "TokenDistributor_v1",
            impl
        );
    }

    /// @notice Deploy TokenDistributor_v1 as Minter fee receiver.
    function deployMinterFeeReceiver(
        DeploymentTypes.State memory stateData,
        string memory marketKey,
        string memory name
    ) internal returns (address proxy) {
        string memory feeReceiverKey = SaltString.key(marketKey, "minterFeeReceiver");
        console.log("    > %s", feeReceiverKey);

        address impl = deployMinterFeeReceiverImplementation(stateData, feeReceiverKey);

        bytes memory initData = abi.encodeCall(TokenDistributor_v1.initialize, (owner(), name));

        proxy = _deployProxyViaStubAndRecord(stateData, feeReceiverKey, impl, initData);
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
