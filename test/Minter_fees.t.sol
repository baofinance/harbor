// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

//import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IMinter, IMinterTreasury } from "src/minter/IMinter.sol";
import { deployed } from "test/deployed.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";

import "test/Useful.sol";
import { TestMinter } from "test/Minter_base.t.sol";

contract TestMinterFees is TestMinter {
    Vm.Wallet user;

    function setUp() public virtual override {
        super.setUp();
        user = vm.createWallet("user");
        setUp_permissions();

        deal(address(deployed.wstETH), user.addr, 100 ether);
        vm.prank(user.addr);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);
    }

    //---------------------------------------------------------------------------------------------
    // Fees
    //---------------------------------------------------------------------------------------------

    function getFees()
        private
        view
        returns (int256 mintPeggedFees, int256 redeemPeggedFees, int256 mintLeveragedFees, int256 redeemLeveragedFees)
    {
        mintPeggedFees = IMinter(minter).mintPeggedTokenFeeRatio(0);
        redeemPeggedFees = IMinter(minter).redeemPeggedTokenFeeRatio(0);
        mintLeveragedFees = IMinter(minter).mintLeveragedTokenFeeRatio(0);
        redeemLeveragedFees = IMinter(minter).redeemLeveragedTokenFeeRatio(0);
    }

    function test_fees() public {
        // TODO: check that the fee is adjusted for begin-state (mintLeveraged) and end-state (mintPegged)
        setUp_collateral(1 ether, 0);
        assertEq(IMinter(minter).collateralRatio(), 1 ether);
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
            ) = getFees();
        }
        // TODO: merge the two checks into one.
        priceForCollateral = (startPrice * config.dangerCollateralRatioUpperBound) / 1 ether;
        for (uint256 price = priceForCollateral - 100000; price < priceForCollateral + 100000; price += 100) {
            MockPriceOracle(priceOracle).setPrice(price);
            uint256 cr = IMinter(minter).collateralRatio();
            (
                uint256 mintPeggedFees,
                uint256 redeemPeggedFees,
                uint256 mintLeveragedFees,
                uint256 redeemLeveragedFees
            ) = getFees();
        }
        */

        // write a gnuplot data file for fees
        string memory file = "./results/fees.csv";
        if (vm.exists(file)) vm.removeFile(file);
        vm.writeLine(
            file,
            "Price, Collateral Ratio, Mint Pegged Fees, Redeem Pegged Fees, Mint Leveraged Fees, Redeem Leveraged Fees"
        );

        //for (uint256 price = (startPrice * 9) / 10; price < (startPrice * 15) / 10; price += 10 ether)

        for (uint256 cr = 9 ether / 10; cr <= 16 ether / 10; cr += 1 ether / 1000) {
            // for (uint256 cr = 11 ether / 10; cr <= 15 ether / 10; cr += 5 ether / 100) {
            uint256 price = (startPrice * cr) / 1 ether;
            MockPriceOracle(priceOracle).setPrice(price);
            assertEq(cr, IMinter(minter).collateralRatio(), "crs must match");
            (
                int256 mintPeggedFees,
                int256 redeemPeggedFees,
                int256 mintLeveragedFees,
                int256 redeemLeveragedFees
            ) = getFees();
            vm.writeLine(
                file,
                string.concat(
                    Useful.toStringScaled(price, 18),
                    ",",
                    Useful.toStringScaled(cr, 18),
                    ",",
                    Useful.toStringScaled(mintPeggedFees, 18),
                    ",",
                    Useful.toStringScaled(redeemPeggedFees, 18),
                    ",",
                    Useful.toStringScaled(mintLeveragedFees, 18),
                    ",",
                    Useful.toStringScaled(redeemLeveragedFees, 18)
                )
            );
        }
        vm.closeFile(file);
    }

    function test_mintPeggedFees() public {
        (, uint256 price, , ) = priceOracle.getPrice();
        setUp_collateral(2 ether, 1 ether); // CR = 3/2 = 1.5
        assertLt(dangerCollateralRatioUpperBound, IMinter(minter).collateralRatio(), "test must start with CR normal");

        // fees at normal
        int256 mintPeggedFees0 = IMinter(minter).mintPeggedTokenFeeRatio(0);
        assertEq(mintPeggedFees0, mintPeggedNormalFeeRatio);

        // fees crossing into danger
        uint256 collateral = 1 ether;
        int256 mintPeggedFees1 = IMinter(minter).mintPeggedTokenFeeRatio(collateral); // CR -> 4/3 = 1.33 in danger
        assertGt(mintPeggedFees1, mintPeggedNormalFeeRatio, "fee is part normal, part danger, so > normal");
        assertLt(mintPeggedFees1, mintPeggedDangerFeeRatio, "fee is part normal, part danger, so < danger");

        // check that the fees match the reported value, both emit and that transferred
        int256 expectedFees = (mintPeggedFees1 * int256(collateral)) / 1 ether;
        uint256 feeReceiverCollateralBalanceBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintPeggedToken(
            user.addr,
            user.addr,
            collateral,
            uint256((int256(price) * (int256(collateral) - expectedFees))) / 1 ether,
            uint256(expectedFees)
        );
        vm.prank(user.addr);
        IMinter(minter).mintPeggedToken(collateral, user.addr, 0);
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            uint256(int256(feeReceiverCollateralBalanceBefore) + expectedFees)
        );

        // we are now in danger (CR=1.33), so check the fee here
        assertGt(dangerCollateralRatioUpperBound, IMinter(minter).collateralRatio(), "test must start with CR danger");
        assertLt(
            config.disallowMintPeggedCollateralRatioUpperBound,
            IMinter(minter).collateralRatio(),
            "test must start with CR danger"
        );
        assertEq(IMinter(minter).mintPeggedTokenFeeRatio(0), mintPeggedDangerFeeRatio, "expected to be in danger");
        // TODO: add a view function to say how much will be minted, given disallowing, maybe the same function mintPeggedTokenFeeRatio
        assertEq(
            IMinter(minter).mintPeggedTokenFeeRatio(3 ether),
            mintPeggedDangerFeeRatio,
            "expected to still be in danger"
        ); // CR -> disallow but fee ratio is still danger
    }

    /*
    function test_mintLeveragedFees() public {
        (, uint256 price, , ) = priceOracle.getPrice();
        setUp_collateral(2 ether, 1 ether);
        assertEq(IMinter(minter).collateralRatio(), 3 ether / 2);

        uint256 collateral = 1 ether; // cr goes to 4 ether / 3 = 1.33, so fees should be well within normal, increasing to danger
        uint256 mintLeveragedFees0 = IMinter(minter).mintLeveragedTokenFeeRatio(); // TODO: make it the lower of the before and after fee
        uint256 mintLeveragedFees1 = IMinter(minter).mintLeveragedTokenFeeRatio();
        assertGt(mintLeveragedFees1, mintLeveragedFees0, "fee ratios increase the more is minted");
        uint256 expectedFees = (mintLeveragedFees1 * collateral) / 1 ether;
        uint256 feeReceiverCollateralBalanceBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintLeveragedToken(
            user.addr,
            user.addr,
            collateral,
            (price * (collateral - expectedFees)) / 1 ether,
            expectedFees
        );
        vm.prank(user.addr);
        IMinter(minter).mintLeveragedToken(collateral, user.addr, 0);
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            feeReceiverCollateralBalanceBefore + expectedFees
        );
    }
    */

    // TODO: check the bonus if properly paid - maybe do this in test mint leveraged
}
