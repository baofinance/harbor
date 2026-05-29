// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IMultipleRewardAccumulator_v3 as IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator_v3.sol";

import {StabilityPoolManager_v2} from "@harbor/minter/StabilityPoolManager_v2.sol";

import "@harbor-test/Useful.sol";
import {TestCollateralRatioRangeSetUp} from "@harbor-test/CollateralRatio.t.sol";
import {TestGraphs} from "@harbor-test/Graphs.t.sol";

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
                new StabilityPoolManager_v2(minter, treasury, stabilityPoolCollateral, stabilityPoolLeveragedEmpty)
            ),
            abi.encodeCall(StabilityPoolManager_v2.initialize, owner)
        );
        IStabilityPoolManager(stabilityPoolManagerCollateral).updateRebalanceThreshold(1.3 ether);
        vm.startPrank(owner);
        IBaoRoles(stabilityPoolCollateral).grantRoles(stabilityPoolManagerCollateral, rebalancerRole);
        IBaoRoles(stabilityPoolLeveragedEmpty).grantRoles(stabilityPoolManagerCollateral, rebalancerRole);
        IBaoRoles(minter).grantRoles(stabilityPoolManagerCollateral, zeroFeeRole);
        vm.stopPrank();

        stabilityPoolManagerLeveraged = UnsafeUpgrades.deployUUPSProxy(
            address(
                new StabilityPoolManager_v2(minter, treasury, stabilityPoolCollateralEmpty, stabilityPoolLeveraged)
            ),
            abi.encodeCall(StabilityPoolManager_v2.initialize, owner)
        );
        IStabilityPoolManager(stabilityPoolManagerLeveraged).updateRebalanceThreshold(1.3 ether);
        vm.startPrank(owner);
        IBaoRoles(stabilityPoolCollateralEmpty).grantRoles(stabilityPoolManagerLeveraged, rebalancerRole);
        IBaoRoles(stabilityPoolLeveraged).grantRoles(stabilityPoolManagerLeveraged, rebalancerRole);
        IBaoRoles(minter).grantRoles(stabilityPoolManagerLeveraged, zeroFeeRole);
        vm.stopPrank();

        stabilityPoolManagerBoth = UnsafeUpgrades.deployUUPSProxy(
            address(new StabilityPoolManager_v2(minter, treasury, stabilityPoolCollateral, stabilityPoolLeveraged)),
            abi.encodeCall(StabilityPoolManager_v2.initialize, owner)
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
                "pegged after liquidate to both",
                "before leveraged price",
                "price after liquidate to collateral",
                "price after liquidate to leveraged",
                "price after liquidate to both"
            )
        );
    }

    function setDown() internal override {
        vm.closeFile(liquidateFile);
    }

    struct PartialMeasures {
        uint256 beforeCR;
        uint256 beforePegged;
        uint256 beforePrice;
        uint256 afterCR_collateral;
        uint256 afterCR_leveraged;
        uint256 afterCR_both;
        uint256 afterPegged_collateral;
        uint256 afterPegged_leveraged;
        uint256 afterPegged_both;
        uint256 afterPrice_collateral;
        uint256 afterPrice_leveraged;
        uint256 afterPrice_both;
    }

    function doOneCollateralRatio() internal override {
        PartialMeasures memory m;
        m.beforePegged = IMinter(minter).peggedTokenBalance();
        m.beforeCR = IMinter(minter).collateralRatio();
        m.beforePrice = IMinter(minter).leveragedTokenPrice();

        uint256 snap = vm.snapshotState();
        if (IStabilityPoolManager(stabilityPoolManagerCollateral).rebalanceable()) {
            IStabilityPoolManager(stabilityPoolManagerCollateral).rebalance(bountyReceiver, 0);
            m.afterCR_collateral = IMinter(minter).collateralRatio();
            m.afterPrice_collateral = IMinter(minter).leveragedTokenPrice();
        } else {
            m.afterCR_collateral = m.beforeCR;
            m.afterPrice_collateral = m.beforePrice;
        }
        m.afterPegged_collateral = IMinter(minter).peggedTokenBalance();
        vm.revertToState(snap);

        if (IStabilityPoolManager(stabilityPoolManagerLeveraged).rebalanceable()) {
            IStabilityPoolManager(stabilityPoolManagerLeveraged).rebalance(bountyReceiver, 0);
            m.afterCR_leveraged = IMinter(minter).collateralRatio();
            m.afterPrice_leveraged = IMinter(minter).leveragedTokenPrice();
        } else {
            m.afterCR_leveraged = m.beforeCR;
            m.afterPrice_leveraged = m.beforePrice;
        }
        m.afterPegged_leveraged = IMinter(minter).peggedTokenBalance();
        vm.revertToState(snap);

        if (IStabilityPoolManager(stabilityPoolManagerBoth).rebalanceable()) {
            IStabilityPoolManager(stabilityPoolManagerBoth).rebalance(bountyReceiver, 0);
            m.afterCR_both = IMinter(minter).collateralRatio();
            m.afterPrice_both = IMinter(minter).leveragedTokenPrice();
        } else {
            m.afterCR_both = m.beforeCR;
            m.afterPrice_both = m.beforePrice;
        }
        m.afterPegged_both = IMinter(minter).peggedTokenBalance();
        vm.revertToState(snap);

        writeLine(
            liquidateFile,
            ua(
                currentCollateralRatio,
                m.afterCR_collateral,
                m.afterCR_leveraged,
                m.afterCR_both,
                m.beforePegged,
                m.afterPegged_collateral,
                m.afterPegged_leveraged,
                m.afterPegged_both,
                m.beforePrice,
                m.afterPrice_collateral,
                m.afterPrice_leveraged,
                m.afterPrice_both
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
            address(new StabilityPoolManager_v2(minter, treasury, stabilityPoolCollateral, stabilityPoolLeveraged)),
            abi.encodeCall(StabilityPoolManager_v2.initialize, owner)
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
                "after SPLeveraged pegged",
                "before leveraged price",
                "after leveraged price"
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
                "after user SPLeveraged balance",
                "after leveraged price"
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
        uint256 leveragedTokenPrice;
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
        m.userBalanceSPCollateral = IERC20(stabilityPoolCollateral).balanceOf(user);
        m.userBalanceSPLeveraged = IERC20(stabilityPoolLeveraged).balanceOf(user);
        m.leveragedTokenPrice = IMinter(minter).leveragedTokenPrice();
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
                post.stabilityPoolLeveragedPegged,
                pre.leveragedTokenPrice,
                post.leveragedTokenPrice
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
                post.userBalanceSPLeveraged,
                post.leveragedTokenPrice
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
