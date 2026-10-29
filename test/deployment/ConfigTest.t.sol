// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {MinterMarketConfigLib, Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {ConfigMarket_ETH_fxUSD_mainnet} from "@harbor-script/config/markets/ConfigMarket_ETH_fxUSD_mainnet.sol";
import {ConfigMarket_BTC_fxUSD_mainnet} from "@harbor-script/config/markets/ConfigMarket_BTC_fxUSD_mainnet.sol";
import {ConfigMarket_BTC_stETH_mainnet} from "@harbor-script/config/markets/ConfigMarket_BTC_stETH_mainnet.sol";
import {ConfigMarket_GOLD_fxUSD_mainnet} from "@harbor-script/config/markets/ConfigMarket_GOLD_fxUSD_mainnet.sol";
import {ConfigMarket_GOLD_stETH_mainnet} from "@harbor-script/config/markets/ConfigMarket_GOLD_stETH_mainnet.sol";
import {ConfigMarket_EUR_fxUSD_mainnet} from "@harbor-script/config/markets/ConfigMarket_EUR_fxUSD_mainnet.sol";
import {ConfigMarket_EUR_stETH_mainnet} from "@harbor-script/config/markets/ConfigMarket_EUR_stETH_mainnet.sol";
import {IHarborConfig} from "@harbor-script/config/IHarborConfig.sol";
import {allMintersConfig} from "@harbor-script/src/AllMintersConfig.sol";

contract ConfigTest is Test {
    using MinterMarketConfigLib for Config_MinterMarket;

    function test_market_ETH_fxUSD() public {
        Config_MinterMarket config = new ConfigMarket_ETH_fxUSD_mainnet();
        assertEq(config.salt(), "ETH::fxUSD");
        // Can also access concrete type methods
        ConfigMarket_ETH_fxUSD_mainnet concrete = ConfigMarket_ETH_fxUSD_mainnet(address(config));
        assertEq(concrete.peg(), "ETH");
        assertEq(concrete.collateral(), "fxUSD");
    }

    function test_market_BTC_fxUSD() public {
        Config_MinterMarket config = new ConfigMarket_BTC_fxUSD_mainnet();
        assertEq(config.salt(), "BTC::fxUSD");
    }

    function test_market_BTC_stETH() public {
        Config_MinterMarket config = new ConfigMarket_BTC_stETH_mainnet();
        assertEq(config.salt(), "BTC::stETH");
    }

    function test_market_GOLD_fxUSD() public {
        Config_MinterMarket config = new ConfigMarket_GOLD_fxUSD_mainnet();
        assertEq(config.salt(), "GOLD::fxUSD");
    }

    function test_market_GOLD_stETH() public {
        Config_MinterMarket config = new ConfigMarket_GOLD_stETH_mainnet();
        assertEq(config.salt(), "GOLD::stETH");
    }

    function test_market_EUR_fxUSD() public {
        Config_MinterMarket config = new ConfigMarket_EUR_fxUSD_mainnet();
        assertEq(config.salt(), "EUR::fxUSD");
    }

    function test_market_EUR_stETH() public {
        Config_MinterMarket config = new ConfigMarket_EUR_stETH_mainnet();
        assertEq(config.salt(), "EUR::stETH");
    }

    /// Every production market's bounty ceilings are a hundred and two hundred dollars' worth of its wrapped
    /// collateral, by the collateral's "about a dollar" unit - the number the config states in place of a price.
    function test_everyMarketsBountyCeilingsAreAHundredAndTwoHundredDollars() public {
        Config_MinterMarket[] memory markets = allMintersConfig();
        assertGt(markets.length, 1, "fixture: more than one market");
        for (uint256 i = 0; i < markets.length; i++) {
            IHarborConfig cfg = IHarborConfig(address(markets[i]));
            string memory market = markets[i].salt();
            uint256 dollarOfCollateral = cfg.aboutADollarInWrappedCollateral();
            assertGt(dollarOfCollateral, 0, string.concat(market, ": the collateral states its dollar unit"));
            assertEq(
                cfg.harvestBountyCeiling(),
                100 * dollarOfCollateral,
                string.concat(market, ": a harvest's ceiling is a hundred dollars' worth")
            );
            assertEq(
                cfg.rebalanceBountyCeiling(),
                200 * dollarOfCollateral,
                string.concat(market, ": a rebalance's ceiling is two hundred dollars' worth")
            );
        }
    }

    /// @notice Example of how deployment scripts should instantiate and use configs.
    /// @dev This replaces ConfigBootstrap - the .s.sol script controls the loop.
    function test_deploymentScriptPattern() public {
        // The deployment script directly instantiates the configs it wants to deploy
        Config_MinterMarket[] memory marketsToDeply = new Config_MinterMarket[](3);
        marketsToDeply[0] = new ConfigMarket_ETH_fxUSD_mainnet();
        marketsToDeply[1] = new ConfigMarket_BTC_fxUSD_mainnet();
        marketsToDeply[2] = new ConfigMarket_BTC_stETH_mainnet();

        // Then loops over them to deploy
        for (uint256 i = 0; i < marketsToDeply.length; i++) {
            Config_MinterMarket config = marketsToDeply[i];
            string memory marketSalt = config.salt();
            // In real deployment: deployMarket(config, marketSalt);
            assertTrue(bytes(marketSalt).length > 0);
        }
    }
}
