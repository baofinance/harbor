// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { Minter_v1 } from "src/minter/Minter_v1.sol";
import { LeveragedToken_v1 } from "src/minter/LeveragedToken_v1.sol";
import { ReservePool_v1 } from "src/minter/ReservePool_v1.sol";

import { IMinter, IMinterTreasury } from "src/minter/IMinter.sol";
import { IMintable } from "src/minter/IMintable.sol";
import { IReservePool } from "src/minter/IReservePool.sol";
import { deployed } from "test/deployed.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";
import { MockRateProvider } from "test/MockRateProvider.sol";
import { IBaoUSD } from "test/IBaoUSD.sol";
import "test/Useful.sol";

contract TestMinter is Test {
    address minter;
    IMinter.Config config;

    address bonusToken;

    address leveragedToken;
    address reservePool;
    MockPriceOracle priceOracle;
    MockRateProvider rateProvider;

    Vm.Wallet feeReceiver;
    Vm.Wallet owner;
    bytes32 ownerRole = 0;
    bytes32 zeroFeeRole = keccak256("ZERO_FEE_ROLE");
    bytes32 minterRole = keccak256("MINTER_ROLE");

    uint256 danger;
    uint256 dangerCollateralRatioUpperBound;
    int256 mintPeggedNormalFeeRatio;
    int256 mintPeggedDangerFeeRatio;
    int256 mintLeveragedNormalFeeRatio;
    int256 mintLeveragedDangerFeeRatio;

    function _percentToEther(uint amount) private pure returns (uint256) {
        return (amount * 1 ether) / 100;
    }

    function _basisPointToEther(int amount) private pure returns (int256) {
        return (amount * 1 ether) / 10000;
    }

    function _makeIncentiveConfig(
        uint[] memory upToPercent,
        int[] memory amountBasisPoints
    ) private pure returns (IMinter.IncentiveConfig memory band) {
        band.collateralRatioBandUpperBounds = new uint256[](upToPercent.length);
        for (uint i = 0; i < upToPercent.length; i++) {
            band.collateralRatioBandUpperBounds[i] = _percentToEther(upToPercent[i]);
        }
        band.incentiveRatios = new int256[](amountBasisPoints.length);
        for (uint i = 0; i < amountBasisPoints.length; i++) {
            band.incentiveRatios[i] = _basisPointToEther(amountBasisPoints[i]);
        }
    }

    function ua() private pure returns (uint[] memory result) {
        result = new uint[](0);
    }
    function ua(uint a_) private pure returns (uint[] memory result) {
        result = new uint[](1);
        result[0] = a_;
    }
    function ua(uint a_, uint b) private pure returns (uint[] memory result) {
        result = new uint[](2);
        result[0] = a_;
        result[1] = b;
    }
    function ua(uint a_, uint b, uint c) private pure returns (uint[] memory result) {
        result = new uint[](3);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
    }
    function ua(uint a_, uint b, uint c, uint d) private pure returns (uint[] memory result) {
        result = new uint[](4);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
    }
    function ua(uint a_, uint b, uint c, uint d, uint e) private pure returns (uint[] memory result) {
        result = new uint[](5);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
    }
    function ua(uint a_, uint b, uint c, uint d, uint e, uint f) private pure returns (uint[] memory result) {
        result = new uint[](6);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
    }

    function a(int a_) private pure returns (int[] memory result) {
        result = new int[](1);
        result[0] = a_;
    }
    function a(int a_, int b) private pure returns (int[] memory result) {
        result = new int[](2);
        result[0] = a_;
        result[1] = b;
    }
    function a(int a_, int b, int c) private pure returns (int[] memory result) {
        result = new int[](3);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
    }
    function a(int a_, int b, int c, int d) private pure returns (int[] memory result) {
        result = new int[](4);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
    }
    function a(int a_, int b, int c, int d, int e) private pure returns (int[] memory result) {
        result = new int[](5);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
    }
    function a(int a_, int b, int c, int d, int e, int f) private pure returns (int[] memory result) {
        result = new int[](6);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
    }

    function setUp() public virtual {
        string memory url = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(url);

        feeReceiver = vm.createWallet("feeReceiver");

        owner = vm.createWallet("owner");
        deal(address(deployed.wstETH), address(this), 20 ether);

        priceOracle = new MockPriceOracle();
        rateProvider = new MockRateProvider();

        leveragedToken = Upgrades.deployUUPSProxy(
            "LeveragedToken_v1.sol",
            abi.encodeCall(LeveragedToken_v1.initialize, (owner.addr, "Leveraged Token", "BaoUSDLwstETH"))
        );

        reservePool = Upgrades.deployUUPSProxy(
            "ReservePool_v1.sol",
            abi.encodeCall(ReservePool_v1.initialize, (owner.addr))
        );

        danger = 140;
        dangerCollateralRatioUpperBound = _percentToEther(danger);
        int mpNormalIR = 50;
        int mpDangerIR = 100;
        mintPeggedNormalFeeRatio = _basisPointToEther(mpNormalIR);
        mintPeggedDangerFeeRatio = _basisPointToEther(mpDangerIR);
        int mlNormalIR = 70;
        int mlDangerIR = 20;
        mintLeveragedNormalFeeRatio = _basisPointToEther(mlNormalIR);
        mintLeveragedDangerFeeRatio = _basisPointToEther(mlDangerIR);

        config.rebalanceCollateralRatioUpperBound = _percentToEther(130);
        config.disallowMintPeggedCollateralRatioUpperBound = _percentToEther(131); // typically the same as the rebalance CR
        config.disallowRedeemLeveragedCollateralRatioUpperBound = _percentToEther(110); // typically the same as the bonus CR
        config.normalCollateralRatioUpperBound = _percentToEther(250);

        config.mintPeggedIncentiveConfig = _makeIncentiveConfig(ua(danger), a(mpDangerIR, mpNormalIR));
        config.mintLeveragedIncentiveConfig = _makeIncentiveConfig(
            ua(110, 120, danger),
            a(-100, 0, mlDangerIR, mlNormalIR)
        );
        config.redeemPeggedIncentiveConfig = _makeIncentiveConfig(ua(110, 120, danger), a(-50, 0, 50, 100));
        config.redeemLeveragedIncentiveConfig = _makeIncentiveConfig(ua(danger), a(150, 120));

        // TODO: test for leveraged, collateral and random tokens
        bonusToken = deployed.wstETH;

        minter = Upgrades.deployUUPSProxy(
            "Minter_v1.sol",
            abi.encodeCall(
                Minter_v1.initialize,
                (
                    owner.addr,
                    IMinter.BalanceTokens(deployed.BaoUSD, address(leveragedToken), deployed.wstETH),
                    address(priceOracle),
                    feeReceiver.addr,
                    reservePool,
                    config
                )
            )
        );
    }

    function setUp_permissions() internal {
        vm.prank(IBaoUSD(deployed.BaoUSD).operator());
        IBaoUSD(deployed.BaoUSD).addMinter(minter);
        vm.prank(owner.addr);
        IAccessControl(leveragedToken).grantRole(minterRole, minter);
    }

    function setUp_collateral(
        uint256 collateralForPegged,
        uint256 collateralForLeveraged
    ) internal returns (uint256 peggedTokens, uint256 leveragedTokens) {
        // put some collateral into the minter to bootstrap it
        // get collateral & allowance
        uint256 totalAmount = collateralForPegged + collateralForLeveraged;
        deal(address(deployed.wstETH), owner.addr, totalAmount + 10 ether);

        setUp_permissions();

        vm.prank(owner.addr);
        IERC20(deployed.wstETH).approve(minter, totalAmount);
        if (collateralForPegged > 0) {
            vm.prank(owner.addr);
            peggedTokens = IMinterTreasury(minter).freeMintPeggedToken(collateralForPegged, owner.addr);
        }
        if (collateralForLeveraged > 0) {
            vm.prank(owner.addr);
            leveragedTokens = IMinterTreasury(minter).freeMintLeveragedToken(collateralForLeveraged, owner.addr);
        }
    }

    function makeAllFeesNormal() internal {
        config.mintPeggedIncentiveConfig = _makeIncentiveConfig(ua(), a(50));
        config.mintLeveragedIncentiveConfig = _makeIncentiveConfig(ua(), a(70));
        config.redeemPeggedIncentiveConfig = _makeIncentiveConfig(ua(), a(100));
        config.redeemLeveragedIncentiveConfig = _makeIncentiveConfig(ua(), a(120));
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);
    }
}

contract TestMinterSetUp is TestMinter {
    function setUp() public override {}

    function test_setUp() public {
        super.setUp();
    }
}

contract TestMinterInit is TestMinter {
    using SafeERC20 for IERC20;

    Vm.Wallet holder;

    function setUp() public override {
        super.setUp();
    }

    function test_initEvents() public {
        vm.expectEmit(false, false, false, true);
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        vm.expectEmit(false, false, false, false);
        emit IERC1967.Upgraded(address(0)); // we don't know the address right now
        vm.expectEmit(true, true, true, false);
        // we have set it up for owner to be this
        // emit IAccessControl.RoleGranted(ownerRole, owner.addr, address(this));
        // vm.expectEmit(false, false, false, true);
        emit Initializable.Initialized(1); // from the proxy delegate call

        Upgrades.deployUUPSProxy(
            "Minter_v1.sol",
            abi.encodeCall(
                Minter_v1.initialize,
                (
                    address(this),
                    IMinter.BalanceTokens(deployed.BaoUSD, address(leveragedToken), deployed.wstETH),
                    address(priceOracle),
                    feeReceiver.addr,
                    reservePool,
                    config
                )
            )
        );
    }

    function test_init() public {
        bytes32 id = keccak256(abi.encode(uint256(keccak256("bao.storage.Minter")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(id, 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00);

        // expect a revert if initialize called twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Minter_v1(minter).initialize(
            address(this),
            IMinter.BalanceTokens(deployed.BaoUSD, address(leveragedToken), deployed.wstETH),
            address(priceOracle),
            feeReceiver.addr,
            reservePool,
            config
        );

        // TODO: test reserve pool is properly set up

        assertTrue(IAccessControl(minter).hasRole(ownerRole, owner.addr));
        assertEq(IMinter(minter).collateralToken(), deployed.wstETH);
        assertEq(IMinter(minter).peggedToken(), deployed.BaoUSD);
        assertEq(IMinter(minter).leveragedToken(), address(leveragedToken));
        assertEq(IMinter(minter).priceOracle(), address(priceOracle));
        assertEq(IMinter(minter).feeReceiver(), feeReceiver.addr);
        assertEq(IMinter(minter).peggedTokenBalance(), 0);

        // no pegged tokens so divide by zero
        assertEq(
            IMinter(minter).collateralRatio(),
            type(uint256).max,
            "very high collateral ratios capped at maxuint256"
        );
    }

    function test_initProtocol() public {
        // 10 ether,
        // 1 ether / 2,
        // holder
    }

    // function testFuzz_SetNumber(uint256 x) public {
    //     counter.setNumber(x);
    //     assertEq(counter.number(), x);
    //}
}
