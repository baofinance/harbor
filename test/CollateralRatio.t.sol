// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Vm } from "forge-std/Vm.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";

import { IMinter } from "src/minter/IMinter.sol";
import { IRebalancePool } from "src/minter/IRebalancePool.sol";
import { deployed } from "test/deployed.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";

import "test/Useful.sol";
import { TestRebalancePool2SetUp } from "test/Liquidate.t.sol";
import { Array } from "test/Array.sol";

contract TestCollateralRatioRangeSetUp is TestRebalancePool2SetUp {
    uint256 startPrice;
    uint256 currentPrice;
    uint256 currentCollateralRatio;

    function setUp() public virtual override {
        super.setUp();
        (, startPrice, , ) = IPriceOracle(priceOracle).getPrice();
        setUp_collateral(10 ether, 10 ether, address(this));
        deal(address(collateralToken), address(this), 1000 ether);
        IERC20(collateralToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        IERC20(peggedToken).approve(rebalancePool, type(uint256).max);
        IERC20(peggedToken).approve(rebalancePoolLeveraged, type(uint256).max);
        vm.prank(owner.addr);
        IAccessControl(minter).grantRole(zeroFeeRole, address(this));
    }

    function doOneCollateralRatio() internal virtual {}
    function setDown() internal virtual {}

    function test_allCollateralRatios() public virtual {
        uint256 startCollateralRatio = 2 ether;
        assertEq(IMinter(minter).collateralRatio(), startCollateralRatio);

        uint256 inc = 1 ether / 500;

        for (currentCollateralRatio = inc; currentCollateralRatio <= 16 ether / 10; currentCollateralRatio += inc) {
            currentPrice = (startPrice * currentCollateralRatio) / startCollateralRatio;

            MockPriceOracle(priceOracle).setPrice(currentPrice);
            assertEq(currentCollateralRatio, IMinter(minter).collateralRatio(), "crs must match");

            doOneCollateralRatio();
        }
        setDown();
    }
}

// TODO: do the dry run v real run comparsison with and without reserve pool
// TODO: do a free comparison v fee'd comparison when fees are set to 0

contract TestCollateralRatioRange is TestCollateralRatioRangeSetUp {
    function setUp() public override {
        super.setUp();
        deal(address(collateralToken), reservePool, 1000 ether);
    }

    function setUpConfig() internal virtual override {
        setUpConfig_likelyNoDisallow();
    }

    struct Holdings {
        uint256 feeReceiverCollateral;
        uint256 reservePoolCollateral;
        uint256 minterCollateral;
        uint256 minterPegged;
        uint256 thisCollateral;
        uint256 thisPegged;
        uint256 thisLeveraged;
    }
    struct DeltaHoldings {
        int256 feeReceiverCollateral;
        int256 reservePoolCollateral;
        int256 minterCollateral;
        int256 minterPegged;
        int256 thisCollateral;
        int256 thisPegged;
        int256 thisLeveraged;
    }

    function readHoldings() private view returns (Holdings memory holdings) {
        holdings.feeReceiverCollateral = IERC20(collateralToken).balanceOf(feeReceiver.addr);
        holdings.reservePoolCollateral = IERC20(collateralToken).balanceOf(reservePool);
        holdings.minterCollateral = IERC20(collateralToken).balanceOf(minter);
        holdings.minterPegged = IMinter(minter).peggedTokenBalance();
        holdings.thisCollateral = IERC20(collateralToken).balanceOf(address(this));
        holdings.thisPegged = IERC20(peggedToken).balanceOf(address(this));
        holdings.thisLeveraged = IERC20(leveragedToken).balanceOf(address(this));
    }

    function compareHoldings(
        Holdings memory antes,
        Holdings memory postres,
        DeltaHoldings memory cambios,
        string memory context
    ) private pure {
        assertEq(
            postres.feeReceiverCollateral,
            uint256(int256(antes.feeReceiverCollateral) + cambios.feeReceiverCollateral),
            string.concat(context, ":", "feeReceiverCollateral")
        );
        assertEq(
            postres.reservePoolCollateral,
            uint256(int256(antes.reservePoolCollateral) + cambios.reservePoolCollateral),
            string.concat(context, ":", "reservePoolCollateral")
        );
        assertEq(
            postres.minterCollateral,
            uint256(int256(antes.minterCollateral) + cambios.minterCollateral),
            string.concat(context, ":", "minterCollateral")
        );
        assertEq(
            postres.minterPegged,
            uint256(int256(antes.minterPegged) + cambios.minterPegged),
            string.concat(context, ":", "minterPegged")
        );
        assertEq(
            postres.thisCollateral,
            uint256(int256(antes.thisCollateral) + cambios.thisCollateral),
            string.concat(context, ":", "thisCollateral")
        );
        assertEq(
            postres.thisPegged,
            uint256(int256(antes.thisPegged) + cambios.thisPegged),
            string.concat(context, ":", "thisPegged")
        );
        assertEq(
            postres.thisLeveraged,
            uint256(int256(antes.thisLeveraged) + cambios.thisLeveraged),
            string.concat(context, ":", "thisLeveraged")
        );
    }

    struct Data {
        uint256 peggedMinted;
        uint256 peggedRedeemed;
        uint256 leveragedMinted;
        uint256 levergedRedeemed;
        uint256 collateralUsed;
        uint256 collateralReturned;
        uint256 fee;
        uint256 reserveCollateralUsed;
        uint256 price;
    }

    function doOneCollateralRatio() internal override {
        // collect the data and check against actuals
        Data memory data;
        Holdings memory beforeHolding;
        Holdings memory afterHolding;
        DeltaHoldings memory deltas;
        uint256 snap;

        // mint pegged
        int256 mintPeggedIncentive;
        (
            mintPeggedIncentive,
            data.collateralUsed,
            data.peggedMinted,
            data.fee,
            data.reserveCollateralUsed,
            data.price
        ) = IMinter(minter).mintPeggedTokenDryRun(1 ether);

        if (mintPeggedIncentive < 1 ether) {
            // minting pegged is allowed
            snap = vm.snapshot();
            beforeHolding = readHoldings();
            IMinter(minter).mintPeggedToken(1 ether, address(this), 0);
            afterHolding = readHoldings();
            deltas = DeltaHoldings(
                int256(data.fee),
                int256(data.reserveCollateralUsed),
                int256(1 ether) - int256(data.fee),
                int256(data.peggedMinted),
                -int256(1 ether),
                int256(data.peggedMinted),
                int256(0)
            );
            compareHoldings(beforeHolding, afterHolding, deltas, "mintPegged");
            vm.revertTo(snap);
        } else {
            // minting pegged is disallowed
            vm.expectRevert(abi.encodeWithSelector(IMinter.MintZeroAmount.selector, peggedToken));
            IMinter(minter).mintPeggedToken(1 ether, address(this), 0);
        }

        // redeem pegged
        (, data.peggedRedeemed, data.collateralReturned, data.fee, data.reserveCollateralUsed, data.price) = IMinter(
            minter
        ).redeemPeggedTokenDryRun(1000 ether);
        snap = vm.snapshot();

        vm.revertTo(snap);

        // mint leveraged
        (, data.collateralUsed, data.leveragedMinted, data.fee, data.reserveCollateralUsed, data.price) = IMinter(
            minter
        ).mintLeveragedTokenDryRun(1 ether);
        snap = vm.snapshot();

        vm.revertTo(snap);

        // leveraged leveraged
        (, data.levergedRedeemed, data.collateralReturned, data.fee, data.reserveCollateralUsed, data.price) = IMinter(
            minter
        ).redeemLeveragedTokenDryRun(1000 ether);
        snap = vm.snapshot();

        vm.revertTo(snap);
    }
}
