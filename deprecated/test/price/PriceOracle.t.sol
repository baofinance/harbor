// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {PriceOracle_v1} from "@harbor/price/PriceOracle_v1.sol";
import {IPriceOracleErrors} from "@harbor/interfaces/IPriceOracleErrors.sol";
import {MockAggregator} from "@harbor-test/mocks/MockAggregator.sol";

contract PriceOracleTest is Test {
    uint64 constant MAX_ANSWER_AGE = 3600; // 1 hour
    uint256 constant MAX_RELATIVE_DEVIATION = 20 * 1e16; // 20%
    uint256 constant MAX_ABSOLUTE_DEVIATION = 1000 * 1 ether; // $1,000 with 18 decimals
    uint256 constant MAX_REVERSAL_DEVIATION = 10 * 1e16; // 10%
    uint8 constant DECIMALS = 18;

    function setUp() public {
        // lets not start at the genesis block!
        vm.warp(100000);
    }

    function _constraints() internal pure returns (PriceOracle_v1.Constraints memory) {
        return
            PriceOracle_v1.Constraints({
                maxAnswerAge: MAX_ANSWER_AGE,
                maxPercentageDeviation: MAX_RELATIVE_DEVIATION,
                maxAbsoluteDeviation: MAX_ABSOLUTE_DEVIATION,
                maxTrendReversalDeviation: MAX_REVERSAL_DEVIATION
            });
    }

    function test_ValidPrice() public {
        uint8 decimals = 8;
        MockAggregator mockFeed = new MockAggregator(decimals);
        mockFeed.setRoundData(1, 1, 2000 * 1 ether, block.timestamp - 3600, block.timestamp - 3600);
        mockFeed.setRoundData(1, 2, 2000 * 1 ether, block.timestamp - 10, block.timestamp - 10);
        mockFeed.setRoundData(1, 3, 2000 * 1 ether, block.timestamp, block.timestamp);

        uint256 price = PriceOracle_v1.latestAnswer(
            PriceOracle_v1.Feed({priceFeed: mockFeed, decimals: decimals}),
            _constraints()
        );
        assertEq(price, 2000 * 1 ether, "Price should match the mocked price");
    }

    function test_RevertWhen_NegativePrice() public {
        uint8 decimals = 8;
        MockAggregator mockFeed = new MockAggregator(decimals);
        // mockFeed.setRoundData(1, 1, 2000 * 1 ether, block.timestamp - 3600, block.timestamp - 3600);
        // mockFeed.setRoundData(1, 2, 2000 * 1 ether, block.timestamp - 10, block.timestamp - 10);
        mockFeed.setRoundData(1, 1, -100 * 1 ether, block.timestamp, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPriceOracleErrors.InvalidUnderlyingPrice.selector,
                address(mockFeed),
                -100 * 1 ether
            )
        );
        PriceOracle_v1.latestAnswer(PriceOracle_v1.Feed({priceFeed: mockFeed, decimals: decimals}), _constraints());
        // TODO: when the price is negative in the past (for validation) and not in the latest round
    }

    // zero price is fully acceptable
    // function test_RevertWhen_ZeroPrice() public {
    //     uint8 decimals = 8;
    //     MockAggregator mockFeed = new MockAggregator(decimals);
    //     mockFeed.setRoundData(1, 1, 2000 * 1 ether, block.timestamp - 3600, block.timestamp - 3600);
    //     mockFeed.setRoundData(1, 2, 2000 * 1 ether, block.timestamp - 10, block.timestamp - 10);
    //     mockFeed.setRoundData(1, 3, 0, block.timestamp, block.timestamp);

    //     vm.expectRevert(
    //         abi.encodeWithSelector(IPriceOracleErrors.InvalidUnderlyingPrice.selector, address(mockFeed), 0)
    //     );
    //     PriceOracle_v1.latestAnswer(
    //         PriceOracle_v1.Feed({priceFeed: mockFeed, decimals: decimals}),
    //         _constraints()
    //     );
    // }

    function test_RevertWhen_StalePrice() public {
        uint8 decimals = 8;
        MockAggregator mockFeed = new MockAggregator(decimals);
        mockFeed.setRoundData(1, 1, 2000 * 1 ether, block.timestamp - 3600, block.timestamp - 3600);
        mockFeed.setRoundData(1, 2, 2000 * 1 ether, block.timestamp - 10, block.timestamp - 10);
        mockFeed.setRoundData(
            1,
            3,
            2000 * 1 ether,
            block.timestamp - MAX_ANSWER_AGE - 1,
            block.timestamp - MAX_ANSWER_AGE - 1
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IPriceOracleErrors.StaleUnderlyingPrice.selector,
                address(mockFeed),
                block.timestamp - MAX_ANSWER_AGE - 1,
                block.timestamp
            )
        );
        PriceOracle_v1.latestAnswer(PriceOracle_v1.Feed({priceFeed: mockFeed, decimals: decimals}), _constraints());
    }

    function test_RevertWhen_PercentageDeviationTooHigh() public {
        uint8 decimals = 8;
        MockAggregator mockFeed = new MockAggregator(decimals);
        mockFeed.setRoundData(1, 1, 2000 * 1 ether, block.timestamp - 3600, block.timestamp - 3600);
        mockFeed.setRoundData(1, 2, 2000 * 1 ether, block.timestamp - 10, block.timestamp - 10);
        mockFeed.setRoundData(1, 3, 2500 * 1 ether, block.timestamp, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPriceOracleErrors.UnderlyingPriceDeviation.selector,
                address(mockFeed),
                2500 * 1 ether,
                2000 * 1 ether,
                MAX_RELATIVE_DEVIATION
            )
        );
        PriceOracle_v1.latestAnswer(PriceOracle_v1.Feed({priceFeed: mockFeed, decimals: decimals}), _constraints());
    }

    function test_RevertWhen_AbsoluteDeviationTooHigh() public {
        uint8 decimals = 8;
        MockAggregator mockFeed = new MockAggregator(decimals);
        mockFeed.setRoundData(1, 1, 2000 * 1 ether, block.timestamp - 3600, block.timestamp - 3600);
        mockFeed.setRoundData(1, 2, 2000 * 1 ether, block.timestamp - 10, block.timestamp - 10);
        mockFeed.setRoundData(1, 3, 3001 * 1 ether, block.timestamp, block.timestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IPriceOracleErrors.UnderlyingPriceDeviation.selector,
                address(mockFeed),
                int256(3001 * 1 ether),
                int256(2000 * 1 ether),
                MAX_ABSOLUTE_DEVIATION
            )
        );
        PriceOracle_v1.latestAnswer(PriceOracle_v1.Feed({priceFeed: mockFeed, decimals: decimals}), _constraints());
    }

    function test_AcceptableDeviation() public {
        uint8 decimals = 8;
        MockAggregator mockFeed = new MockAggregator(decimals);
        mockFeed.setRoundData(1, 1, 2000 * 1 ether, block.timestamp - 3600, block.timestamp - 3600);
        mockFeed.setRoundData(1, 2, 2400 * 1 ether, block.timestamp - 10, block.timestamp - 10);
        mockFeed.setRoundData(1, 3, 2400 * 1 ether, block.timestamp, block.timestamp);

        uint256 price = PriceOracle_v1.latestAnswer(
            PriceOracle_v1.Feed({priceFeed: mockFeed, decimals: decimals}),
            _constraints()
        );
        assertEq(price, 2400 * 1 ether, "Price should be accepted when at max deviation");
    }

    function test_NoHistoricalData() public {
        uint8 decimals = 8;
        MockAggregator mockFeed = new MockAggregator(decimals);

        // no data
        vm.expectRevert(
            abi.encodeWithSelector(IPriceOracleErrors.InvalidUnderlyingPrice.selector, address(mockFeed), 0)
        );
        PriceOracle_v1.latestAnswer(PriceOracle_v1.Feed({priceFeed: mockFeed, decimals: decimals}), _constraints());

        // add some data but not enough for validation
        mockFeed.setRoundData(1, 1, 2000 * 1 ether, block.timestamp, block.timestamp);
        uint256 price = PriceOracle_v1.latestAnswer(
            PriceOracle_v1.Feed({priceFeed: mockFeed, decimals: decimals}),
            _constraints()
        );
        assertEq(price, 2000 * 1 ether, "Price should be accepted when only one round is available");

        // add enough for simple validation
        mockFeed.setRoundData(1, 2, 2000 * 1 ether, block.timestamp, block.timestamp);
        price = PriceOracle_v1.latestAnswer(
            PriceOracle_v1.Feed({priceFeed: mockFeed, decimals: decimals}),
            _constraints()
        );
        assertEq(price, 2000 * 1 ether, "Price should be accepted when two rounds are available");
    }

    function test_NormalisationWithDifferentDecimals() public {
        // Test with 6 decimals
        MockAggregator mockFeed6 = new MockAggregator(6);
        mockFeed6.setRoundData(1, 1, 2000 * 1 ether, block.timestamp - 3600, block.timestamp - 3600);
        mockFeed6.setRoundData(1, 2, 2000 * 1 ether, block.timestamp - 10, block.timestamp - 10);
        mockFeed6.setRoundData(1, 3, 2400 * 1 ether, block.timestamp, block.timestamp);

        uint256 price6 = PriceOracle_v1.latestAnswer(
            PriceOracle_v1.Feed({priceFeed: mockFeed6, decimals: mockFeed6.decimals()}),
            _constraints()
        );
        // Should be normalised to 18 decimals
        assertEq(price6, 2400 * 1 ether, "Price should be normalised from 6 decimals to 18");

        // Test with 18 decimals
        MockAggregator mockFeed18 = new MockAggregator(18);
        mockFeed18.setRoundData(1, 1, 2000 * 1 ether, block.timestamp - 3600, block.timestamp - 3600);
        mockFeed18.setRoundData(1, 2, 2000 * 1 ether, block.timestamp - 10, block.timestamp - 10);
        mockFeed18.setRoundData(1, 3, 2400 * 1 ether, block.timestamp, block.timestamp);

        uint256 price18 = PriceOracle_v1.latestAnswer(
            PriceOracle_v1.Feed({priceFeed: mockFeed18, decimals: mockFeed18.decimals()}),
            _constraints()
        );
        assertEq(price18, 2400 * 1 ether, "Price should be correct for 18 decimals");
    }
}
