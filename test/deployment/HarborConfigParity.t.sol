// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {stdJson} from "forge-std/StdJson.sol";

import {BaoDeploymentTest} from "@bao-test/deployment/BaoDeploymentTest.sol";
import {HarborDeploymentTestingFoundry} from "@harbor-test/deployment/HarborDeploymentTesting.sol";
import {HarborKeys} from "@harbor-script/deployment/HarborKeys.sol";
import {DeploymentConfig} from "@bao-script/deployment/DeploymentConfig.sol";

contract HarborConfigParitySetup is BaoDeploymentTest {
    function setUp() public virtual override {
        super.setUp();
    }

    function _startHarbor(
        string memory json,
        string memory label
    ) internal returns (HarborDeploymentTestingFoundry harbor) {
        harbor = new HarborDeploymentTestingFoundry();
        vm.label(address(harbor), string.concat("harbor-", label));
        harbor.start(DeploymentConfig.fromJson(json), string.concat("parity:", label));
    }

    function _baseConfig(address owner) internal pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    '{"schemaVersion":1,"version":"v1.0.0","owner":"',
                    vm.toString(owner),
                    '","pegged":{"registryKey":"pegged"},"collateral":{"registryKey":"wrappedCollateral"}}'
                )
            );
    }

    function _peggedMetadataConfig(
        address owner,
        string memory name,
        string memory symbol,
        uint256 decimals
    ) internal pure returns (string memory) {
        return
            string(
                abi.encodePacked(
                    '{"schemaVersion":1,"version":"v1.0.0","owner":"',
                    vm.toString(owner),
                    '","pegged":{"registryKey":"pegged","name":"',
                    name,
                    '","symbol":"',
                    symbol,
                    '","decimals":',
                    vm.toString(decimals),
                    '},"collateral":{"registryKey":"wrappedCollateral"}}'
                )
            );
    }
}

contract HarborConfigParityTest is HarborConfigParitySetup {
    using stdJson for string;

    function test_configFileMatchesManualParameters_peggedMetadata_() public {
        address owner = makeAddr("parity-owner");
        string memory peggedName = "Bao USD";
        string memory peggedSymbol = "BAOUSD";
        uint256 peggedDecimals = 18;

        HarborDeploymentTestingFoundry configDriven = _startHarbor(
            _peggedMetadataConfig(owner, peggedName, peggedSymbol, peggedDecimals),
            "config"
        );
        HarborDeploymentTestingFoundry manual = _startHarbor(_baseConfig(owner), "manual");

        manual.setString(HarborKeys.PEGGED_NAME, peggedName);
        manual.setString(HarborKeys.PEGGED_SYMBOL, peggedSymbol);
        manual.setUint(HarborKeys.PEGGED_DECIMALS, peggedDecimals);

        assertEq(configDriven.hasPeggedName(), true, "config-driven pegged name set");
        assertEq(manual.hasPeggedName(), true, "manual pegged name set");
        assertEq(configDriven.hasPeggedSymbol(), true, "config-driven pegged symbol set");
        assertEq(manual.hasPeggedSymbol(), true, "manual pegged symbol set");
        assertEq(configDriven.hasPeggedDecimals(), true, "config-driven pegged decimals set");
        assertEq(manual.hasPeggedDecimals(), true, "manual pegged decimals set");

        assertEq(configDriven.getPeggedName(), manual.getPeggedName(), "registry pegged name parity");
        assertEq(configDriven.getPeggedSymbol(), manual.getPeggedSymbol(), "registry pegged symbol parity");
        assertEq(configDriven.getPeggedDecimals(), manual.getPeggedDecimals(), "registry pegged decimals parity");
    }

    function test_configUsdEth_matchesExpectedValues_() public view {
        string memory path = string.concat(vm.projectRoot(), "/script/config-USD-ETH.json");
        string memory json = vm.readFile(path);

        string memory peggedName = json.readString(".pegged.name");
        string memory peggedSymbol = json.readString(".pegged.symbol");
        uint256 peggedDecimals = json.readUint(".pegged.decimals");
        string memory collateralAddressRaw = json.readString(".collateral.address");
        address collateralAddress = vm.parseAddress(collateralAddressRaw);

        assertEq(peggedName, "Bao USD", "usd-eth pegged name");
        assertEq(peggedSymbol, "BAOUSD", "usd-eth pegged symbol");
        assertEq(peggedDecimals, 18, "usd-eth pegged decimals");
        assertEq(collateralAddress, address(0x1), "usd-eth collateral address");

        uint256[] memory mintPeggedBounds = json.readUintArray(
            ".minter.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds"
        );
        assertEq(mintPeggedBounds.length, 2, "usd-eth mint pegged bounds length");
        assertEq(mintPeggedBounds[0], 1300000000000000000, "usd-eth mint pegged bound[0]");
        assertEq(mintPeggedBounds[1], 1400000000000000000, "usd-eth mint pegged bound[1]");

        int256[] memory mintPeggedRatios = json.readIntArray(".minter.mintPeggedIncentiveConfig.incentiveRatios");
        assertEq(mintPeggedRatios.length, 3, "usd-eth mint pegged ratio length");
        assertEq(mintPeggedRatios[0], int256(1000000000000000000), "usd-eth mint pegged ratio[0]");
        assertEq(mintPeggedRatios[1], int256(10000000000000000), "usd-eth mint pegged ratio[1]");
        assertEq(mintPeggedRatios[2], int256(5000000000000000), "usd-eth mint pegged ratio[2]");

        uint256[] memory redeemPeggedBounds = json.readUintArray(
            ".minter.redeemPeggedIncentiveConfig.collateralRatioBandUpperBounds"
        );
        assertEq(redeemPeggedBounds.length, 4, "usd-eth redeem pegged bounds length");
        assertEq(redeemPeggedBounds[0], 1000000000000000000, "usd-eth redeem pegged bound[0]");
        assertEq(redeemPeggedBounds[3], 1500000000000000000, "usd-eth redeem pegged bound[3]");

        int256[] memory redeemPeggedRatios = json.readIntArray(".minter.redeemPeggedIncentiveConfig.incentiveRatios");
        assertEq(redeemPeggedRatios.length, 5, "usd-eth redeem pegged ratio length");
        assertEq(redeemPeggedRatios[0], int256(-7500000000000000), "usd-eth redeem pegged ratio[0]");
        assertEq(redeemPeggedRatios[4], int256(8000000000000000), "usd-eth redeem pegged ratio[4]");

        uint256[] memory mintLeveragedBounds = json.readUintArray(
            ".minter.mintLeveragedIncentiveConfig.collateralRatioBandUpperBounds"
        );
        assertEq(mintLeveragedBounds.length, 4, "usd-eth mint leveraged bounds length");
        assertEq(mintLeveragedBounds[0], 1000000000000000000, "usd-eth mint leveraged bound[0]");
        assertEq(mintLeveragedBounds[3], 1450000000000000000, "usd-eth mint leveraged bound[3]");

        int256[] memory mintLeveragedRatios = json.readIntArray(".minter.mintLeveragedIncentiveConfig.incentiveRatios");
        assertEq(mintLeveragedRatios.length, 5, "usd-eth mint leveraged ratio length");
        assertEq(mintLeveragedRatios[0], int256(-5000000000000000), "usd-eth mint leveraged ratio[0]");
        assertEq(mintLeveragedRatios[4], int256(7000000000000000), "usd-eth mint leveraged ratio[4]");

        uint256[] memory redeemLeveragedBounds = json.readUintArray(
            ".minter.redeemLeveragedIncentiveConfig.collateralRatioBandUpperBounds"
        );
        assertEq(redeemLeveragedBounds.length, 2, "usd-eth redeem leveraged bounds length");
        assertEq(redeemLeveragedBounds[0], 1050000000000000000, "usd-eth redeem leveraged bound[0]");
        assertEq(redeemLeveragedBounds[1], 1350000000000000000, "usd-eth redeem leveraged bound[1]");

        int256[] memory redeemLeveragedRatios = json.readIntArray(
            ".minter.redeemLeveragedIncentiveConfig.incentiveRatios"
        );
        assertEq(redeemLeveragedRatios.length, 3, "usd-eth redeem leveraged ratio length");
        assertEq(redeemLeveragedRatios[0], int256(1000000000000000000), "usd-eth redeem leveraged ratio[0]");
        assertEq(redeemLeveragedRatios[2], int256(12000000000000000), "usd-eth redeem leveraged ratio[2]");
    }
}
