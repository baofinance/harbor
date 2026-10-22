// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {Deploy_BTC_Minter} from "@harbor-script/src/Deploy_BTC_Minter.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {Deploy_EUR_Minter} from "@harbor-script/src/Deploy_EUR_Minter.sol";
import {Deploy_GOLD_Minter} from "@harbor-script/src/Deploy_GOLD_Minter.sol";
import {Deploy_MCAP_Minter} from "@harbor-script/src/Deploy_MCAP_Minter.sol";
import {Deploy_SILVER_Minter} from "@harbor-script/src/Deploy_SILVER_Minter.sol";
import {MarketUpgradeRun} from "@harbor-test/harness/MarketUpgradeRun.sol";

/// @title MinterUpgradePreflight — will every deployed minter work once its market is upgraded?
/// @notice Each deployed market is upgraded on a fork by `UpgradeMarketToV3.upgradeMarketsToV3`, the function the
///         upgrade script runs, with the holder capture this run is pointed at, and checked for the two things the
///         upgrade carries across from Minter_v2:
///
///         The incentive config. The upgrade loads each minter's stored config through Minter_v3's own loader, which
///         reverts on schedules v2's accepted - a subsidy in the highest band of redeem pegged or mint leveraged, a
///         bound too wide for its field - and v3's band walks rely on that: the leveraged mint never subsidises its
///         highest band. A config the loader refuses reverts the market's whole upgrade. FAILS - naming each market -
///         if the loader refuses its config (the revert is logged) or the upgraded minter reads it back differently.
///
///         The backing. v3 halts a market whose recorded backing exceeds what its wrapped holding converts to at the
///         low edge of the oracle's rate band - every mint and redeem reverts `UnrecognisedImpairment` - a check v2
///         never made. So v3's own `impairment()` says, on each upgraded market, whether the record is covered. FAILS
///         - naming each market - if one would halt the moment it is upgraded.
///
///         RUN BEFORE UPGRADING, through `run-preflight --holders-dir <capture>` (needs MAINNET_RPC_URL, archival at the
///         capture's block), with the capture the upgrade will use.
///         Config red -> update the named minter's config, under v2, to one the v3 loader accepts, and re-run.
///         Backing red -> the named market halts on upgrade until its rate recovers, its shortfall is donated, or it
///         is recognised after the upgrade: decide which before upgrading it.
///
///         Read-only: everything happens on a mainnet fork at the capture's block, so nothing deployed is touched.
///         Markets are enumerated through the deploy scripts' own configs, so this checks exactly the set the deploy
///         made.
contract MinterUpgradePreflight is
    Test,
    Deploy_BTC_Minter,
    Deploy_ETH_Minter,
    Deploy_EUR_Minter,
    Deploy_GOLD_Minter,
    Deploy_MCAP_Minter,
    Deploy_SILVER_Minter
{
    /// @dev The capture the upgrade reads its pools' holders from. The fork is at its block, read from its manifest.
    string internal holdersDir;
    uint256 internal deployedCount;
    uint256 internal revertsOnLoadCount;
    uint256 internal readsBackDifferentlyCount;
    uint256 internal wouldHaltCount;

    function setUp() public {
        holdersDir = vm.envOr("HOLDERS_DIR", HolderCaptureLib.DEFAULT_DIRECTORY);
        vm.createSelectFork(vm.rpcUrl("mainnet"), HolderCaptureLib.captureBlock(holdersDir));
        _setSaltPrefix("harbor_v1");
    }

    function test_everyDeployedMinterWorksUnderMinterV3() public {
        Config_MinterMarket[] memory markets;
        (, markets) = createBTCMintersConfig();
        _upgradeAndCheck(markets);
        (, markets) = createETHMintersConfig();
        _upgradeAndCheck(markets);
        (, markets) = createEURMintersConfig();
        _upgradeAndCheck(markets);
        (, markets) = createGOLDMintersConfig();
        _upgradeAndCheck(markets);
        (, markets) = createMCAPMintersConfig();
        _upgradeAndCheck(markets);
        (, markets) = createSILVERMintersConfig();
        _upgradeAndCheck(markets);

        console.log(
            "Pre-flight: %d minters deployed, %d configs the v3 loader reverts on, %d read back differently",
            deployedCount,
            revertsOnLoadCount,
            readsBackDifferentlyCount
        );
        console.log("Pre-flight: %d would halt under v3", wouldHaltCount);
        assertGt(deployedCount, 0, "no minters checked - fork or enumeration broken");
        assertEq(
            revertsOnLoadCount,
            0,
            "a deployed minter holds a config the v3 loader reverts on - see REVERTED in the log"
        );
        assertEq(readsBackDifferentlyCount, 0, "a config would read back differently under v3 - see the log");
        assertEq(wouldHaltCount, 0, "a deployed minter's record exceeds its holding at the min rate - see WOULD HALT");
    }

    /// @dev Upgrades each deployed market of `markets`, one at a time, and counts what it finds. Only the config
    ///      loader's own reverts are findings about a market; any other revert is a fault in the upgrade or the fork,
    ///      and fails this as it stands.
    function _upgradeAndCheck(Config_MinterMarket[] memory markets) internal {
        for (uint256 i = 0; i < markets.length; i++) {
            address minter = minterAddress(markets[i]);
            if (minter.code.length == 0) {
                continue; // not deployed - nothing to upgrade
            }
            deployedCount++;
            string memory key = minterKey(markets[i]);
            IMinter.Config memory stored = IMinter(minter).config();

            Config_MinterMarket[] memory market = new Config_MinterMarket[](1);
            market[0] = markets[i];
            MarketUpgradeRun upgrade = new MarketUpgradeRun(market, holdersDir);
            try upgrade.run("harbor_v1") {
                if (keccak256(abi.encode(IMinter(minter).config())) != keccak256(abi.encode(stored))) {
                    readsBackDifferentlyCount++;
                    console.log(string.concat("READS BACK DIFFERENTLY: ", key));
                }
                (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
                if (recorded > held) {
                    wouldHaltCount++;
                    console.log(
                        string.concat("WOULD HALT: ", key, " recorded ", vm.toString(recorded), " held ", vm.toString(held))
                    );
                } else {
                    console.log(
                        string.concat(key, " upgraded; covered: recorded ", vm.toString(recorded), " held ", vm.toString(held))
                    );
                }
            } catch (bytes memory reason) {
                string memory loaderError = _loaderErrorName(reason);
                if (bytes(loaderError).length == 0) {
                    assembly {
                        revert(add(reason, 0x20), mload(reason))
                    }
                }
                revertsOnLoadCount++;
                // the whole payload decodes with `cast decode-error`
                console.log(string.concat("REVERTED: ", key, " ", loaderError, " ", vm.toString(reason)));
            }
        }
    }

    /// @dev The name of the v3 config loader's error `reason` carries, or empty when it is not one of them.
    function _loaderErrorName(bytes memory reason) internal pure returns (string memory) {
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
