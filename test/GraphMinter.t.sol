// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";

import {StabilityPool_v1} from "src/minter/StabilityPool_v1.sol";

import "test/Useful.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {TestMinterFeeSetUp} from "test/Minter_fees.t.sol";
import {Array} from "test/Array.sol";
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
