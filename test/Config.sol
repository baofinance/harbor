// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {stdJson} from "forge-std/StdJson.sol";
import {Test} from "forge-std/Test.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";

abstract contract ConfigFile is Test {
    function readConfigFile(string memory fileName) internal view returns (IMinter.Config memory config) {
        string memory json = vm.readFile(fileName);

        config.mintPeggedIncentiveConfig = _readIncentiveConfig(json, "mintPeggedIncentiveConfig");
        config.mintLeveragedIncentiveConfig = _readIncentiveConfig(json, "mintLeveragedIncentiveConfig");
        config.redeemPeggedIncentiveConfig = _readIncentiveConfig(json, "redeemPeggedIncentiveConfig");
        config.redeemLeveragedIncentiveConfig = _readIncentiveConfig(json, "redeemLeveragedIncentiveConfig");
    }

    function readConfig(string memory style) internal view returns (IMinter.Config memory config) {
        config = readConfigFile(_filename(style));
    }

    function writeConfig(IMinter.Config memory config, string memory style) internal {
        // serialise the thresholds

        string memory json = _addIncentiveConfig(config.mintPeggedIncentiveConfig, "mintPeggedIncentiveConfig");
        json = _addIncentiveConfig(config.mintLeveragedIncentiveConfig, "mintLeveragedIncentiveConfig");
        json = _addIncentiveConfig(config.redeemPeggedIncentiveConfig, "redeemPeggedIncentiveConfig");
        json = _addIncentiveConfig(config.redeemLeveragedIncentiveConfig, "redeemLeveragedIncentiveConfig");

        vm.writeJson(json, _filename(style));
    }

    function _filename(string memory style) internal pure returns (string memory filename) {
        filename = string.concat("./results/config-", style, ".json");
    }

    function _readIncentiveConfig(
        string memory json,
        string memory name
    ) private pure returns (IMinter.IncentiveConfig memory incentiveConfig) {
        incentiveConfig.collateralRatioBandUpperBounds = stdJson.readUintArray(
            json,
            string.concat(".", name, ".collateralRatioBandUpperBounds")
        );
        incentiveConfig.incentiveRatios = stdJson.readIntArray(json, string.concat(".", name, ".incentiveRatios"));
    }

    function _addIncentiveConfig(
        IMinter.IncentiveConfig memory incentiveConfig,
        string memory name
    ) private returns (string memory json) {
        json = vm.serializeString(
            "config",
            name,
            vm.serializeUint(name, "collateralRatioBandUpperBounds", incentiveConfig.collateralRatioBandUpperBounds)
        );
        json = vm.serializeString(
            "config",
            name,
            vm.serializeInt(name, "incentiveRatios", incentiveConfig.incentiveRatios)
        );
    }
}
