// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {HolderCaptureLib} from "@harbor-script/holders/HolderCaptureLib.sol";
import {mcapMintersConfig} from "@harbor-script/src/Deploy_MCAP_Minter.sol";

import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {MarketUpgradeRun} from "@harbor-test/harness/MarketUpgradeRun.sol";

/// @notice The shared market upgrade, `UpgradeMarketToV3.upgradeMarketsToV3`, on the live MCAP::fxUSD market at the
///         block of a committed holder capture: deployed and never used, so its pools are empty and the capture lists
///         no holders. What it checks is the minter's config, which the upgrade loads again through Minter_v3's loader.
contract UpgradeMarketToV3Test is Test {
    string internal constant CAPTURE = "test/fixtures/holders-25272609/";

    MarketUpgradeRun internal upgrade;
    address internal minter;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), HolderCaptureLib.captureBlock(CAPTURE));
        (, Config_MinterMarket[] memory markets) = mcapMintersConfig();
        Config_MinterMarket[] memory upgraded = new Config_MinterMarket[](1);
        upgraded[0] = markets[0]; // MCAP::fxUSD
        upgrade = new MarketUpgradeRun(upgraded, CAPTURE);
        minter = new HarborDeployRun(address(0), address(0), "harbor_v1", "mainnet", HarborDeployRun.Cut.Whole)
            .minterAddress(markets[0]);
    }

    /// The upgrade moves the minter to a new implementation and keeps its stored config: loaded again through
    /// Minter_v3's loader, the config reads back exactly as Minter_v2 stored it.
    function test_upgradeKeepsTheStoredConfig() public {
        IMinter.Config memory stored = IMinter(minter).config();
        bytes32 implementationBefore = vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT);

        upgrade.run("harbor_v1");

        assertNotEq(vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT), implementationBefore, "the minter is upgraded");
        assertEq(keccak256(abi.encode(IMinter(minter).config())), keccak256(abi.encode(stored)), "the config is kept");
    }

    /// A config Minter_v3's loader refuses - a subsidy in redeem pegged's highest band, which Minter_v2 accepts - reverts
    /// the market's whole upgrade with the loader's own error, and the minter stays on Minter_v2.
    function test_upgradeRefusesAConfigMinterV3Rejects() public {
        IMinter.Config memory config = IMinter(minter).config();
        uint256 highest = config.redeemPeggedIncentiveConfig.incentiveRatios.length - 1;
        config.redeemPeggedIncentiveConfig.incentiveRatios[highest] = -0.01 ether;
        vm.startPrank(IBaoOwnable(minter).owner());
        IMinter(minter).updateConfig(config);
        vm.stopPrank();
        bytes32 implementationBefore = vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT);

        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter_v3.InvalidIncentiveRatioValue.selector,
                "redeem pegged",
                highest,
                int256(-0.01 ether),
                "highest band must be >= 0"
            )
        );
        upgrade.run("harbor_v1");

        assertEq(vm.load(minter, ERC1967Utils.IMPLEMENTATION_SLOT), implementationBefore, "the minter stays on v2");
    }
}
