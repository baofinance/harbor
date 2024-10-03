// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/StdJson.sol";
import "forge-std/console2.sol";

import { IMinter } from "src/minter/IMinter.sol";
import { IRebalancePool } from "src/minter/IRebalancePool.sol";

import "src/minter/LeveragedToken_v1.sol";

import { TestMinterBasics, TestMinterSetUp, TestMinter0 } from "test/Minter_base.t.sol";
import { deployed } from "@bao/deployed.sol";

contract TestDeploySetUp is TestMinterSetUp {
    address rebalancePoolCollateral;
    address rebalancePoolLeveraged;

    string network;
    string addresses;

    constructor() {
        network = "local";
        addresses = vm.readFile(string.concat("./results/deploy-", network, ".log"));
    }

    function addr(string memory name) private view returns (address it) {
        it = vm.parseJsonAddress(addresses, string.concat(".", name)); // jq style path
        vm.assertNotEq(it, address(0), string.concat("zero address for ", name));
    }

    function setUpFork() internal virtual override(TestMinterSetUp) {
        console2.log("TestDeploySetUp.setUpFork()");
        vm.createSelectFork(vm.rpcUrl(network));

        owner = addr("owner");
        priceOracle = addr("priceOracle");
        leveragedToken = addr("leveragedToken");
        feeReceiver = addr("feeReceiver");
        peggedToken = addr("peggedToken");
        collateralToken = addr("collateralToken");
        reservePool = addr("reservePool");
        minter = addr("minter");
        rebalancePoolCollateral = addr("rebalancePoolCollateral");
        rebalancePoolLeveraged = addr("rebalancePoolLeveraged");

        uint256 minterRole = LeveragedToken_v1(leveragedToken).MINTER_ROLE();
        vm.prank(owner);
        OwnableRoles(leveragedToken).grantRoles(minter, minterRole);
    }

    function setUpConfig() internal virtual override {
        // override the config set up as it is in the deploy script
        config.rebalanceCollateralRatioUpperBound = _percentToEther(130);
        config.harvestCollateralRatioLowerBound = _percentToEther(250);
        config.mintPeggedIncentiveConfig = ic(ua(131, 140), ia(disallow, 100, 50));
        config.mintLeveragedIncentiveConfig = ic(ua(110, 120, 145), ia(-50, 0, 20, 70));
        config.redeemPeggedIncentiveConfig = ic(ua(105, 115, 150), ia(-75, -25, 60, 80));
        config.redeemLeveragedIncentiveConfig = ic(ua(105, 135), ia(disallow, 150, 120));
    }
}

contract TestDeploy0 is TestMinter0, TestDeploySetUp {
    function setUp() public override(TestMinter0, TestMinterSetUp) {}

    function setUpFork() internal override(TestDeploySetUp, TestMinterSetUp) {
        TestDeploySetUp.setUpFork();
    }

    function setUpConfig() internal override(TestDeploySetUp, TestMinterSetUp) {
        TestDeploySetUp.setUpConfig();
    }

    function test_setUp() public virtual override {
        TestMinter0.setUp();
    }
}

contract TestDeploy is TestDeploySetUp {
    function _test_rebalanceConnections(address rp, address liquidateTo) private view {
        assertEq(IRebalancePool(rp).minter(), minter);
        assertEq(IRebalancePool(rp).liquidatableCollateralRatio(), IMinter(minter).rebalanceCollateralRatio());
        assertEq(IRebalancePool(rp).liquidationToken(), liquidateTo);
        assertEq(IRebalancePool(rp).assetToken(), peggedToken);
        assertEq(IRebalancePool(rp).totalAssetSupply(), 0);
    }

    function test_rebalancePool() public view {
        _test_rebalanceConnections(rebalancePoolLeveraged, leveragedToken);
        _test_rebalanceConnections(rebalancePoolCollateral, collateralToken);
    }
}
