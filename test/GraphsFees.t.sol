// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";

import "@harbor-test/Useful.sol";
import {TestCollateralRatioRangeSetUp} from "@harbor-test/CollateralRatio.t.sol";
import {TestGraphs} from "@harbor-test/Graphs.t.sol";

contract TestGraphsFees is TestGraphs, TestCollateralRatioRangeSetUp {
    string feesFile;
    string fees1File;
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

        // IStabilityPool(stabilityPoolCollateral).deposit(4 * startPrice, address(this), 0);
        // IStabilityPool(stabilityPoolLeveraged).deposit(4 * startPrice, address(this), 0);
    }

    function setDown() internal override {
        vm.closeFile(feesFile);
        vm.closeFile(fees1File);
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
        (mintLeveragedIncentive, , , , , , ) = IMinter(minter).mintLeveragedTokenDryRun(multiplier * 1 ether);
        (redeemLeveragedIncentive, , , , , ) = IMinter(minter).redeemLeveragedTokenDryRun(multiplier * 1000 ether);
    }

    function doOneCollateralRatio() internal override {
        // write a gnuplot data file line for fees and liquidation

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
    }
}

contract TestGraphsFeesNoDisallow is TestGraphsFees {
    function setUpConfig() internal override {
        setUp_config_likelyNoDisallow();
    }

    function context() internal pure override returns (string memory) {
        return "_noDisallow";
    }
}

contract TestGraphsFeesDeploy is TestGraphsFees {
    function setUpRange() internal override {
        start = 0.8 ether;
        finish = 2.6 ether;
        increment = 0.005 ether;
    }

    function setUpConfig() internal override {
        setUp_config(readConfigFile("./test/minter-fee-config.json"));
        writeConfig(config, "deploy");
    }

    function context() internal pure override returns (string memory) {
        return "_deploy";
    }
}
