// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

//import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import { IMinter } from "src/minter/IMinter.sol";
import { IRebalancePool } from "src/minter/IRebalancePool.sol";
import { deployed } from "test/deployed.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";

import "test/Useful.sol";
import { TestRebalancePool2SetUp } from "test/Liquidate.t.sol";
import { Array } from "test/Array.sol";

contract TestGraphs is TestRebalancePool2SetUp {
    function openFile(string memory name, string[] memory header) private returns (string memory file) {
        file = string.concat("./results/", name, ".csv");
        if (vm.exists(file)) vm.removeFile(file);
        vm.writeLine(file, Useful.join(header, ","));
    }

    function writeLine(string memory file, int[] memory data) private {
        string[] memory strData = new string[](data.length);
        for (uint i = 0; i < data.length; i++) {
            strData[i] = Useful.toStringScaled(data[i], 18);
        }
        vm.writeLine(file, Useful.join(strData, ","));
    }

    function writeLine(string memory file, uint[] memory data) private {
        string[] memory strData = new string[](data.length);
        for (uint i = 0; i < data.length; i++) {
            strData[i] = Useful.toStringScaled(data[i], 18);
        }
        vm.writeLine(file, Useful.join(strData, ","));
    }

    function getIncentives()
        private
        view
        returns (
            int256 mintPeggedIncentive,
            int256 redeemPeggedIncentive,
            int256 mintLeveragedIncentive,
            int256 redeemLeveragedIncentive
        )
    {
        mintPeggedIncentive = IMinter(minter).mintPeggedTokenIncentiveRatio();
        redeemPeggedIncentive = IMinter(minter).redeemPeggedTokenIncentiveRatio();
        mintLeveragedIncentive = IMinter(minter).mintLeveragedTokenIncentiveRatio();
        redeemLeveragedIncentive = IMinter(minter).redeemLeveragedTokenIncentiveRatio();
    }

    function getIncentives(
        uint256 collateral,
        uint256 price
    )
        private
        view
        returns (
            int256 mintPeggedIncentive,
            int256 redeemPeggedIncentive,
            int256 mintLeveragedIncentive,
            int256 redeemLeveragedIncentive
        )
    {
        (mintPeggedIncentive, , , , , ) = IMinter(minter).mintPeggedTokenDryRun(collateral);
        (redeemPeggedIncentive, , , , , ) = IMinter(minter).redeemPeggedTokenDryRun((collateral * price) / 1 ether);
        (mintLeveragedIncentive, , , , , ) = IMinter(minter).mintLeveragedTokenDryRun(collateral);
        (redeemLeveragedIncentive, , , , , ) = IMinter(minter).redeemLeveragedTokenDryRun(
            (collateral * price) / 1 ether
        );
    }

    function test_CRGraphs() public {
        setUp_collateral(10 ether, 10 ether, address(this));
        deal(address(deployed.wstETH), reservePool, 1000 ether);
        IERC20(deployed.BaoUSD).approve(rebalancePool, type(uint256).max);
        IERC20(deployed.BaoUSD).approve(rebalancePoolLeveraged, type(uint256).max);

        uint256 startCR = 2 ether;
        assertEq(IMinter(minter).collateralRatio(), startCR);
        (, uint256 startPrice, , ) = IPriceOracle(priceOracle).getPrice();

        /*
        // test fees at the extremities, around rebalance and danger
        // CR is proportional to price
        // console.log(
            "startPrice (%s) * config.rebalanceCollateralRatioUpperBound (%s)",
            startPrice,
            config.rebalanceCollateralRatioUpperBound
        );
        uint256 priceForCollateral = (startPrice * config.rebalanceCollateralRatioUpperBound) / 1 ether;
        for (uint256 price = priceForCollateral - 100000; price < priceForCollateral + 100000; price += 100) {
            MockPriceOracle(priceOracle).setPrice(price);
            uint256 cr = IMinter(minter).collateralRatio();
            // TODO: check the results against the expected behavior:
            // always rising/falling or staying the same and last value is geater/less than the first, etc.
            // inflection point is around the config collateral ratio
            //console.log("%s - %s - %s", price, config.rebalanceCollateralRatioUpperBound, cr);
            (
                uint256 mintPeggedFees,
                uint256 redeemPeggedFees,
                uint256 mintLeveragedFees,
                uint256 redeemLeveragedFees
            ) = IncentiveRatio(();
        }
        // TODO: merge the two checks into one.
        priceForCollateral = (startPrice * penultimate(config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds)) / 1 ether;
        for (uint256 price = priceForCollateral - 100000; price < priceForCollateral + 100000; price += 100) {
            MockPriceOracle(priceOracle).setPrice(price);
            uint256 cr = IMinter(minter).collateralRatio();
            (
                uint256 mintPeggedFees,
                uint256 redeemPeggedFees,
                uint256 mintLeveragedFees,
                uint256 redeemLeveragedFees
            ) = IncentiveRatio(();
        }
        */

        // write a gnuplot data file for fees
        string memory feesFile = openFile(
            "fees",
            sa(
                "Price",
                "Collateral Ratio",
                "Mint Pegged Config",
                "Redeem Pegged Config",
                "Mint Leveraged Config",
                "Redeem Leveraged Config"
            )
        );
        string memory fees1File = openFile(
            "fees1",
            sa(
                "Price",
                "Collateral Ratio",
                "Mint Pegged Fees",
                "Redeem Pegged Fees",
                "Mint Leveraged Fees",
                "Redeem Leveraged Fees"
            )
        );

        string memory invariantFile = openFile(
            "invariant",
            sa("Collateral Ratio", "Leveraged Ratio", "Pegged NAV", "Leveraged NAV", "Collateral NAV")
        );

        IRebalancePool(rebalancePool).deposit(4 * startPrice, address(this), 0);
        IRebalancePool(rebalancePoolLeveraged).deposit(4 * startPrice, address(this), 0);
        string memory liquidateFile = openFile(
            "liquidate",
            sa("before CR", "liquidate to collateral", "liquidate to leveraged")
        );

        //for (uint256 price = (startPrice * 9) / 10; price < (startPrice * 15) / 10; price += 10 ether)
        int256 mintPeggedFees;
        int256 redeemPeggedFees;
        int256 mintLeveragedFees;
        int256 redeemLeveragedFees;

        uint256 inc = 1 ether / 500;
        for (uint256 cr = inc / 10; cr <= 16 ether / 10; cr += inc) {
            // for (uint256 cr = 11 ether / 10; cr <= 15 ether / 10; cr += 5 ether / 100) {
            uint256 price = (startPrice * cr) / startCR;

            MockPriceOracle(priceOracle).setPrice(price);
            assertEq(cr, IMinter(minter).collateralRatio(), "crs must match");

            // zero collateral (instantaneous) incentives
            (mintPeggedFees, redeemPeggedFees, mintLeveragedFees, redeemLeveragedFees) = getIncentives();
            writeLine(
                feesFile,
                ia(int(price), int(cr), mintPeggedFees, redeemPeggedFees, mintLeveragedFees, redeemLeveragedFees)
            );

            (mintPeggedFees, redeemPeggedFees, mintLeveragedFees, redeemLeveragedFees) = getIncentives(
                1 ether,
                1000 ether
            );
            writeLine(
                fees1File,
                ia(int(price), int(cr), mintPeggedFees, redeemPeggedFees, mintLeveragedFees, redeemLeveragedFees)
            );

            writeLine(
                invariantFile,
                ua(
                    cr,
                    IMinter(minter).leverageRatio(),
                    IMinter(minter).peggedTokenPrice(),
                    IMinter(minter).leveragedTokenPrice(),
                    price
                )
            );

            uint256 afterLiquidate;
            uint256 afterLiquidateLeveraged;
            if (cr < 13 ether / 10) {
                uint256 snap = vm.snapshot();
                IRebalancePool(rebalancePool).liquidate(0);
                afterLiquidate = IMinter(minter).collateralRatio();
                vm.revertTo(snap);
                IRebalancePool(rebalancePoolLeveraged).liquidate(0);
                afterLiquidateLeveraged = IMinter(minter).collateralRatio();
                vm.revertTo(snap);
            } else {
                afterLiquidate = IMinter(minter).collateralRatio();
                afterLiquidateLeveraged = afterLiquidate;
            }
            writeLine(liquidateFile, ua(cr, afterLiquidate, afterLiquidateLeveraged));
        }
        vm.closeFile(feesFile);
        vm.closeFile(fees1File);
        vm.closeFile(invariantFile);
    }
}
