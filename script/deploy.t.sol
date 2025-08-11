// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/StdJson.sol";
import "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
// import { IBaoOwnableRoles } from "@bao/interfaces/IBaoOwnableRoles.sol";

import {Deployed} from "@bao/Deployed.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {DeployState} from "./DeployState.sol";

import {TestLeveragedToken} from "lib/bao-base/test/MintableBurnableERC20.t.sol";
import {TestReservePool} from "test/ReservePool.t.sol";
import {TestTokenDistributor} from "test/TokenDistributor.t.sol";
import {TestMinterBasics} from "test/Minter_base.t.sol";
import {IBaoUSD} from "test/IBaoUSD.sol";

contract TestDeployed is Test, DeployState {
    string network;

    function setUp_fork() internal /*string network*/ {
        network = "local"; // TODO: read from env
        string memory chain = "mainnet";
        string memory script = "deploy-minter";
        setStateFile(network, chain, script);
        vm.createSelectFork(vm.rpcUrl(network));
    }
}

contract TestDeployedLeveragedToken is TestLeveragedToken, TestDeployed {
    function setUpFork() internal override {
        setUp_fork();
        owner = addr("owner");
        minter = addr("minter");
        // Align expected leveraged token metadata with deploy script
        name = "Zhenglong governance steamedPBxstETH";
        symbol = "steamedPBxstETH";
    }

    function setUpContract() internal override {
        leveragedToken = addr("leveragedToken");
    }
}

contract TestDeployedFeeDistributor is TestTokenDistributor, TestDeployed {
    function setUpFork() internal override {
        setUp_fork();
        owner = addr("owner");
        claimer = addr("owner");
    }

    function setUpContract() internal override {
        name = "Fee Receiver";
        tokenDistributor = addr("feeReceiver");
    }
}

contract TestDeployedReservePool is TestReservePool, TestDeployed {
    function setUpFork() internal override {
        setUp_fork();
        owner = addr("owner");
        bonusReceiver = addr("minter");
        minter = addr("minter");
    }

    function setUpContract() internal override {
        reservePool = addr("reservePool");
    }
}

contract TestDeployedMinter is TestMinterBasics, TestDeployed {
    function setUpFork() internal override {
        setUp_fork();
        owner = addr("owner");
        peggedToken = addr("peggedToken");
        leveragedToken = addr("leveragedToken");
        wrappedCollateralToken = addr("wrappedCollateralToken");
        priceOracle = addr("priceOracle");
        feeReceiver = addr("feeReceiver");
        reservePool = addr("reservePool");
    }

    function setUpConfig() internal override {
        config = readConfig("free");
    }

    function setUpContract() internal override {
        minter = addr("minter");
        zeroFee = addr("developer");

        // TODO: this is a hack to for BaoUSD
        address operator = IBaoUSD(Deployed.BaoUSD).operator();
        vm.prank(operator);
        IBaoUSD(Deployed.BaoUSD).addMinter(minter);
    }
}

/*
contract TestDeploySetUp is TestMinterSetUp, TestDeployed {
    address stabilityPoolCollateral;
    address stabilityPoolLeveraged;

    address genesis;

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
        stabilityPoolCollateral = addr("stabilityPoolCollateral");
        stabilityPoolLeveraged = addr("stabilityPoolLeveraged");
        genesis = addr("genesis");

        uint256 minterRole = MintableBurnableERC20_v1(leveragedToken).MINTER_ROLE();
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

contract TestDeploy is TestDeploySetUp {
    function test_leveragedToken() public view {
        // TODO: test introspection, etc.
        // This needs to re-use the code in TestLeveragedToken

        // has the right meta data
        assertEq(IERC20Metadata(leveragedToken).symbol(), "BaoUSD-wstETH");
        assertEq(IERC20Metadata(leveragedToken).name(), "BaoMinter BaoUSD-wstETH");
        assertEq(IERC20Metadata(leveragedToken).decimals(), 18);

        // correct access
        assertEq(IBaoOwnable(leveragedToken).owner(), Deployed.BAOMULTISIG);
        assertTrue(IBaoRoles(leveragedToken).hasAllRoles(minter, ILeveragedToken(leveragedToken).MINTER_ROLE()));
    }

    function _test_stabilityConnections(address sp, address liquidateTo) private view {
        assertEq(IStabilityPool(sp).minter(), minter);
        assertEq(IStabilityPool(sp).liquidatableCollateralRatio(), IMinter(minter).rebalanceCollateralRatio());
        assertEq(IStabilityPool(sp).liquidationToken(), liquidateTo);
        assertEq(IStabilityPool(sp).assetToken(), peggedToken);
        assertEq(IStabilityPool(sp).totalAssetSupply(), 0);
    }

    function test_stabilityPool() public view {
        _test_stabilityConnections(stabilityPoolLeveraged, leveragedToken);
        _test_stabilityConnections(stabilityPoolCollateral, collateralToken);
    }

    function test_genesis() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Genesis_v1(genesis).initialize(address(this), minter);

        // check the data has been set up correctly
        assertEq(IBaoOwnable(genesis).owner(), owner, "wrong owner");
        assertEq(IGenesis(genesis).collateralToken(), collateralToken, "wrong collateral");
        assertEq(IGenesis(genesis).peggedToken(), peggedToken, "wrong pegged");
        assertEq(IGenesis(genesis).leveragedToken(), leveragedToken, "wrong leveraged");
        assertEq(IGenesis(genesis).balanceOf(address(this)), 0, "wrong balance");
        assertFalse(IGenesis(genesis).genesisIsEnded());

        vm.expectRevert(IGenesis.GenesisIsNotEnded.selector);
        IGenesis(genesis).claimable(address(this));
    }
}
*/
