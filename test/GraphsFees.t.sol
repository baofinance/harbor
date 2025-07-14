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
import {StabilityPool_v1} from "src/minter/StabilityPool_v1.sol";
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {StabilityPoolManager_v1} from "src/minter/StabilityPoolManager_v1.sol";

import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";

import "test/Useful.sol";
import {TestCollateralRatioRangeSetUp} from "test/CollateralRatio.t.sol";
import {Array} from "test/Array.sol";
import {TestGraphs} from "test/Graphs.t.sol";

contract TestGraphsDisallow is TestGraphs, TestCollateralRatioRangeSetUp {
    string feesFile;
    string fees1File;
    string invariantFile;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public override {
        super.setUp();
        deal(address(wrappedCollateralToken), reservePool, 1000 ether);

        feesFile = openFile(
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
        fees1File = openFile(
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

        invariantFile = openFile(
            "invariant",
            sa("Collateral Ratio", "Leverage Ratio", "Pegged NAV", "Leveraged NAV", "Collateral NAV")
        );

        // IStabilityPool(stabilityPoolCollateral).deposit(4 * startPrice, address(this), 0);
        // IStabilityPool(stabilityPoolLeveraged).deposit(4 * startPrice, address(this), 0);
    }

    function setDown() internal override {
        vm.closeFile(feesFile);
        vm.closeFile(fees1File);
        vm.closeFile(invariantFile);
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
