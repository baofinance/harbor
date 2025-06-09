// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ConfigIncentiveLib} from "src/minter/lib/ConfigIncentiveLib.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

/// @title Config_v1 Library
/// @notice Handles validation and storage-efficient formatting for infrequently called config operations
/// @dev Extracts config validation from the main Minter contract to reduce its size, at the cost of increased gas.
/// We take this hit because upgrading the config is an infrequent cost.
/// @dev this contract doesn't modify storage so is upgrade safe
// solhint-disable-next-line contract-name-camelcase
library Config_v1 {
    using ConfigIncentiveLib for ConfigIncentiveLib.ActionIncentive;

    /// @notice Checks a given incentive config for errors and returns it ready for storage
    /// @param name Label for error messages
    /// @param config_ The user friendly config being checked and copied
    /// @param disallowNotDiscount If true, the config may have a disallow and not a discount
    /// true means it's a mint pegged or redeem leveraged config
    /// false means it's a redeem pegged or mint leveraged config
    /// @return out the storage efficient config
    // slither-disable-next-line cyclomatic-complexity as this code is simple in what it tries to do, it's just that there are a few checks
    function checkAndCopyBands(
        string calldata name,
        IMinter.IncentiveConfig calldata config_,
        bool disallowNotDiscount
    ) external pure returns (ConfigIncentiveLib.ActionIncentive memory out) {
        // check the array sizes match
        if (config_.incentiveRatios.length < 1) {
            revert IMinter.TooFewIncentiveRatios(name, config_.incentiveRatios.length, 1);
        }
        if (config_.incentiveRatios.length != config_.collateralRatioBandUpperBounds.length + 1) {
            revert IMinter.CollateralRatioBoundsIncentivesLengthsMismatch(
                name,
                config_.collateralRatioBandUpperBounds.length,
                config_.incentiveRatios.length
            );
        }
        out = ConfigIncentiveLib.ActionIncentive(0, 0);
        uint256 prevUpperBound = 0;
        int256 prevIncentiveRatio;
        uint iOut = 0; // solhint-disable-line explicit-types
        // solhint-disable-next-line explicit-types
        for (uint i = 0; i < config_.incentiveRatios.length; i++) {
            int256 incentiveRatio = ConfigIncentiveLib._incentiveRatioToStoragePrecision(config_.incentiveRatios[i]);

            // incentive ratios cannot be too precise for the storage schema
            if (incentiveRatio != config_.incentiveRatios[i]) {
                revert IMinter.IncentiveRatioTooPrecise(name, config_.incentiveRatios[i]);
            }

            // check the incentive array values given
            if (disallowNotDiscount) {
                // it's mint pegged or redeem leveraged
                // check against interval [0, 1] i.e. zero fees to some fees to disallow (100% fees)
                if (incentiveRatio < 0 ether || incentiveRatio > 1 ether) {
                    revert IMinter.InvalidIncentiveRatioValue(name, i, config_.incentiveRatios[i], "must be in [0, 1]");
                }
                // disallows, if they exist, must be at index 0
                if (incentiveRatio == 1 ether && i != 0) {
                    revert IMinter.InvalidIncentiveRatioValue(
                        name,
                        i,
                        config_.incentiveRatios[i],
                        "disallow (1) must be at index 0"
                    );
                }
                // fees are the same or decreasing with collateral ratio
                // this is not necessary for mathematical reasons
                // given the action reduces collateral ratio, decreasing a fee as collateral ratio decreases is a likely error
                if (i == 0) prevIncentiveRatio = incentiveRatio;
                else if (incentiveRatio > prevIncentiveRatio)
                    revert IMinter.InvalidIncentiveRatioValue(
                        name,
                        i,
                        config_.incentiveRatios[i],
                        "must be decreasing"
                    );
            } else {
                // it's a redeem pegged or mint leveraged
                // check against interval (-1, 1) i.e. some discount; to zero; to some fees
                if (incentiveRatio <= -1 ether || incentiveRatio >= 1 ether) {
                    revert IMinter.InvalidIncentiveRatioValue(
                        name,
                        i,
                        config_.incentiveRatios[i],
                        "must be in (-1, 1)"
                    );
                }
                // fees are the same or decreasing with collateral ratio
                // this *is* necessary for mathematical reasons - given the reserve pool can be exhausted we must ensure that discounts applied
                // are path independent - i.e. dollar-by-dollar actions results in the same total discount as a single action of the same total value.
                // given the action increases collateral ratio, increasing a fee or decreasing a discount as collateral ratio increases is a likely error
                if (i == 0) prevIncentiveRatio = incentiveRatio;
                else if (incentiveRatio < prevIncentiveRatio)
                    revert IMinter.InvalidIncentiveRatioValue(
                        name,
                        i,
                        config_.incentiveRatios[i],
                        "must be increasing"
                    );
            }

            // check collateral ratio upper bounds are strictly increasing and then copy
            uint256 currentUpperBound;
            if (i < config_.collateralRatioBandUpperBounds.length) {
                currentUpperBound = ConfigIncentiveLib._collateralRatioToStoragePrecision(
                    config_.collateralRatioBandUpperBounds[i]
                );
                if (currentUpperBound != config_.collateralRatioBandUpperBounds[i]) {
                    revert IMinter.CollateralRatioBoundTooPrecise(name, config_.collateralRatioBandUpperBounds[i]);
                }
                if (i == 0 && currentUpperBound < 1 ether) {
                    revert IMinter.InvalidCollateralRatioBoundValue(
                        name,
                        currentUpperBound,
                        i,
                        "first boundary must be >= 1"
                    );
                }
                if (i > 0 && currentUpperBound <= 1 ether) {
                    revert IMinter.InvalidCollateralRatioBoundValue(name, currentUpperBound, i, "boundary must be > 1");
                }
            } else {
                currentUpperBound = type(uint256).max;
            }

            if (i == 0) {
                // add a depeg boundary as the first band one unless there is already one or it is a disallow band
                // if we didn't do it here, we would have to do it in each of the fee calculation functions
                // this makes the check against band == 0 the same as a check for depegged
                // it also makes the math simpler: i.e. how, otherwise, do we manage multiple incentive ratios for the depegged situation?
                // especially as the actual collateral ratio (not the one we calculate as _collateralRatio()) never goes below 1 ether
                if (currentUpperBound != 1 ether && incentiveRatio != 1 ether)
                    revert IMinter.NoDepegBoundaryOrDisallow(name);
            } else {
                // each subsequent must be strictly increasing at the storage precision
                if (currentUpperBound <= prevUpperBound) {
                    revert IMinter.CollateralRatioBoundValueNotIncreasing(
                        name,
                        config_.collateralRatioBandUpperBounds[i],
                        i,
                        config_.collateralRatioBandUpperBounds[i - 1]
                    );
                }
            }
            if (iOut >= ConfigIncentiveLib.MAX_BANDS) {
                revert IMinter.TooManyIncentiveRatios(
                    name,
                    config_.incentiveRatios.length,
                    config_.incentiveRatios.length - 1
                );
            }

            ConfigIncentiveLib._setIncentiveRatio(out, iOut, incentiveRatio);
            if (i < config_.collateralRatioBandUpperBounds.length) {
                ConfigIncentiveLib._setCollateralRatioUpperBounds(out, iOut, currentUpperBound);
                prevUpperBound = currentUpperBound;
            }
            iOut++;
        }

        ConfigIncentiveLib._setCollateralRatioBandCount(out, iOut);
        return out;
    }

    /// @notice Converts the compact storage format back to the full IncentiveConfig
    /// @param config_ The storage-efficient configuration to convert back
    /// @return out The user-friendly config structure
    function copyBandsBack(
        ConfigIncentiveLib.ActionIncentive memory config_
    ) external pure returns (IMinter.IncentiveConfig memory out) {
        uint iOut = 0; // solhint-disable-line explicit-types
        uint outBands = ConfigIncentiveLib._collateralRatioBandCount(config_); // solhint-disable-line explicit-types
        uint outBounds = outBands - 1; // solhint-disable-line explicit-types
        out.collateralRatioBandUpperBounds = new uint256[](outBounds);
        out.incentiveRatios = new int256[](outBands);
        // solhint-disable-next-line explicit-types
        for (uint i = 0; i < outBounds; i++) {
            uint256 ub = ConfigIncentiveLib._collateralRatioUpperBounds(config_, i);
            if (ub == 1 ether - 1) ub = 1 ether;
            out.collateralRatioBandUpperBounds[iOut] = ub;
            out.incentiveRatios[iOut] = ConfigIncentiveLib._incentiveRatio(config_, i);
            iOut++;
        }
        out.incentiveRatios[iOut] = ConfigIncentiveLib._incentiveRatio(config_, outBounds);
        return out;
    }

    function defaultActionIncentive() external pure returns (ConfigIncentiveLib.ActionIncentive memory out) {
        // default config is a single band with no fees
        // we need the mandatory depeg boundary at 1 ether

        ConfigIncentiveLib._setIncentiveRatio(out, 0, 0); // in depeg
        ConfigIncentiveLib._setCollateralRatioUpperBounds(out, 0, 1 ether); // depeg boundary
        ConfigIncentiveLib._setIncentiveRatio(out, 1, 0); // pegged
        ConfigIncentiveLib._setCollateralRatioBandCount(out, 2); // two bands: de-pegged and pegged

        return out;
    }
}
