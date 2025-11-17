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

contract TestGraphsInvariant is TestGraphs, TestCollateralRatioRangeSetUp {
    string invariantFile;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public override {
        super.setUp();
        deal(address(wrappedCollateralToken), reservePool, 1000 ether);

        invariantFile = openFile(
            "invariant",
            sa("Collateral Ratio", "Leverage Ratio", "Pegged NAV", "Leveraged NAV", "Collateral NAV")
        );
    }

    function setDown() internal override {
        vm.closeFile(invariantFile);
    }

    function doOneCollateralRatio() internal override {
        // write a gnuplot data file line for fees, invariant and liquidation

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
