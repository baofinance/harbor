// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//import { Test } from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@interfaces/IMinter.sol";
import {IRebalancePool} from "@interfaces/IRebalancePool.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IPriceOracle} from "@interfaces/IPriceOracle.sol";
import {MockPriceOracle} from "test/mock/MockPriceOracle.sol";

import "test/Useful.sol";
import {TestCollateralRatioRangeSetUp} from "test/CollateralRatio.t.sol";
import {Array} from "test/Array.sol";

contract TestGraphsDisallow is TestCollateralRatioRangeSetUp {
    string feesFile;
    string fees1File;
    string invariantFile;
    string liquidateFile;
    int256 NaN = type(int256).max;
    uint256 uNaN = type(uint256).max;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function context() internal pure virtual returns (string memory) {
        return "";
    }

    function setUp() public override {
        super.setUp();
        deal(address(collateralToken), reservePool, 1000 ether);

        feesFile = openFile(
            string.concat("fees", context()),
            sa(
                "Price",
                "Collateral Ratio",
                "Mint Pegged Config",
                "Redeem Pegged Config",
                "Mint Leveraged Config",
                "Redeem Leveraged Config"
            )
        );
        fees1File = openFile(
            string.concat("fees1", context()),
            sa(
                "Price",
                "Collateral Ratio",
                "Mint Pegged Fees",
                "Redeem Pegged Fees",
                "Mint Leveraged Fees",
                "Redeem Leveraged Fees"
            )
        );

        invariantFile = openFile(
            string.concat("invariant", context()),
            sa("Collateral Ratio", "Leveraged Ratio", "Pegged NAV", "Leveraged NAV", "Collateral NAV")
        );

        IRebalancePool(rebalancePool).deposit(4 * startPrice, address(this), 0);
        IRebalancePool(rebalancePoolLeveraged).deposit(4 * startPrice, address(this), 0);
        liquidateFile = openFile(
            string.concat("liquidate", context()),
            sa("antes CR", "liquidate to collateral", "liquidate to leveraged")
        );
    }

    function setDown() internal override {
        vm.closeFile(feesFile);
        vm.closeFile(fees1File);
        vm.closeFile(invariantFile);
    }

    function openFile(string memory name, string[] memory header) private returns (string memory file) {
        file = string.concat("./results/", name, ".csv");
        if (vm.exists(file)) vm.removeFile(file);
        vm.writeLine(file, Useful.join(header, ","));
    }

    function writeLine(string memory file, int[] memory data) private {
        string[] memory strData = new string[](data.length);
        for (uint i = 0; i < data.length; i++) {
            strData[i] = data[i] == NaN ? "NaN" : Useful.toStringScaled(data[i], 18);
        }
        vm.writeLine(file, Useful.join(strData, ","));
    }

    function writeLine(string memory file, uint[] memory data) private {
        string[] memory strData = new string[](data.length);
        for (uint i = 0; i < data.length; i++) {
            strData[i] = data[i] == uNaN ? "NaN" : Useful.toStringScaled(data[i], 18);
        }
        vm.writeLine(file, Useful.join(strData, ","));
    }

    function getInstantIncentives()
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
        if (leveraged()) {
            mintLeveragedIncentive = IMinter(minter).mintLeveragedTokenIncentiveRatio();
            redeemLeveragedIncentive = IMinter(minter).redeemLeveragedTokenIncentiveRatio();
        } else {
            mintLeveragedIncentive = NaN;
            redeemLeveragedIncentive = NaN;
        }
    }

    function getDryRunIncentives(
        uint256 multiplier
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
        // collect the data and check against actuals
        (mintPeggedIncentive, , , , , ) = IMinter(minter).mintPeggedTokenDryRun(multiplier * 1 ether);
        (redeemPeggedIncentive, , , , , ) = IMinter(minter).redeemPeggedTokenDryRun(multiplier * 1000 ether);
        if (pegged()) {
            (mintLeveragedIncentive, , , , , ) = IMinter(minter).mintLeveragedTokenDryRun(multiplier * 1 ether);
            (redeemLeveragedIncentive, , , , , ) = IMinter(minter).redeemLeveragedTokenDryRun(multiplier * 1000 ether);
        } else {
            mintLeveragedIncentive = NaN;
            redeemLeveragedIncentive = NaN;
        }
    }

    function doOneCollateralRatio() internal override {
        // write a gnuplot data file line for fees, invariant and liquidation

        int256 mintPeggedFees;
        int256 redeemPeggedFees;
        int256 mintLeveragedFees;
        int256 redeemLeveragedFees;

        // zero collateral (instantaneous) incentives
        (mintPeggedFees, redeemPeggedFees, mintLeveragedFees, redeemLeveragedFees) = getInstantIncentives();
        writeLine(
            feesFile,
            ia(
                int(currentPrice),
                int(currentCollateralRatio),
                mintPeggedFees,
                redeemPeggedFees,
                mintLeveragedFees,
                redeemLeveragedFees
            )
        );

        (mintPeggedFees, redeemPeggedFees, mintLeveragedFees, redeemLeveragedFees) = getDryRunIncentives(1);
        writeLine(
            fees1File,
            ia(
                int(currentPrice),
                int(currentCollateralRatio),
                mintPeggedFees,
                redeemPeggedFees,
                mintLeveragedFees,
                redeemLeveragedFees
            )
        );

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

        uint256 afterLiquidate;
        uint256 afterLiquidateLeveraged;
        if (currentCollateralRatio < 13 ether / 10) {
            uint256 snap = vm.snapshotState();
            IRebalancePool(rebalancePool).liquidate(0);
            afterLiquidate = IMinter(minter).collateralRatio();
            vm.revertToState(snap);
            IRebalancePool(rebalancePoolLeveraged).liquidate(0);
            afterLiquidateLeveraged = IMinter(minter).collateralRatio();
            vm.revertToState(snap);
        } else {
            afterLiquidate = IMinter(minter).collateralRatio();
            afterLiquidateLeveraged = afterLiquidate;
        }
        writeLine(liquidateFile, ua(currentCollateralRatio, afterLiquidate, afterLiquidateLeveraged));
    }
}

contract TestGraphsNoDisallow is TestGraphsDisallow {
    function setUpConfig() internal override {
        setUp_config_likelyNoDisallow();
    }

    function context() internal pure override returns (string memory) {
        return "_noDisallow";
    }
}
