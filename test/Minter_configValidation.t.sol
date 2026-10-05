// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {ConfigIncentiveLib} from "@harbor/minter/library/ConfigIncentiveLib.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice What the minter's config loader accepts and reverts on: each rule tried in every one of the four schedules,
///         the schedule under test placed in one slot of an otherwise valid config.
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

    /// @dev The name a schedule's errors carry, by slot.
    function _name(uint256 slot) private pure returns (string memory) {
        return ["mint pegged", "redeem pegged", "mint leveraged", "redeem leveraged"][slot];
    }

    /// @dev Submits `config_` as the owner, expecting it to revert with `reason`.
    function _expectUpdateConfigReverts(IMinter.Config memory config_, bytes memory reason) private {
        vm.startPrank(owner());
        vm.expectRevert(reason);
        IMinter(minter).updateConfig(config_);
        vm.stopPrank();
    }

    /// @dev Submits `config_` as the owner and checks it reads back exactly.
    function _expectAccepted(IMinter.Config memory config_) private {
        vm.startPrank(owner());
        IMinter(minter).updateConfig(config_);
        vm.stopPrank();
        _assertEqConfig(IMinter(minter).config(), config_);
    }

    /// Only the owner sets the config: for a stranger and a holder of the zero-fee role it reverts.
    function test_updateConfig_revertsForAnyoneButTheOwner() public {
        IMinter.Config memory config_ = _configWith(0, ic(ua(100), ia(0, 0)));
        address[2] memory unauthorised = [makeAddr("stranger"), zeroFee];
        for (uint256 i = 0; i < unauthorised.length; i++) {
            vm.startPrank(unauthorised[i]);
            vm.expectRevert(IHarborOwnable.Unauthorized.selector);
            IMinter(minter).updateConfig(config_);
            vm.stopPrank();
        }
    }

    /// Setting the config announces the whole config set.
    function test_updateConfig_emitsTheConfigGiven() public {
        IMinter.Config memory config_ = _configWith(1, ic(ua(100, 130), ia(-50, -20, 10)));
        vm.startPrank(owner());
        vm.expectEmit(minter);
        emit IMinter.UpdateConfig(config_);
        IMinter(minter).updateConfig(config_);
        vm.stopPrank();
    }

    /// Eight bands - the most a schedule stores - read back exactly in all four schedules at once, a bound of exactly 1
    /// among them. A first band that disallows past the peg takes no extra band for the depeg: mint pegged still holds
    /// eight.
    function test_config_readsBackEightBandsInEverySchedule() public {
        IMinter.Config memory config_;
        config_.mintPeggedIncentiveConfig = ic(
            ua(110, 120, 130, 140, 150, 160, 170),
            ia(disallow, 90, 80, 70, 60, 50, 40, 30)
        );
        config_.redeemPeggedIncentiveConfig = ic(
            ua(100, 110, 120, 130, 140, 150, 160),
            ia(-90, -80, -70, -60, -50, 0, 10, 20)
        );
        config_.mintLeveragedIncentiveConfig = ic(
            ua(100, 110, 120, 130, 140, 150, 160),
            ia(-95, -85, -75, -65, -55, 5, 15, 25)
        );
        config_.redeemLeveragedIncentiveConfig = ic(
            ua(100, 110, 120, 130, 140, 150, 160),
            ia(disallow, 95, 85, 75, 65, 55, 45, 35)
        );
        _expectAccepted(config_);
    }

    /// A schedule needs at least one incentive ratio, in every schedule.
    function test_updateConfig_revertsOnAScheduleWithNoRatios_inEverySchedule() public {
        for (uint256 slot = 0; slot < 4; slot++) {
            _expectUpdateConfigReverts(
                _configWith(slot, ic(ua(), ia())),
                abi.encodeWithSelector(IMinter.TooFewIncentiveRatios.selector, _name(slot), 0, 1)
            );
        }
    }

    /// Every band needs its ratio - one more ratio than bounds - in every schedule, short either way.
    function test_updateConfig_revertsOnBoundsAndRatiosThatDoNotPair_inEverySchedule() public {
        for (uint256 slot = 0; slot < 4; slot++) {
            _expectUpdateConfigReverts(
                _configWith(slot, ic(ua(), ia(0, 0))),
                abi.encodeWithSelector(
                    IMinter.CollateralRatioBoundsIncentivesLengthsMismatch.selector,
                    _name(slot),
                    0,
                    2
                )
            );
            _expectUpdateConfigReverts(
                _configWith(slot, ic(ua(100), ia(0))),
                abi.encodeWithSelector(
                    IMinter.CollateralRatioBoundsIncentivesLengthsMismatch.selector,
                    _name(slot),
                    1,
                    1
                )
            );
        }
    }

    /// A ratio or a bound finer than its storage precision reverts rather than being rounded, in every schedule.
    function test_updateConfig_revertsOnValuesTooPreciseForStorage_inEverySchedule() public {
        for (uint256 slot = 0; slot < 4; slot++) {
            IMinter.IncentiveConfig memory schedule = ic(ua(100), ia(0, 50));
            schedule.incentiveRatios[1] += 1;
            _expectUpdateConfigReverts(
                _configWith(slot, schedule),
                abi.encodeWithSelector(IMinter.IncentiveRatioTooPrecise.selector, _name(slot), 0.005 ether + 1)
            );

            schedule = ic(ua(100, 130), ia(0, 0, 0));
            schedule.collateralRatioBandUpperBounds[1] += 1;
            _expectUpdateConfigReverts(
                _configWith(slot, schedule),
                abi.encodeWithSelector(IMinter.CollateralRatioBoundTooPrecise.selector, _name(slot), 1.3 ether + 1)
            );
        }
    }

    /// Bands below the peg are meaningless: a first bound under 1, or a later one at or under 1, reverts by name, in
    /// every schedule.
    function test_updateConfig_revertsOnBoundsBelowThePeg_inEverySchedule() public {
        for (uint256 slot = 0; slot < 4; slot++) {
            _expectUpdateConfigReverts(
                _configWith(slot, ic(ua(90), ia(0, 0))),
                abi.encodeWithSelector(
                    IMinter.InvalidCollateralRatioBoundValue.selector,
                    _name(slot),
                    0.9 ether,
                    0,
                    "first boundary must be >= 1"
                )
            );
            _expectUpdateConfigReverts(
                _configWith(slot, ic(ua(100, 100), ia(0, 0, 0))),
                abi.encodeWithSelector(
                    IMinter.InvalidCollateralRatioBoundValue.selector,
                    _name(slot),
                    1 ether,
                    1,
                    "boundary must be > 1"
                )
            );
        }
    }

    /// The first band must end exactly at the peg or disallow - depegged pricing never straddles a bound - in every
    /// schedule, a lone band included.
    function test_updateConfig_revertsOnAFirstBandThatNeitherEndsAtThePegNorDisallows_inEverySchedule() public {
        for (uint256 slot = 0; slot < 4; slot++) {
            _expectUpdateConfigReverts(
                _configWith(slot, ic(ua(130), ia(0, 0))),
                abi.encodeWithSelector(IMinter.NoDepegBoundaryOrDisallow.selector, _name(slot))
            );
            _expectUpdateConfigReverts(
                _configWith(slot, ic(ua(), ia(0))),
                abi.encodeWithSelector(IMinter.NoDepegBoundaryOrDisallow.selector, _name(slot))
            );
        }
    }

    /// A first band that disallows may end anywhere, or nowhere - a lone disallowing band is a schedule with no bound at
    /// all - in the schedules that may disallow: mint pegged (slot 0) and redeem leveraged (slot 3).
    function test_updateConfig_acceptsAFirstBandThatDisallows_withOrWithoutABound() public {
        _expectAccepted(_configWith(0, ic(ua(130), ia(disallow, 0))));
        _expectAccepted(_configWith(3, ic(ua(), ia(disallow))));
    }

    /// Bounds strictly increase: an equal or a lower bound reverts wherever it sits, naming it and the one before, in
    /// every schedule. The first pair can only fail after a first band that disallows - a first bound of 1 leaves no room
    /// below the second - so that position is tried in the schedules that may disallow.
    function test_updateConfig_revertsOnBoundsThatDoNotIncrease_inEverySchedule() public {
        for (uint256 slot = 0; slot < 4; slot++) {
            _expectUpdateConfigReverts(
                _configWith(slot, ic(ua(100, 130, 130, 150), ia(0, 0, 0, 0, 0))),
                abi.encodeWithSelector(
                    IMinter.CollateralRatioBoundValueNotIncreasing.selector,
                    _name(slot),
                    1.3 ether,
                    2,
                    1.3 ether
                )
            );
            _expectUpdateConfigReverts(
                _configWith(slot, ic(ua(100, 130, 150, 140), ia(0, 0, 0, 0, 0))),
                abi.encodeWithSelector(
                    IMinter.CollateralRatioBoundValueNotIncreasing.selector,
                    _name(slot),
                    1.4 ether,
                    3,
                    1.5 ether
                )
            );
        }
        for (uint256 slot = 0; slot <= 3; slot += 3) {
            _expectUpdateConfigReverts(
                _configWith(slot, ic(ua(150, 130), ia(disallow, 0, 0))),
                abi.encodeWithSelector(
                    IMinter.CollateralRatioBoundValueNotIncreasing.selector,
                    _name(slot),
                    1.3 ether,
                    1,
                    1.5 ether
                )
            );
        }
    }

    /// More than eight bands reverts in every schedule, and the revert reports the eight-band limit whatever the
    /// count offered.
    function test_updateConfig_revertsOnMoreThanEightBands_reportingTheLimit_inEverySchedule() public {
        for (uint256 bands = 9; bands <= 10; bands++) {
            IMinter.IncentiveConfig memory schedule;
            schedule.collateralRatioBandUpperBounds = new uint256[](bands - 1);
            for (uint256 i = 0; i < bands - 1; i++) {
                schedule.collateralRatioBandUpperBounds[i] = 1 ether + i * 0.1 ether;
            }
            schedule.incentiveRatios = new int256[](bands);
            for (uint256 slot = 0; slot < 4; slot++) {
                _expectUpdateConfigReverts(
                    _configWith(slot, schedule),
                    abi.encodeWithSelector(
                        IMinter.TooManyIncentiveRatios.selector,
                        _name(slot),
                        bands,
                        ConfigIncentiveLib.MAX_BANDS
                    )
                );
            }
        }
    }

    /// Redeeming pegged and minting leveraged can never be disallowed: their ratios live in (-1, 1), so +1 and -1 are
    /// revert and the values just inside them are accepted.
    function test_updateConfig_neverDisallowsPeggedRedemptionOrLeveragedMinting() public {
        for (uint256 slot = 1; slot <= 2; slot++) {
            IMinter.IncentiveConfig memory schedule = ic(ua(100), ia(0, 0));
            schedule.incentiveRatios[1] = 1 ether;
            _expectUpdateConfigReverts(
                _configWith(slot, schedule),
                abi.encodeWithSelector(
                    IMinter.InvalidIncentiveRatioValue.selector,
                    _name(slot),
                    1,
                    1 ether,
                    "must be in (-1, 1)"
                )
            );
            schedule = ic(ua(100), ia(0, 0));
            schedule.incentiveRatios[0] = -1 ether;
            _expectUpdateConfigReverts(
                _configWith(slot, schedule),
                abi.encodeWithSelector(
                    IMinter.InvalidIncentiveRatioValue.selector,
                    _name(slot),
                    0,
                    -1 ether,
                    "must be in (-1, 1)"
                )
            );
            // one storage step inside each end
            schedule = ic(ua(100), ia(0, 0));
            schedule.incentiveRatios[0] = -1 ether + int256(10 ** (18 - ConfigIncentiveLib.INCENTIVE_RATIO_DECIMALS));
            schedule.incentiveRatios[1] = 1 ether - int256(10 ** (18 - ConfigIncentiveLib.INCENTIVE_RATIO_DECIMALS));
            _expectAccepted(_configWith(slot, schedule));
        }
    }

    /// The highest band of redeem pegged and mint leveraged never subsidises - above the last bound a subsidy would have
    /// no end - so a negative ratio there reverts, however many bands; a free highest band is accepted, and so are
    /// subsidies below it.
    function test_updateConfig_revertsOnASubsidyInTheHighestBand_ofRedeemPeggedAndMintLeveraged() public {
        int256 step = int256(10 ** (18 - ConfigIncentiveLib.INCENTIVE_RATIO_DECIMALS));
        for (uint256 slot = 1; slot <= 2; slot++) {
            _expectAccepted(_configWith(slot, ic(ua(100, 130), ia(-50, -20, 0))));
            IMinter.IncentiveConfig memory schedule = ic(ua(100), ia(0, 0));
            schedule.incentiveRatios[1] = -step;
            _expectUpdateConfigReverts(
                _configWith(slot, schedule),
                abi.encodeWithSelector(
                    IMinter.InvalidIncentiveRatioValue.selector,
                    _name(slot),
                    1,
                    -step,
                    "highest band must be >= 0"
                )
            );
            _expectUpdateConfigReverts(
                _configWith(slot, ic(ua(100, 130), ia(-50, -20, -10))),
                abi.encodeWithSelector(
                    IMinter.InvalidIncentiveRatioValue.selector,
                    _name(slot),
                    2,
                    -0.001 ether,
                    "highest band must be >= 0"
                )
            );
        }
    }

    /// Minting pegged and redeeming leveraged can never be subsidised: their ratios live in [0, 1], so a negative ratio
    /// and one above 1 revert, and 0 and 1 (disallow) are accepted.
    function test_updateConfig_neverSubsidisesPeggedMintingOrLeveragedRedemption() public {
        int256 step = int256(10 ** (18 - ConfigIncentiveLib.INCENTIVE_RATIO_DECIMALS));
        for (uint256 slot = 0; slot <= 3; slot += 3) {
            IMinter.IncentiveConfig memory schedule = ic(ua(100), ia(0, 0));
            schedule.incentiveRatios[1] = -step;
            _expectUpdateConfigReverts(
                _configWith(slot, schedule),
                abi.encodeWithSelector(
                    IMinter.InvalidIncentiveRatioValue.selector,
                    _name(slot),
                    1,
                    -step,
                    "must be in [0, 1]"
                )
            );
            schedule = ic(ua(100), ia(0, 0));
            schedule.incentiveRatios[0] = 1 ether + step;
            _expectUpdateConfigReverts(
                _configWith(slot, schedule),
                abi.encodeWithSelector(
                    IMinter.InvalidIncentiveRatioValue.selector,
                    _name(slot),
                    0,
                    1 ether + step,
                    "must be in [0, 1]"
                )
            );
            _expectAccepted(_configWith(slot, ic(ua(100), ia(disallow, 0))));
        }
    }

    /// A disallow may sit only in the first band, so blocking never carves into a healthy schedule: a disallow in a
    /// later band reverts, with or without one in the first.
    function test_updateConfig_allowsADisallowOnlyInTheFirstBand() public {
        for (uint256 slot = 0; slot <= 3; slot += 3) {
            _expectAccepted(_configWith(slot, ic(ua(120), ia(disallow, 50))));
            _expectUpdateConfigReverts(
                _configWith(slot, ic(ua(100), ia(0, disallow))),
                abi.encodeWithSelector(
                    IMinter.InvalidIncentiveRatioValue.selector,
                    _name(slot),
                    1,
                    1 ether,
                    "disallow (1) must be at index 0"
                )
            );
            _expectUpdateConfigReverts(
                _configWith(slot, ic(ua(120), ia(disallow, disallow))),
                abi.encodeWithSelector(
                    IMinter.InvalidIncentiveRatioValue.selector,
                    _name(slot),
                    1,
                    1 ether,
                    "disallow (1) must be at index 0"
                )
            );
        }
    }

    /// A collateral-ratio bound too wide for its storage field reverts by name, in every schedule, rather than
    /// stored truncated.
    function test_updateConfig_revertsOnABoundTooLargeForItsStorage_inEverySchedule() public {
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
