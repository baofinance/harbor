// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Test} from "forge-std/Test.sol";
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
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";

import {StabilityPool_v1} from "src/minter/StabilityPool_v1.sol";
import {StabilityPoolManager_v1} from "src/minter/StabilityPoolManager_v1.sol";

import {Deployed} from "@bao/Deployed.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";

import "test/Useful.sol";
import {TestCollateralRatioRangeSetUp} from "test/CollateralRatio.t.sol";
import {Array} from "test/Array.sol";
import {TestGraphs} from "test/Graphs.t.sol";

contract TestGraphsLiquidatePartial is TestGraphs, TestCollateralRatioRangeSetUp {
    string liquidateFile;
    address stabilityPoolManagerCollateral;
    address stabilityPoolManagerLeveraged;
    address stabilityPoolManagerBoth;
    address bountyReceiver;
    address treasury;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public override {
        super.setUp();

        IStabilityPool(stabilityPoolCollateral).deposit(4 * startPrice, address(this), 0);
        IStabilityPool(stabilityPoolLeveraged).deposit(4 * startPrice, address(this), 0);

        bountyReceiver = makeAddr("bountyReceiver");
        treasury = makeAddr("treasury");

        address stabilityPoolCollateralEmpty = _setupStabilityPool(wrappedCollateralToken);
        address stabilityPoolLeveragedEmpty = _setupStabilityPool(leveragedToken);

        uint256 rebalancerRole = IStabilityPool(stabilityPoolCollateral).REBALANCER_ROLE();
        uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();

        // set up the stability pool managers
        stabilityPoolManagerCollateral = UnsafeUpgrades.deployUUPSProxy(
            address(
                new StabilityPoolManager_v1(minter, treasury, stabilityPoolCollateral, stabilityPoolLeveragedEmpty)
            ),
            abi.encodeCall(StabilityPoolManager_v1.initialize, owner)
        );
        IStabilityPoolManager(stabilityPoolManagerCollateral).updateRebalanceThreshold(1.3 ether);
        vm.startPrank(owner);
        IBaoRoles(stabilityPoolCollateral).grantRoles(stabilityPoolManagerCollateral, rebalancerRole);
        IBaoRoles(stabilityPoolLeveragedEmpty).grantRoles(stabilityPoolManagerCollateral, rebalancerRole);
        IBaoRoles(minter).grantRoles(stabilityPoolManagerCollateral, zeroFeeRole);
        vm.stopPrank();

        stabilityPoolManagerLeveraged = UnsafeUpgrades.deployUUPSProxy(
            address(
                new StabilityPoolManager_v1(minter, treasury, stabilityPoolCollateralEmpty, stabilityPoolLeveraged)
            ),
            abi.encodeCall(StabilityPoolManager_v1.initialize, owner)
        );
        IStabilityPoolManager(stabilityPoolManagerLeveraged).updateRebalanceThreshold(1.3 ether);
        vm.startPrank(owner);
        IBaoRoles(stabilityPoolCollateralEmpty).grantRoles(stabilityPoolManagerLeveraged, rebalancerRole);
        IBaoRoles(stabilityPoolLeveraged).grantRoles(stabilityPoolManagerLeveraged, rebalancerRole);
        IBaoRoles(minter).grantRoles(stabilityPoolManagerLeveraged, zeroFeeRole);
        vm.stopPrank();

        stabilityPoolManagerBoth = UnsafeUpgrades.deployUUPSProxy(
            address(new StabilityPoolManager_v1(minter, treasury, stabilityPoolCollateral, stabilityPoolLeveraged)),
            abi.encodeCall(StabilityPoolManager_v1.initialize, owner)
        );
        IStabilityPoolManager(stabilityPoolManagerBoth).updateRebalanceThreshold(1.3 ether);
        vm.startPrank(owner);
        IBaoRoles(stabilityPoolLeveraged).grantRoles(stabilityPoolManagerBoth, rebalancerRole);
        IBaoRoles(stabilityPoolCollateral).grantRoles(stabilityPoolManagerBoth, rebalancerRole);
        IBaoRoles(minter).grantRoles(stabilityPoolManagerBoth, zeroFeeRole);
        vm.stopPrank();

        liquidateFile = openFile(
            "liquidate_partial",
            sa(
                "before CR",
                "CR after liquidate to collateral",
                "CR after liquidate to leveraged",
                "CR after liquidate to both",
                "pegged before",
                "pegged after liquidate to collateral",
                "pegged after liquidate to leveraged",
                "pegged after liquidate to both"
            )
        );
    }

    function setDown() internal override {
        vm.closeFile(liquidateFile);
    }

    function doOneCollateralRatio() internal override {
        uint256 beforeLiquidatePeggedTokens = IMinter(minter).peggedTokenBalance();
        uint256 beforeLiquidate = IMinter(minter).collateralRatio();
        uint256 afterLiquidateCollateral;
        uint256 afterLiquidateLeveraged;
        uint256 afterLiquidateBoth;
        uint256 afterLiquidateCollateralPeggedTokens;
        uint256 afterLiquidateLeveragedPeggedTokens;
        uint256 afterLiquidateBothPeggedTokens;

        uint256 snap = vm.snapshotState();
        if (IStabilityPoolManager(stabilityPoolManagerCollateral).rebalanceable()) {
            IStabilityPoolManager(stabilityPoolManagerCollateral).rebalance(bountyReceiver, 0);
            afterLiquidateCollateral = IMinter(minter).collateralRatio();
        } else {
            afterLiquidateCollateral = beforeLiquidate;
        }
        afterLiquidateCollateralPeggedTokens = IMinter(minter).peggedTokenBalance();
        vm.revertToState(snap);

        if (IStabilityPoolManager(stabilityPoolManagerLeveraged).rebalanceable()) {
            IStabilityPoolManager(stabilityPoolManagerLeveraged).rebalance(bountyReceiver, 0);
            afterLiquidateLeveraged = IMinter(minter).collateralRatio();
        } else {
            afterLiquidateLeveraged = beforeLiquidate;
        }
        afterLiquidateLeveragedPeggedTokens = IMinter(minter).peggedTokenBalance();
        vm.revertToState(snap);

        if (IStabilityPoolManager(stabilityPoolManagerBoth).rebalanceable()) {
            IStabilityPoolManager(stabilityPoolManagerBoth).rebalance(bountyReceiver, 0);
            afterLiquidateBoth = IMinter(minter).collateralRatio();
        } else {
            afterLiquidateBoth = beforeLiquidate;
        }
        afterLiquidateBothPeggedTokens = IMinter(minter).peggedTokenBalance();
        vm.revertToState(snap);

        writeLine(
            liquidateFile,
            ua(
                currentCollateralRatio,
                afterLiquidateCollateral,
                afterLiquidateLeveraged,
                afterLiquidateBoth,
                beforeLiquidatePeggedTokens,
                afterLiquidateCollateralPeggedTokens,
                afterLiquidateLeveragedPeggedTokens,
                afterLiquidateBothPeggedTokens
            )
        );
    }
}

contract TestGraphsLiquidate is TestGraphs, TestCollateralRatioRangeSetUp {
    string liquidateFile;
    string toFile;
    address stabilityPoolManager;
    address bountyReceiver;
    address treasury;
    uint256 peggedForSPCRatio;
    uint256 peggedForSPLRatio;
    address user;

    constructor(uint256 peggedForSPCRatio_, uint256 peggedForSPLRatio_) {
        peggedForSPCRatio = peggedForSPCRatio_;
        peggedForSPLRatio = peggedForSPLRatio_;
    }

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public override {
        super.setUp();
        uint256 minterPegged = IMinter(minter).peggedTokenBalance();

        uint256 peggedForSPC = (peggedForSPCRatio * minterPegged) / 1 ether;
        uint256 peggedForSPL = (peggedForSPLRatio * minterPegged) / 1 ether;
        if (peggedForSPC > 0) {
            IStabilityPool(stabilityPoolCollateral).deposit(peggedForSPC, address(this), 0);
        }
        if (peggedForSPL > 0) {
            IStabilityPool(stabilityPoolLeveraged).deposit(peggedForSPL, address(this), 0);
        }
        user = address(this);
        bountyReceiver = makeAddr("bountyReceiver");
        treasury = makeAddr("treasury");

        uint256 rebalancerRole = IStabilityPool(stabilityPoolCollateral).REBALANCER_ROLE();
        uint256 zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();

        // set up the stability pool managers
        stabilityPoolManager = UnsafeUpgrades.deployUUPSProxy(
            address(new StabilityPoolManager_v1(minter, treasury, stabilityPoolCollateral, stabilityPoolLeveraged)),
            abi.encodeCall(StabilityPoolManager_v1.initialize, owner)
        );
        IStabilityPoolManager(stabilityPoolManager).updateRebalanceThreshold(1.3 ether);
        vm.startPrank(owner);
        IBaoRoles(stabilityPoolCollateral).grantRoles(stabilityPoolManager, rebalancerRole);
        IBaoRoles(stabilityPoolLeveraged).grantRoles(stabilityPoolManager, rebalancerRole);
        IBaoRoles(minter).grantRoles(stabilityPoolManager, zeroFeeRole);
        vm.stopPrank();

        liquidateFile = openFile(
            "liquidate",
            sa(
                "current CR",
                "before CR",
                "after CR",
                "before minter pegged",
                "after minter pegged",
                "before SPCollateral pegged",
                "after SPCollateral pegged",
                "before SPLeveraged pegged",
                "after SPLeveraged pegged"
            )
        );

        toFile = openFile(
            "liquidate_to",
            sa(
                "current CR",
                "after user collateral",
                "after SPCollateral collateral",
                "after user leveraged",
                "after SPLeveraged leveraged",
                "",
                "after minter collateral",
                "after user SPCollateral balance",
                "after user SPLeveraged balance"
            )
        );
    }

    function setDown() internal override {
        vm.closeFile(liquidateFile);
        vm.closeFile(toFile);
    }

    struct Measures {
        uint256 collateralRatio;
        uint256 minterPegged;
        uint256 minterCollateral;
        uint256 stabilityPoolCollateralPegged;
        uint256 stabilityPoolLeveragedPegged;
        uint256 stabilityPoolCollateralCollateral;
        uint256 stabilityPoolLeveragedLeveraged;
        uint256 userCollateral;
        uint256 userLeveraged;
        uint256 userBalanceSPCollateral;
        uint256 userBalanceSPLeveraged;
    }

    function _readMeasures() internal view returns (Measures memory m) {
        m.collateralRatio = IMinter(minter).collateralRatio();
        m.minterPegged = IMinter(minter).peggedTokenBalance();
        m.minterCollateral = IERC20(wrappedCollateralToken).balanceOf(minter);
        m.stabilityPoolCollateralPegged = IERC20(peggedToken).balanceOf(stabilityPoolCollateral);
        m.stabilityPoolLeveragedPegged = IERC20(peggedToken).balanceOf(stabilityPoolLeveraged);
        m.stabilityPoolCollateralCollateral = IERC20(wrappedCollateralToken).balanceOf(stabilityPoolCollateral);
        m.stabilityPoolLeveragedLeveraged = IERC20(leveragedToken).balanceOf(stabilityPoolLeveraged);
        m.userCollateral = IMultipleRewardAccumulator(stabilityPoolCollateral).claimable(user, wrappedCollateralToken);
        m.userLeveraged = IMultipleRewardAccumulator(stabilityPoolLeveraged).claimable(user, leveragedToken);
        m.userBalanceSPCollateral = IStabilityPool(stabilityPoolCollateral).assetBalanceOf(user);
        m.userBalanceSPLeveraged = IStabilityPool(stabilityPoolLeveraged).assetBalanceOf(user);
    }

    function doOneCollateralRatio() internal override {
        Measures memory pre = _readMeasures();

        uint256 snap = vm.snapshotState();

        if (IStabilityPoolManager(stabilityPoolManager).rebalanceable()) {
            IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);
        }

        Measures memory post = _readMeasures();

        vm.revertToState(snap);

        writeLine(
            liquidateFile,
            ua(
                currentCollateralRatio,
                pre.collateralRatio,
                post.collateralRatio,
                pre.minterPegged,
                post.minterPegged,
                pre.stabilityPoolCollateralPegged,
                post.stabilityPoolCollateralPegged,
                pre.stabilityPoolLeveragedPegged,
                post.stabilityPoolLeveragedPegged
            )
        );
        writeLine(
            toFile,
            ua(
                currentCollateralRatio,
                post.userCollateral,
                post.stabilityPoolCollateralCollateral,
                post.userLeveraged,
                post.stabilityPoolLeveragedLeveraged,
                0,
                post.minterCollateral,
                post.userBalanceSPCollateral,
                post.userBalanceSPLeveraged
            )
        );
    }
}

contract TestGraphsLiquidateAllCollateral is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(1 ether, 0) {}
    function context() internal pure override returns (string memory) {
        return "_all_collateral";
    }
}

contract TestGraphsLiquidateAllLeveraged is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(0, 1 ether) {}

    function context() internal pure override returns (string memory) {
        return "_all_leveraged";
    }
}

contract TestGraphsLiquidateAllBoth is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(1 ether / 2, 1 ether - 1 ether / 2) {}
    function context() internal pure override returns (string memory) {
        return "_all_both";
    }
}

//////////////////////

contract TestGraphsLiquidatePartialCollateral is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(1 ether / 2, 0) {}
    function context() internal pure override returns (string memory) {
        return "_partial_collateral";
    }
}

contract TestGraphsLiquidatePartialLeveraged is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(0, 1 ether / 2) {}
    function context() internal pure override returns (string memory) {
        return "_partial_leveraged";
    }
}

contract TestGraphsLiquidatePartialBoth33 is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(0.4 ether, 0.4 ether) {}
    function context() internal pure override returns (string memory) {
        return "_partial_both44";
    }
}

contract TestGraphsLiquidatePartialBoth15 is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(0.2 ether, 0.6 ether) {}
    function context() internal pure override returns (string memory) {
        return "_partial_both26";
    }
}

contract TestGraphsLiquidatePartialBoth51 is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(0.6 ether, 0.2 ether) {}
    function context() internal pure override returns (string memory) {
        return "_partial_both62";
    }
}

//////////////////////

contract TestGraphsLiquidateParameters is TestGraphs, TestCollateralRatioRangeSetUp {
    string file;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    function setUp() public override {
        super.setUp();

        file = openFile(
            "liquidate_parameters",
            sa(
                "current CR",
                "pegged for collateral for 1.01",
                "pegged for leveraged for 1.01",
                "pegged for collateral for 1.25",
                "pegged for leveraged for 1.25",
                "pegged for collateral for 1.5",
                "pegged for leveraged for 1.5"
            )
        );
    }

    function setDown() internal override {
        vm.closeFile(file);
    }

    function doOneCollateralRatio() internal override {
        (uint256 peggedForCollateral101, uint256 peggedForLeveraged101) = IMinter(minter)
            .redeemPeggedForCollateralRatio(1.01 ether);
        (uint256 peggedForCollateral125, uint256 peggedForLeveraged125) = IMinter(minter)
            .redeemPeggedForCollateralRatio(1.25 ether);
        (uint256 peggedForCollateral150, uint256 peggedForLeveraged150) = IMinter(minter)
            .redeemPeggedForCollateralRatio(1.50 ether);
        writeLine(
            file,
            ua(
                currentCollateralRatio,
                peggedForCollateral101,
                peggedForLeveraged101,
                peggedForCollateral125,
                peggedForLeveraged125,
                peggedForCollateral150,
                peggedForLeveraged150
            )
        );
    }
}
