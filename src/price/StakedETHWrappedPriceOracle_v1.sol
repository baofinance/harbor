// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {PriceOracle} from "./PriceOracle.sol";
import {IWstETH} from "@bao/interfaces/IWstETH.sol";

/**
 * @title StakedETHWrappedPriceOracleV1
 * @notice A contract for safely consuming Chainlink price feeds for staked ETH with heartbeat detection
 * @dev This contract is designed to be used with a UUPS proxy.
 * @dev even though the contract has no state variables in the proxy space, it still uses the UUPS pattern
 *      to allow for future upgrades without requiring updates of all the contracts that use it
 */
// solhint-disable contract-name-camelcase
contract StakedETHWrappedPriceOracle_v1 is
    IWrappedPriceOracle,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    BaoOwnable
{
    error InvalidPriceFeed(address stethPriceFeed);
    error InvalidMaxPriceAge(uint64 maxPriceAge);
    error InvalidMaxRelativeDeviation(uint64 maxRelativeDeviation);
    error InvalidMaxAbsoluteDeviation(uint256 maxAbsoluteDeviation);

    // Immutable variables for gas-efficient access
    address public immutable STETH_FEED;
    uint8 public immutable STETH_FEED_DECIMALS;
    IWstETH public constant WSTETH = IWstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

    // PriceOracle.Constraints
    uint64 private immutable _MAX_PRICE_AGE;
    uint64 private immutable _MAX_RELATIVE_DEVIATION;
    uint256 private immutable _MAX_ABSOLUTE_DEVIATION;
    uint256 private immutable _MAX_TREND_REVERSAL;

    // Errors specific to implementation details
    error InconsistentRoundData(uint80 roundId, uint80 prevRoundId);

    /// @inheritdoc IWrappedPriceOracle
    function latestAnswer()
        external
        view
        returns (uint256 minUnderlyingPrice, uint256 maxUnderlyingPrice, uint256 minWrappedRate, uint256 maxWrappedRate)
    {
        PriceOracle.Feed memory feed = PriceOracle.Feed({
            priceFeed: AggregatorV3Interface(STETH_FEED),
            decimals: STETH_FEED_DECIMALS
        });
        PriceOracle.Constraints memory constraints = PriceOracle.Constraints({
            maxAnswerAge: _MAX_PRICE_AGE,
            maxPercentageDeviation: _MAX_RELATIVE_DEVIATION,
            maxAbsoluteDeviation: _MAX_ABSOLUTE_DEVIATION,
            maxTrendReversalDeviation: _MAX_TREND_REVERSAL
        });

        minUnderlyingPrice = maxUnderlyingPrice = PriceOracle.latestAnswer(feed, constraints);

        minWrappedRate = maxWrappedRate = WSTETH.stEthPerToken();
    }

    /**
     * @dev Blocks initialization of the implementation contract and sets immutable configuration
     */
    constructor(
        address stethFeed_,
        uint64 maxPriceAge_,
        uint64 maxRelativeDeviation_,
        uint256 maxAbsoluteDeviation_,
        uint256 maxTrendReversalDeviation_
    ) {
        // only allow initialization via the proxy
        _disableInitializers();

        if (stethFeed_ == address(0)) {
            revert InvalidPriceFeed(stethFeed_);
        }
        if (maxPriceAge_ == 0) {
            revert InvalidMaxPriceAge(maxPriceAge_);
        }
        if (maxRelativeDeviation_ == 0) {
            revert InvalidMaxRelativeDeviation(maxRelativeDeviation_);
        }
        if (maxAbsoluteDeviation_ == 0) {
            revert InvalidMaxAbsoluteDeviation(maxAbsoluteDeviation_);
        }

        // Set feed constants
        STETH_FEED = stethFeed_;
        STETH_FEED_DECIMALS = AggregatorV3Interface(stethFeed_).decimals();

        // Set price feed constraints
        _MAX_PRICE_AGE = maxPriceAge_;
        _MAX_RELATIVE_DEVIATION = maxRelativeDeviation_;
        _MAX_ABSOLUTE_DEVIATION = maxAbsoluteDeviation_;
        _MAX_TREND_REVERSAL = maxTrendReversalDeviation_;
    }

    /**
     * @notice Initialize the contract with the owner
     * @param owner_ Address of the contract owner
     */
    function initialize(address owner_) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        _initializeOwner(owner_);
    }

    /**
     * @dev Function that authorizes upgrades, restricted to owner
     */
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // Validation can be added here if needed
    }
}
