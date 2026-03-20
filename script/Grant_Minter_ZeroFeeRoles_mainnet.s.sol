// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {console2 as console} from "forge-std/console2.sol";

import {LibString} from "@solady/utils/LibString.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "script/config/ConfigBase.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

import {Deploy_BTC_Minter} from "script/src/Deploy_BTC_Minter.sol";
import {Deploy_ETH_Minter} from "script/src/Deploy_ETH_Minter.sol";
import {Deploy_EUR_Minter} from "script/src/Deploy_EUR_Minter.sol";
import {Deploy_GOLD_Minter} from "script/src/Deploy_GOLD_Minter.sol";
import {Deploy_MCAP_Minter} from "script/src/Deploy_MCAP_Minter.sol";
import {Deploy_SILVER_Minter} from "script/src/Deploy_SILVER_Minter.sol";

import {SafeBatch} from "script/safe/SafeBatch.s.sol";

/// @notice Grant ZERO_FEE_ROLE to all StabilityPoolManagers on their minters.
/// @dev This role was missing from the initial deployment. Queue as a separate Safe batch.
///      Run via: script/run-script Grant_Minter_ZeroFeeRoles_mainnet --salt harbor_v1 --network mainnet --broadcast
contract Grant_Minter_ZeroFeeRoles_mainnet is
    SafeBatch,
    Deploy_BTC_Minter,
    Deploy_ETH_Minter,
    Deploy_EUR_Minter,
    Deploy_GOLD_Minter,
    Deploy_MCAP_Minter,
    Deploy_SILVER_Minter
{
    using LibString for address;

    function _grantForMarkets(Config_MinterMarket[] memory markets) internal {
        for (uint i = 0; i < markets.length; i++) {
            string memory marketKey = MinterMarketConfigLib.salt(markets[i]);
            address minter = _predictAddress(marketKey, "minter");
            address spm = _predictAddress(marketKey, "stabilityPoolManager");

            uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();

            console.log("  %s: grant ZERO_FEE_ROLE to SPM %s", marketKey, spm.toHexString());

            queue(
                _saltString(marketKey, "minter"),
                abi.encodeCall(IBaoRoles.grantRoles, (spm, zeroFeeRole)),
                string.concat("grant ZERO_FEE_ROLE to SPM on ", marketKey, "::minter")
            );
        }
    }

    function build() internal override {
        Config_MinterMarket[] memory markets;

        (, markets) = createBTCMintersConfig();
        _grantForMarkets(markets);

        // ETH::fxUSD already done manually
        // (, markets) = createETHMintersConfig();
        // _grantForMarkets(markets);

        (, markets) = createEURMintersConfig();
        _grantForMarkets(markets);

        (, markets) = createGOLDMintersConfig();
        _grantForMarkets(markets);

        (, markets) = createMCAPMintersConfig();
        _grantForMarkets(markets);

        (, markets) = createSILVERMintersConfig();
        _grantForMarkets(markets);
    }
}
