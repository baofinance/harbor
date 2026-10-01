// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {ConfigIncentiveLib} from "@harbor/minter/library/ConfigIncentiveLib.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice What the minter's config loader accepts and refuses: each rule tried in every one of the four schedules, the
///         schedule under test placed in one slot of an otherwise valid config.
contract TestMinterConfigValidation is TestMinterSetUp {
    /// @dev The widest collateral-ratio bound a schedule can store, 1e18-scaled: a 32-bit field counting steps of
    ///      `10 ** -COLLATERAL_RATIO_DECIMALS` - 4294.967295.
    function _largestStorableBound() private pure returns (uint256) {
        return uint256(type(uint32).max) * 10 ** (18 - ConfigIncentiveLib.COLLATERAL_RATIO_DECIMALS);
    }

    /// @dev Three free bands, split at the peg and at `upperBound`.
    function _freeBandsSplitAt(uint256 upperBound) private pure returns (IMinter.IncentiveConfig memory schedule) {
        schedule.collateralRatioBandUpperBounds = new uint256[](2);
        schedule.collateralRatioBandUpperBounds[0] = 1 ether;
        schedule.collateralRatioBandUpperBounds[1] = upperBound;
        schedule.incentiveRatios = new int256[](3);
    }

    /// @dev A valid config - every schedule two free bands split at the peg - with `schedule` in slot `slot`: 0 mint
    ///      pegged, 1 redeem pegged, 2 mint leveraged, 3 redeem leveraged.
    function _configWith(
        uint256 slot,
        IMinter.IncentiveConfig memory schedule
    ) private pure returns (IMinter.Config memory config_) {
        IMinter.IncentiveConfig memory free;
        free.collateralRatioBandUpperBounds = new uint256[](1);
        free.collateralRatioBandUpperBounds[0] = 1 ether;
        free.incentiveRatios = new int256[](2);
        config_.mintPeggedIncentiveConfig = slot == 0 ? schedule : free;
        config_.redeemPeggedIncentiveConfig = slot == 1 ? schedule : free;
        config_.mintLeveragedIncentiveConfig = slot == 2 ? schedule : free;
        config_.redeemLeveragedIncentiveConfig = slot == 3 ? schedule : free;
    }

    /// A collateral-ratio bound too wide for its storage field is refused by name, in every schedule, rather than
    /// stored truncated.
    function test_updateConfig_refusesABoundTooLargeForItsStorage_inEverySchedule() public {
        string[4] memory names = ["mint pegged", "redeem pegged", "mint leveraged", "redeem leveraged"];
        // one storage step past the widest bound the field holds
        uint256 tooLarge = _largestStorableBound() + 10 ** (18 - ConfigIncentiveLib.COLLATERAL_RATIO_DECIMALS);

        vm.startPrank(owner());
        for (uint256 slot = 0; slot < names.length; slot++) {
            IMinter.Config memory config_ = _configWith(slot, _freeBandsSplitAt(tooLarge));
            vm.expectRevert(
                abi.encodeWithSelector(
                    IMinter.InvalidCollateralRatioBoundValue.selector,
                    names[slot],
                    tooLarge,
                    1,
                    "boundary too large for storage"
                )
            );
            IMinter(minter).updateConfig(config_);
        }
        vm.stopPrank();
    }

    /// The widest bound the storage holds is accepted and reads back exactly, in every schedule.
    function test_updateConfig_acceptsTheLargestBoundItsStorageHolds_inEverySchedule() public {
        uint256 largest = _largestStorableBound();
        for (uint256 slot = 0; slot < 4; slot++) {
            IMinter.Config memory config_ = _configWith(slot, _freeBandsSplitAt(largest));
            vm.startPrank(owner());
            IMinter(minter).updateConfig(config_);
            vm.stopPrank();
            _assertEqConfig(IMinter(minter).config(), config_);
        }
    }
}
