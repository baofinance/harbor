// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//import { Test } from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IRebalancePool} from "src/interfaces/IRebalancePool.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";

import "test/Useful.sol";
import {TestRebalancePool2SetUp} from "test/Liquidate.t.sol";
import {Array} from "test/Array.sol";

contract TestGraphs is TestRebalancePool2SetUp {
    int256 NaN = type(int256).max;
    uint256 uNaN = type(uint256).max;

    function setUp() public virtual override {
        super.setUp();
        deal(address(collateralToken), address(this), 1000 ether);
        IERC20(collateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(rebalancePool, type(uint256).max);
        IERC20(peggedToken).approve(rebalancePoolLeveraged, type(uint256).max);
        vm.prank(owner);
        IBaoRoles(minter).grantRoles(address(this), zeroFeeRole);
        assertEq(0, IERC20(collateralToken).balanceOf(reservePool), "reserve pool should be empty");
    }

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

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

contract TestGraphBasicCalculations is TestGraphs {
    // TODO: collateral ratio
    // TODO: leveraged Ratio
    // TODO: pegged price on depeg
    // under scenrios of
    // price change
    // redeem all pegged
    // redeem all leveraged
    // price drops and we redeem all pegged
    // price drops and we redeem all leveraged

    function setUp() public override {
        super.setUp();
        deal(address(collateralToken), reservePool, 1000 ether);
    }

    function openFile(string memory name) internal returns (string memory file) {
        file = openFile(
            string.concat("basicCalculations-", name),
            sa(
                "Collateral",
                "Price",
                "Pegged",
                "PeggedTokenPrice",
                "Leveraged",
                "LeveragedTokenPrice",
                "Invariant",
                "CollateralRatio",
                "LeveragedRatio"
            )
        );
    }

    function writeOneLine(string memory file) internal {
        int256 collateral = int256(IMinter(minter).collateralTokenBalance());
        (uint uprice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        int256 price = int256(uprice);
        int256 pegged = int256(IMinter(minter).peggedTokenBalance());
        int256 peggedTokenPrice = int256(IMinter(minter).peggedTokenPrice());
        int256 leveraged = int256(IMinter(minter).leveragedTokenBalance());
        int256 leveragedTokenPrice = int256(IMinter(minter).leveragedTokenPrice());
        int256 invariant = (int256(collateral * price) -
            int256(pegged * peggedTokenPrice + leveraged * leveragedTokenPrice)) / 1 ether;
        int256 collateralRatio;
        try IMinter(minter).collateralRatio() returns (uint256 cr) {
            collateralRatio = int256(cr);
        } catch {
            collateralRatio = NaN;
        }
        int256 leverageRatio;
        try IMinter(minter).leverageRatio() returns (uint256 lr) {
            leverageRatio = int256(lr);
        } catch {
            leverageRatio = NaN;
        }
        // write a gnuplot data file line for fees, invariant and liquidation
        writeLine(
            file,
            ia(
                collateral,
                price,
                pegged,
                peggedTokenPrice,
                leveraged,
                leveragedTokenPrice,
                invariant,
                collateralRatio,
                leverageRatio
            )
        );
    }

    function test_priceChange() public {
        // add collateral, peggged and leveraged
        uint midway = 2000;
        // at a price mid-way between the value rang below
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(midway * 1 ether);
        setUp_collateral(10 ether, 10 ether, address(this));

        string memory priceChangeFile = openFile("priceChange");

        for (uint256 price = 0; price <= midway * 2; price += 10) {
            MockWrappedPriceOracle(priceOracle).setLatestAnswer(price * 1 ether);

            writeOneLine(priceChangeFile);
        }

        vm.closeFile(priceChangeFile);
    }
}
