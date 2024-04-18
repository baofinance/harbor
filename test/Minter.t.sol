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
import { IMinter, IMinterTreasury } from "src/minter/IMinter.sol";
import { IMintable } from "src/minter/IMintable.sol";
import { deployed } from "test/deployed.sol";
import { IPriceOracle } from "src/price/IPriceOracle.sol";
import { MockPriceOracle } from "test/MockPriceOracle.sol";
import { MockRateProvider } from "test/MockRateProvider.sol";
import { IBaoUSD } from "test/IBaoUSD.sol";

import { LeveragedToken_v1 } from "src/minter/LeveragedToken_v1.sol";
import "test/Useful.sol";

contract TestMinter is Test {
    address minter;
    uint256 bonusCollateralRatio;
    uint256 rebalanceCollateralRatio;
    uint256 dangerCollateralRatio;
    uint256 normalCollateralRatio;

    IMinter.FeeConfigForAction mintPeggedFeeRatios;
    IMinter.FeeConfigForAction redeemPeggedFeeRatios;
    IMinter.FeeConfigForAction mintLeveragedFeeRatios;
    IMinter.FeeConfigForAction redeemLeveragedFeeRatios;
    address bonusToken;
    uint256 mintLeveragedBonusRatio;
    uint256 redeemPeggedBonusRatio;

    address leveragedToken;
    MockPriceOracle priceOracle;
    MockRateProvider rateProvider;

    Vm.Wallet feeReceiver;
    Vm.Wallet owner;
    bytes32 ownerRole = 0;
    bytes32 zeroFeeRole = keccak256("ZERO_FEE_ROLE");
    bytes32 minterRole = keccak256("MINTER_ROLE");

    function percent(uint value) private pure returns (uint256) {
        return (value * 1 ether) / 100;
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
            abi.encodeCall(LeveragedToken_v1.initialize, (owner.addr, "Leveraged Token", "BaoL"))
        );

        // TODO: test for illegal collateral ratios
        bonusCollateralRatio = percent(110);
        rebalanceCollateralRatio = percent(120);
        dangerCollateralRatio = percent(130);
        normalCollateralRatio = percent(140);

        mintPeggedFeeRatios = IMinter.FeeConfigForAction(0, 0, percent(10), percent(5), percent(3));
        redeemPeggedFeeRatios = IMinter.FeeConfigForAction(0, 0, percent(0), percent(10), percent(7));
        mintLeveragedFeeRatios = IMinter.FeeConfigForAction(0, 0, percent(2), percent(7), percent(5));
        redeemLeveragedFeeRatios = IMinter.FeeConfigForAction(0, percent(20), percent(15), percent(12), percent(10));
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
                    IMinter.CollateralRatioBoundsConfig(
                        bonusCollateralRatio,
                        rebalanceCollateralRatio,
                        dangerCollateralRatio,
                        normalCollateralRatio
                    ),
                    IMinter.FeeConfig(
                        mintPeggedFeeRatios,
                        redeemPeggedFeeRatios,
                        mintLeveragedFeeRatios,
                        redeemLeveragedFeeRatios
                    ),
                    IMinter.BonusConfig(bonusToken, mintLeveragedBonusRatio, redeemPeggedBonusRatio)
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

    function makeSafeFeesNormal() internal {
        mintPeggedFeeRatios.safeFeeRatio = mintPeggedFeeRatios.normalFeeRatio;
        redeemPeggedFeeRatios.safeFeeRatio = redeemPeggedFeeRatios.normalFeeRatio;
        mintLeveragedFeeRatios.safeFeeRatio = mintLeveragedFeeRatios.normalFeeRatio;
        redeemLeveragedFeeRatios.safeFeeRatio = redeemLeveragedFeeRatios.normalFeeRatio;
        vm.prank(owner.addr);
        IMinter(minter).updateFeeConfig(
            IMinter.FeeConfig(
                mintPeggedFeeRatios,
                redeemPeggedFeeRatios,
                mintLeveragedFeeRatios,
                redeemLeveragedFeeRatios
            )
        );
    }
}

contract Test_MinterInit is TestMinter {
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
                    IMinter.CollateralRatioBoundsConfig(
                        bonusCollateralRatio,
                        rebalanceCollateralRatio,
                        dangerCollateralRatio,
                        normalCollateralRatio
                    ),
                    IMinter.FeeConfig(
                        mintPeggedFeeRatios,
                        redeemPeggedFeeRatios,
                        mintLeveragedFeeRatios,
                        redeemLeveragedFeeRatios
                    ),
                    IMinter.BonusConfig(bonusToken, mintLeveragedBonusRatio, redeemPeggedBonusRatio)
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
            IMinter.CollateralRatioBoundsConfig(
                bonusCollateralRatio,
                rebalanceCollateralRatio,
                dangerCollateralRatio,
                normalCollateralRatio
            ),
            IMinter.FeeConfig(
                mintPeggedFeeRatios,
                redeemPeggedFeeRatios,
                mintLeveragedFeeRatios,
                redeemLeveragedFeeRatios
            ),
            IMinter.BonusConfig(bonusToken, mintLeveragedBonusRatio, redeemPeggedBonusRatio)
        );

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

contract TestMinterFees is TestMinter {
    //---------------------------------------------------------------------------------------------
    // Fees
    //---------------------------------------------------------------------------------------------

    function getFees()
        private
        view
        returns (
            uint256 mintPeggedFees,
            uint256 redeemPeggedFees,
            uint256 mintLeveragedFees,
            uint256 redeemLeveragedFees
        )
    {
        mintPeggedFees = IMinter(minter).mintPeggedTokenFeeRatio(0);
        redeemPeggedFees = IMinter(minter).redeemPeggedTokenFeeRatio();
        mintLeveragedFees = IMinter(minter).mintLeveragedTokenFeeRatio();
        redeemLeveragedFees = IMinter(minter).redeemLeveragedTokenFeeRatio(0);
    }

    function test_fees() public {
        // TODO: check that the fee is adjusted for begin-state (mintLeveraged) and end-state (mintPegged)
        setUp_collateral(1 ether, 0);
        assertEq(IMinter(minter).collateralRatio(), 1 ether);
        (, uint256 startPrice, , ) = IPriceOracle(priceOracle).getPrice();
        /*
        // test fees at the extremities, around rebalance and danger
        // CR is proportional to price
        uint256 priceForCollateral = (startPrice * rebalanceCollateralRatio) / 1 ether;
        for (uint256 price = priceForCollateral - 100000; price < priceForCollateral + 100000; price += 100) {
            MockPriceOracle(priceOracle).setPrice(price);
            uint256 cr = IMinter(minter).collateralRatio();
            // TODO: check the results against the expected behavior:
            // always rising/falling or staying the same and last value is geater/less than the first, etc.
            // inflection point is around the config collateral ratio
            //console.log("%s - %s - %s", price, rebalanceCollateralRatio, cr);
            (
                uint256 mintPeggedFees,
                uint256 redeemPeggedFees,
                uint256 mintLeveragedFees,
                uint256 redeemLeveragedFees
            ) = getFees();
        }
        // TODO: merge the two checks into one.
        priceForCollateral = (startPrice * dangerCollateralRatio) / 1 ether;
        for (uint256 price = priceForCollateral - 100000; price < priceForCollateral + 100000; price += 100) {
            MockPriceOracle(priceOracle).setPrice(price);
            uint256 cr = IMinter(minter).collateralRatio();
            (
                uint256 mintPeggedFees,
                uint256 redeemPeggedFees,
                uint256 mintLeveragedFees,
                uint256 redeemLeveragedFees
            ) = getFees();
        }
        */
        // write a gnuplot data file for fees
        string memory file = "./results/fees.csv";
        if (vm.exists(file)) vm.removeFile(file);
        vm.writeLine(
            file,
            "Price, Collateral Ratio, Mint Pegged Fees, Redeem Pegged Fees, Mint Leveraged Fees, Redeem Leveraged Fees"
        );

        //for (uint256 price = (startPrice * 9) / 10; price < (startPrice * 15) / 10; price += 10 ether)

        for (uint256 cr = 9 ether / 10; cr <= 15 ether / 10; cr += 1 ether / 1000) {
            // for (uint256 cr = 11 ether / 10; cr <= 15 ether / 10; cr += 5 ether / 100) {
            uint256 price = (startPrice * cr) / 1 ether;
            MockPriceOracle(priceOracle).setPrice(price);
            assertEq(cr, IMinter(minter).collateralRatio(), "crs must match");
            (
                uint256 mintPeggedFees,
                uint256 redeemPeggedFees,
                uint256 mintLeveragedFees,
                uint256 redeemLeveragedFees
            ) = getFees();
            vm.writeLine(
                file,
                string.concat(
                    Useful.toStringScaled(price, 18),
                    ",",
                    Useful.toStringScaled(cr, 18),
                    ",",
                    Useful.toStringScaled(mintPeggedFees, 18),
                    ",",
                    Useful.toStringScaled(redeemPeggedFees, 18),
                    ",",
                    Useful.toStringScaled(mintLeveragedFees, 18),
                    ",",
                    Useful.toStringScaled(redeemLeveragedFees, 18)
                )
            );
        }
        vm.closeFile(file);
    }
}

contract TestMinterMint is TestMinter {
    using SafeERC20 for IERC20;

    Vm.Wallet system;
    Vm.Wallet sender;
    Vm.Wallet receiver;

    function setUp() public override {
        super.setUp();
        system = vm.createWallet("system");
        sender = vm.createWallet("sender");
        receiver = vm.createWallet("receiver");
        setUp_permissions();
        makeSafeFeesNormal(); // makes fee calculations simple and we're not concerned with fees here
    }

    //---------------------------------------------------------------------------------------------
    // Free Mint Pegged
    //---------------------------------------------------------------------------------------------

    function _freeMintPeggedToken(uint256 collateralIn) private {
        (, uint256 price, , ) = priceOracle.getPrice();

        uint256 ownerCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            ownerCollateralDecrease = IERC20(deployed.wstETH).balanceOf(owner.addr);
        } else {
            ownerCollateralDecrease = collateralIn;
        }
        uint256 receiverBaoUSDIncrease = (price * ownerCollateralDecrease) / 1 ether;

        uint256 ownerCollateralBefore = IERC20(deployed.wstETH).balanceOf(owner.addr);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);
        uint256 receiverBaoUSDBefore = IERC20(deployed.BaoUSD).balanceOf(receiver.addr);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterWstETHBefore = IERC20(deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintPeggedToken(owner.addr, receiver.addr, ownerCollateralDecrease, receiverBaoUSDIncrease, 0);
        vm.prank(owner.addr);
        uint256 minted = IMinterTreasury(minter).freeMintPeggedToken(collateralIn, receiver.addr);
        //               --------------------------------------------------------------------
        assertEq(minted, receiverBaoUSDIncrease, "unexpected amount minted compared to price");
        assertEq(IERC20(deployed.wstETH).balanceOf(owner.addr), ownerCollateralBefore - ownerCollateralDecrease);
        assertEq(IERC20(deployed.wstETH).balanceOf(receiver.addr), receiverCollateralBefore);
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), receiverBaoUSDBefore + receiverBaoUSDIncrease);
        assertEq(IMinter(minter).collateralTokenBalance(), minterCollateralBefore + ownerCollateralDecrease);
        assertEq(IERC20(deployed.wstETH).balanceOf(minter), minterWstETHBefore + ownerCollateralDecrease);
        assertLe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio <= before");
    }

    function test_freeMintPegged() public {
        // mint noaccess
        assertFalse(AccessControlUpgradeable(minter).hasRole(zeroFeeRole, receiver.addr));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, receiver.addr, zeroFeeRole)
        );
        vm.prank(receiver.addr);
        IMinterTreasury(minter).freeMintPeggedToken(1 ether, receiver.addr);
        //-------------------------------------------------------------

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(owner.addr), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeMintPeggedToken(0, receiver.addr);
        //-------------------------------------------------------

        // some input, when none
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeMintPeggedToken(1 ether, receiver.addr);
        //-------------------------------------------------------------

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeMintPeggedToken(type(uint256).max, receiver.addr);
        //-----------------------------------------------------------------------

        // get collateral & allowance
        deal(address(deployed.wstETH), owner.addr, 10 ether);
        vm.prank(owner.addr);
        IERC20(deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeMintPeggedToken(0, receiver.addr);

        (, uint256 price, , ) = priceOracle.getPrice();

        // first mint
        assertEq(IMinter(minter).collateralRatio(), type(uint256).max, "collateral ratio = 1/0");
        assertTrue(AccessControlUpgradeable(minter).hasRole(ownerRole, owner.addr));
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);
        _freeMintPeggedToken(1 ether);
        //---------------------------
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio = 100%");
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), price);

        // more than one mint
        _freeMintPeggedToken(2 ether);
        //---------------------------

        // check all-of function, when some
        _freeMintPeggedToken(type(uint256).max);
        //-------------------------------------
    }

    //---------------------------------------------------------------------------------------------
    // Mint Pegged
    //---------------------------------------------------------------------------------------------

    function _mintPeggedToken(uint256 collateralIn) private {
        (, uint256 price, , ) = priceOracle.getPrice();

        uint256 ownerCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            ownerCollateralDecrease = IERC20(deployed.wstETH).balanceOf(owner.addr);
        } else {
            ownerCollateralDecrease = collateralIn;
        }

        deal(address(deployed.wstETH), sender.addr, ownerCollateralDecrease);
        vm.prank(sender.addr);
        IERC20(deployed.wstETH).approve(minter, 10 ether);

        uint256 mintPeggedFee = (ownerCollateralDecrease * mintPeggedFeeRatios.normalFeeRatio) / 1 ether;
        uint256 receiverBaoUSDIncrease = (price * (ownerCollateralDecrease - mintPeggedFee)) / 1 ether;

        uint256 feeReceiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        uint256 ownerCollateralBefore = IERC20(deployed.wstETH).balanceOf(owner.addr);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);
        uint256 receiverBaoUSDBefore = IERC20(deployed.BaoUSD).balanceOf(receiver.addr);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterWstETHBefore = IERC20(deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintPeggedToken(
            sender.addr,
            receiver.addr,
            ownerCollateralDecrease,
            receiverBaoUSDIncrease,
            mintPeggedFee
        );
        vm.prank(sender.addr);
        uint256 minted = IMinter(minter).mintPeggedToken(collateralIn, receiver.addr, 0);
        //               -----------------------------------------------------------
        assertEq(minted, receiverBaoUSDIncrease, "unexpected amount minted compared to price");
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            feeReceiverCollateralBefore + mintPeggedFee,
            "fee transferred"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(owner.addr),
            ownerCollateralBefore - ownerCollateralDecrease,
            "collateral sent"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(receiver.addr),
            receiverCollateralBefore,
            "no change in receiver collateral"
        );
        assertEq(
            IERC20(deployed.BaoUSD).balanceOf(receiver.addr),
            receiverBaoUSDBefore + receiverBaoUSDIncrease,
            "receiver received baoUSD"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            minterCollateralBefore + ownerCollateralDecrease - mintPeggedFee,
            "minter has the collateral"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(minter),
            minterWstETHBefore + ownerCollateralDecrease,
            "wstETH has minter owning it"
        );
        assertLe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio <= before");
    }

    function test_mintPeggedBasic() public {
        /*
        (uint256 initialPeggedTokens, ) = setUp_collateral(10 ether, 0);
        priceOracle.setPrice(4000 ether); // put the collateral ratio to 2, so no excess fees
        assertEq(IMinter(minter).collateralRatio(), 2 ether);
        assertEq(IERC20(deployed.BaoUSD).balanceOf(user.addr), 0);
        */

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(0, receiver.addr, 0);
        //----------------------------------------------------

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(type(uint256).max, receiver.addr, 0);
        //----------------------------------------------------------------------

        // some input, when none
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(1 ether, receiver.addr, 0);
        //-------------------------------------------------------------

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(type(uint256).max, receiver.addr, 0);

        // get collateral
        deal(address(deployed.wstETH), sender.addr, 10 ether);

        // mint no allowance
        assertEq(IERC20(deployed.wstETH).allowance(sender.addr, minter), 0);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(1 ether, receiver.addr, 0);
        //----------------------------------------------------

        // get allowance
        vm.prank(sender.addr);
        IERC20(deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(0, receiver.addr, 0);
        //----------------------------------------------------
    }

    function test_mintPegged() public {
        // set up some collateral,
        (uint256 initialPeggedTokens, ) = setUp_collateral(10 ether, 10 ether);
        console.log("collateral ratio=%s", IMinter(minter).collateralRatio());

        // first mint
        _mintPeggedToken(1 ether);
        //-----------------------
        /*
        (, uint256 price, , ) = priceOracle.getPrice();
        uint256 minterOpeningBalance = IMinter(minter).collateralTokenBalance();
        assertEq(IERC20(deployed.BaoUSD).balanceOf(user.addr), 0);

        uint256 collateralMinusFee = 1 ether - mintPeggedFeeRatios;
        uint256 expectedPeggedTokenOut = (price * collateralMinusFee) / 1 ether;
        vm.expectEmit(true, true, false, false, minter);
        emit IMinter.MintPeggedToken(
            user.addr,
            user.addr,
            collateralMinusFee,
            expectedPeggedTokenOut,
            mintPeggedFeeRatios
        );
        vm.prank(user.addr);
        uint256 minted = IMinter(minter).mintPeggedToken(1 ether, user.addr, 0);
        assertEq(minted, expectedPeggedTokenOut, "unexpected amount minted compared to price");
        assertEq(
            IMinter(minter).peggedTokenBalance(),
            initialPeggedTokens + expectedPeggedTokenOut,
            "pegged token controlled"
        );
        assertEq(IERC20(deployed.wstETH).balanceOf(user.addr), 9 ether, "user loses 1 ether");
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            minterOpeningBalance + collateralMinusFee,
            "minter has the collateral minus fee"
        );
        assertEq(IERC20(deployed.BaoUSD).balanceOf(user.addr), expectedPeggedTokenOut, "user has minted deployed.BaoUSD");
        assertEq(IERC20(deployed.wstETH).balanceOf(feeReceiver.addr), mintPeggedFeeRatios);
        */

        // second mint
        _mintPeggedToken(2 ether);

        /*

        // do a mint but expect more
        vm.prank(user.addr);
        IMinter(minter).mintPeggedToken(1 ether, user.addr, expectedPeggedTokenOut);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.MintInsufficientAmount.selector,
                deployed.BaoUSD,
                expectedPeggedTokenOut + 1,
                expectedPeggedTokenOut
            )
        );
        vm.prank(user.addr);
        IMinter(minter).mintPeggedToken(1 ether, user.addr, expectedPeggedTokenOut + 1);

        // mint from all of balance
        uint256 before = IERC20(deployed.wstETH).balanceOf(user.addr);
        assertGt(before, 0);
        vm.prank(user.addr);
        IMinter(minter).mintPeggedToken(type(uint256).max, user.addr, 0);
        assertEq(IERC20(deployed.wstETH).balanceOf(user.addr), 0, "transferred it all");
        */
    }

    //---------------------------------------------------------------------------------------------
    // Free Mint Leveraged
    //---------------------------------------------------------------------------------------------

    function _freeMintLeveragedToken(uint256 collateralIn) private {
        (, uint256 price, , ) = priceOracle.getPrice();

        uint256 ownerCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            ownerCollateralDecrease = IERC20(deployed.wstETH).balanceOf(owner.addr);
        } else {
            ownerCollateralDecrease = collateralIn;
        }
        uint256 receiverLeveragedIncrease = (price * ownerCollateralDecrease) / 1 ether;

        uint256 ownerCollateralBefore = IERC20(deployed.wstETH).balanceOf(owner.addr);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);
        uint256 receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver.addr);
        uint256 minterCollateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterWstETHBefore = IERC20(deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintLeveragedToken(
            owner.addr,
            receiver.addr,
            ownerCollateralDecrease,
            receiverLeveragedIncrease,
            0,
            0
        );
        vm.prank(owner.addr);
        uint256 minted = IMinterTreasury(minter).freeMintLeveragedToken(collateralIn, receiver.addr);
        //               --------------------------------------------------------------------
        assertEq(minted, receiverLeveragedIncrease, "unexpected amount free minted leveraged compared to price");
        assertEq(
            IERC20(deployed.wstETH).balanceOf(owner.addr),
            ownerCollateralBefore - ownerCollateralDecrease,
            "collateral not paid"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(receiver.addr),
            receiverCollateralBefore,
            "collateral not mis-transferred to receiver"
        );
        assertEq(
            IERC20(leveragedToken).balanceOf(receiver.addr),
            receiverLeveragedBefore + receiverLeveragedIncrease,
            "receiver leveraged balance after"
        );
        assertEq(IMinter(minter).collateralTokenBalance(), minterCollateralBefore + ownerCollateralDecrease);
        assertEq(IERC20(deployed.wstETH).balanceOf(minter), minterWstETHBefore + ownerCollateralDecrease);
        assertLe(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio <= before");
    }

    function test_freeMintLeveraged() public {
        // mint noaccess
        assertFalse(AccessControlUpgradeable(minter).hasRole(zeroFeeRole, sender.addr));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, sender.addr, zeroFeeRole)
        );
        vm.prank(sender.addr);
        IMinterTreasury(minter).freeMintLeveragedToken(1 ether, receiver.addr);
        //-------------------------------------------------------------

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(owner.addr), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeMintLeveragedToken(0, receiver.addr);
        //-------------------------------------------------------

        // some input, when none
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeMintLeveragedToken(1 ether, receiver.addr);
        //-------------------------------------------------------------------

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeMintLeveragedToken(type(uint256).max, receiver.addr);
        //------------------------------------------------------------------------------

        // get collateral & allowance
        deal(address(deployed.wstETH), owner.addr, 10 ether);
        vm.prank(owner.addr);
        IERC20(deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(owner.addr);
        IMinterTreasury(minter).freeMintLeveragedToken(0, receiver.addr);
        //--------------------------------------------------------------

        (, uint256 price, , ) = priceOracle.getPrice();

        // first mint
        assertEq(IMinter(minter).collateralRatio(), type(uint256).max, "collateral ratio = 1/0");
        assertTrue(AccessControlUpgradeable(minter).hasRole(ownerRole, owner.addr));
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);
        _freeMintLeveragedToken(1 ether);
        //---------------------------
        // collateral ratio is undefined for just minting leveraged tokens
        assertEq(IMinter(minter).collateralRatio(), type(uint256).max, unicode"collateral ratio = ∞");
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), price);

        // more than one mint
        _freeMintLeveragedToken(2 ether);
        //---------------------------

        // check all-of function, when some
        _freeMintLeveragedToken(type(uint256).max);
        //-------------------------------------
    }

    //---------------------------------------------------------------------------------------------
    // Mint Leveraged
    //---------------------------------------------------------------------------------------------

    // TODO: check bonus function
    function test_mintLeveraged() public {
        (, uint256 initialLeveragedTokens) = setUp_collateral(10 ether, 0);
        priceOracle.setPrice(4000 ether); // put the collateral ratio to 2, so no excess feessender
        assertEq(IMinter(minter).collateralRatio(), 2 ether);
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // mint no balance
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), 0);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(sender.addr);
        IMinter(minter).mintLeveragedToken(1 ether, receiver.addr, 0);
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // get collateral
        deal(address(deployed.wstETH), sender.addr, 10 ether);

        // mint no allowance
        assertEq(IERC20(deployed.wstETH).allowance(sender.addr, minter), 0);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        vm.prank(sender.addr);
        IMinter(minter).mintLeveragedToken(1 ether, receiver.addr, 0);
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // get allowance
        vm.prank(sender.addr);
        IERC20(deployed.wstETH).approve(minter, 10 ether);

        // mint
        (, uint256 price, , ) = priceOracle.getPrice();
        uint256 minterOpeningBalance = IMinter(minter).collateralTokenBalance();
        uint256 feeReceiverOpeningBalance = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);
        uint256 collateralMinusFee = 1 ether - mintLeveragedFeeRatios.normalFeeRatio;
        uint256 expectedLeveragedTokenOut = IMinter(minter).leverageTokensForCollateral(collateralMinusFee);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();
        vm.expectEmit(true, true, false, false, minter);
        emit IMinter.MintLeveragedToken(
            sender.addr,
            receiver.addr,
            collateralMinusFee,
            expectedLeveragedTokenOut,
            mintLeveragedFeeRatios.normalFeeRatio,
            0
        );
        vm.prank(sender.addr);
        (uint256 minted, uint256 bonus) = IMinter(minter).mintLeveragedToken(1 ether, receiver.addr, 0);
        console.log(
            "leveragedMinted=%s, price=%s, leveragedNAV=%s",
            minted,
            price,
            IMinter(minter).leveragedTokenNAV()
        );
        assertEq(bonus, 0);
        assertEq(minted, expectedLeveragedTokenOut, "unexpected amount minted leveraged compared to price");
        assertEq(
            IMinter(minter).leveragedTokenBalance(),
            initialLeveragedTokens + expectedLeveragedTokenOut,
            "leveraged token controlled"
        );
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), 9 ether, "sender loses 1 ether");
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            minterOpeningBalance + collateralMinusFee,
            "minter has the collateral minus fee"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            feeReceiverOpeningBalance + mintLeveragedFeeRatios.normalFeeRatio,
            "fee receiver has the fee" // TODO: check this happens with minting pegged
        );

        assertEq(
            IERC20(leveragedToken).balanceOf(receiver.addr),
            expectedLeveragedTokenOut,
            "receiver has minted leveragedToken"
        );
        assertEq(IERC20(deployed.wstETH).balanceOf(feeReceiver.addr), mintLeveragedFeeRatios.normalFeeRatio);
        console.log("collateral ratio %s -> %s", collateralRatioBefore, IMinter(minter).collateralRatio());

        // do a mint but expect more, just below the line
        expectedLeveragedTokenOut = IMinter(minter).leverageTokensForCollateral(
            1 ether - mintLeveragedFeeRatios.normalFeeRatio
        );
        console.log("expectedLeveragedTokenOut=%s", expectedLeveragedTokenOut);
        vm.prank(sender.addr);
        (minted, ) = IMinter(minter).mintLeveragedToken(1 ether, receiver.addr, expectedLeveragedTokenOut);
        console.log(
            "leveragedMinted=%s, price=%s, leveragedNAV=%s",
            minted,
            price,
            IMinter(minter).leveragedTokenNAV()
        );

        // do a mint but expect more, just above the line
        expectedLeveragedTokenOut = IMinter(minter).leverageTokensForCollateral(1 ether);
        console.log("expectedLeveragedTokenOut=%s", expectedLeveragedTokenOut);
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.MintInsufficientAmount.selector,
                leveragedToken,
                expectedLeveragedTokenOut + 1,
                expectedLeveragedTokenOut
            )
        );
        vm.prank(sender.addr);
        (minted, ) = IMinter(minter).mintLeveragedToken(1 ether, receiver.addr, expectedLeveragedTokenOut + 1);
        console.log(
            "leveragedMinted=%s, price=%s, leveragedNAV=%s",
            minted,
            price,
            IMinter(minter).leveragedTokenNAV()
        );

        // mint from all of balance
        uint256 before = IERC20(deployed.wstETH).balanceOf(sender.addr);
        assertGt(before, 0);
        vm.prank(sender.addr);
        IMinter(minter).mintLeveragedToken(type(uint256).max, receiver.addr, 0);
        console.log(
            "leveragedMinted=%s, price=%s, leveragedNAV=%s",
            minted,
            price,
            IMinter(minter).leveragedTokenNAV()
        );
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), 0, "transferred it all");
    }

    function testMinterRedeemPegged() public {}
}
