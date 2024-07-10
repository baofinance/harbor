// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

//import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";

import { IMinter, IMinterTreasury } from "src/minter/IMinter.sol";
import { deployed } from "test/deployed.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";

import "test/Useful.sol";
import { TestMinter } from "test/Minter_base.t.sol";
import { Array } from "test/Array.sol";

// TODO: need to test discounts

contract TestMinterGraphs is Array, TestMinter {
    Vm.Wallet user;

    function setUpConfig() public override {
        setUpConfig(
            130,
            250,
            ic(ua(130, 140), ia(disallow, 100, 50)),
            ic(ua(110, 120, 145), ia(-50, 0, 20, 70)),
            ic(ua(105, 115, 150), ia(-75, -25, 60, 80)),
            ic(ua(105, 135), ia(disallow, 150, 120))
        );
    }

    function setUp() public virtual override {
        super.setUp();
        user = vm.createWallet("user");
        setUp_permissions();

        deal(address(deployed.wstETH), user.addr, 100 ether);
        vm.prank(user.addr);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);
    }

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

    function getIncentives(
        uint256 collateral
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
        (mintPeggedIncentive, ) = IMinter(minter).mintPeggedTokenIncentiveRatio(collateral);
        redeemPeggedIncentive = IMinter(minter).redeemPeggedTokenIncentiveRatio(collateral);
        mintLeveragedIncentive = IMinter(minter).mintLeveragedTokenIncentiveRatio(collateral);
        (redeemLeveragedIncentive, ) = IMinter(minter).redeemLeveragedTokenIncentiveRatio(collateral);
    }

    function test_CRgraphs() public {
        setUp_collateral(10 ether, 10 ether);
        uint256 startCR = 2 ether;
        assertEq(IMinter(minter).collateralRatio(), startCR);
        (, uint256 startPrice, , ) = IPriceOracle(priceOracle).getPrice();

        /*
        // test fees at the extremities, around rebalance and danger
        // CR is proportional to price
        console.log(
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
        string[] memory feesHeaders = sa(
            "Price",
            "Collateral Ratio",
            "Mint Pegged Fees",
            "Redeem Pegged Fees",
            "Mint Leveraged Fees",
            "Redeem Leveraged Fees"
        );
        string memory feesFile = openFile("fees", feesHeaders);
        string memory fees1File = openFile("fees1", feesHeaders);

        //for (uint256 price = (startPrice * 9) / 10; price < (startPrice * 15) / 10; price += 10 ether)
        int256 mintPeggedFees;
        int256 redeemPeggedFees;
        int256 mintLeveragedFees;
        int256 redeemLeveragedFees;

        for (uint256 cr = 9 ether / 10; cr <= 16 ether / 10; cr += 1 ether / 1000) {
            // for (uint256 cr = 11 ether / 10; cr <= 15 ether / 10; cr += 5 ether / 100) {
            uint256 price = (startPrice * cr) / startCR;

            MockPriceOracle(priceOracle).setPrice(price);
            assertEq(cr, IMinter(minter).collateralRatio(), "crs must match");

            // zero collateral (instantaneous) incentives
            (mintPeggedFees, redeemPeggedFees, mintLeveragedFees, redeemLeveragedFees) = getIncentives(0);
            writeLine(
                feesFile,
                ia(int(price), int(cr), mintPeggedFees, redeemPeggedFees, mintLeveragedFees, redeemLeveragedFees)
            );

            (mintPeggedFees, redeemPeggedFees, mintLeveragedFees, redeemLeveragedFees) = getIncentives(1 ether);
            writeLine(
                fees1File,
                ia(int(price), int(cr), mintPeggedFees, redeemPeggedFees, mintLeveragedFees, redeemLeveragedFees)
            );
        }
        vm.closeFile(feesFile);
        vm.closeFile(fees1File);
    }
}
