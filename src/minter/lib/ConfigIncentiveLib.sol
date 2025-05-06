// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {WordCodec} from "src/common/WordCodec.sol";

/// @title ConfigIncentiveLib
/// @notice Low-level data structure operations for ActionIncentive
/// @dev Used by both Minter_v1 and Config_v1
library ConfigIncentiveLib {
    using WordCodec for bytes32;

    ///////////////
    // Constants //
    ///////////////

    /// @notice The precision at which incentive ratios are stored.
    /// @dev With decimals = 9, this gives a max ratio of 2 (200%) with precision of 0.000000001 (0.0000001%)
    uint internal constant INCENTIVE_RATIO_DECIMALS = 9;

    /// @notice The precision at which collateral ratio bounds are stored.
    /// @dev With decimals = 6, this gives a max ratio of 4,000 (400,000%) with precision of 0.000001 (0.0001%)
    uint internal constant COLLATERAL_RATIO_DECIMALS = 6;

    /// @notice The maximum number of fee/discount value bands that can be stored
    uint internal constant MAX_BANDS = 8;

    /// @notice The maximum number of collateral ratio bounds for fee/discount variation that can be stored
    uint internal constant MAX_BOUNDS = MAX_BANDS - 1;

    ///////////////
    // Structs   //
    ///////////////

    /// @notice The storage format for the array of incentive ratios and collateral ratio bound.
    /// @dev We use a struct here but implement our own storage within because solidity uses too many slots
    /// @dev There are a set of accessor functions for each logical item in the structure.
    struct ActionIncentive {
        bytes32 slot0;
        // uint32[7] collateralRatioUpperBounds;      0:223
        // uint8 collateralRatioBandCount;          224:231
        bytes32 slot1;
        // int32[8] incentiveRatios;                  0:255
    }

    ///////////////////////////
    // Accessor Functions    //
    ///////////////////////////

    // slot accessors for ActionIncentive
    /// @notice Returns a collateral ratio bound at the given index
    // solhint-disable-next-line explicit-types
    function _collateralRatioUpperBounds(
        ActionIncentive memory config_,
        uint index
    ) internal pure returns (uint256 result) {
        result = (config_.slot0.decodeUint(index * 32, 32) * 10 ** (18 - COLLATERAL_RATIO_DECIMALS));
        // an upper bound of 1 ether actually means an upper bound just below 1 ether because that's where it becomes depegged
        // we treat 1 ether specially, as we can't specify 1 ether -1 so we just subtract 1 here
        if (result == 1 ether) result = 1 ether - 1;
    }

    /// @notice Returns a collateral ratio lower bound at the given index`
    // solhint-disable-next-line explicit-types
    function _collateralRatioLowerBounds(
        ActionIncentive memory config_,
        uint index
    ) internal pure returns (uint256 result) {
        // if we are in the lowest band, the lower bound is 0
        // else its the previous upper bound
        result = index == 0 ? 0 ether : _collateralRatioUpperBounds(config_, index - 1);
    }

    /// @notice Returns the collateral ratio bound count
    // solhint-disable-next-line explicit-types
    function _collateralRatioBandCount(ActionIncentive memory config_) internal pure returns (uint count) {
        count = config_.slot0.decodeUint(224, 8);
    }

    /// @notice Returns a incentive ratio at the given index
    // solhint-disable-next-line explicit-types
    function _incentiveRatio(ActionIncentive memory config_, uint index) internal pure returns (int256 result) {
        result = config_.slot1.decodeInt(index * 32, 32) * int256(10 ** (18 - INCENTIVE_RATIO_DECIMALS));
    }

    ///////////////////////////
    // Modifier Functions    //
    ///////////////////////////

    /// @notice Stores a collateral ratio bound at the given index
    // solhint-disable-next-line explicit-types
    function _setCollateralRatioUpperBounds(ActionIncentive memory config_, uint index, uint256 value) internal pure {
        config_.slot0 = config_.slot0.encodeUint(value / 10 ** (18 - COLLATERAL_RATIO_DECIMALS), index * 32, 32);
    }

    /// @notice Stored the collateral ratio bound count
    // solhint-disable-next-line explicit-types
    function _setCollateralRatioBandCount(ActionIncentive memory config_, uint value) internal pure {
        config_.slot0 = config_.slot0.encodeUint(value, 224, 8);
    }

    /// @notice Stores a incentive ratio at the given index
    // solhint-disable-next-line explicit-types
    function _setIncentiveRatio(ActionIncentive memory config_, uint index, int256 value) internal pure {
        config_.slot1 = config_.slot1.encodeInt(value / int256(10 ** (18 - INCENTIVE_RATIO_DECIMALS)), index * 32, 32);
    }

    ///////////////////////////
    // Helper Functions      //
    ///////////////////////////

    /// @notice Returns the value of an incentive ratio after it has been cycled (and possibly truncated) through its
    /// storage.
    function _incentiveRatioToStoragePrecision(int256 ratio) internal pure returns (int256 result) {
        int256 factor = int256(10 ** (18 - INCENTIVE_RATIO_DECIMALS));
        // slither-disable-next-line divide-before-multiply
        result = ((ratio / factor) * factor);
    }

    /// @notice Returns the value of an collateral ratio bound after it has been cycled (and possibly truncated) through
    /// its storage
    function _collateralRatioToStoragePrecision(uint256 ratio) internal pure returns (uint256 result) {
        uint256 factor = 10 ** (18 - COLLATERAL_RATIO_DECIMALS);
        // slither-disable-next-line divide-before-multiply
        result = ((ratio / factor) * factor);
    }
}
