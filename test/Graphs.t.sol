// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

//import { Test } from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";

import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {StabilityPool_v1} from "src/minter/StabilityPool_v1.sol";
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {StabilityPoolManager_v1} from "src/minter/StabilityPoolManager_v1.sol";

import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";

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
    address stabilityPoolManagerCollateral;
    address stabilityPoolManagerLeveraged;
    address bountyReceiver;
    address treasury;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function context() internal pure virtual returns (string memory) {
        return "";
    }

    function setUp() public override {
        super.setUp();
        deal(address(wrappedCollateralToken), reservePool, 1000 ether);

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
            sa("Collateral Ratio", "Leverage Ratio", "Pegged NAV", "Leveraged NAV", "Collateral NAV")
        );

        IStabilityPool(stabilityPoolCollateral).deposit(4 * startPrice, address(this), 0);
        IStabilityPool(stabilityPoolLeveraged).deposit(4 * startPrice, address(this), 0);
        // console2.log(
        //     "peggedToken.balanceOf stabilityPoolCollateral=",
        //     IERC20(peggedToken).balanceOf(stabilityPoolCollateral)
        // );
        // console2.log(
        //     "peggedToken.balanceOf stabilityPoolLeveraged=",
        //     IERC20(peggedToken).balanceOf(stabilityPoolLeveraged)
        // );

        bountyReceiver = vm.createWallet("bountyReceiver").addr;
        treasury = vm.createWallet("treasury").addr;

        address stabilityPoolCollateralEmpty = UnsafeUpgrades.deployUUPSProxy(
            address(new StabilityPool_v1(stabilityERC20Collateral, minter, wrappedCollateralToken, 1 weeks)),
            abi.encodeCall(StabilityPool_v1.initialize, owner)
        );

        address stabilityPoolLeveragedEmpty = UnsafeUpgrades.deployUUPSProxy(
            address(new StabilityPool_v1(stabilityERC20Collateral, minter, leveragedToken, 1 weeks)),
            abi.encodeCall(StabilityPool_v1.initialize, owner)
        );

        // set up the stability pool managers
        stabilityPoolManagerCollateral = UnsafeUpgrades.deployUUPSProxy(
            address(
                new StabilityPoolManager_v1(minter, treasury, stabilityPoolCollateral, stabilityPoolLeveragedEmpty)
            ),
            abi.encodeCall(StabilityPoolManager_v1.initialize, (owner))
        );
        IStabilityPoolManager(stabilityPoolManagerCollateral).setRebalanceThreshold(1.3 ether);

        stabilityPoolManagerLeveraged = UnsafeUpgrades.deployUUPSProxy(
            address(
                new StabilityPoolManager_v1(minter, treasury, stabilityPoolCollateralEmpty, stabilityPoolLeveraged)
            ),
            abi.encodeCall(StabilityPoolManager_v1.initialize, (owner))
        );
        IStabilityPoolManager(stabilityPoolManagerLeveraged).setRebalanceThreshold(1.3 ether);

        uint256 rebalancerRole = IStabilityPool(stabilityPoolCollateral).REBALANCER_ROLE();
        uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();

        vm.startPrank(owner);
        IBaoRoles(stabilityPoolCollateral).grantRoles(stabilityPoolManagerCollateral, rebalancerRole);
        IBaoRoles(minter).grantRoles(stabilityPoolManagerCollateral, zeroFeeRole);

        IBaoRoles(stabilityPoolLeveraged).grantRoles(stabilityPoolManagerLeveraged, rebalancerRole);
        IBaoRoles(minter).grantRoles(stabilityPoolManagerLeveraged, zeroFeeRole);
        vm.stopPrank();

        liquidateFile = openFile(
            string.concat("liquidate", context()),
            sa("antes CR", "liquidate to collateral", "liquidate to leveraged")
        );
    }

    function setDown() internal override {
        vm.closeFile(feesFile);
        vm.closeFile(fees1File);
        vm.closeFile(invariantFile);
        vm.closeFile(liquidateFile);
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

        // if (leveraged()) {
        mintLeveragedIncentive = IMinter(minter).mintLeveragedTokenIncentiveRatio();
        redeemLeveragedIncentive = IMinter(minter).redeemLeveragedTokenIncentiveRatio();
        // } else {
        //     mintLeveragedIncentive = NaN;
        //     redeemLeveragedIncentive = NaN;
        // }
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
        (redeemPeggedIncentive, , , , , , ) = IMinter(minter).redeemPeggedTokenDryRun(multiplier * 1000 ether);

        try IMinter(minter).mintLeveragedTokenDryRun(multiplier * 1 ether) returns (
            int256 mintLeveraged,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        ) {
            mintLeveragedIncentive = mintLeveraged;
        } catch (bytes memory reason) {
            require(
                keccak256(reason) == keccak256(abi.encodeWithSelector(IMinter.ActionPaused.selector)),
                "unexpected error"
            );
            mintLeveragedIncentive = 0;
        }

        try IMinter(minter).redeemLeveragedTokenDryRun(multiplier * 1000 ether) returns (
            int256 redeemLeveraged,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        ) {
            redeemLeveragedIncentive = redeemLeveraged;
        } catch (bytes memory reason) {
            require(
                keccak256(reason) == keccak256(abi.encodeWithSelector(IMinter.ActionPaused.selector)),
                "unexpected error"
            );
            redeemLeveragedIncentive = 0;
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

        uint256 beforeLiquidate = IMinter(minter).collateralRatio();
        uint256 afterLiquidateCollateral;
        uint256 afterLiquidateLeveraged;

        uint256 snap = vm.snapshotState();
        if (IStabilityPoolManager(stabilityPoolManagerCollateral).rebalanceable()) {
            // console2.log("liquidate to collateral");
            // uint256 liquidated =
            IStabilityPoolManager(stabilityPoolManagerCollateral).rebalance(bountyReceiver, 0);
            afterLiquidateCollateral = IMinter(minter).collateralRatio();
            // assertGt(liquidated, 0, "liquidation must liquidate some pegged (collateral)");
            // assertGt(
            //     afterLiquidateCollateral,
            //     beforeLiquidate,
            //     "collateral ratio must go up after liquidation (collateral)"
            // );
        } else {
            afterLiquidateCollateral = beforeLiquidate;
        }
        vm.revertToState(snap);

        if (IStabilityPoolManager(stabilityPoolManagerLeveraged).rebalanceable()) {
            // console2.log("liquidate to leveraged");
            // uint256 liquidated =
            IStabilityPoolManager(stabilityPoolManagerLeveraged).rebalance(bountyReceiver, 0);
            afterLiquidateLeveraged = IMinter(minter).collateralRatio();
            // assertGt(liquidated, 0, "liquidation must liquidate some pegged (leveraged)");
            // assertGt(
            //     afterLiquidateLeveraged,
            //     beforeLiquidate,
            //     "collateral ratio must go up after liquidation (leveraged)"
            // );
        } else {
            afterLiquidateLeveraged = beforeLiquidate;
        }
        vm.revertToState(snap);

        writeLine(liquidateFile, ua(currentCollateralRatio, afterLiquidateCollateral, afterLiquidateLeveraged));
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
