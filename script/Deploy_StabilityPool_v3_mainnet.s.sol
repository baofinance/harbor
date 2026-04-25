// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";

import {LibString} from "@solady/utils/LibString.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {StabilityPool} from "@harbor-script/src/contracts/StabilityPool.sol";

import {Deploy_BTC_Minter} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {Deploy_EUR_Minter} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {Deploy_GOLD_Minter} from "@harbor-script/src/Deploy_GOLD_Minter.sol";
import {Deploy_MCAP_Minter} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {Deploy_SILVER_Minter} from "@harbor-script/src/Deploy_SILVER_Minter.sol";

import {Script} from "forge-std/Script.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";

interface IFullMinterConfig {
    function wrappedCollateralToken() external view returns (address);
}

/// @notice Deploy StabilityPool_v3 implementations and queue upgrade transactions for all pools.
/// @dev Prerequisite: Remediate_Accumulators must have been executed first to force-migrate
///      all users from V1 to V2 accumulator storage.
///
/// Run via: script/run-script Deploy_StabilityPool_v3_mainnet --salt harbor_v1 --network mainnet --broadcast
contract Deploy_StabilityPool_v3_mainnet is
    Script,
    Deploy_BTC_Minter,
    Deploy_ETH_Minter,
    Deploy_EUR_Minter,
    Deploy_GOLD_Minter,
    Deploy_MCAP_Minter,
    Deploy_SILVER_Minter
{
    using LibString for address;

    function _doOneMinter(DeploymentTypes.State memory state, Config_MinterMarket[] memory markets) internal {
        for (uint i = 0; i < markets.length; i++) {
            string memory marketKey = MinterMarketConfigLib.salt(markets[i]);
            address minter = _predictAddress(_key(marketKey, "minter"));
            address leveragedToken = _predictAddress(_key(marketKey, "leveraged"));
            address collateralToken = IFullMinterConfig(address(markets[i])).wrappedCollateralToken();

            address implLeveraged = deployStabilityPoolImplementation(
                StabilityPoolLeveraged,
                state,
                markets[i],
                minter,
                leveragedToken
            );

            address implCollateral = deployStabilityPoolImplementation(
                StabilityPoolCollateral,
                state,
                markets[i],
                minter,
                collateralToken
            );

            // Queue Safe upgrade transactions
            queue(
                _saltString(_key(marketKey, StabilityPoolLeveraged)),
                abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implLeveraged, "")),
                string.concat("upgrade to StabilityPool_v3 ", implLeveraged.toHexString())
            );
            queue(
                _saltString(_key(marketKey, StabilityPoolCollateral)),
                abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implCollateral, "")),
                string.concat("upgrade to StabilityPool_v3 ", implCollateral.toHexString())
            );
        }
    }

    function build() internal override {
        DeploymentTypes.State memory state = DeploymentState.load(_stateFileRead());
        state.baoFactory = baoFactory();

        Config_MinterMarket[] memory markets;

        vm.startBroadcast();

        (, markets) = createBTCMintersConfig();
        _doOneMinter(state, markets);

        (, markets) = createETHMintersConfig();
        _doOneMinter(state, markets);

        (, markets) = createEURMintersConfig();
        _doOneMinter(state, markets);

        (, markets) = createGOLDMintersConfig();
        _doOneMinter(state, markets);

        (, markets) = createMCAPMintersConfig();
        _doOneMinter(state, markets);

        (, markets) = createSILVERMintersConfig();
        _doOneMinter(state, markets);

        vm.stopBroadcast();

        _saveState(state);
    }
}
