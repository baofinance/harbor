// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {Minter_v3} from "@harbor/minter/Minter_v3.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {Deploy_BTC_Minter} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {Deploy_EUR_Minter} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {Deploy_GOLD_Minter} from "@harbor-script/src/Deploy_GOLD_Minter.sol";
import {Deploy_MCAP_Minter} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {Deploy_SILVER_Minter} from "@harbor-script/src/Deploy_SILVER_Minter.sol";

/// @title MinterUpgradePreflight — is every deployed minter's stored config one Minter_v3 accepts?
/// @notice The v2 -> v3 upgrade carries each minter's incentive config across unchecked: `upgradeToAndCall` swaps the
///         implementation and v3 reads the stored encoding as it stands. v3's loader refuses schedules v2's accepted -
///         a subsidy in the highest band of redeem pegged or mint leveraged, a bound too wide for its field - and v3's
///         band walks rely on that: the leveraged mint never subsidises its highest band. So each deployed minter's
///         config is loaded, on a mainnet fork, through a fresh Minter_v3's own `updateConfig`, and must be accepted
///         and read back unchanged.
///
///         PASSES iff every deployed minter's config is accepted and reads back exactly. FAILS - naming each minter -
///         if the v3 loader refuses its config (the refusal is logged) or would hold it differently.
///
///         RUN BEFORE UPGRADING:
///           `forge test --mp script/verify/minter-v3-upgrade/MinterUpgradePreflight.t.sol -vv`  (needs MAINNET_RPC_URL)
///         Red -> update the named minter's config, under v2, to one the v3 loader accepts, and re-run.
///
///         Read-only: nothing deployed is touched. Minters are enumerated through the deploy scripts' own salt
///         derivation, so this checks exactly the set the deploy made.
contract MinterUpgradePreflight is
    Test,
    Deploy_BTC_Minter,
    Deploy_ETH_Minter,
    Deploy_EUR_Minter,
    Deploy_GOLD_Minter,
    Deploy_MCAP_Minter,
    Deploy_SILVER_Minter
{
    uint256 internal deployedCount;
    uint256 internal refusedCount;
    uint256 internal readsBackDifferentlyCount;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        _setSaltPrefix("harbor_v1");
    }

    function test_everyDeployedConfigLoadsUnderMinterV3() public {
        Config_MinterMarket[] memory markets;
        (, markets) = createBTCMintersConfig();
        _check(markets);
        (, markets) = createETHMintersConfig();
        _check(markets);
        (, markets) = createEURMintersConfig();
        _check(markets);
        (, markets) = createGOLDMintersConfig();
        _check(markets);
        (, markets) = createMCAPMintersConfig();
        _check(markets);
        (, markets) = createSILVERMintersConfig();
        _check(markets);

        console.log(
            "Pre-flight: %d minters deployed, %d configs refused by the v3 loader, %d read back differently",
            deployedCount,
            refusedCount,
            readsBackDifferentlyCount
        );
        assertGt(deployedCount, 0, "no minters checked - fork or enumeration broken");
        assertEq(refusedCount, 0, "a deployed minter holds a config the v3 loader refuses - see REFUSED in the log");
        assertEq(readsBackDifferentlyCount, 0, "a config would read back differently under v3 - see the log");
    }

    function _check(Config_MinterMarket[] memory markets) internal {
        for (uint256 i = 0; i < markets.length; i++) {
            address minter = minterAddress(markets[i]);
            if (minter.code.length == 0) {
                continue; // not deployed - nothing to upgrade
            }
            deployedCount++;
            string memory key = minterKey(markets[i]);
            IMinter.Config memory stored = IMinter(minter).config();

            // A Minter_v3 over the same tokens, owned by this check, so the v3 loader runs on the stored config exactly
            // as the upgraded minter's own `updateConfig` would.
            address candidate = UnsafeUpgrades.deployUUPSProxy(
                address(
                    new Minter_v3(
                        IMinter(minter).WRAPPED_COLLATERAL_TOKEN(),
                        IMinter(minter).PEGGED_TOKEN(),
                        IMinter(minter).LEVERAGED_TOKEN()
                    )
                ),
                abi.encodeCall(Minter_v3.initialize, (address(this), makeAddr("pendingOwner")))
            );

            try IMinter(candidate).updateConfig(stored) {
                if (keccak256(abi.encode(IMinter(candidate).config())) != keccak256(abi.encode(stored))) {
                    readsBackDifferentlyCount++;
                    console.log(string.concat("READS BACK DIFFERENTLY: ", key));
                } else {
                    console.log(string.concat(key, " accepted"));
                }
            } catch (bytes memory reason) {
                // Only the loader's own refusals are findings about the config; anything else is a fault in this
                // check or the fork, and fails it as it stands.
                string memory refusal = _loaderRefusal(reason);
                if (bytes(refusal).length == 0) {
                    assembly {
                        revert(add(reason, 0x20), mload(reason))
                    }
                }
                refusedCount++;
                // the whole payload decodes with `cast decode-error`
                console.log(string.concat("REFUSED: ", key, " ", refusal, " ", vm.toString(reason)));
            }
        }
    }

    /// @dev The name of the v3 config loader's error `reason` carries, or empty when it is not one of them.
    function _loaderRefusal(bytes memory reason) internal pure returns (string memory) {
        if (reason.length < 4) {
            return "";
        }
        bytes4 selector = bytes4(reason);
        if (selector == IMinter_v3.TooFewIncentiveRatios.selector) {
            return "TooFewIncentiveRatios";
        }
        if (selector == IMinter_v3.TooManyIncentiveRatios.selector) {
            return "TooManyIncentiveRatios";
        }
        if (selector == IMinter_v3.CollateralRatioBoundsIncentivesLengthsMismatch.selector) {
            return "CollateralRatioBoundsIncentivesLengthsMismatch";
        }
        if (selector == IMinter_v3.IncentiveRatioTooPrecise.selector) {
            return "IncentiveRatioTooPrecise";
        }
        if (selector == IMinter_v3.InvalidIncentiveRatioValue.selector) {
            return "InvalidIncentiveRatioValue";
        }
        if (selector == IMinter_v3.CollateralRatioBoundTooPrecise.selector) {
            return "CollateralRatioBoundTooPrecise";
        }
        if (selector == IMinter_v3.InvalidCollateralRatioBoundValue.selector) {
            return "InvalidCollateralRatioBoundValue";
        }
        if (selector == IMinter_v3.CollateralRatioBoundValueNotIncreasing.selector) {
            return "CollateralRatioBoundValueNotIncreasing";
        }
        if (selector == IMinter_v3.NoDepegBoundaryOrDisallow.selector) {
            return "NoDepegBoundaryOrDisallow";
        }
        return "";
    }
}
