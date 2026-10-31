// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {BaoTest} from "@bao-test/BaoTest.sol";
import {LibString} from "@solady/utils/LibString.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MinterValuationLib} from "@harbor/minter/library/MinterValuationLib.sol";
import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {ConfigMarket_USD_wBTC_mainnet} from "@harbor-script/config/markets/ConfigMarket_USD_wBTC_mainnet.sol";
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

/// @notice A market's config states about a dollar of its wrapped collateral and about a dollar of its pegged token, and
///         at the market's live oracle the first buys about the second. The minter computes pegged tokens from a price
///         with no decimals handling, so an oracle whose scale is wrong for its collateral fails here by many orders of
///         magnitude.
/// @dev Forked at a block of its own: the shared pin predates the USD markets' oracles.
contract ConfigAtTheLiveOracleTest is BaoTest {
    using MinterMarketConfigLib for Config_MinterMarket;

    /// @dev How far a dollar of collateral may buy from a dollar of pegged. Each is stated by hand, roughly, so a
    ///      factor of ten is well within what a config may be out by, and far short of the smallest scale error, 1e8.
    uint256 private constant _WITHIN_A_FACTOR_OF = 10;

    function forkBlock() internal pure override returns (uint256) {
        return 26308489;
    }

    /// Every production market but one passes. USD::wBTC is the exception, which the next test holds to its reason.
    function test_aboutADollarOfCollateralIsAboutADollarOfPegged_atTheLiveOracle() public {
        forkMainnet();
        HarborDeployRun addresses = _liveAddresses();
        Config_MinterMarket[] memory markets = allMintersConfig();
        assertGt(markets.length, 1, "fixture: more than one market");
        for (uint256 i = 0; i < markets.length; i++) {
            string memory market = markets[i].salt();
            if (!LibString.eq(market, "USD::wBTC")) {
                uint256 bought = _peggedBoughtByADollarOfCollateral(addresses, markets[i]);
                uint256 dollarOfPegged = IHarborConfig(address(markets[i])).aboutADollarInPegged();
                assertLt(bought, dollarOfPegged * _WITHIN_A_FACTOR_OF, string.concat(market, ": buys too much"));
                assertGt(bought * _WITHIN_A_FACTOR_OF, dollarOfPegged, string.concat(market, ": buys too little"));
            }
        }
    }

    /// USD::wBTC's oracle answers at a scale wrong for its 8-decimal collateral, so its dollar buys far too much. The fix
    /// belongs to its aggregator: a pin past that fix fails this test, and the exception above then goes.
    function test_theUSDwBTCOracle_failsThePriceScaleCheck() public {
        forkMainnet();
        HarborDeployRun addresses = _liveAddresses();
        Config_MinterMarket market = new ConfigMarket_USD_wBTC_mainnet();
        assertGt(
            _peggedBoughtByADollarOfCollateral(addresses, market),
            IHarborConfig(address(market)).aboutADollarInPegged() * _WITHIN_A_FACTOR_OF,
            "the live oracle's scale is wrong for 8 decimals"
        );
    }

    /// @dev Used only to resolve where production's contracts are: this run deploys nothing.
    function _liveAddresses() private returns (HarborDeployRun) {
        return new HarborDeployRun(address(0), address(0), "harbor_v1", "mainnet", HarborDeployRun.Cut.Whole);
    }

    /// @dev The pegged tokens a dollar of `market`'s wrapped collateral buys from an empty market at its live oracle's low
    ///      price and rate, by the minter's own arithmetic.
    function _peggedBoughtByADollarOfCollateral(
        HarborDeployRun addresses,
        Config_MinterMarket market
    ) private returns (uint256) {
        (uint256 minPrice, , uint256 minRate, ) = IWrappedPriceOracle(addresses.wrappedPriceOracleAddress(market))
            .latestAnswer();
        return
            MinterValuationLib.peggedForCollateral(
                MinterValuationLib.wrappedAsCollateral(
                    IHarborConfig(address(market)).aboutADollarInWrappedCollateral(),
                    minRate
                ),
                0,
                0,
                minPrice
            );
    }
}
