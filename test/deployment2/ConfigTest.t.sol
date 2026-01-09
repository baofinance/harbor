// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {MinterMarketConfigLib, Config_MinterMarket} from "script/config/ConfigBase.sol";
import {Config_Market_ETH_fxUSD} from "script/config/markets/Config_Market_ETH_fxUSD.sol";
import {Config_Market_BTC_fxUSD} from "script/config/markets/Config_Market_BTC_fxUSD.sol";
import {Config_Market_BTC_stETH} from "script/config/markets/Config_Market_BTC_stETH.sol";
import {Config_Market_GOLD_fxUSD} from "script/config/markets/Config_Market_GOLD_fxUSD.sol";
import {Config_Market_GOLD_stETH} from "script/config/markets/Config_Market_GOLD_stETH.sol";
import {Config_Market_EUR_fxUSD} from "script/config/markets/Config_Market_EUR_fxUSD.sol";
import {Config_Market_EUR_stETH} from "script/config/markets/Config_Market_EUR_stETH.sol";
import {MinterConfig, StabilityPoolManagerConfig, StabilityPoolConfig} from "script/config/MinterTypes.sol";

contract ConfigTest is Test {
    using MinterMarketConfigLib for Config_MinterMarket;

    function test_market_ETH_fxUSD() public {
        Config_MinterMarket config = new Config_Market_ETH_fxUSD();
        assertEq(config.salt(), "ETH::fxUSD");
        // Can also access concrete type methods
        Config_Market_ETH_fxUSD concrete = Config_Market_ETH_fxUSD(address(config));
        assertEq(concrete.peg(), "ETH");
        assertEq(concrete.collateral(), "fxUSD");
    }

    function test_market_BTC_fxUSD() public {
        Config_MinterMarket config = new Config_Market_BTC_fxUSD();
        assertEq(config.salt(), "BTC::fxUSD");
    }

    function test_market_BTC_stETH() public {
        Config_MinterMarket config = new Config_Market_BTC_stETH();
        assertEq(config.salt(), "BTC::stETH");
    }

    function test_market_GOLD_fxUSD() public {
        Config_MinterMarket config = new Config_Market_GOLD_fxUSD();
        assertEq(config.salt(), "GOLD::fxUSD");
    }

    function test_market_GOLD_stETH() public {
        Config_MinterMarket config = new Config_Market_GOLD_stETH();
        assertEq(config.salt(), "GOLD::stETH");
    }

    function test_market_EUR_fxUSD() public {
        Config_MinterMarket config = new Config_Market_EUR_fxUSD();
        assertEq(config.salt(), "EUR::fxUSD");
    }

    function test_market_EUR_stETH() public {
        Config_MinterMarket config = new Config_Market_EUR_stETH();
        assertEq(config.salt(), "EUR::stETH");
    }

    /// @notice Example of how deployment scripts should instantiate and use configs.
    /// @dev This replaces ConfigBootstrap - the .s.sol script controls the loop.
    function test_deploymentScriptPattern() public {
        // The deployment script directly instantiates the configs it wants to deploy
        Config_MinterMarket[] memory marketsToDeply = new Config_MinterMarket[](3);
        marketsToDeply[0] = new Config_Market_ETH_fxUSD();
        marketsToDeply[1] = new Config_Market_BTC_fxUSD();
        marketsToDeply[2] = new Config_Market_BTC_stETH();

        // Then loops over them to deploy
        for (uint256 i = 0; i < marketsToDeply.length; i++) {
            Config_MinterMarket config = marketsToDeply[i];
            string memory marketSalt = config.salt();
            // In real deployment: deployMarket(config, marketSalt);
            assertTrue(bytes(marketSalt).length > 0);
        }
    }
}
