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

        bountyReceiver = vm.createWallet("bountyReceiver").addr;
        treasury = vm.createWallet("treasury").addr;

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
    address stabilityPoolManager;
    address bountyReceiver;
    address treasury;
    uint256 peggedForSPCRatio;
    uint256 peggedForSPLRatio;

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
        bountyReceiver = vm.createWallet("bountyReceiver").addr;
        treasury = vm.createWallet("treasury").addr;

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
    }

    function setDown() internal override {
        vm.closeFile(liquidateFile);
    }

    function doOneCollateralRatio() internal override {
        uint256 beforeCollateralRatio = IMinter(minter).collateralRatio();
        uint256 beforeMinterPegged = IMinter(minter).peggedTokenBalance();
        uint256 beforeStabilityPoolCollateralPegged = IERC20(peggedToken).balanceOf(stabilityPoolCollateral);
        uint256 beforeStabilityPoolLeveragedPegged = IERC20(peggedToken).balanceOf(stabilityPoolLeveraged);

        uint256 snap = vm.snapshotState();

        if (IStabilityPoolManager(stabilityPoolManager).rebalanceable()) {
            IStabilityPoolManager(stabilityPoolManager).rebalance(bountyReceiver, 0);
        }
        uint256 afterCollateralRatio = IMinter(minter).collateralRatio();
        uint256 afterMinterPegged = IMinter(minter).peggedTokenBalance();
        uint256 afterStabilityPoolCollateralPegged = IERC20(peggedToken).balanceOf(stabilityPoolCollateral);
        uint256 afterStabilityPoolLeveragedPegged = IERC20(peggedToken).balanceOf(stabilityPoolLeveraged);

        vm.revertToState(snap);

        writeLine(
            liquidateFile,
            ua(
                currentCollateralRatio,
                beforeCollateralRatio,
                afterCollateralRatio,
                beforeMinterPegged,
                afterMinterPegged,
                beforeStabilityPoolCollateralPegged,
                afterStabilityPoolCollateralPegged,
                beforeStabilityPoolLeveragedPegged,
                afterStabilityPoolLeveragedPegged
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

contract TestGraphsLiquidatePartialBoth is TestGraphsLiquidate {
    constructor() TestGraphsLiquidate(1 ether / 4, 1 ether / 4) {}
    function context() internal pure override returns (string memory) {
        return "_partial_both";
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
        writeLine(
            file,
            ua(
                currentCollateralRatio,
                IMinter(minter).redeemPeggedForCollateralRatio(1.01 ether),
                IMinter(minter).swapPeggedForLeveragedForCollateralRatio(1.01 ether),
                IMinter(minter).redeemPeggedForCollateralRatio(1.25 ether),
                IMinter(minter).swapPeggedForLeveragedForCollateralRatio(1.25 ether),
                IMinter(minter).redeemPeggedForCollateralRatio(1.5 ether),
                IMinter(minter).swapPeggedForLeveragedForCollateralRatio(1.5 ether)
            )
        );
    }
}
