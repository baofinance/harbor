// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AggregatorV3Interface} from "@chainlink/contracts/shared/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {BaoOwnable} from "@bao/BaoOwnable.sol";
import {IWrappedPriceOracle} from "@interfaces/IWrappedPriceOracle.sol";
import {PriceOracle} from "./PriceOracle.sol";
import {IWstETH} from "@bao/interfaces/IWstETH.sol";

/**
 * @title StakedETHWrappedPriceOracleV1
 * @notice A contract for safely consuming Chainlink price feeds for staked ETH with heartbeat detection
 * @dev This contract is designed to be used with a UUPS proxy
 */
contract StakedETHWrappedPriceOracleV1 is
    IWrappedPriceOracle,
    UUPSUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    BaoOwnable
{
    // Immutable variables for gas-efficient access
    address public immutable stethFeed;
    uint256 public immutable stethFeedDecimals;
    bool public immutable hasAnsweredInRound;
    IWstETH public immutable wstETH;
    uint64 private immutable _maxPriceAge;
    uint64 private immutable _maxRelativeDeviation;
    uint256 private immutable _maxAbsoluteDeviation;
    uint256 private immutable _maxTrendReversalDeviation;

    // Errors specific to implementation details
    error InconsistentRoundData(uint80 roundId, uint80 prevRoundId);

    /// @inheritdoc IWrappedPriceOracle
    function latestAnswer()
        external
        view
        returns (uint256 minUnderlyingPrice, uint256 maxUnderlyingPrice, uint256 minWrappedRate, uint256 maxWrappedRate)
    {
        PriceOracle.Feed memory feed = PriceOracle.Feed({
            priceFeed: AggregatorV3Interface(stethFeed),
            decimals: uint8(stethFeedDecimals),
            hasAnsweredInRound: hasAnsweredInRound
        });
        PriceOracle.Constraints memory constraints = PriceOracle.Constraints({
            maxAnswerAge: _maxPriceAge,
            maxPercentageDeviation: _maxRelativeDeviation,
            maxAbsoluteDeviation: _maxAbsoluteDeviation,
            maxTrendReversalDeviation: _maxTrendReversalDeviation
        });

        minUnderlyingPrice = maxUnderlyingPrice = PriceOracle.latestAnswer(feed, constraints);

        minWrappedRate = maxWrappedRate = wstETH.stEthPerToken();
    }

    /**
     * @dev Blocks initialization of the implementation contract and sets immutable configuration
     */
    constructor(
        address stethFeed_,
        bool hasAnsweredInRound_,
        uint64 maxPriceAge_,
        uint64 maxRelativeDeviation_,
        uint256 maxAbsoluteDeviation_,
        uint256 maxTrendReversalDeviation_
    ) {
        // only allow initialization via the proxy
        _disableInitializers();
        // Set immutable variables
        stethFeed = stethFeed_;
        stethFeedDecimals = AggregatorV3Interface(stethFeed_).decimals();
        hasAnsweredInRound = hasAnsweredInRound_;
        wstETH = IWstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
        _maxPriceAge = maxPriceAge_;
        _maxRelativeDeviation = maxRelativeDeviation_;
        _maxAbsoluteDeviation = maxAbsoluteDeviation_;
        _maxTrendReversalDeviation = maxTrendReversalDeviation_;
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
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        // Validation can be added here if needed
    }

    // /**
    //  * @notice Get the underlying feed
    //  */
    // function stethFeed() external view returns (AggregatorV3Interface) {
    //     return AggregatorV3Interface(_stethFeed);
    // }

    // /// @notice The storage hash for the shared-with-proxy storage
    // /// @dev keccak256(abi.encode(uint256(keccak256("bao.storage.WrappedPriceOracle")) - 1)) & ~bytes32(uint256(0xff));
    // bytes32 private constant _PRICE_ORACLE_STORAGE = 0x3c0f448ab3cca9ae0473c5ddfae9fee617b16a5a264b49d4b2ef5fda40f1e300;

    // /// @notice Returns a reference to the contract state
    // function _getPriceOracleStorage() private pure returns (WrappedPriceOracleStorage storage $) {
    //     // solhint-disable-next-line no-inline-assembly
    //     assembly {
    //         $.slot := _PRICE_ORACLE_STORAGE
    //     }
    // }
}
