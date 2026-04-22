// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Test} from "forge-std/Test.sol";

import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@harbor-test/Useful.sol";

abstract contract TestGraphs is Test {
    int256 NaN = type(int256).max;
    uint256 uNaN = type(uint256).max;

    function context() internal pure virtual returns (string memory) {
        return "";
    }

    function openFile(string memory name, string[] memory header) internal returns (string memory file) {
        file = string.concat("./results/", string.concat(name, context()), ".csv");
        if (vm.exists(file)) vm.removeFile(file);
        vm.writeLine(file, Useful.join(header, ","));
    }

    function writeLine(string memory file, int[] memory data) internal {
        string[] memory strData = new string[](data.length);
        for (uint i = 0; i < data.length; i++) {
            strData[i] = data[i] == NaN ? "NaN" : Useful.toStringScaled(data[i], 18);
        }
        vm.writeLine(file, Useful.join(strData, ","));
    }

    function writeLine(string memory file, uint[] memory data) internal {
        string[] memory strData = new string[](data.length);
        for (uint i = 0; i < data.length; i++) {
            strData[i] = data[i] == uNaN ? "NaN" : Useful.toStringScaled(data[i], 18);
        }
        vm.writeLine(file, Useful.join(strData, ","));
    }
}
