// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

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
import { Token } from "src/common/Token.sol";
import { IMintable } from "src/minter/IMintable.sol";
import { IReservePool } from "src/minter/IReservePool.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";

import { deployed } from "test/deployed.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";
import { IBaoUSD } from "test/IBaoUSD.sol";
import "test/Useful.sol";
import { Array } from "test/Array.sol";

contract TestMinter is Test, Clog, Array {
    address minter;
    IMinter.Config config;
    int constant disallow = 10000;

    address leveragedToken;
    address reservePool;
    MockPriceOracle priceOracle;

    Vm.Wallet feeReceiver;
    Vm.Wallet owner;
    bytes32 ownerRole = 0;
    bytes32 zeroFeeRole = keccak256("ZERO_FEE_ROLE");
    bytes32 minterRole = keccak256("MINTER_ROLE");
    bytes32 requesterRole = keccak256("REQUESTER_ROLE");

    function _percentToEther(uint amount) private pure returns (uint256) {
        return (amount * 1 ether) / 100;
    }

    function _etherToBasisPoint(int256 amount) private pure returns (int) {
        return (amount * 10000) / 1 ether;
    }

    function _basisPointToEther(int amount) private pure returns (int256) {
        return (amount * 1 ether) / 10000;
    }

    function ic(
        uint[] memory upToPercent,
        int[] memory amountBasisPoints
    ) internal pure returns (IMinter.IncentiveConfig memory band) {
        band.collateralRatioBandUpperBounds = new uint256[](upToPercent.length);
        for (uint i = 0; i < upToPercent.length; i++) {
            band.collateralRatioBandUpperBounds[i] = _percentToEther(upToPercent[i]);
        }
        band.incentiveRatios = new int256[](amountBasisPoints.length);
        for (uint i = 0; i < amountBasisPoints.length; i++) {
            band.incentiveRatios[i] = _basisPointToEther(amountBasisPoints[i]);
        }
    }

    function setUpConfig(
        uint rebalance,
        uint harvest,
        IMinter.IncentiveConfig memory mintPegged,
        IMinter.IncentiveConfig memory mintLeveraged,
        IMinter.IncentiveConfig memory redeemPegged,
        IMinter.IncentiveConfig memory redeemLeveraged
    ) public {
        config.rebalanceCollateralRatioUpperBound = _percentToEther(rebalance);
        config.harvestCollateralRatioUpperBound = _percentToEther(harvest);
        config.mintPeggedIncentiveConfig = mintPegged;
        config.mintLeveragedIncentiveConfig = mintLeveraged;
        config.redeemPeggedIncentiveConfig = redeemPegged;
        config.redeemLeveragedIncentiveConfig = redeemLeveraged;
    }

    function _assertEqIncentiveConfig(
        IMinter.IncentiveConfig memory actual,
        IMinter.IncentiveConfig memory expected
    ) internal pure {
        assertEq(
            actual.collateralRatioBandUpperBounds.length,
            expected.collateralRatioBandUpperBounds.length,
            "collateralRatioBandUpperBounds.length differ "
        );
        for (uint i = 0; i < actual.collateralRatioBandUpperBounds.length; i++) {
            assertEq(
                actual.collateralRatioBandUpperBounds[i],
                expected.collateralRatioBandUpperBounds[i],
                string.concat("collateralRatioBandUpperBounds[", Useful.toString(i), "] differ")
            );
        }
        assertEq(actual.incentiveRatios.length, expected.incentiveRatios.length, "incentiveRatios.length differ ");
        for (uint i = 0; i < actual.incentiveRatios.length; i++) {
            assertEq(
                actual.incentiveRatios[i],
                expected.incentiveRatios[i],
                string.concat("incentiveRatios[", Useful.toString(i), "] differ")
            );
        }
    }

    function _assertEqConfig(IMinter.Config memory actual, IMinter.Config memory expected) internal pure {
        assertEq(
            actual.rebalanceCollateralRatioUpperBound,
            expected.rebalanceCollateralRatioUpperBound,
            "rebalanceCollateralRatioUpperBound differ"
        );
        assertEq(
            actual.harvestCollateralRatioUpperBound,
            expected.harvestCollateralRatioUpperBound,
            "harvestCollateralRatioUpperBound differ"
        );
        _assertEqIncentiveConfig(actual.mintPeggedIncentiveConfig, expected.mintPeggedIncentiveConfig);
        _assertEqIncentiveConfig(actual.mintLeveragedIncentiveConfig, expected.mintLeveragedIncentiveConfig);
        _assertEqIncentiveConfig(actual.redeemPeggedIncentiveConfig, expected.redeemPeggedIncentiveConfig);
        _assertEqIncentiveConfig(actual.redeemLeveragedIncentiveConfig, expected.redeemLeveragedIncentiveConfig);
    }
    function setUpConfig() public virtual {
        setUpConfig(
            130,
            250,
            ic(ua(131, 140), ia(disallow, 100, 50)),
            ic(ua(110, 120, 140), ia(-50, 0, 20, 70)),
            ic(ua(110, 120, 140), ia(-50, 0, 60, 80)),
            ic(ua(110, 140), ia(disallow, 150, 120))
        );
    }

    function setUp() public virtual {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 19210000);

        feeReceiver = vm.createWallet("feeReceiver");

        owner = vm.createWallet("owner");
        deal(address(deployed.wstETH), address(this), 20 ether);

        priceOracle = new MockPriceOracle();

        leveragedToken = UnsafeUpgrades.deployUUPSProxy(
            address(new LeveragedToken_v1()), // "LeveragedToken_v1.sol",
            abi.encodeCall(LeveragedToken_v1.initialize, (owner.addr, "Leveraged Token", "BaoUSDLwstETH"))
        );

        reservePool = UnsafeUpgrades.deployUUPSProxy(
            address(new ReservePool_v1()), //"ReservePool_v1.sol",
            abi.encodeCall(ReservePool_v1.initialize, (owner.addr))
        );

        setUpConfig();

        minter = UnsafeUpgrades.deployUUPSProxy(
            address(new Minter_v1()), // "Minter_v1.sol",
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
        vm.prank(owner.addr);
        ReservePool_v1(reservePool).grantRole(requesterRole, minter);
    }

    function setUp_collateral(
        uint256 collateralForPegged,
        uint256 collateralForLeveraged
    ) internal returns (uint256 peggedTokens, uint256 leveragedTokens) {
        return setUp_collateral(collateralForPegged, collateralForLeveraged, owner.addr);
    }

    function setUp_collateral(
        uint256 collateralForPegged,
        uint256 collateralForLeveraged,
        address recipient
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
            peggedTokens = IMinterTreasury(minter).freeMintPeggedToken(collateralForPegged, recipient);
        }
        if (collateralForLeveraged > 0) {
            vm.prank(owner.addr);
            leveragedTokens = IMinterTreasury(minter).freeMintLeveragedToken(collateralForLeveraged, recipient);
        }
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

    function setUp() public override {
        super.setUp();
    }
    // TODO: test the ERC20 check in Token - expect revert doesn't work for deployUUPS
    function test_notERC20() private {
        //                   -------
        /*
        console.log("good deploy");
        UnsafeUpgrades.deployUUPSProxy(
            address(new Minter_v1()), // "Minter_v1.sol",
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
        */

        // not a contract
        console.log("not a contract");
        vm.expectRevert(abi.encodeWithSelector(Token.NotContractAddress.selector, owner.addr));

        UnsafeUpgrades.deployUUPSProxy(
            address(new Minter_v1()), // "Minter_v1.sol",
            abi.encodeCall(
                Minter_v1.initialize,
                (
                    address(this),
                    IMinter.BalanceTokens(deployed.BaoUSD, address(leveragedToken), owner.addr),
                    address(priceOracle),
                    feeReceiver.addr,
                    reservePool,
                    config
                )
            )
        );

        // contract but not ERC20
        console.log("not an ERC20");
        vm.expectRevert(abi.encodeWithSelector(Token.NotERC20Token.selector, address(priceOracle)));
        UnsafeUpgrades.deployUUPSProxy(
            address(new Minter_v1()), // "Minter_v1.sol",
            abi.encodeCall(
                Minter_v1.initialize,
                (
                    address(this),
                    IMinter.BalanceTokens(deployed.BaoUSD, address(leveragedToken), address(priceOracle)),
                    address(priceOracle),
                    feeReceiver.addr,
                    reservePool,
                    config
                )
            )
        );
    }

    function test_initEvents() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        vm.expectEmit(false, false, false, false);
        emit IERC1967.Upgraded(address(0)); // we don't know the address right now
        vm.expectEmit();
        emit IAccessControl.RoleGranted(ownerRole, owner.addr, address(this));
        vm.expectEmit();
        emit IMinter.UpdatePriceOracle(address(0), address(priceOracle));
        vm.expectEmit();
        emit IMinter.UpdateFeeReceiver(address(0), feeReceiver.addr);
        vm.expectEmit();
        emit IMinter.UpdateReservePool(address(0), address(reservePool));
        vm.expectEmit();
        emit IMinter.UpdateConfig(config);
        vm.expectEmit();
        emit IAccessControl.RoleGranted(zeroFeeRole, owner.addr, address(this));
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call

        UnsafeUpgrades.deployUUPSProxy(
            address(new Minter_v1()), // "Minter_v1.sol",
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

        assertTrue(IAccessControl(minter).hasRole(ownerRole, owner.addr));
        assertEq(IMinter(minter).collateralToken(), deployed.wstETH);
        assertEq(IMinter(minter).peggedToken(), deployed.BaoUSD);
        assertEq(IMinter(minter).leveragedToken(), address(leveragedToken));
        assertEq(IMinter(minter).priceOracle(), address(priceOracle));
        assertEq(IMinter(minter).feeReceiver(), feeReceiver.addr);
        assertEq(IMinter(minter).reservePool(), reservePool);
        assertEq(IMinter(minter).peggedTokenBalance(), 0);
        _assertEqConfig(IMinter(minter).config(), config);

        // TODO: add configuration check - also add it to the setup config function

        // also add checks for leveraged price, etc - all the view functions

        // no pegged tokens so divide by zero
        assertEq(
            IMinter(minter).collateralRatio(),
            type(uint256).max,
            "very high collateral ratios capped at maxuint256"
        );
    }
}

contract TestMinterBasics is TestMinter {
    function test_introspection() public view {
        assertTrue(Minter_v1(minter).supportsInterface(type(IMinter).interfaceId), "should support IMinter");
        assertTrue(
            Minter_v1(minter).supportsInterface(type(IMinterTreasury).interfaceId),
            "should support IMinterTreasury"
        );
        assertFalse(Minter_v1(minter).supportsInterface(bytes4(0)), "doesn't support 0");
    }

    function _checkConfig(
        uint rebalance,
        uint harvest,
        IMinter.IncentiveConfig memory mintPegged,
        IMinter.IncentiveConfig memory mintLeveraged,
        IMinter.IncentiveConfig memory redeemPegged,
        IMinter.IncentiveConfig memory redeemLeveraged
    ) private {
        setUpConfig(rebalance, harvest, mintPegged, mintLeveraged, redeemPegged, redeemLeveraged);
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);
        IMinter.Config memory readConfig = IMinter(minter).config();
        _assertEqConfig(readConfig, config);
    }

    function test_config() public {
        IMinter.Config memory readConfig = IMinter(minter).config();
        _assertEqConfig(readConfig, config); // check the default setup
        // do a null update to make sure the update config function works
        _checkConfig(
            130,
            250,
            ic(ua(131, 140), ia(disallow, 100, 50)),
            ic(ua(110, 120, 140), ia(-50, 0, 20, 70)),
            ic(ua(110, 120, 140), ia(-50, 0, 60, 80)),
            ic(ua(110, 140), ia(disallow, 150, 120))
        );
        // now test for other conditions

        // depeg already added - at the start, middle & and end
        _checkConfig(
            130,
            250,
            ic(ua(100, 131, 140), ia(200, 150, 100, 50)),
            ic(ua(90, 100, 140), ia(-50, 0, 20, 70)),
            ic(ua(80, 90, 100), ia(-50, 0, 60, 80)),
            // no bounds
            ic(ua(), ia(120))
        );

        _checkConfig(
            130,
            250,
            ic(ua(131, 140), ia(disallow, 100, 50)),
            ic(ua(110, 120, 140), ia(-50, 0, 20, 70)),
            // max bands
            ic(ua(110, 120, 140, 150, 160), ia(-50, 0, 60, 80, 90, 100)),
            // min bands
            ic(ua(), ia(120))
        );

        // mismatched length, too many bands
        config.mintPeggedIncentiveConfig = ic(ua(), ia(disallow, 100));
        vm.expectRevert(abi.encodeWithSelector(IMinter.CollateralRatioBoundsIncentivesLengthsMismatch.selector, 0, 2));
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);

        // mismatched length, too many bands
        config.mintPeggedIncentiveConfig = ic(ua(100), ia(100));
        vm.expectRevert(abi.encodeWithSelector(IMinter.CollateralRatioBoundsIncentivesLengthsMismatch.selector, 1, 1));
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);

        // more than max
        config.mintPeggedIncentiveConfig = ic(
            ua(90, 100, 131, 140, 150, 160, 170, 180),
            ia(disallow, 100, 50, 100, 200, 300, 400, 500, 600)
        );
        vm.expectRevert(abi.encodeWithSelector(IMinter.TooManyIncentiveRatios.selector, 9, 8));
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);

        // config.mintPeggedIncentiveConfig = ic(ua(90, 100, 131, 140, 150), ia(disallow, 100, 50, 100, 200, 300, 400));
        // vm.expectRevert(abi.encodeWithSelector(IMinter.TooManyIncentiveRatios.selector, 7, 6));
        // vm.prank(owner.addr);
        // IMinter(minter).updateConfig(config);

        // less than min
        config.mintPeggedIncentiveConfig = ic(ua(), ia());
        vm.expectRevert(abi.encodeWithSelector(IMinter.TooFewIncentiveRatios.selector, 0, 1));
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);

        // check the collateral ratio bounds are are checked for strictly increasing
        // all
        config.mintPeggedIncentiveConfig = ic(ua(200, 200), ia(1, 2, 3));
        vm.expectRevert(abi.encodeWithSelector(IMinter.InvalidCollateralRatioBoundValue.selector, 2 ether, 2 ether));
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);
        // middle
        config.mintPeggedIncentiveConfig = ic(ua(100, 200, 200, 300), ia(1, 2, 3, 4, 5));
        vm.expectRevert(abi.encodeWithSelector(IMinter.InvalidCollateralRatioBoundValue.selector, 2 ether, 2 ether));
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);
        // start
        config.mintPeggedIncentiveConfig = ic(ua(200, 200, 300, 400), ia(1, 2, 3, 4, 5));
        vm.expectRevert(abi.encodeWithSelector(IMinter.InvalidCollateralRatioBoundValue.selector, 2 ether, 2 ether));
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);
        // end
        config.mintPeggedIncentiveConfig = ic(ua(100, 200, 300, 300), ia(1, 2, 3, 4, 5));
        vm.expectRevert(abi.encodeWithSelector(IMinter.InvalidCollateralRatioBoundValue.selector, 3 ether, 3 ether));
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);
        // < not <=
        config.mintPeggedIncentiveConfig = ic(ua(100, 90, 300, 300), ia(1, 2, 3, 4, 5));
        vm.expectRevert(
            abi.encodeWithSelector(IMinter.InvalidCollateralRatioBoundValue.selector, 9 ether / 10, 1 ether)
        );
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);

        // set up the incentive configs for precise testing of values
        config.mintPeggedIncentiveConfig = ic(ua(), ia(0));
        config.mintLeveragedIncentiveConfig = ic(ua(), ia(0));
        config.redeemPeggedIncentiveConfig = ic(ua(), ia(0));
        config.redeemLeveragedIncentiveConfig = ic(ua(), ia(0));

        // check the incentive ratios are in the range for the action
        // max
        config.mintPeggedIncentiveConfig.incentiveRatios[0] = 1 ether;
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);
        // > max
        config.mintPeggedIncentiveConfig.incentiveRatios[0] = 1 ether + 1;
        vm.expectRevert(abi.encodeWithSelector(IMinter.IncentiveRatioTooPrecise.selector, 1 ether + 1));
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);

        config.mintPeggedIncentiveConfig.incentiveRatios[0] = 1 ether + 10 ** 9;
        vm.expectRevert(abi.encodeWithSelector(IMinter.InvalidIncentiveRatioValue.selector, 1 ether + 10 ** 9));
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);

        // min
        config.mintPeggedIncentiveConfig.incentiveRatios[0] = 0;
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);
        // < min
        config.mintPeggedIncentiveConfig.incentiveRatios[0] = -1;
        vm.expectRevert(abi.encodeWithSelector(IMinter.IncentiveRatioTooPrecise.selector, -1));
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);

        config.mintPeggedIncentiveConfig.incentiveRatios[0] = -10 ** 9;
        vm.expectRevert(abi.encodeWithSelector(IMinter.InvalidIncentiveRatioValue.selector, -10 ** 9));
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);

        // TODO: test the adding a depeg band in + when there is a disallow band
        // TODO: test the other actions, not just mint pegged

        /*
        config.mintPeggedIncentiveConfig.incentiveRatios[0] = -1;
        vm.expectRevert(
            abi.encodeWithSelector(IMinter.InvalidIncentiveRatioValue.selector, )
        );
        vm.prank(owner.addr);
        IMinter(minter).updateConfig(config);
        */
        //                 revert InvalidIncentiveRatioValue(currentUpperBound, prevUpperBound);  one

        //                 revert InvalidIncentiveRatioValue(currentUpperBound, prevUpperBound);  start

        //                 revert InvalidIncentiveRatioValue(currentUpperBound, prevUpperBound);  middle

        //                 revert InvalidIncentiveRatioValue(currentUpperBound, prevUpperBound);  end

        //                 max

        //                 revert InvalidIncentiveRatioValue();  max +1

        //                 min

        //                 revert InvalidIncentiveRatioValue();  min -1
    }

    // function test_leverageRatio() public {

    // }

    // function testFuzz_SetNumber(uint256 x) public {
    //     counter.setNumber(x);
    //     assertEq(counter.number(), x);
    //}
}
