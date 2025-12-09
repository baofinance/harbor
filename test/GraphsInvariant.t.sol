// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "src/interfaces/IMinter.sol";

import "test/Useful.sol";
import {TestCollateralRatioRangeSetUp} from "test/CollateralRatio.t.sol";
import {TestGraphs} from "test/Graphs.t.sol";

contract TestGraphsInvariant is TestGraphs, TestCollateralRatioRangeSetUp {
    string invariantFile;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public override {
        super.setUp();
        deal(address(wrappedCollateralToken), reservePool, 1000 ether);

        invariantFile = openFile(
            "invariant",
            sa("Collateral Ratio", "Leverage Ratio", "Pegged NAV", "Leveraged NAV", "Collateral NAV")
        );
    }

    function setDown() internal override {
        vm.closeFile(invariantFile);
    }

    function doOneCollateralRatio() internal override {
        // write a gnuplot data file line for fees, invariant and liquidation

        writeLine(
            invariantFile,
            ua(
                currentCollateralRatio,
                IMinter(minter).leverageRatio(),
                IMinter(minter).peggedTokenPrice(),
                IMinter(minter).leveragedTokenPrice(),
                currentPrice
            )
        );
    }
}
