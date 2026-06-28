// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;
import {SaltString} from "@bao-script/deployment/SaltString.sol";

import {console2 as console} from "forge-std/console2.sol";

import {LibString} from "@solady/utils/LibString.sol";
import {DeploymentState} from "@bao-script/deployment/DeploymentState.sol";
import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {Config_MinterMarket, IMarketConfig, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {Deploy_BTC_Minter} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {Deploy_EUR_Minter} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {Deploy_GOLD_Minter} from "@harbor-script/src/Deploy_GOLD_Minter.sol";
import {Deploy_MCAP_Minter} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {Deploy_SILVER_Minter} from "@harbor-script/src/Deploy_SILVER_Minter.sol";

import {Script} from "forge-std/Script.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";

import {console2} from "forge-std/console2.sol";

/// @notice Deploy Minter v2 implementations and queue upgrade transactions for all minters.
/// @dev Broadcasts implementation deployments, then queues UUPS upgrade calls as a Safe batch.
///      Run via: script/run-script Deploy_Minter_v2_mainnet --salt harbor_v1 --network mainnet --broadcast
contract Deploy_Minter_v2_mainnet is
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
            IHarborConfig cfg = IHarborConfig(address(markets[i]));
            address wrappedCollateral = cfg.wrappedCollateralToken();
            address peggedToken = _predictAddress(SaltString.key(cfg.peg(), "pegged"));
            address leveragedToken = _predictAddress(SaltString.key(marketKey, "leveraged"));

            (address impl, string memory key) = deployMinterImplementation(
                state,
                marketKey,
                wrappedCollateral,
                peggedToken,
                leveragedToken
            );

            // Queue Safe upgrade transactions
            queue(
                key,
                abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (impl, "")),
                string.concat("upgrade to Minter_v2 ", impl.toHexString())
            );
        }
    }

    function build() internal override {
        DeploymentTypes.State memory state = DeploymentState.load(_stateFileRead());
        console.log("Loaded state: %d implementations", state.implementations.length);
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
