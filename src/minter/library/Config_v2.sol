// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ConfigIncentiveLib} from "@harbor/minter/library/ConfigIncentiveLib.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";

/// @title Config_v2 Library
/// @notice Handles validation and storage-efficient formatting for infrequently called config operations
/// @dev Extracts config validation from the main Minter contract to reduce its size, at the cost of increased gas.
/// We take this hit because upgrading the config is an infrequent cost.
/// @dev this contract doesn't modify storage so is upgrade safe
// solhint-disable-next-line contract-name-camelcase
library Config_v2 {
    using ConfigIncentiveLib for ConfigIncentiveLib.ActionIncentive;

    uint public constant MINT_PEGGED = 0; // solhint-disable-line explicit-types
    uint public constant REDEEM_PEGGED = 1; // solhint-disable-line explicit-types
    uint public constant MINT_LEVERAGED = 2; // solhint-disable-line explicit-types
    uint public constant REDEEM_LEVERAGED = 3; // solhint-disable-line explicit-types

    /// @notice Checks a given incentive config for errors and returns it ready for storage
    /// @param name Label for error messages
    /// @param config_ The user friendly config being checked and copied
    /// @param disallowNotDiscount If true, the config may have a disallow and not a discount
    /// true means it's a mint pegged or redeem leveraged config
    /// false means it's a redeem pegged or mint leveraged config
    /// @return out the storage efficient config
    // slither-disable-next-line cyclomatic-complexity as this code is simple in what it tries to do, it's just that there are a few checks
    function checkAndCopyBands(
        string memory name,
        IMinter.IncentiveConfig calldata config_,
        bool disallowNotDiscount
    ) internal pure returns (ConfigIncentiveLib.ActionIncentive memory out) {
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
                // check first band covers depeg territory or is a disallow band
                // this allows the different math involved in a depeg scenario doesn't straddle a band
                // if we didn't do it here, we would have to do it in each of the fee calculation functions
                // there is also at most one depegged band and you determine if you are in the band by checking the boundary against 1 ether
                // it makes the math simpler: i.e. how, otherwise, do we manage multiple incentive ratios for the depegged situation?
                // especially as the actual collateral ratio (not the one we calculate as _collateralRatio()) never goes below 1 ether
                if (currentUpperBound != 1 ether && incentiveRatio != 1 ether) {
                    revert IMinter.NoDepegBoundaryOrDisallow(name);
                }
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

    function checkAndCopyIncentives(
        IMinter.Config calldata config_,
        ConfigIncentiveLib.ActionIncentive[4] storage out
    ) external {
        out[MINT_PEGGED] = checkAndCopyBands("mint pegged", config_.mintPeggedIncentiveConfig, true);
        out[REDEEM_PEGGED] = checkAndCopyBands("redeem pegged", config_.redeemPeggedIncentiveConfig, false);
        out[MINT_LEVERAGED] = checkAndCopyBands("mint leveraged", config_.mintLeveragedIncentiveConfig, false);
        out[REDEEM_LEVERAGED] = checkAndCopyBands("redeem leveraged", config_.redeemLeveragedIncentiveConfig, true);
    }

    /// @notice Converts the compact storage format back to the full IncentiveConfig
    /// @param config_ The storage-efficient configuration to convert back
    /// @return out The user-friendly config structure
    function copyBandsBack(
        ConfigIncentiveLib.ActionIncentive memory config_
    ) internal pure returns (IMinter.IncentiveConfig memory out) {
        uint iOut = 0; // solhint-disable-line explicit-types
        uint outBands = ConfigIncentiveLib._collateralRatioBandCount(config_); // solhint-disable-line explicit-types
        uint outBounds = outBands - 1; // solhint-disable-line explicit-types
        out.collateralRatioBandUpperBounds = new uint256[](outBounds);
        out.incentiveRatios = new int256[](outBands);
        // solhint-disable-next-line explicit-types
        for (uint i = 0; i < outBounds; i++) {
            uint256 ub = ConfigIncentiveLib._collateralRatioUpperBounds(config_, i);
            if (ub == 1 ether - 1) {
                ub = 1 ether;
            }
            out.collateralRatioBandUpperBounds[iOut] = ub;
            out.incentiveRatios[iOut] = ConfigIncentiveLib._incentiveRatio(config_, i);
            iOut++;
        }
        out.incentiveRatios[iOut] = ConfigIncentiveLib._incentiveRatio(config_, outBounds);
        return out;
    }

    function copyIncentivesBack(
        ConfigIncentiveLib.ActionIncentive[4] memory config_
    ) internal pure returns (IMinter.Config memory out) {
        out.mintPeggedIncentiveConfig = copyBandsBack(config_[MINT_PEGGED]);
        out.redeemPeggedIncentiveConfig = copyBandsBack(config_[REDEEM_PEGGED]);
        out.mintLeveragedIncentiveConfig = copyBandsBack(config_[MINT_LEVERAGED]);
        out.redeemLeveragedIncentiveConfig = copyBandsBack(config_[REDEEM_LEVERAGED]);
    }

    function defaultActionIncentive() internal pure returns (ConfigIncentiveLib.ActionIncentive memory out) {
        // default config is a single band with no fees, discounts or disallows
        // we need the mandatory depeg boundary at 1 ether

        ConfigIncentiveLib._setIncentiveRatio(out, 0, 0); // in depeg
        ConfigIncentiveLib._setCollateralRatioUpperBounds(out, 0, 1 ether); // depeg boundary
        ConfigIncentiveLib._setIncentiveRatio(out, 1, 0); // pegged
        ConfigIncentiveLib._setCollateralRatioBandCount(out, 2); // two bands: de-pegged and pegged

        return out;
    }

    function defaultIncentive(ConfigIncentiveLib.ActionIncentive[4] storage out) external {
        out[0] = defaultActionIncentive(); // mint pegged
        out[1] = defaultActionIncentive(); // redeem pegged
        out[2] = defaultActionIncentive(); // mint leveraged
        out[3] = defaultActionIncentive(); // redeem leveraged
    }
}
