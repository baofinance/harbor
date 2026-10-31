// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test, console2} from "forge-std/Test.sol";

import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {frozenPegsConfig} from "@harbor-script/src/AllMintersConfig.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {UpgradeMarketToV3} from "@harbor-script/src/UpgradeMarketToV3.sol";
import {FROZEN_MARKETS_CAPTURE} from "@harbor-script/Upgrade_MarketsToV3_mainnet.s.sol";
import {MarketSettings} from "@harbor-script/verify/v3-upgrade/MarketSettings.sol";

import {OracleSaltDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {FrozenMarketUpgradeRun} from "@harbor-test/harness/MarketUpgradeRun.sol";

/// @title UpgradedMarketsMatchANativeDeploy
/// @notice Each live market, upgraded from the state the pause froze, holds the settings a native v3 deploy of the same
///         market holds: those of its minter, with its reserve pool and tokens, of both its pools and of its manager -
///         config, owners, roles, the addresses each names, limits, windows and reward tokens. Its code is built from the
///         same source as a native deploy's, and the rehearsal checks its holdings carried over, so a market that passes
///         behaves as a native market would, holding what it holds.
/// @dev On a fork at the block after the capture, where every minter and pool is paused. The upgrade script's own
///      function upgrades each market of a peg. The production deploy then deploys the same peg beside it, under a salt
///      of its own, wired to the live oracles and owned and paid as production's. `MarketSettings` reads both markets
///      alike, and each address the native market names is read as the upgraded market's at the same deploy key. Every
///      difference is logged before the test fails. One test per peg, as `MarketVerificationOfEveryMarketTest` does, so
///      each stays within a test's gas and a failure names its peg.
contract UpgradedMarketsMatchANativeDeploy is Test {
    /// @dev The salt prefix the live markets were deployed under.
    string private constant LIVE_SALT_PREFIX = "harbor_v1";

    /// @dev The salt prefix the native deploy runs under, beside the live one.
    string private constant NATIVE_SALT_PREFIX = "native_v3";

    /// @dev The two markets compared and what compares them: the run that upgraded the live market, the run that
    ///      deployed the native one, the reader of both, and every contract each run placed, by deploy key - an address
    ///      in `nativeAddresses` is read as the one at the same index of `upgradedAddresses`.
    struct Comparison {
        HarborDeployer upgraded;
        HarborDeployer native;
        MarketSettings settings;
        address[] nativeAddresses;
        address[] upgradedAddresses;
    }

    /// The BTC markets, upgraded, hold the settings a native deploy of the BTC peg holds.
    function test_theBTCMarkets_holdANativeDeploysSettings() public {
        _compareWithANativeDeploy(0);
    }

    /// The ETH market, upgraded, holds the settings a native deploy of the ETH peg holds.
    function test_theETHMarket_holdsANativeDeploysSettings() public {
        _compareWithANativeDeploy(1);
    }

    /// The EUR markets, upgraded, hold the settings a native deploy of the EUR peg holds.
    function test_theEURMarkets_holdANativeDeploysSettings() public {
        _compareWithANativeDeploy(2);
    }

    /// The GOLD markets, upgraded, hold the settings a native deploy of the GOLD peg holds.
    function test_theGOLDMarkets_holdANativeDeploysSettings() public {
        _compareWithANativeDeploy(3);
    }

    /// The MCAP markets, upgraded, hold the settings a native deploy of the MCAP peg holds.
    function test_theMCAPMarkets_holdANativeDeploysSettings() public {
        _compareWithANativeDeploy(4);
    }

    /// The SILVER markets, upgraded, hold the settings a native deploy of the SILVER peg holds.
    function test_theSILVERMarkets_holdANativeDeploysSettings() public {
        _compareWithANativeDeploy(5);
    }

    /// @dev Upgrade the markets of the peg at `pegIndex` of `frozenPegsConfig`, deploy the peg natively beside them, and
    ///      require each contract of each market to hold the same settings in both.
    function _compareWithANativeDeploy(uint256 pegIndex) private {
        vm.createSelectFork(vm.rpcUrl("mainnet"), HolderCaptureLib.captureBlock(FROZEN_MARKETS_CAPTURE) + 1);
        Comparison memory c;
        Config_MinterMarket[] memory markets;
        {
            (ConfigPeg[6] memory pegs, Config_MinterMarket[][6] memory marketsByPeg) = frozenPegsConfig();
            markets = marketsByPeg[pegIndex];
            assertGt(markets.length, 0, "precondition: the peg has markets");

            FrozenMarketUpgradeRun upgraded = new FrozenMarketUpgradeRun(
                markets,
                FROZEN_MARKETS_CAPTURE,
                new UpgradeMarketToV3.OwnerOperations[](0)
            );
            // It reads the frozen markets on forks of its own, then returns to this one.
            vm.makePersistent(address(upgraded));
            upgraded.run(LIVE_SALT_PREFIX);

            OracleSaltDeployRun native = new OracleSaltDeployRun(
                upgraded.owner(),
                upgraded.treasury(),
                NATIVE_SALT_PREFIX,
                LIVE_SALT_PREFIX
            );
            native.ensureFactory();
            native.deploy(pegs[pegIndex], markets, true, markets);

            c.upgraded = upgraded;
            c.native = native;
        }
        c.settings = new MarketSettings();

        // Every contract each deploy places, by deploy key: the peg's pegged token, then each market's seven.
        c.nativeAddresses = new address[](1 + 7 * markets.length);
        c.upgradedAddresses = new address[](c.nativeAddresses.length);
        c.nativeAddresses[0] = c.native.peggedTokenAddress(markets[0]);
        c.upgradedAddresses[0] = c.upgraded.peggedTokenAddress(markets[0]);
        for (uint256 i = 0; i < markets.length; ++i) {
            address[7] memory nativeMarket = _placedByTheDeploy(c.native, markets[i]);
            address[7] memory upgradedMarket = _placedByTheDeploy(c.upgraded, markets[i]);
            for (uint256 k = 0; k < 7; ++k) {
                c.nativeAddresses[1 + 7 * i + k] = nativeMarket[k];
                c.upgradedAddresses[1 + 7 * i + k] = upgradedMarket[k];
            }
        }

        uint256 differences;
        for (uint256 i = 0; i < markets.length; ++i) {
            Config_MinterMarket market = markets[i];
            string memory key = c.upgraded.minterKey(market);
            differences += _differences(
                c,
                key,
                c.settings.serializeMinter(string.concat("upgraded ", key), c.upgraded, market),
                c.settings.serializeMinter(string.concat("native ", key), c.native, market)
            );
            for (uint256 p = 0; p < 2; ++p) {
                HarborDeployer.StabilityPoolType poolType = HarborDeployer.StabilityPoolType(p);
                key = c.upgraded.stabilityPoolKey(market, poolType);
                c.settings.serializePool(string.concat("upgraded ", key), c.upgraded, market, poolType);
                c.settings.serializePool(string.concat("native ", key), c.native, market, poolType);
                differences += _differences(
                    c,
                    key,
                    c.settings.serializePoolV3(string.concat("upgraded ", key), c.upgraded, market, poolType),
                    c.settings.serializePoolV3(string.concat("native ", key), c.native, market, poolType)
                );
            }
            key = c.upgraded.stabilityPoolManagerKey(market);
            c.settings.serializeManager(string.concat("upgraded ", key), c.upgraded, market);
            c.settings.serializeManager(string.concat("native ", key), c.native, market);
            differences += _differences(
                c,
                key,
                c.settings.serializeManagerV2(string.concat("upgraded ", key), c.upgraded, market),
                c.settings.serializeManagerV2(string.concat("native ", key), c.native, market)
            );
        }
        assertEq(differences, 0, "the settings logged above differ from a native deploy's");
    }

    /// @dev The seven contracts `deployment` places for `market`, in a fixed order: its minter, reserve pool, genesis,
    ///      collateral pool, leveraged pool, manager and leveraged token.
    function _placedByTheDeploy(
        HarborDeployer deployment,
        Config_MinterMarket market
    ) private returns (address[7] memory placed) {
        placed[0] = deployment.minterAddress(market);
        placed[1] = deployment.reservePoolAddress(market);
        placed[2] = deployment.genesisAddress(market);
        placed[3] = deployment.stabilityPoolAddress(market, HarborDeployer.StabilityPoolType.Collateral);
        placed[4] = deployment.stabilityPoolAddress(market, HarborDeployer.StabilityPoolType.Leveraged);
        placed[5] = deployment.stabilityPoolManagerAddress(market);
        placed[6] = deployment.leveragedTokenAddress(market);
    }

    /// @dev How many settings of the contract `label` differ between the upgraded market's record, `upgradedJson`, and
    ///      the native one's, `nativeJson`, each logged: a setting only one record holds, or a value that differs once
    ///      an address the native deploy placed is read as the upgraded market's at the same deploy key.
    function _differences(
        Comparison memory c,
        string memory label,
        string memory upgradedJson,
        string memory nativeJson
    ) private view returns (uint256 count) {
        string[] memory keys = vm.parseJsonKeys(upgradedJson, "$");
        for (uint256 k = 0; k < keys.length; ++k) {
            string memory path = string.concat(".", keys[k]);
            string memory upgradedValue = vm.parseJsonString(upgradedJson, path);
            if (!vm.keyExistsJson(nativeJson, path)) {
                console2.log(string.concat(label, " ", keys[k], ": upgraded ", upgradedValue, ", native has none"));
                ++count;
            } else {
                string memory nativeValue = vm.parseJsonString(nativeJson, path);
                for (uint256 a = 0; a < c.nativeAddresses.length; ++a) {
                    if (keccak256(bytes(nativeValue)) == keccak256(bytes(vm.toString(c.nativeAddresses[a])))) {
                        nativeValue = vm.toString(c.upgradedAddresses[a]);
                        break;
                    }
                }
                if (keccak256(bytes(upgradedValue)) != keccak256(bytes(nativeValue))) {
                    console2.log(
                        string.concat(label, " ", keys[k], ": upgraded ", upgradedValue, ", native ", nativeValue)
                    );
                    ++count;
                }
            }
        }
        string[] memory nativeKeys = vm.parseJsonKeys(nativeJson, "$");
        for (uint256 k = 0; k < nativeKeys.length; ++k) {
            string memory path = string.concat(".", nativeKeys[k]);
            if (!vm.keyExistsJson(upgradedJson, path)) {
                console2.log(
                    string.concat(
                        label,
                        " ",
                        nativeKeys[k],
                        ": native ",
                        vm.parseJsonString(nativeJson, path),
                        ", upgraded has none"
                    )
                );
                ++count;
            }
        }
    }
}
