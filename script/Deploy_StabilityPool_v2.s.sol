// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

import {LibString} from "@solady/utils/LibString.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {ConfigPeg} from "script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "script/config/ConfigBase.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {StabilityPool} from "script/src/contracts/StabilityPool.sol";
import {Deploy_GOLD_Minter} from "script/src/Deploy_GOLD_Minter.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "script/config/ConfigBase.sol";

import {ConfigMarket_GOLD_fxUSD_mainnet} from "script/config/markets/ConfigMarket_GOLD_fxUSD_mainnet.sol";
import {ConfigMarket_GOLD_stETH_mainnet} from "script/config/markets/ConfigMarket_GOLD_stETH_mainnet.sol";

import {ConfigPeg_GOLD} from "script/config/pegs/ConfigPeg_GOLD.sol";
import {ConfigCollateral_stETH_mainnet} from "script/config/collaterals/ConfigCollateral_stETH_mainnet.sol";
import {ConfigCollateral_fxUSD_mainnet} from "script/config/collaterals/ConfigCollateral_fxUSD_mainnet.sol";

import {ConfigStabilityPool} from "script/config/stabilitypool/ConfigStabilityPool.sol";
import {SafeBatchBase} from "script/safe/SafeBatchBase.s.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

// TODO: put this in a file and have everything share it (or break it up or something)
interface IFullMinterConfig {
    function wrappedCollateralToken() external view returns (address);
}

/// @notice Deploy Harbor GOLD pegged token and GOLD markets.
contract Deploy_StabilityPool_v2_mainnet is Script, SafeBatchBase, Deploy_GOLD_Minter {
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

        // GOLD
        Config_MinterMarket[] memory goldMarkets;
        (, goldMarkets) = createGOLDMintersConfig();

        vm.startBroadcast();

        _doOneMinter(state, goldMarkets);

        vm.stopBroadcast();

        _saveState(state);

        if (executeLocal) {
            address owner = IBaoOwnable(_transactions[0].target).owner();
            for (uint i = 0; i < _transactions.length; i++) {
                console.log("Executing upgrade:", _transactions[i].description);
                vm.prank(owner);
                (bool ok, bytes memory ret) = _transactions[i].target.call(_transactions[i].data);
                if (!ok) {
                    assembly { revert(add(ret, 32), mload(ret)) }
                }
            }
        } else {
            _saveTransactions(network, "Deploy_StabilityPool_v2");
        }
    }
}
