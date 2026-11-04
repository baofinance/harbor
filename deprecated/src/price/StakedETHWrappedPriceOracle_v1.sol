// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {PriceOracle_v1} from "./PriceOracle_v1.sol";
import {IWstETH} from "@bao/interfaces/IWstETH.sol";

/// @title StakedETHWrappedPriceOracleV1
/// @notice A contract for safely consuming Chainlink price feeds for staked ETH with heartbeat detection
/// @dev This contract is designed to be used with a UUPS proxy.
/// @dev even though the contract has no state variables in the proxy space, it still uses the UUPS pattern
///      to allow for future upgrades without requiring updates of all the contracts that use it
/// @custom:oz-upgrades-unsafe-allow external-library-linking
// solhint-disable contract-name-camelcase
contract StakedETHWrappedPriceOracle_v1 is
    IWrappedPriceOracle,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    BaoOwnable
{
    using PriceOracle_v1 for PriceOracle_v1.Feed;
    using PriceOracle_v1 for PriceOracle_v1.Constraints;

    error InvalidPriceSource(address stethPriceSource);
    error InvalidRateSource(address wstethRateSource);
    error InvalidMaxPriceAge(uint64 maxPriceAge);
    error InvalidMaxRelativeDeviation(uint64 maxRelativeDeviation);
    error InvalidMaxAbsoluteDeviation(uint256 maxAbsoluteDeviation);

    // these variables are set in the constructor, not the initializer, to improve contract size and gas usage
    // to change them the contract must be upgraded
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable STETH_FEED;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint8 public immutable STETH_FEED_DECIMALS; // chainlink doesn't change the decimals of a feed
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    IWstETH public immutable WSTETH;

    // PriceOracle_v1.Constraints
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint64 private immutable _MAX_PRICE_AGE;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint64 private immutable _MAX_RELATIVE_DEVIATION;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 private immutable _MAX_ABSOLUTE_DEVIATION;
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 private immutable _MAX_TREND_REVERSAL;

    // Errors specific to implementation details
    error InconsistentRoundData(uint80 roundId, uint80 prevRoundId);

    /// @inheritdoc IWrappedPriceOracle
    function latestAnswer()
        external
        view
        returns (uint256 minUnderlyingPrice, uint256 maxUnderlyingPrice, uint256 minWrappedRate, uint256 maxWrappedRate)
    {
        PriceOracle_v1.Feed memory feed = PriceOracle_v1.Feed({
            priceFeed: AggregatorV3Interface(STETH_FEED),
            decimals: STETH_FEED_DECIMALS
        });
        PriceOracle_v1.Constraints memory constraints = PriceOracle_v1.Constraints({
            maxAnswerAge: _MAX_PRICE_AGE,
            maxPercentageDeviation: _MAX_RELATIVE_DEVIATION,
            maxAbsoluteDeviation: _MAX_ABSOLUTE_DEVIATION,
            maxTrendReversalDeviation: _MAX_TREND_REVERSAL
        });

        minUnderlyingPrice = maxUnderlyingPrice = PriceOracle_v1.latestAnswer(feed, constraints);

        minWrappedRate = maxWrappedRate = WSTETH.stEthPerToken();
    }

    /// @dev Blocks initialization of the implementation contract and sets immutable configuration
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address stethFeed_, // 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8 for ethereum mainnet
        address wstETH, // (0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 for ethereum mainnet
        uint64 maxPriceAge_,
        uint64 maxRelativeDeviation_,
        uint256 maxAbsoluteDeviation_,
        uint256 maxTrendReversalDeviation_
    ) {
        // only allow initialization via the proxy
        _disableInitializers();

        if (stethFeed_ == address(0)) {
            revert InvalidPriceSource(stethFeed_);
        }
        if (wstETH == address(0)) {
            revert InvalidRateSource(wstETH);
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
        WSTETH = IWstETH(wstETH);

        // Set price feed constraints
        _MAX_PRICE_AGE = maxPriceAge_;
        _MAX_RELATIVE_DEVIATION = maxRelativeDeviation_;
        _MAX_ABSOLUTE_DEVIATION = maxAbsoluteDeviation_;
        _MAX_TREND_REVERSAL = maxTrendReversalDeviation_;
    }

    /// @notice Initialize the contract with the owner
    /// @param owner_ Address of the contract owner
    function initialize(address owner_) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();
        _initializeOwner(owner_);
    }

    /// @dev Function that authorizes upgrades, restricted to owner
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // Validation can be added here if needed
    }
}
