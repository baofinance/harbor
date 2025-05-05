// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IRebalancePool} from "src/interfaces/IRebalancePool.sol";
import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";

import "test/Useful.sol";
import {TestRebalancePool2SetUp} from "test/Liquidate.t.sol";
import {Array} from "test/Array.sol";

import "test/clog.sol";

contract TestCollateralRatioRangeSetUp is TestRebalancePool2SetUp {
    uint256 startPrice;
    uint256 currentPrice;
    uint256 currentCollateralRatio;
    uint256 increment = 1 ether / 500;

    function setUp() public virtual override {
        super.setUp();
        (startPrice, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(10 ether, 10 ether, address(this));
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

    function pegged() internal view returns (bool) {
        return currentCollateralRatio >= 1 ether;
    }

    function leveraged() internal view returns (bool) {
        return currentCollateralRatio > 1 ether;
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

    function readHoldings() internal view returns (Holdings memory holdings) {
        holdings.feeReceiverCollateral = IERC20(collateralToken).balanceOf(feeReceiver);
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
    ) internal pure {
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
        int256 incentiveRatio;
        uint256 peggedMinted;
        uint256 peggedRedeemed;
        uint256 leveragedMinted;
        uint256 levergedRedeemed;
        uint256 collateralUsed;
        uint256 collateralReturned;
        uint256 fee;
        uint256 discount;
        uint256 price;
        uint256 rate;
    }

    function doOneCollateralRatio() internal virtual {
        // make sure this is overriden and doesn't get called
        // assertFalse(true);
    }
    function setDown() internal virtual {}

    function test_allCollateralRatios() public virtual {
        uint256 startCollateralRatio = 2 ether;
        assertEq(IMinter(minter).collateralRatio(), startCollateralRatio);

        for (
            currentCollateralRatio = increment;
            currentCollateralRatio <= 16 ether / 10;
            currentCollateralRatio += increment
        ) {
            currentPrice = (startPrice * currentCollateralRatio) / startCollateralRatio;

            MockWrappedPriceOracle(priceOracle).setLatestAnswer(currentPrice);
            assertEq(currentCollateralRatio, IMinter(minter).collateralRatio(), "crs must match");

            doOneCollateralRatio();
        }
        setDown();
    }
}

// TODO: do a free comparison v fee'd comparison when fees are set to 0 and reserve pool is empty

contract TestCollateralRatioRangeTransfersNoReserve is TestCollateralRatioRangeSetUp {
    function setUp() public virtual override {
        super.setUp();
        // c.log("collateralToken", IERC20(collateralToken).balanceOf(address(this)));
        // c.log("leveragedToken", IERC20(leveragedToken).balanceOf(address(this)));
        // c.log("peggedToken", IERC20(peggedToken).balanceOf(address(this)));
        increment = 1 ether / 100;
    }

    function setUpConfig() internal virtual override {
        setUp_config_likelyNoDisallow();
    }

    function doOneCollateralRatio() internal override {
        // collect the data and check against actuals
        Data memory data;
        Holdings memory beforeHolding;
        Holdings memory afterHolding;
        DeltaHoldings memory deltas;
        uint256 snap;

        // mint pegged
        (data.incentiveRatio, data.fee, data.collateralUsed, data.peggedMinted, , ) = IMinter(minter)
            .mintPeggedTokenDryRun(1 ether);

        if (data.incentiveRatio < 1 ether) {
            // minting pegged is allowed
            snap = vm.snapshotState();
            beforeHolding = readHoldings();
            IMinter(minter).mintPeggedToken(1 ether, address(this), 0);
            afterHolding = readHoldings();
            deltas = DeltaHoldings(
                int256(data.fee),
                int256(0),
                int256(data.collateralUsed) - int256(data.fee),
                int256(data.peggedMinted),
                -int256(data.collateralUsed),
                int256(data.peggedMinted),
                int256(0)
            );
            compareHoldings(beforeHolding, afterHolding, deltas, "mintPegged");
            vm.revertToState(snap);
        } else {
            // minting pegged is disallowed
            vm.expectRevert(abi.encodeWithSelector(IMinter.MintZeroAmount.selector, peggedToken));
            IMinter(minter).mintPeggedToken(1 ether, address(this), 0);
        }

        // redeem pegged
        (, data.fee, data.discount, data.peggedRedeemed, data.collateralReturned, data.price, data.rate) = IMinter(
            minter
        ).redeemPeggedTokenDryRun(1000 ether);
        snap = vm.snapshotState();
        beforeHolding = readHoldings();
        IMinter(minter).redeemPeggedToken(1000 ether, address(this), 0);
        afterHolding = readHoldings();
        deltas = DeltaHoldings(
            int256(data.fee),
            -int256(data.discount),
            -int256(data.collateralReturned) + int256(data.discount) - int256(data.fee),
            -int256(data.peggedRedeemed),
            int256(data.collateralReturned),
            -int256(data.peggedRedeemed),
            int256(0)
        );
        compareHoldings(beforeHolding, afterHolding, deltas, "redeemPegged");
        vm.revertToState(snap);

        // leveraged operations don't work for depegged

        // mint leveraged
        if (currentCollateralRatio > 1 ether) {
            (, data.fee, data.discount, data.collateralUsed, data.leveragedMinted, , ) = IMinter(minter)
                .mintLeveragedTokenDryRun(1 ether);

            snap = vm.snapshotState();
            beforeHolding = readHoldings();
            IMinter(minter).mintLeveragedToken(1 ether, address(this), 0);
            afterHolding = readHoldings();
            deltas = DeltaHoldings(
                int256(data.fee),
                -int256(data.discount),
                int256(data.collateralUsed) + int256(data.discount) - int256(data.fee),
                int256(0),
                -int256(data.collateralUsed),
                int256(0),
                int256(data.leveragedMinted)
            );
            compareHoldings(beforeHolding, afterHolding, deltas, "mintLeveraged");
            vm.revertToState(snap);

            // redeem leveraged
            (data.incentiveRatio, data.fee, data.levergedRedeemed, data.collateralReturned, , ) = IMinter(minter)
                .redeemLeveragedTokenDryRun(1000 ether);
            if (data.incentiveRatio < 1 ether) {
                snap = vm.snapshotState();
                beforeHolding = readHoldings();
                IMinter(minter).redeemLeveragedToken(1000 ether, address(this), 0);
                afterHolding = readHoldings();
                deltas = DeltaHoldings(
                    int256(data.fee),
                    -int256(data.discount),
                    -int256(data.collateralReturned) + int256(data.discount) - int256(data.fee),
                    -int256(0),
                    int256(data.collateralReturned),
                    int256(0),
                    -int256(data.levergedRedeemed)
                );
                compareHoldings(beforeHolding, afterHolding, deltas, "redeemLeveraged");

                vm.revertToState(snap);
            }
        }
    }
}

contract TestCollateralRatioRangeTransfersWithReserve is TestCollateralRatioRangeTransfersNoReserve {
    function setUp() public override {
        super.setUp();
        deal(address(collateralToken), reservePool, 1000 ether);
    }
}

/////////////////////////////////////////////////////////////////////////////////////////////////////////////

contract TestCollateralRatioRangeIntegralNoReserve is TestCollateralRatioRangeSetUp {
    enum Action {
        MintPegged,
        RedeemPegged,
        MintLeveraged,
        RedeemLeveraged
    }

    uint repeats = 10;

    function setUpConfig() internal virtual override {
        setUp_config_likelyNoDisallow();
        increment = 1 ether / 10;
    }

    function setUp() public virtual override {
        super.setUp();
        setUp_collateral(repeats * 10, repeats * 10, address(this));
    }

    function makeDeltaHoldings(
        Holdings memory antes,
        Holdings memory postres
    ) internal pure returns (DeltaHoldings memory cambios) {
        cambios.feeReceiverCollateral = int256(postres.feeReceiverCollateral) - int256(antes.feeReceiverCollateral);
        cambios.reservePoolCollateral = int256(postres.reservePoolCollateral) - int256(antes.reservePoolCollateral);
        cambios.minterCollateral = int256(postres.minterCollateral) - int256(antes.minterCollateral);
        cambios.minterPegged = int256(postres.minterPegged) - int256(antes.minterPegged);
        cambios.thisCollateral = int256(postres.thisCollateral) - int256(antes.thisCollateral);
        cambios.thisPegged = int256(postres.thisPegged) - int256(antes.thisPegged);
        cambios.thisLeveraged = int256(postres.thisLeveraged) - int256(antes.thisLeveraged);
    }

    function addDeltaHoldings(
        DeltaHoldings memory changesSoFar,
        DeltaHoldings memory cambios
    ) internal pure returns (DeltaHoldings memory withNewChanges) {
        withNewChanges.feeReceiverCollateral = changesSoFar.feeReceiverCollateral + cambios.feeReceiverCollateral;
        withNewChanges.reservePoolCollateral = changesSoFar.reservePoolCollateral + cambios.reservePoolCollateral;
        withNewChanges.minterCollateral = changesSoFar.minterCollateral + cambios.minterCollateral;
        withNewChanges.minterPegged = changesSoFar.minterPegged + cambios.minterPegged;
        withNewChanges.thisCollateral = changesSoFar.thisCollateral + cambios.thisCollateral;
        withNewChanges.thisPegged = changesSoFar.thisPegged + cambios.thisPegged;
        withNewChanges.thisLeveraged = changesSoFar.thisLeveraged + cambios.thisLeveraged;
    }

    function compareDeltaHoldings(
        DeltaHoldings memory a,
        DeltaHoldings memory b,
        uint256 tolerance,
        string memory context
    ) internal pure {
        assertApproxEqAbs(
            a.feeReceiverCollateral,
            b.feeReceiverCollateral,
            tolerance,
            string.concat(context, ":", "feeReceiverCollateral")
        );
        assertApproxEqAbs(
            a.reservePoolCollateral,
            b.reservePoolCollateral,
            tolerance,
            string.concat(context, ":", "reservePoolCollateral")
        );
        assertApproxEqAbs(
            a.minterCollateral,
            b.minterCollateral,
            tolerance,
            string.concat(context, ":", "minterCollateral")
        );
        assertApproxEqAbs(
            a.minterPegged,
            b.minterPegged,
            tolerance * 1000,
            string.concat(context, ":", "minterPegged")
        );
        assertApproxEqAbs(a.thisCollateral, b.thisCollateral, tolerance, string.concat(context, ":", "thisCollateral"));
        assertApproxEqAbs(a.thisPegged, b.thisPegged, tolerance * 1000, string.concat(context, ":", "thisPegged"));
        assertApproxEqAbs(
            a.thisLeveraged,
            b.thisLeveraged,
            tolerance * 1000,
            string.concat(context, ":", "thisLeveraged")
        );
    }

    function toString(Action action) private pure returns (string memory s) {
        if (action == Action.MintPegged) s = "mintPegged";
        else if (action == Action.RedeemPegged) s = "redeemPegged";
        else if (action == Action.MintLeveraged) s = "mintLeveraged";
        else if (action == Action.RedeemLeveraged) s = "redeemLeveraged";
        else s = "unknown";
    }

    function doOne(
        Action action,
        uint multiple,
        DeltaHoldings memory changesSoFar
    ) internal returns (DeltaHoldings memory withNewChanges) {
        // before
        Holdings memory antes = readHoldings();
        // do it
        if (action == Action.MintPegged) {
            IMinter(minter).mintPeggedToken(multiple * 1 ether, address(this), 0);
        } else if (action == Action.RedeemPegged) {
            IMinter(minter).redeemPeggedToken(multiple * 1000 ether, address(this), 0);
        } else if (action == Action.MintLeveraged) {
            if (leveraged()) IMinter(minter).mintLeveragedToken(multiple * 1 ether, address(this), 0);
        } else if (action == Action.RedeemLeveraged) {
            if (leveraged()) IMinter(minter).redeemLeveragedToken(multiple * 1000 ether, address(this), 0);
        }
        // after + changes
        DeltaHoldings memory cambios = makeDeltaHoldings(antes, readHoldings());
        withNewChanges = addDeltaHoldings(changesSoFar, cambios);
    }

    function doOneCollateralRatio() internal override(TestCollateralRatioRangeSetUp) {
        // for each action we mint 10 small amounts then mint one large amount = 10 * small amount
        // we then compare the transfers - the 10 small amounts should equal the one large amount.

        DeltaHoldings memory largeChanges;
        DeltaHoldings memory smallChanges;
        uint256 snap;

        for (uint a = 0; a <= uint(type(Action).max); a++) {
            snap = vm.snapshotState();
            largeChanges = doOne(Action(a), repeats, largeChanges);
            vm.revertToState(snap);
            snap = vm.snapshotState();
            for (uint i = 0; i < repeats; i++) {
                smallChanges = doOne(Action(a), 1, smallChanges);
            }
            // TODO: see if we can get this tollerance down a bit
            compareDeltaHoldings(largeChanges, smallChanges, 40, toString(Action(a)));
            vm.revertToState(snap);
        }
    }
}

contract TestCollateralRatioRangeIntegralWithReserve is TestCollateralRatioRangeIntegralNoReserve {
    function setUp() public virtual override {
        super.setUp();
        deal(address(collateralToken), reservePool, 1000 ether);
    }
}
