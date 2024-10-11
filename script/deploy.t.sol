// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/StdJson.sol";
import "forge-std/console2.sol";

import { IMinter } from "src/minter/IMinter.sol";
import { IRebalancePool } from "src/minter/IRebalancePool.sol";

import "src/minter/LeveragedToken_v1.sol";
import "src/minter/Genesis_v1.sol";

import { TestMinterBasics, TestMinterSetUp, TestMinter0 } from "test/Minter_base.t.sol";
import { Deployed } from "@bao/Deployed.sol";

import { DeployState } from "./DeployState.sol";

contract TestDeploySetUp is TestMinterSetUp, DeployState {
    address rebalancePoolCollateral;
    address rebalancePoolLeveraged;

    address genesis;

    string network;

    constructor() {
        network = "local";
        setStateFile(network);
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
        genesis = addr("genesis");

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
    function test_leveragedToken() public view {
        // TODO: test introspection, etc.
        // This needs to re-use the code in TestLeveragedToken

        // has the right meta data
        assertEq(IERC20Metadata(leveragedToken).symbol(), "BaoUSD-wstETH");
        assertEq(IERC20Metadata(leveragedToken).name(), "BaoMinter BaoUSD-wstETH");
        assertEq(IERC20Metadata(leveragedToken).decimals(), 18);

        // correct access
        assertEq(IOwnable(leveragedToken).owner(), Deployed.BAOMULTISIG);
        assertTrue(IOwnableRoles(leveragedToken).hasAllRoles(minter, ILeveragedToken(leveragedToken).MINTER_ROLE()));
    }

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

    function test_genesis() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Genesis_v1(genesis).initialize(address(this), minter);

        // check the data has been set up correctly
        assertEq(IOwnable(genesis).owner(), owner, "wrong owner");
        assertEq(IGenesis(genesis).collateralToken(), collateralToken, "wrong collateral");
        assertEq(IGenesis(genesis).peggedToken(), peggedToken, "wrong pegged");
        assertEq(IGenesis(genesis).leveragedToken(), leveragedToken, "wrong leveraged");
        assertEq(IGenesis(genesis).balanceOf(address(this)), 0, "wrong balance");
        assertFalse(IGenesis(genesis).genesisIsEnded());

        vm.expectRevert(IGenesis.GenesisIsNotEnded.selector);
        IGenesis(genesis).claimable(address(this));
    }
}
