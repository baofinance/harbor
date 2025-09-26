// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "test/Useful.sol";
import {TestMinterFeeSetUp} from "test/Minter_fees.t.sol";
import {TestGraph} from "test/Graph.t.sol";

abstract contract TestGraphMinter is TestGraph, TestMinterFeeSetUp {
    string file;
    uint256 rate;
    uint256 multiplier = 118; // a percentage increase
    uint256 mintFee;
    uint256 minted;
    uint256 collateralUsed;
    uint256 redeemFee;
    uint256 redeemed;
    uint256 collateralReturned;

    function setUp() public virtual override {
        super.setUp();

        startX = 0;
        finishX = startX + 1e30;

        file = openFile(
            "minter",
            sa("supply", "mintFee", "minted", "collateralUsed", "redeemFee", "redeemed", "collateralReturned")
        );
    }

    function incrementX() internal virtual override {
        currentX = (currentX * multiplier) / 100; // exponential growth
    }

    function setDown() internal override {
        vm.closeFile(file);
    }

    function doActions() internal virtual;

    function doOneX() internal virtual override {
        // write a gnuplot data file line for fees, invariant and liquidation

        doActions();

        writeLine(file, ua(mintFee, minted, collateralUsed, redeemFee, redeemed, collateralReturned));
    }
}

abstract contract TestGraphMinterPegged is TestGraphMinter {
    function context() internal pure override returns (string memory) {
        return "_pegged";
    }

    function doActions() internal virtual override {}
}
