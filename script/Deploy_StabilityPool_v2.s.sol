// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

import {LibString} from "@solady/utils/LibString.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {StabilityPool} from "script/src/contracts/StabilityPool.sol";

import {Deploy_BTC_Minter} from "script/src/Deploy_BTC_Minter.sol";
import {Deploy_ETH_Minter} from "script/src/Deploy_ETH_Minter.sol";
import {Deploy_EUR_Minter} from "script/src/Deploy_EUR_Minter.sol";
import {Deploy_GOLD_Minter} from "script/src/Deploy_GOLD_Minter.sol";
import {Deploy_MCAP_Minter} from "script/src/Deploy_MCAP_Minter.sol";
import {Deploy_SILVER_Minter} from "script/src/Deploy_SILVER_Minter.sol";

import {SafeBatchBase} from "script/safe/SafeBatchBase.s.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

// TODO: put this in a file and have everything share it (or break it up or something)
interface IFullMinterConfig {
    function wrappedCollateralToken() external view returns (address);
}

/// @notice Deploy StabilityPool v2 implementations and queue upgrade transactions for all minters.
contract Deploy_StabilityPool_v2_mainnet is
    Script,
    SafeBatchBase,
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
            address minter = _predictAddress(marketKey, "minter");
            address leveragedToken = _predictAddress(marketKey, "leveraged");
            address collateralToken = IFullMinterConfig(address(markets[i])).wrappedCollateralToken();

            address implLeveraged = deployStabilityPoolImplementation(
                StabilityPoolLeveraged,
                state,
                marketKey,
                minter,
                leveragedToken,
                address(markets[i])
            );
            address implCollateral = deployStabilityPoolImplementation(
                StabilityPoolCollateral,
                state,
                marketKey,
                minter,
                collateralToken,
                address(markets[i])
            );

            // Queue Safe upgrade transactions
            queue(
                _saltString(marketKey, StabilityPoolLeveraged),
                abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implLeveraged, "")),
                string.concat("upgrade to StabilityPool_v2 ", implLeveraged.toHexString())
            );
            queue(
                _saltString(marketKey, StabilityPoolCollateral),
                abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (implCollateral, "")),
                string.concat("upgrade to StabilityPool_v2 ", implCollateral.toHexString())
            );
        }
    }

    /// @param saltPrefix System salt for CREATE3 deployment (e.g., "harbor_v1").
    /// @param network Network name (e.g., "mainnet", "arbitrum").
    /// @param executeLocal When true, execute upgrade transactions directly against
    ///        local anvil (requires --auto-impersonate). When false, generate Safe
    ///        batch JSON for multisig execution.
    function run(string memory saltPrefix, string memory network, bool executeLocal) external {
        _setSaltPrefix(saltPrefix);
        DeploymentTypes.State memory state = DeploymentState.load(network, saltPrefix);
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

        console.log("");
        _saveTransactions(network, "Deploy_StabilityPool_v2");
        console.log("");

        if (executeLocal) {
            address owner = IBaoOwnable(_transactions[0].target).owner();
            vm.startBroadcast(owner);
            for (uint i = 0; i < _transactions.length; i++) {
                console.log("Executing upgrade:", _transactions[i].description);
                (bool ok, bytes memory ret) = _transactions[i].target.call(_transactions[i].data);
                if (!ok) {
                    assembly {
                        revert(add(ret, 32), mload(ret))
                    }
                }
            }
            vm.stopBroadcast();
        }
    }
}
