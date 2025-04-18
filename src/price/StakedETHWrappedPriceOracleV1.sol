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
    address public immutable underlyingFeed;
    IWstETH public immutable wstETH;
    uint64 private immutable _maxTimeDelay;
    uint64 private immutable _maxPercentageDeviation;
    uint256 private immutable _maxAbsoluteDeviation;

    // Events specific to implementation and not needed by consumers
    event ConfigUpdated(uint256 newMaxTimeDelay);

    // Errors specific to implementation details
    error InconsistentRoundData(uint80 roundId, uint80 prevRoundId);

    /**
     * @notice Gets the validated price from the underlying feed without updating state
     * @dev This is the primary function for price validation, now using the PriceOracle library
     * @return underlyingPrice The validated underlying price
     * @return wrappedRate Currently returns 1 ether as a fixed rate
     */
    function latestAnswer() external view returns (uint256 underlyingPrice, uint256 wrappedRate) {
        // Using immutable variables directly for gas efficiency
        underlyingPrice = PriceOracle.latestAnswer(
            AggregatorV3Interface(underlyingFeed),
            _maxTimeDelay,
            _maxPercentageDeviation,
            _maxAbsoluteDeviation
        );
        // now calculate the wrapped rate
        uint256 stEthPerToken = wstETH.stEthPerToken();
        return (underlyingPrice, stEthPerToken);
    }

    /**
     * @dev Blocks initialization of the implementation contract and sets immutable configuration
     */
    constructor(
        address underlyingFeed_,
        uint64 maxTimeDelay_,
        uint64 maxPercentageDeviation_,
        uint256 maxAbsoluteDeviation_
    ) {
        _disableInitializers();
        underlyingFeed = underlyingFeed_;
        _maxTimeDelay = maxTimeDelay_;
        _maxPercentageDeviation = maxPercentageDeviation_;
        _maxAbsoluteDeviation = maxAbsoluteDeviation_;
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
    // function underlyingFeed() external view returns (AggregatorV3Interface) {
    //     return AggregatorV3Interface(_underlyingFeed);
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
