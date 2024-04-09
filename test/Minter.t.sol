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
    uint256 defaultMintPeggedFee;
    uint256 defaultRedeemPeggedFee;
    uint256 defaultMintLeveragedFee;
    uint256 defaultRedeemLeveragedFee;
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
        bonusCollateralRatio = 110 ether / 100;
        rebalanceCollateralRatio = 120 ether / 100;
        dangerCollateralRatio = 130 ether / 100;
        defaultMintPeggedFee = 10 ether / 100;
        defaultRedeemPeggedFee = 5 ether / 100;
        defaultMintLeveragedFee = 15 ether / 100;
        defaultRedeemLeveragedFee = 20 ether / 100;
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
                    IMinter.CollateralRatioConfig(
                        bonusCollateralRatio,
                        rebalanceCollateralRatio,
                        dangerCollateralRatio
                    ),
                    IMinter.FeeConfig(
                        defaultMintPeggedFee,
                        defaultRedeemPeggedFee,
                        defaultMintLeveragedFee,
                        defaultRedeemLeveragedFee
                    ),
                    IMinter.BonusConfig(bonusToken, mintLeveragedBonusRatio, redeemPeggedBonusRatio)
                )
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
                    IMinter.CollateralRatioConfig(
                        bonusCollateralRatio,
                        rebalanceCollateralRatio,
                        dangerCollateralRatio
                    ),
                    IMinter.FeeConfig(
                        defaultMintPeggedFee,
                        defaultRedeemPeggedFee,
                        defaultMintLeveragedFee,
                        defaultRedeemLeveragedFee
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
            IMinter.CollateralRatioConfig(bonusCollateralRatio, rebalanceCollateralRatio, dangerCollateralRatio),
            IMinter.FeeConfig(
                defaultMintPeggedFee,
                defaultRedeemPeggedFee,
                defaultMintLeveragedFee,
                defaultRedeemLeveragedFee
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
        vm.expectRevert();
        IMinter(minter).collateralRatio();
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

contract TestMinterMint is TestMinter {
    using SafeERC20 for IERC20;

    address baoUSD;
    address wstETH;
    Vm.Wallet system;
    Vm.Wallet user;

    function setUp() public override {
        super.setUp();
        baoUSD = deployed.BaoUSD;
        wstETH = deployed.wstETH;
        system = vm.createWallet("system");
        user = vm.createWallet("user");
        vm.prank(IBaoUSD(baoUSD).operator());
        IBaoUSD(baoUSD).addMinter(minter);
    }

    function test_freeMintPegged() public {
        // mint noaccess
        assertFalse(AccessControlUpgradeable(minter).hasRole(zeroFeeRole, user.addr));
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user.addr, zeroFeeRole)
        );
        vm.prank(user.addr);
        IMinterTreasury(minter).freeMintPeggedToken(1 ether, user.addr);

        // get collateral & allowance
        deal(address(wstETH), owner.addr, 10 ether);
        vm.prank(owner.addr);
        IERC20(wstETH).approve(minter, 1 ether);

        // mint
        assertTrue(AccessControlUpgradeable(minter).hasRole(ownerRole, owner.addr));
        (, uint256 price, , ) = priceOracle.getPrice();
        assertEq(IERC20(baoUSD).balanceOf(user.addr), 0);
        // TODO: add in all the other events
        vm.expectEmit(false, false, false, true, minter);
        emit IMinter.MintPeggedToken(owner.addr, user.addr, 1 ether, price, 0);
        vm.prank(owner.addr);
        uint256 minted = IMinterTreasury(minter).freeMintPeggedToken(1 ether, user.addr);
        assertEq(minted, price, "unexpected amount minted compared to price");
        assertEq(IERC20(wstETH).balanceOf(owner.addr), 9 ether);
        assertEq(IERC20(wstETH).balanceOf(minter), 1 ether);
        assertEq(IERC20(baoUSD).balanceOf(user.addr), price);
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "collateral ratio = 100%");
    }

    function setUp_collateral(uint256 amount) private returns (uint256 peggedTokens) {
        // put some collateral into the minter to bootstrap it
        // get collateral & allowance
        deal(address(wstETH), owner.addr, amount + 10 ether);
        vm.prank(owner.addr);
        IERC20(wstETH).approve(minter, amount);
        vm.prank(owner.addr);
        peggedTokens = IMinterTreasury(minter).freeMintPeggedToken(amount, owner.addr);
    }

    function getFees()
        private
        returns (
            uint256 mintPeggedFees,
            uint256 redeemPeggedFees,
            uint256 mintLeveragedFees,
            uint256 redeemLeveragedFees
        )
    {
        mintPeggedFees = IMinter(minter).mintPeggedTokenFeeRatio(0);
        redeemPeggedFees = IMinter(minter).redeemPeggedTokenFeeRatio(0);
        mintLeveragedFees = IMinter(minter).mintLeveragedTokenFeeRatio(0);
        redeemLeveragedFees = IMinter(minter).redeemLeveragedTokenFeeRatio(0);
    }

    function test_fees() public {
        setUp_collateral(1 ether);
        assertEq(IMinter(minter).collateralRatio(), 1 ether);
        (, uint256 startPrice, , ) = IPriceOracle(priceOracle).getPrice();

        // test fees at the extremities, around rebalance and danger
        // CR is proportional to price
        uint256 priceForCollateral = (startPrice * rebalanceCollateralRatio) / 1 ether;
        for (uint256 price = priceForCollateral - 100000; price < priceForCollateral + 100000; price += 100) {
            MockPriceOracle(priceOracle).setPrice(price);
            uint256 cr = IMinter(minter).collateralRatio();
            //console.log("%s - %s - %s", price, rebalanceCollateralRatio, cr);
            (
                uint256 mintPeggedFees,
                uint256 redeemPeggedFees,
                uint256 mintLeveragedFees,
                uint256 redeemLeveragedFees
            ) = getFees();
        }

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

        // write a gnuplot data file for fees
        string memory file = "./results/fees.csv";
        if (vm.exists(file)) vm.removeFile(file);
        vm.writeLine(
            file,
            "Price, Collateral Ratio, Mint Pegged Fees, Redeem Pegged Fees, Mint Leveraged Fees, Redeem Leveraged Fees"
        );

        for (uint256 price = (startPrice * 9) / 10; price < (startPrice * 15) / 10; price += 10 ether) {
            MockPriceOracle(priceOracle).setPrice(price);
            uint256 cr = IMinter(minter).collateralRatio();
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

    function test_mintPegged() public {
        uint256 initialPeggedTokens = setUp_collateral(10 ether);
        priceOracle.setPrice(4000 ether); // put the collateral ratio to 2, so no excess fees
        assertEq(IMinter(minter).collateralRatio(), 2 ether);
        assertEq(IERC20(baoUSD).balanceOf(user.addr), 0);

        // mint no balance
        assertEq(IERC20(wstETH).balanceOf(user.addr), 0);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(user.addr);
        IMinter(minter).mintPeggedToken(1 ether, user.addr, 0);
        assertEq(IERC20(baoUSD).balanceOf(user.addr), 0);

        // get collateral
        deal(address(wstETH), user.addr, 10 ether);

        // mint no allowance
        assertEq(IERC20(wstETH).allowance(user.addr, minter), 0);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        vm.prank(user.addr);
        IMinter(minter).mintPeggedToken(1 ether, user.addr, 0);
        assertEq(IERC20(baoUSD).balanceOf(user.addr), 0);

        // get allowance
        vm.prank(user.addr);
        IERC20(wstETH).approve(minter, 1 ether);

        // TODO: add all the events emitted
        // mint
        (, uint256 price, , ) = priceOracle.getPrice();
        uint256 minterOpeningBalance = IERC20(wstETH).balanceOf(minter);
        assertEq(IERC20(baoUSD).balanceOf(user.addr), 0);

        uint256 collateralMinusFee = 1 ether - defaultMintPeggedFee;
        uint256 peggedTokenMinted = (price * collateralMinusFee) / 1 ether;
        vm.expectEmit(true, true, false, false, minter);
        emit IMinter.MintPeggedToken(user.addr, user.addr, collateralMinusFee, peggedTokenMinted, defaultMintPeggedFee);
        vm.prank(user.addr);
        uint256 minted = IMinter(minter).mintPeggedToken(1 ether, user.addr, 0);
        assertEq(minted, peggedTokenMinted, "unexpected amount minted compared to price");
        assertEq(
            IMinter(minter).peggedTokenBalance(),
            initialPeggedTokens + peggedTokenMinted,
            "pegged token controlled"
        );
        assertEq(IERC20(wstETH).balanceOf(user.addr), 9 ether, "user loses 1 ether");
        assertEq(
            IERC20(wstETH).balanceOf(minter),
            minterOpeningBalance + collateralMinusFee,
            "minter has the collateral minus fee"
        );
        assertEq(IERC20(baoUSD).balanceOf(user.addr), peggedTokenMinted, "user has minted baoUSD");
        assertEq(IERC20(wstETH).balanceOf(feeReceiver.addr), defaultMintPeggedFee);
    }

    function testMinterRedeemPegged() public {}
}
