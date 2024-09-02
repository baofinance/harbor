// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/StdJson.sol";
import "forge-std/console2.sol";

import { TestMinterBasics, TestMinterSetUp } from "test/Minter_base.t.sol";
import { deployed } from "test/deployed.sol";

contract TestDeploy is TestMinterBasics {
    address rebalancePoolCollateral;
    address rebalancePoolLeveraged;

    string network;
    string addresses;

    constructor() {
        network = "local";
        addresses = vm.readFile(string.concat("./results/deploy-", network, ".log"));
    }

    function addr(string memory name) private view returns (address) {
        return vm.parseJsonAddress(addresses, string.concat(".", name)); // jq style path
    }

    function setUpFork() public override(TestMinterSetUp) {
        vm.createSelectFork(vm.rpcUrl(network));

        owner = addr("owner");
        priceOracle = addr("priceOracle");
        leveragedToken = addr("leveragedToken");
        feeReceiver = addr("feeReceiver");
        peggedToken = addr("peggedToken");
        collateralToken = addr("collateralToken");
        reservePool = addr("reservePool");
        minter = addr("minter");
    }

    function setUp() public override {
        super.setUp();
        // override the config set up as it is in the deploy script
        config.rebalanceCollateralRatioUpperBound = _percentToEther(130);
        config.harvestCollateralRatioLowerBound = _percentToEther(250);
        config.mintPeggedIncentiveConfig = ic(ua(131, 140), ia(disallow, 100, 50));
        config.mintLeveragedIncentiveConfig = ic(ua(110, 120, 145), ia(-50, 0, 20, 70));
        config.redeemPeggedIncentiveConfig = ic(ua(105, 115, 150), ia(-75, -25, 60, 80));
        config.redeemLeveragedIncentiveConfig = ic(ua(105, 135), ia(disallow, 150, 120));
    }

    function test_rebalanceConnections() public pure {
        assertTrue(true);
    }
}
