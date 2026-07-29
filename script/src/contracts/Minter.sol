// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";

import {Minter_v3} from "@harbor/minter/Minter_v3.sol";
import {ReservePool_v2} from "@harbor/minter/ReservePool_v2.sol";
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
    ) internal virtual returns (address impl, string memory key) {
        key = minterKey(marketKey);
        console.log("    > %s", key);

        impl = address(new Minter_v3(wrappedCollateral, peggedToken, leveragedToken));
        console.log("        Impl:  %s", impl);

        _recordImplementation(stateData, key, "@harbor/minter/Minter_v3.sol", "Minter_v3", impl);
    }

    /// @notice Deploy a fully wired Minter: impl+proxy, recorded in state and registered for ownership
    ///         transfer, with every dependency and its incentive config already set.
    /// @dev Takes the market config, not the Minter's constructor arguments. This function is the ONLY
    ///      place that decides how each value reaches the contract — constructor argument, `initialize`
    ///      calldata, or post-deploy setter. Moving a value between those three changes this body and
    ///      nothing else; callers pass the same config either way.
    function deployMinter(
        DeploymentTypes.State memory stateData,
        Config_MinterMarket marketConfig
    ) internal returns (address proxy) {
        IHarborConfig cfg = IHarborConfig(address(marketConfig));
        string memory marketKey = MinterMarketConfigLib.salt(marketConfig);

        (address impl, string memory key) = deployMinterImplementation(
            stateData,
            marketKey,
            cfg.wrappedCollateralToken(),
            peggedTokenAddress(cfg.peg()),
            leveragedTokenAddress(marketKey)
        );

        bytes memory initData = abi.encodeCall(Minter_v3.initialize, (address(this), owner()));

        proxy = _deployProxyAndRecord(stateData, key, impl, initData);

        IMinter(proxy).updateConfig(cfg.minterConfig());
        IMinter(proxy).updateReservePool(reservePoolAddress(marketKey));
        IMinter(proxy).updateFeeReceiver(treasury());
        IMinter(proxy).updatePriceOracle(wrappedPriceOracleAddress(MinterMarketConfigLib.priceOracleKey(marketConfig)));
    }

    /// @notice Grant Minter roles to downstream contracts.
    /// @param marketKey The market salt key (e.g., "ETH::fxUSD").
    function grantMinterRoles(string memory marketKey) internal {
        string memory key = minterKey(marketKey);
        address minterProxy = minterAddress(marketKey);
        address spm = stabilityPoolManagerAddress(marketKey);
        address genesis = genesisAddress(marketKey);
        _grantRoles(
            key,
            minterProxy,
            spm,
            "stabilityPoolManager",
            IMinter(minterProxy).HARVESTER_ROLE() | IMinter(minterProxy).ZERO_FEE_ROLE(),
            "HARVESTER | ZERO_FEE"
        );
        _grantRoles(key, minterProxy, genesis, "genesis", IMinter(minterProxy).ZERO_FEE_ROLE(), "ZERO_FEE");
    }

    // ========== RESERVE POOL DEPLOYMENT ==========

    /// @notice Deploy ReservePool_v2 impl only, record in state.
    function deployReservePoolImplementation(
        DeploymentTypes.State memory stateData,
        string memory reservePoolKey
    ) internal virtual returns (address impl) {
        impl = address(new ReservePool_v2());
        console.log("        Impl:  %s", impl);

        _recordImplementation(stateData, reservePoolKey, "@harbor/minter/ReservePool_v2.sol", "ReservePool_v2", impl);
    }

    /// @notice Deploy ReservePool impl+proxy, record both in state, register for ownership transfer.
    function deployReservePool(
        DeploymentTypes.State memory stateData,
        string memory marketKey
    ) internal returns (address proxy) {
        string memory key = reservePoolKey(marketKey);
        console.log("    > %s", key);

        address impl = deployReservePoolImplementation(stateData, key);

        bytes memory initData = abi.encodeCall(ReservePool_v2.initialize, (address(this), owner()));

        proxy = _deployProxyAndRecord(stateData, key, impl, initData);
    }

    /// @notice Grant ReservePool REQUESTER_ROLE to Minter.
    /// @param marketKey The market salt key (e.g., "ETH::fxUSD").
    function grantReservePoolRoles(string memory marketKey) internal {
        string memory key = reservePoolKey(marketKey);
        address rp = reservePoolAddress(marketKey);
        address minter = minterAddress(marketKey);
        _grantRoles(key, rp, minter, "minter", ReservePool_v2(rp).REQUESTER_ROLE(), "REQUESTER");
    }
}
