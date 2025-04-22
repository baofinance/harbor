// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";

import {Minter_v1} from "src/minter/Minter_v1.sol";
import {LeveragedToken_v1} from "src/minter/LeveragedToken_v1.sol";
import {ReservePool_v1} from "src/minter/ReservePool_v1.sol";

import {IMinter} from "@interfaces/IMinter.sol";
import {Token} from "@bao/Token.sol";
import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IReservePool} from "@interfaces/IReservePool.sol";
import {IPriceOracle} from "@interfaces/IPriceOracle.sol";

import {Deployed} from "@bao/Deployed.sol";
import {MockPriceOracle} from "test/mock/MockPriceOracle.sol";
import {IBaoUSD} from "test/IBaoUSD.sol";
import "test/Useful.sol";
import {Array} from "test/Array.sol";

import {ConfigFile} from "test/Config.sol";

import "test/clog.sol";

contract TestMinterSetUp is Test, Clog, Array, ConfigFile {
    address minter;
    IMinter.Config config;
    int constant disallow = 10000;

    address peggedToken;
    address collateralToken;

    address leveragedToken;
    address reservePool;
    address priceOracle;

    address feeReceiver;
    address owner;
    bytes32 ownerRole = 0;
    uint256 zeroFeeRole;
    uint256 minterRole;
    uint256 requesterRole;

    function _percentToEther(uint amount) internal pure returns (uint256) {
        return (amount * 1 ether) / 100;
    }

    function _etherToBasisPoint(int256 amount) internal pure returns (int) {
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

    function setUp_config_free() internal {
        setUp_config(130, 250, ic(ua(), ia(0)), ic(ua(), ia(0)), ic(ua(), ia(0)), ic(ua(), ia(0)));
        // config = readConfig("free", config);
    }

    function setUp_config_flat() internal {
        setUp_config(130, 250, ic(ua(), ia(50)), ic(ua(), ia(80)), ic(ua(), ia(70)), ic(ua(), ia(120)));
        // config = readConfig("flat");
    }

    function setUp_config_basicWithDisallow() internal {
        // setUp_config(
        //     130,
        //     250,
        //     ic(ua(131), ia(disallow, 50)),
        //     ic(ua(), ia(80)),
        //     ic(ua(), ia(70)),
        //     ic(ua(110), ia(disallow, 120))
        // );
        config = readConfig("basicWithDisallow");
    }

    function setUp_config_likely() internal {
        // setUp_config(
        //     130,
        //     250,
        //     ic(ua(130, 140), ia(disallow, 100, 50)), // mint pegged
        //     ic(ua(105, 115, 150), ia(-75, -25, 60, 80)), // redeem pegged
        //     ic(ua(110, 120, 145), ia(-50, 0, 20, 70)), // mint leveraged
        //     ic(ua(105, 135), ia(disallow, 150, 120)) // redeem leveraged
        // );
        config = readConfig("likely");
    }

    function setUp_config_likelyNoDisallow() internal {
        // setUp_config(
        //     130,
        //     250,
        //     ic(ua(140), ia(100, 50)), // mint pegged
        //     ic(ua(105, 115, 150), ia(-75, -25, 60, 80)), // redeem pegged
        //     ic(ua(110, 120, 145), ia(-50, 0, 20, 70)), // mint leveraged
        //     ic(ua(135), ia(150, 120)) // redeem leveraged
        // );
        config = readConfig("likelyNoDisallow");
    }

    function setUp_config(
        uint rebalance,
        uint harvest,
        IMinter.IncentiveConfig memory mintPegged,
        IMinter.IncentiveConfig memory redeemPegged,
        IMinter.IncentiveConfig memory mintLeveraged,
        IMinter.IncentiveConfig memory redeemLeveraged
    ) public {
        config.rebalanceCollateralRatioUpperBound = _percentToEther(rebalance);
        config.harvestCollateralRatioLowerBound = _percentToEther(harvest);
        config.mintPeggedIncentiveConfig = mintPegged;
        config.mintLeveragedIncentiveConfig = mintLeveraged;
        config.redeemPeggedIncentiveConfig = redeemPegged;
        config.redeemLeveragedIncentiveConfig = redeemLeveraged;
    }

    function _assertEqIncentiveConfig(
        IMinter.IncentiveConfig memory actual,
        IMinter.IncentiveConfig memory expected,
        string memory name
    ) internal pure {
        assertEq(
            actual.collateralRatioBandUpperBounds.length,
            expected.collateralRatioBandUpperBounds.length,
            string.concat(name, " collateralRatioBandUpperBounds.length differ")
        );
        for (uint i = 0; i < actual.collateralRatioBandUpperBounds.length; i++) {
            assertEq(
                actual.collateralRatioBandUpperBounds[i],
                expected.collateralRatioBandUpperBounds[i],
                string.concat(name, " collateralRatioBandUpperBounds[", Useful.toString(i), "] differ")
            );
        }
        assertEq(actual.incentiveRatios.length, expected.incentiveRatios.length, "incentiveRatios.length differ ");
        for (uint i = 0; i < actual.incentiveRatios.length; i++) {
            assertEq(
                actual.incentiveRatios[i],
                expected.incentiveRatios[i],
                string.concat(name, " incentiveRatios[", Useful.toString(i), "] differ")
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
            actual.harvestCollateralRatioLowerBound,
            expected.harvestCollateralRatioLowerBound,
            "harvestCollateralRatioLowerBound differ"
        );
        _assertEqIncentiveConfig(actual.mintPeggedIncentiveConfig, expected.mintPeggedIncentiveConfig, "mint pegged");
        _assertEqIncentiveConfig(
            actual.mintLeveragedIncentiveConfig,
            expected.mintLeveragedIncentiveConfig,
            "mint leveraged"
        );
        _assertEqIncentiveConfig(
            actual.redeemPeggedIncentiveConfig,
            expected.redeemPeggedIncentiveConfig,
            "redeem pegged"
        );
        _assertEqIncentiveConfig(
            actual.redeemLeveragedIncentiveConfig,
            expected.redeemLeveragedIncentiveConfig,
            "redeem leveraged"
        );
    }
    function setUpConfig() internal virtual {
        setUp_config(
            130,
            250,
            ic(ua(131, 140), ia(disallow, 100, 50)),
            ic(ua(110, 120, 140), ia(-50, 0, 60, 80)),
            ic(ua(110, 120, 140), ia(-50, 0, 20, 70)),
            ic(ua(110, 140), ia(disallow, 150, 120))
        );
        writeConfig("default", config);
    }

    function setUp_leveragedToken() internal virtual {
        leveragedToken = UnsafeUpgrades.deployUUPSProxy(
            address(new LeveragedToken_v1()), // "LeveragedToken_v1.sol",
            abi.encodeCall(LeveragedToken_v1.initialize, (owner, "Leveraged Token", "BaoUSDLwstETH"))
        );
        IBaoOwnable(leveragedToken).transferOwnership(owner);
        minterRole = LeveragedToken_v1(leveragedToken).MINTER_ROLE();
    }

    function setUp_reservePool() internal virtual {
        reservePool = UnsafeUpgrades.deployUUPSProxy(
            address(new ReservePool_v1()), //"ReservePool_v1.sol",
            abi.encodeCall(ReservePool_v1.initialize, (owner))
        );
        IBaoOwnable(reservePool).transferOwnership(owner);
    }

    function setUp_minter() internal virtual {
        minter = UnsafeUpgrades.deployUUPSProxy(
            address(new Minter_v1(Deployed.stETH, Deployed.BaoUSD, address(leveragedToken), Deployed.wstETH)), // "Minter_v1.sol",
            abi.encodeCall(Minter_v1.initialize, (owner))
        );

        IMinter(minter).updatePriceOracle(address(priceOracle));
        IMinter(minter).updateFeeReceiver(feeReceiver);
        IMinter(minter).updateReservePool(reservePool);
        IMinter(minter).updateConfig(config);
        IBaoRoles(minter).grantRoles(owner, IMinter(minter).ZERO_FEE_ROLE());

        IBaoOwnable(minter).transferOwnership(owner);
        zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
    }

    function setUpFork() internal virtual {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 19210000);

        feeReceiver = vm.createWallet("feeReceiver").addr;

        owner = vm.createWallet("owner").addr;

        priceOracle = address(new MockPriceOracle());

        setUp_leveragedToken();
        peggedToken = Deployed.BaoUSD;
        collateralToken = Deployed.wstETH;

        setUp_reservePool();
    }

    function setUpContract() internal virtual {
        setUp_minter();

        vm.prank(owner);
        IBaoRoles(leveragedToken).grantRoles(minter, minterRole);
        requesterRole = ReservePool_v1(reservePool).REQUESTER_ROLE();
        vm.prank(owner);
        ReservePool_v1(reservePool).grantRoles(minter, requesterRole);

        setUp_BaoUSD();
    }

    function setUp_BaoUSD() internal {
        vm.prank(IBaoUSD(Deployed.BaoUSD).operator());
        IBaoUSD(Deployed.BaoUSD).addMinter(minter);
    }

    function setUp() public virtual {
        setUpFork();
        deal(address(Deployed.wstETH), address(this), 20 ether);
        setUpConfig();
        setUpContract();
    }

    function setUp_collateral(
        uint256 collateralForPegged,
        uint256 collateralForLeveraged
    ) internal returns (uint256 peggedTokens, uint256 leveragedTokens) {
        return setUp_collateral(collateralForPegged, collateralForLeveraged, owner);
    }

    function setUp_collateral(
        uint256 collateralForPegged,
        uint256 collateralForLeveraged,
        address recipient
    ) internal returns (uint256 peggedTokens, uint256 leveragedTokens) {
        // put some collateral into the minter to bootstrap it
        // get collateral & allowance
        uint256 totalAmount = collateralForPegged + collateralForLeveraged;
        deal(address(Deployed.wstETH), owner, totalAmount + 10 ether);

        vm.prank(owner);
        IERC20(Deployed.wstETH).approve(minter, totalAmount);
        if (collateralForPegged > 0) {
            vm.prank(owner);
            peggedTokens = IMinter(minter).freeMintPeggedToken(collateralForPegged, recipient);
        }
        if (collateralForLeveraged > 0) {
            vm.prank(owner);
            leveragedTokens = IMinter(minter).freeMintLeveragedToken(collateralForLeveraged, recipient);
        }
    }
}

contract TestMinterInit is TestMinterSetUp {
    using SafeERC20 for IERC20;
    address impl;

    function setUp() public override {
        super.setUp();
        impl = address(new Minter_v1(Deployed.stETH, Deployed.BaoUSD, address(leveragedToken), Deployed.wstETH));
    }
    // TODO: remove this as we no longer test for valid erc20 token on initialisation
    // test the ERC20 check in Token - expect revert doesn't work for deployUUPS
    // function test_notERC20() private {
    //     //                   -------
    //     /*
    //     // console.log("good deploy");
    //     UnsafeUpgrades.deployUUPSProxy(
    //         address(new Minter_v1()), // "Minter_v1.sol",
    //         abi.encodeCall(
    //             Minter_v1.initialize,
    //             (
    //                 address(this),
    //                 IMinter.BalanceTokens(Deployed.BaoUSD, address(leveragedToken), Deployed.wstETH),
    //                 address(priceOracle),
    //                 feeReceiver,
    //                 reservePool,
    //                 config
    //             )
    //         )
    //     );
    //     */

    //     // not a contract
    //     // console.log("not a contract");
    //     vm.expectRevert(abi.encodeWithSelector(Token.NotContractAddress.selector, owner));

    //     UnsafeUpgrades.deployUUPSProxy(
    //         address(new Minter_v1()), // "Minter_v1.sol",
    //         abi.encodeCall(
    //             Minter_v1.initialize,
    //             (
    //                 address(this),
    //                 IMinter.BalanceTokens(Deployed.BaoUSD, address(leveragedToken), owner),
    //                 type(IBurnable).interfaceId,
    //                 address(priceOracle),
    //                 feeReceiver,
    //                 reservePool,
    //                 config
    //             )
    //         )
    //     );

    //     // contract but not ERC20
    //     // console.log("not an ERC20");
    //     vm.expectRevert(abi.encodeWithSelector(Token.NotERC20Token.selector, address(priceOracle)));
    //     UnsafeUpgrades.deployUUPSProxy(
    //         address(new Minter_v1()), // "Minter_v1.sol",
    //         abi.encodeCall(
    //             Minter_v1.initialize,
    //             (
    //                 address(this),
    //                 IMinter.BalanceTokens(Deployed.BaoUSD, address(leveragedToken), address(priceOracle)),
    //                 type(IBurnable).interfaceId,
    //                 address(priceOracle),
    //                 feeReceiver,
    //                 reservePool,
    //                 config
    //             )
    //         )
    //     );
    // }

    function test_initEventsImplementation() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        address(new Minter_v1(Deployed.stETH, Deployed.BaoUSD, address(leveragedToken), Deployed.wstETH));
    }

    function test_initEvents() public {
        vm.expectEmit();
        emit IERC1967.Upgraded(impl);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call

        UnsafeUpgrades.deployUUPSProxy(
            impl, // "Minter_v1.sol",
            abi.encodeCall(Minter_v1.initialize, (owner))
        );
    }

    function test_init() public {
        bytes32 id = keccak256(abi.encode(uint256(keccak256("bao.storage.Minter")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(id, 0x92e73fe9557052b4a0b810a38eb7ef595ff750f166ca39d63b3f4c74937fef00);

        // expect a revert if initialize called twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Minter_v1(minter).initialize(address(this));

        assertEq(IMinter(minter).rebalanceCollateralRatio(), 130 ether / 100);
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

contract TestMinterBasics is TestMinterSetUp {
    address user;

    function setUp() public virtual override(TestMinterSetUp) {
        super.setUp();
        user = vm.createWallet("user").addr;
    }

    function test_introspection() public view {
        assertTrue(Minter_v1(minter).supportsInterface(type(IMinter).interfaceId), "should support IMinter");
        assertTrue(Minter_v1(minter).supportsInterface(type(IMinter).interfaceId), "should support IMinter");
        assertFalse(Minter_v1(minter).supportsInterface(bytes4(0)), "doesn't support 0");
    }

    function _checkConfig(
        uint rebalance,
        uint harvest,
        IMinter.IncentiveConfig memory mintPegged,
        IMinter.IncentiveConfig memory redeemPegged,
        IMinter.IncentiveConfig memory mintLeveraged,
        IMinter.IncentiveConfig memory redeemLeveraged,
        bytes memory revertSelector
    ) private {
        setUp_config(rebalance, harvest, mintPegged, redeemPegged, mintLeveraged, redeemLeveraged);
        vm.prank(owner);
        if (revertSelector.length != 0) vm.expectRevert(revertSelector);
        IMinter(minter).updateConfig(config);
        IMinter.Config memory readConfig = IMinter(minter).config();
        _assertEqConfig(readConfig, config);
    }

    // TODO: check other functions:
    // free mint/redeem of leveraged/pegged
    // swap
    // mint/redeem of leveraged/pegged
    // collateral ratio, leveraged ratio, prices
    // all should be independent of the whether it is a mock or actual being called
    // mocks are: priceOracle, feeReceiver, baousd & wstETH

    function test_init() public view {
        assertEq(IBaoOwnable(minter).owner(), owner);
        assertEq(IMinter(minter).collateralToken(), Deployed.wstETH);
        assertEq(IMinter(minter).peggedToken(), Deployed.BaoUSD);
        assertEq(IMinter(minter).leveragedToken(), address(leveragedToken));
        assertEq(IMinter(minter).priceOracle(), address(priceOracle));
        assertEq(IMinter(minter).feeReceiver(), feeReceiver);
        assertEq(IMinter(minter).reservePool(), reservePool);
        assertEq(IMinter(minter).peggedTokenBalance(), 0);
        assertEq(IMinter(minter).leveragedTokenBalance(), 0);
        assertEq(IMinter(minter).collateralTokenBalance(), 0);
        assertEq(IMinter(minter).rebalanceCollateralRatio(), 130 ether / 100);
        assertEq(IMinter(minter).collateralRatio(), type(uint256).max);
        assertEq(IMinter(minter).leverageRatio(), type(uint256).max);
        assertEq(IMinter(minter).leveragedTokenPrice(), 1 ether);
        assertEq(IMinter(minter).peggedTokenPrice(), 1 ether);
    }

    function test_firstMintRedeem() public {
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "no pegged");
        assertEq(IMinter(minter).leveragedTokenBalance(), 0, "no leveraged");

        vm.expectRevert(IMinter.ActionPaused.selector);
        vm.prank(owner);
        IMinter(minter).mintPeggedToken(1 ether, user, 0);

        vm.expectRevert(IMinter.ActionPaused.selector);
        vm.prank(owner);
        IMinter(minter).mintLeveragedToken(1 ether, user, 0);

        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, peggedToken));
        vm.prank(owner);
        IMinter(minter).redeemPeggedToken(1 ether, user, 0);

        vm.expectRevert(abi.encodeWithSelector(IMinter.NoRedeemableTokens.selector, leveragedToken));
        vm.prank(owner);
        IMinter(minter).redeemLeveragedToken(1 ether, user, 0);
    }

    // TODO: test that if the config is set up for no fees or discounts then free mint/redeem = normal mint/redeem

    function test_connections() public {
        // simple config that has a fee and a discount
        _checkConfig(130, 250, ic(ua(), ia(50)), ic(ua(), ia(-100)), ic(ua(), ia(-50)), ic(ua(), ia(100)), "");
        // need collateral to start the process
        setUp_collateral(1 ether, 1 ether, address(this));
        IERC20(peggedToken).approve(minter, type(uint256).max);
        IERC20(leveragedToken).approve(minter, type(uint256).max);
        IERC20(collateralToken).approve(minter, type(uint256).max);
        deal(collateralToken, reservePool, 1 ether);

        // price
        (, uint256 collateralUsed, uint256 peggedMinted, uint256 fee, , uint256 price) = IMinter(minter)
            .mintPeggedTokenDryRun(1 ether);
        assertGt(price, 1 ether, "if eth drops below 1 usd this test will be no use to anyone");
        assertEq(IMinter(minter).peggedTokenBalance(), price, "correct amount minted");
        assertEq(collateralUsed, 1 ether);

        // feeReceiver
        assertEq(IERC20(collateralToken).balanceOf(feeReceiver), 0);
        uint256 startCollateral = IERC20(collateralToken).balanceOf(address(this));
        uint256 minted = IMinter(minter).mintPeggedToken(1 ether, address(this), 0);
        // --------------------------------------------------------------------------
        assertEq(fee, (1 ether * 5) / 1000);
        assertEq(IERC20(collateralToken).balanceOf(feeReceiver), (1 ether * 5) / 1000);
        assertEq(IMinter(minter).peggedTokenBalance(), price + (price * 995) / 1000, "correct amount minted, 2");
        assertEq(minted, peggedMinted, "amount minted is the same as predicted");
        assertEq(IERC20(collateralToken).balanceOf(address(this)), startCollateral - 1 ether);

        // reserve pool - same as above but with a discount, not a fee
        (, uint256 peggedRedeemed, uint256 collateralReturned, , uint256 reserveCollateralUsed, ) = IMinter(minter)
            .redeemPeggedTokenDryRun(price);
        assertEq(IERC20(collateralToken).balanceOf(reservePool), 1 ether);
        uint256 returned = IMinter(minter).redeemPeggedToken(price, address(this), 0);
        // --------------------------------------------------------------------------
        assertEq(peggedRedeemed, price);
        assertEq(reserveCollateralUsed, (1 ether * 10) / 1000);
        assertEq(IERC20(collateralToken).balanceOf(feeReceiver), (1 ether * 5) / 1000);
        assertEq(IMinter(minter).peggedTokenBalance(), (price * 995) / 1000, "correct amount minted, 2");
        assertEq(returned, collateralReturned, "amount returned is the same as predicted");
        assertEq(IERC20(collateralToken).balanceOf(address(this)), startCollateral + collateralReturned - 1 ether);

        // tokens
        assertEq(IMinter(minter).peggedToken(), Deployed.BaoUSD);
        assertEq(IMinter(minter).collateralToken(), Deployed.wstETH);

        // TODO: rebalance pool
    }

    function test_incentiveRatios() private view {
        // TODO: add these back in when collateral ratio function is fixed
        int256 instantaneousIr = IMinter(minter).mintPeggedTokenIncentiveRatio();
        (int256 ir, , , , , ) = IMinter(minter).mintPeggedTokenDryRun(0);
        assertEq(instantaneousIr, ir, "mint pegged ir");
    }

    function test_freeMint() public {
        setUp_collateral(10 ether, 10 ether);
        assertEq(IMinter(minter).collateralRatio(), 2 ether, "collateral ratio");
        assertEq(IMinter(minter).peggedTokenPrice(), 1 ether, "pegged token price");
        // TODO: do the actual mint
    }

    function test_mint() public {
        // compare the dry run with the actual
    }

    // function test_leverageRatio() public {

    // }

    function test_config() public {
        int256 incentivePrecision = 10 ** 9;

        // TODO: read config from files - same for deploy script

        IMinter.Config memory readConfig = IMinter(minter).config();
        _assertEqConfig(readConfig, config); // check the default setup
        // do a null update to make sure the update config function works
        _checkConfig(
            130,
            250,
            ic(ua(131, 140), ia(disallow, 100, 50)),
            ic(ua(110, 120, 140), ia(-50, 0, 20, 70)),
            ic(ua(110, 120, 140), ia(-50, 0, 60, 80)),
            ic(ua(110, 140), ia(disallow, 150, 120)),
            ""
        );
        // now test for other conditions

        // depeg already added
        _checkConfig(
            130,
            250,
            ic(ua(100, 131, 140), ia(200, 150, 100, 50)),
            ic(ua(100, 140), ia(0, 20, 70)),
            ic(ua(100), ia(60, 80)),
            // no bounds
            ic(ua(), ia(120)),
            ""
        );

        _checkConfig(
            130,
            250,
            ic(ua(131, 140), ia(disallow, 100, 50)),
            ic(ua(110, 120, 140), ia(-50, 0, 20, 70)),
            // max bands
            ic(ua(110, 120, 140, 150, 160), ia(-50, 0, 60, 80, 90, 100)),
            // min bands
            ic(ua(), ia(120)),
            ""
        );

        // mismatched length, too many bands
        config.mintPeggedIncentiveConfig = ic(ua(), ia(disallow, 100));
        vm.expectRevert(abi.encodeWithSelector(IMinter.CollateralRatioBoundsIncentivesLengthsMismatch.selector, 0, 2));
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // mismatched length, too many bands
        config.mintPeggedIncentiveConfig = ic(ua(100), ia(100));
        vm.expectRevert(abi.encodeWithSelector(IMinter.CollateralRatioBoundsIncentivesLengthsMismatch.selector, 1, 1));
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // depegged not first
        config.mintPeggedIncentiveConfig = ic(
            ua(90, 100, 131, 140, 150, 160, 170),
            ia(disallow, 100, 50, 100, 200, 300, 400, 500)
        );
        vm.expectRevert(abi.encodeWithSelector(IMinter.InvalidCollateralRatioBoundValue.selector, 9 ether / 10, 0));
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        config.mintPeggedIncentiveConfig = ic(
            ua(100, 101, 131, 140, 150, 160, 170),
            ia(disallow, 100, 50, 100, 200, 300, 400, 500)
        );
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // more than max number
        config.mintPeggedIncentiveConfig = ic(
            ua(100, 102, 131, 140, 150, 160, 170, 180),
            ia(disallow, 100, 50, 100, 200, 300, 400, 500, 600)
        );
        vm.expectRevert(abi.encodeWithSelector(IMinter.TooManyIncentiveRatios.selector, 9, 8));
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // more than max with no depeg band, we allow one less
        config.mintPeggedIncentiveConfig = ic(
            ua(101, 102, 131, 140, 150, 160, 170),
            ia(50, 100, 50, 100, 200, 300, 400, 500)
        );
        vm.expectRevert(abi.encodeWithSelector(IMinter.TooManyIncentiveRatios.selector, 8, 7));
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // more than max with no depeg band, we allow one less unless it's a disallow
        config.mintPeggedIncentiveConfig = ic(
            ua(101, 102, 131, 140, 150, 160, 170),
            ia(disallow, 100, 50, 100, 200, 300, 400, 500)
        );
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // numerical precision
        config.mintPeggedIncentiveConfig = ic(ua(130, 130), ia(100, 50, 10));
        config.mintPeggedIncentiveConfig.collateralRatioBandUpperBounds[1] = 130 * 10 ** 16 + 1;
        vm.expectRevert(abi.encodeWithSelector(IMinter.CollateralRatioBoundTooPrecise.selector, 130 * 10 ** 16 + 1));
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        config.mintPeggedIncentiveConfig = ic(ua(130, 130), ia(100, 50, 10));
        config.mintPeggedIncentiveConfig.incentiveRatios[1] = 50 * 10 ** 16 + 1;
        vm.expectRevert(abi.encodeWithSelector(IMinter.IncentiveRatioTooPrecise.selector, 50 * 10 ** 16 + 1));
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // less than min length
        config.mintPeggedIncentiveConfig = ic(ua(), ia());
        vm.expectRevert(abi.encodeWithSelector(IMinter.TooFewIncentiveRatios.selector, 0, 1));
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // check the collateral ratio bounds are are checked for strictly increasing
        // all
        config.mintPeggedIncentiveConfig = ic(ua(200, 200), ia(1, 2, 3));
        vm.expectRevert(
            abi.encodeWithSelector(IMinter.CollateralRatioBoundValueNotIncreasing.selector, 2 ether, 1, 2 ether)
        );
        vm.prank(owner);
        IMinter(minter).updateConfig(config);
        // middle
        config.mintPeggedIncentiveConfig = ic(ua(100, 200, 200, 300), ia(1, 2, 3, 4, 5));
        vm.expectRevert(
            abi.encodeWithSelector(IMinter.CollateralRatioBoundValueNotIncreasing.selector, 2 ether, 2, 2 ether)
        );
        vm.prank(owner);
        IMinter(minter).updateConfig(config);
        // start
        config.mintPeggedIncentiveConfig = ic(ua(200, 200, 300, 400), ia(1, 2, 3, 4, 5));
        vm.expectRevert(
            abi.encodeWithSelector(IMinter.CollateralRatioBoundValueNotIncreasing.selector, 2 ether, 1, 2 ether)
        );
        vm.prank(owner);
        IMinter(minter).updateConfig(config);
        // end
        config.mintPeggedIncentiveConfig = ic(ua(100, 200, 300, 300), ia(1, 2, 3, 4, 5));
        vm.expectRevert(
            abi.encodeWithSelector(IMinter.CollateralRatioBoundValueNotIncreasing.selector, 3 ether, 3, 3 ether)
        );
        vm.prank(owner);
        IMinter(minter).updateConfig(config);
        // < not <=
        config.mintPeggedIncentiveConfig = ic(ua(300, 200, 300, 300), ia(1, 2, 3, 4, 5));
        vm.expectRevert(
            abi.encodeWithSelector(IMinter.CollateralRatioBoundValueNotIncreasing.selector, 2 ether, 1, 3 ether)
        );
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // set up the incentive configs for precise testing of values
        config.mintPeggedIncentiveConfig = ic(ua(), ia(0));
        config.mintLeveragedIncentiveConfig = ic(ua(), ia(0));
        config.redeemPeggedIncentiveConfig = ic(ua(), ia(0));
        config.redeemLeveragedIncentiveConfig = ic(ua(), ia(0));

        // check the incentive ratios are in the range for the action
        // max - mint pegged = 1 ether
        // > max
        config.mintPeggedIncentiveConfig.incentiveRatios[0] = 1 ether + incentivePrecision;
        vm.expectRevert(
            abi.encodeWithSelector(IMinter.InvalidIncentiveRatioValue.selector, 1 ether + incentivePrecision)
        );
        vm.prank(owner);
        IMinter(minter).updateConfig(config);
        // = max
        config.mintPeggedIncentiveConfig.incentiveRatios[0] = 1 ether;
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // max - mint leveraged = 1 ether -1
        // > max
        config.mintLeveragedIncentiveConfig.incentiveRatios[0] = 1 ether;
        vm.expectRevert(abi.encodeWithSelector(IMinter.InvalidIncentiveRatioValue.selector, 1 ether));
        vm.prank(owner);
        IMinter(minter).updateConfig(config);
        // = max
        config.mintLeveragedIncentiveConfig.incentiveRatios[0] = 1 ether - incentivePrecision;
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // min - mint pegged = 0
        // < min
        config.mintPeggedIncentiveConfig.incentiveRatios[0] = -incentivePrecision;
        vm.expectRevert(abi.encodeWithSelector(IMinter.InvalidIncentiveRatioValue.selector, -incentivePrecision));
        vm.prank(owner);
        IMinter(minter).updateConfig(config);
        // = min
        config.mintPeggedIncentiveConfig.incentiveRatios[0] = 0;
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // min - mint leveraged = - 1 ether
        // < min
        config.mintLeveragedIncentiveConfig.incentiveRatios[0] = -1 ether;
        vm.expectRevert(abi.encodeWithSelector(IMinter.InvalidIncentiveRatioValue.selector, -1 ether));
        vm.prank(owner);
        IMinter(minter).updateConfig(config);
        // = min
        config.mintLeveragedIncentiveConfig.incentiveRatios[0] = -1 ether + incentivePrecision;
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // two disallow bands
        config.mintPeggedIncentiveConfig = ic(ua(120), ia(disallow, disallow));
        vm.expectRevert(abi.encodeWithSelector(IMinter.InvalidIncentiveRatioValue.selector, 1 ether));
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        // disallow not in first band
        config.mintPeggedIncentiveConfig = ic(ua(120), ia(100, disallow));
        vm.expectRevert(abi.encodeWithSelector(IMinter.InvalidIncentiveRatioValue.selector, 1 ether));
        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        /*
        config.mintPeggedIncentiveConfig.incentiveRatios[0] = -1;
        vm.expectRevert(
            abi.encodeWithSelector(IMinter.InvalidIncentiveRatioValue.selector, )
        );
        vm.prank(owner);
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

    // function testFuzz_SetNumber(uint256 x) public {
    //     counter.setNumber(x);
    //     assertEq(counter.number(), x);
    //}
}
