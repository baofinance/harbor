// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;
import {SaltString} from "@bao-script/deployment/SaltString.sol";

import {console2 as console} from "forge-std/console2.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";

import {Genesis_v2} from "@harbor/minter/Genesis_v2.sol";

/// @notice Harbor Genesis_v2 deployment logic.
/// @dev File Organization Pattern (see deployment2-design.md Section 3.3.2):
/// @dev - This file: contract-specific deployment for Genesis
/// @dev - Uses DeploymentOwnership pattern: register deployed contracts, transfer at end
///
/// @dev Genesis Ecosystem:
/// @dev - Genesis is a special contract for initial token minting during launch
/// @dev - Genesis needs: ZERO_FEE_ROLE on Minter (obtained via Minter deployment)
abstract contract Genesis is HarborDeployer {
    // ========== GENESIS DEPLOYMENT ==========

    /// @notice Deploy Genesis_v2 impl only, record in state.
    function deployGenesisImplementation(
        DeploymentTypes.State memory stateData,
        string memory genesisKey,
        address minter
    ) internal virtual returns (address impl) {
        impl = address(new Genesis_v2(minter));
        console.log("        Impl:  %s", impl);

        _recordImplementation(stateData, genesisKey, "@harbor/minter/Genesis_v2.sol", "Genesis_v2", impl);
    }

    /// @notice Deploy Genesis impl+proxy, record both in state, register for ownership transfer.
    function deployGenesis(
        DeploymentTypes.State memory stateData,
        string memory marketKey,
        address minter
    ) internal returns (address proxy) {
        string memory key = genesisKey(marketKey);
        console.log("    > %s", key);

        address impl = deployGenesisImplementation(stateData, key, minter);

        bytes memory initData = abi.encodeCall(Genesis_v2.initialize, (address(this), owner()));

        proxy = _deployProxyAndRecord(stateData, key, impl, initData);
    }

    // ========== ADDRESS PREDICTION ==========

    /// @notice Predict genesis contract address from salt.
    function predictGenesisAddress(
        address baoFactoryAddr,
        string memory saltPrefix,
        string memory marketKey
    ) internal view returns (address) {
        bytes32 salt = keccak256(abi.encodePacked(SaltString.key(saltPrefix, genesisKey(marketKey))));
        return IBaoFactory(baoFactoryAddr).predictAddress(salt);
    }
}
