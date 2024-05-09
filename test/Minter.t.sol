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
    IMinter.Config config;

    address bonusToken;

    address leveragedToken;
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
            abi.encodeCall(LeveragedToken_v1.initialize, (owner.addr, "Leveraged Token", "BaoL"))
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
            config
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
    Vm.Wallet user;

    function setUp() public override {
        super.setUp();
        user = vm.createWallet("user");
        setUp_permissions();

        deal(address(deployed.wstETH), user.addr, 100 ether);
        vm.prank(user.addr);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);
    }

    //---------------------------------------------------------------------------------------------
    // Fees
    //---------------------------------------------------------------------------------------------

    function getFees()
        private
        view
        returns (int256 mintPeggedFees, int256 redeemPeggedFees, int256 mintLeveragedFees, int256 redeemLeveragedFees)
    {
        mintPeggedFees = IMinter(minter).mintPeggedTokenFeeRatio(0);
        redeemPeggedFees = IMinter(minter).redeemPeggedTokenFeeRatio(0);
        mintLeveragedFees = IMinter(minter).mintLeveragedTokenFeeRatio(0);
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
        console.log(
            "startPrice (%s) * config.rebalanceCollateralRatioUpperBound (%s)",
            startPrice,
            config.rebalanceCollateralRatioUpperBound
        );
        uint256 priceForCollateral = (startPrice * config.rebalanceCollateralRatioUpperBound) / 1 ether;
        for (uint256 price = priceForCollateral - 100000; price < priceForCollateral + 100000; price += 100) {
            MockPriceOracle(priceOracle).setPrice(price);
            uint256 cr = IMinter(minter).collateralRatio();
            // TODO: check the results against the expected behavior:
            // always rising/falling or staying the same and last value is geater/less than the first, etc.
            // inflection point is around the config collateral ratio
            //console.log("%s - %s - %s", price, config.rebalanceCollateralRatioUpperBound, cr);
            (
                uint256 mintPeggedFees,
                uint256 redeemPeggedFees,
                uint256 mintLeveragedFees,
                uint256 redeemLeveragedFees
            ) = getFees();
        }
        // TODO: merge the two checks into one.
        priceForCollateral = (startPrice * config.dangerCollateralRatioUpperBound) / 1 ether;
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

        for (uint256 cr = 9 ether / 10; cr <= 16 ether / 10; cr += 1 ether / 1000) {
            // for (uint256 cr = 11 ether / 10; cr <= 15 ether / 10; cr += 5 ether / 100) {
            uint256 price = (startPrice * cr) / 1 ether;
            MockPriceOracle(priceOracle).setPrice(price);
            assertEq(cr, IMinter(minter).collateralRatio(), "crs must match");
            (
                int256 mintPeggedFees,
                int256 redeemPeggedFees,
                int256 mintLeveragedFees,
                int256 redeemLeveragedFees
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

    function test_mintPeggedFees() public {
        (, uint256 price, , ) = priceOracle.getPrice();
        setUp_collateral(2 ether, 1 ether); // CR = 3/2 = 1.5
        assertLt(dangerCollateralRatioUpperBound, IMinter(minter).collateralRatio(), "test must start with CR normal");

        // fees at normal
        int256 mintPeggedFees0 = IMinter(minter).mintPeggedTokenFeeRatio(0);
        assertEq(mintPeggedFees0, mintPeggedNormalFeeRatio);

        // fees crossing into danger
        uint256 collateral = 1 ether;
        int256 mintPeggedFees1 = IMinter(minter).mintPeggedTokenFeeRatio(collateral); // CR -> 4/3 = 1.33 in danger
        assertGt(mintPeggedFees1, mintPeggedNormalFeeRatio, "fee is part normal, part danger, so > normal");
        assertLt(mintPeggedFees1, mintPeggedDangerFeeRatio, "fee is part normal, part danger, so < danger");

        // check that the fees match the reported value, both emit and that transferred
        int256 expectedFees = (mintPeggedFees1 * int256(collateral)) / 1 ether;
        uint256 feeReceiverCollateralBalanceBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintPeggedToken(
            user.addr,
            user.addr,
            collateral,
            uint256((int256(price) * (int256(collateral) - expectedFees))) / 1 ether,
            uint256(expectedFees)
        );
        vm.prank(user.addr);
        IMinter(minter).mintPeggedToken(collateral, user.addr, 0);
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            uint256(int256(feeReceiverCollateralBalanceBefore) + expectedFees)
        );

        // we are now in danger (CR=1.33), so check the fee here
        assertGt(dangerCollateralRatioUpperBound, IMinter(minter).collateralRatio(), "test must start with CR danger");
        assertLt(
            config.disallowMintPeggedCollateralRatioUpperBound,
            IMinter(minter).collateralRatio(),
            "test must start with CR danger"
        );
        assertEq(IMinter(minter).mintPeggedTokenFeeRatio(0), mintPeggedDangerFeeRatio, "expected to be in danger");
        // TODO: add a view function to say how much will be minted, given disallowing, maybe the same function mintPeggedTokenFeeRatio
        assertEq(
            IMinter(minter).mintPeggedTokenFeeRatio(3 ether),
            mintPeggedDangerFeeRatio,
            "expected to still be in danger"
        ); // CR -> disallow but fee ratio is still danger
    }

    /*
    function test_mintLeveragedFees() public {
        (, uint256 price, , ) = priceOracle.getPrice();
        setUp_collateral(2 ether, 1 ether);
        assertEq(IMinter(minter).collateralRatio(), 3 ether / 2);

        uint256 collateral = 1 ether; // cr goes to 4 ether / 3 = 1.33, so fees should be well within normal, increasing to danger
        uint256 mintLeveragedFees0 = IMinter(minter).mintLeveragedTokenFeeRatio(); // TODO: make it the lower of the before and after fee
        uint256 mintLeveragedFees1 = IMinter(minter).mintLeveragedTokenFeeRatio();
        assertGt(mintLeveragedFees1, mintLeveragedFees0, "fee ratios increase the more is minted");
        uint256 expectedFees = (mintLeveragedFees1 * collateral) / 1 ether;
        uint256 feeReceiverCollateralBalanceBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintLeveragedToken(
            user.addr,
            user.addr,
            collateral,
            (price * (collateral - expectedFees)) / 1 ether,
            expectedFees
        );
        vm.prank(user.addr);
        IMinter(minter).mintLeveragedToken(collateral, user.addr, 0);
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            feeReceiverCollateralBalanceBefore + expectedFees
        );
    }
    */
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
        makeAllFeesNormal(); // makes fee calculations simple as we're not concerned with fees here
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
            IERC20(deployed.BaoUSD).balanceOf(receiver.addr),
            receiverBaoUSDBefore + receiverBaoUSDIncrease,
            "receiver baoUSD balance after"
        );
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

        uint256 senderCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            senderCollateralDecrease = IERC20(deployed.wstETH).balanceOf(sender.addr);
        } else {
            senderCollateralDecrease = collateralIn;
        }

        deal(address(deployed.wstETH), sender.addr, senderCollateralDecrease);
        vm.prank(sender.addr);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);

        int256 mintPeggedFee = (int256(senderCollateralDecrease) * mintPeggedNormalFeeRatio) / 1 ether;
        uint256 receiverBaoUSDIncrease = uint256(int256(price) * (int256(senderCollateralDecrease) - mintPeggedFee)) /
            1 ether;

        uint256 feeReceiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        uint256 senderCollateralBefore = IERC20(deployed.wstETH).balanceOf(sender.addr);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);
        uint256 receiverPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(receiver.addr);
        uint256 minterCollateralBalanceBefore = IMinter(minter).collateralTokenBalance();
        uint256 minterPeggedBalanceBefore = IMinter(minter).peggedTokenBalance();
        // uint256 minterLeveragedBalanceBefore = IMinter(minter).peggedTokenBalance();
        uint256 minterCollateralBefore = IERC20(deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintPeggedToken(
            sender.addr,
            receiver.addr,
            senderCollateralDecrease,
            receiverBaoUSDIncrease,
            uint256(mintPeggedFee)
        );
        vm.prank(sender.addr);
        uint256 minted = IMinter(minter).mintPeggedToken(collateralIn, receiver.addr, 0);
        //               -----------------------------------------------------------
        assertEq(minted, receiverBaoUSDIncrease, "unexpected amount minted compared to price");
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            uint256(int256(feeReceiverCollateralBefore) + mintPeggedFee),
            "fee transferred"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(sender.addr),
            senderCollateralBefore - senderCollateralDecrease,
            "collateral sent"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(receiver.addr),
            receiverCollateralBefore,
            "no change in receiver collateral"
        );
        assertEq(
            IERC20(deployed.BaoUSD).balanceOf(receiver.addr),
            receiverPeggedBefore + receiverBaoUSDIncrease,
            "receiver received baoUSD"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            uint256(int256(minterCollateralBalanceBefore + senderCollateralDecrease) - mintPeggedFee),
            "minter is tracking the new collateral"
        );
        assertEq(
            IMinter(minter).peggedTokenBalance(),
            minterPeggedBalanceBefore + receiverBaoUSDIncrease,
            "minter is tracking the new pegged"
        );
        //assertEq(IMinter(minter).leveragedTokenBalance(), minterLeveragedBalanceBefore, "no new leveraged tokens");
        assertEq(
            IERC20(deployed.wstETH).balanceOf(minter),
            uint256(int256(minterCollateralBefore + senderCollateralDecrease) - mintPeggedFee),
            "wstETH has minter owning it"
        );
        assertLt(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio <= before");
    }

    function test_mintPeggedBasic() public {
        assertEq(IMinter(minter).collateralRatio(), type(uint256).max);
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(0, receiver.addr, 0);
        //----------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(type(uint256).max, receiver.addr, 0);
        //----------------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // some input, when infinite collateral ratio
        vm.expectRevert(abi.encodeWithSelector(IMinter.ActionPaused.selector));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(1 ether, receiver.addr, 0);
        //-------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // some input, when in the rebalance zone
        setUp_collateral(1 ether, 0); // make a finite collateral ratio, 1.0
        vm.expectRevert(abi.encodeWithSelector(IMinter.MintZeroAmount.selector, deployed.BaoUSD));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(1 ether, receiver.addr, 0);
        //-------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // some input, when none
        setUp_collateral(0, 1 ether); // make collateral ratio ~ 2
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(1 ether, receiver.addr, 0);
        //-------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(type(uint256).max, receiver.addr, 0);
        //------------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // get collateral
        deal(address(deployed.wstETH), sender.addr, 10 ether);

        // mint no allowance
        assertEq(IERC20(deployed.wstETH).allowance(sender.addr, minter), 0);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(1 ether, receiver.addr, 0);
        //--------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);

        // get allowance
        vm.prank(sender.addr);
        IERC20(deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(0, receiver.addr, 0);
        //--------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), 0);
    }

    function test_mintPeggedDisallow() public {
        // get collateral & allow
        deal(address(deployed.wstETH), sender.addr, 10 ether);
        vm.prank(sender.addr);
        IERC20(deployed.wstETH).approve(minter, 10 ether);

        // no minting in disallow zone
        setUp_collateral(1 ether, 0); // make a finite collateral ratio, 1.0
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "CR=1.0");
        vm.expectRevert(abi.encodeWithSelector(IMinter.MintZeroAmount.selector, deployed.BaoUSD));
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(1 ether, receiver.addr, 0);
        //--------------------------------------------------------
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "still CR=1.0");

        // no minting into rebalance zone
        setUp_collateral(3 ether, 2 ether); // make CR = 6/4  = 1.5
        assertEq(IMinter(minter).collateralRatio(), 6 ether / 4, "CR=1.5");
        assertGt(
            config.disallowMintPeggedCollateralRatioUpperBound,
            10 ether / 8,
            "test should push CR below disallow"
        );
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(4 ether, receiver.addr, 0); // push CR to 10/8 = 1.25
        //--------------------------------------------------------
        // CR should now be disallow (1.3+), not 1.25
        assertApproxEqAbs(
            IMinter(minter).collateralRatio(),
            config.disallowMintPeggedCollateralRatioUpperBound + 1,
            1,
            "CR=disallow(1.3)"
        );
        assertGt(
            IMinter(minter).collateralRatio(),
            config.disallowMintPeggedCollateralRatioUpperBound,
            "CR>disallow(1.3)"
        );
    }

    function test_mintPegged() public {
        // set up some collateral,
        setUp_collateral(10 ether, 10 ether);
        (, uint256 price, , ) = priceOracle.getPrice();
        assertEq(IMinter(minter).collateralRatio(), 2 ether);

        // first mint
        _mintPeggedToken(1 ether);

        // second mint
        _mintPeggedToken(2 ether);

        // check token out check
        uint256 collateral = 3 ether;
        deal(address(deployed.wstETH), sender.addr, collateral * 3);

        int256 mintPeggedFee = (int256(collateral) * mintPeggedNormalFeeRatio) / 1 ether;
        uint256 expectedPeggedTokenOut = uint256((int256(collateral) - mintPeggedFee) * int256(price)) / 1 ether;
        uint256 senderCollateralBefore = IERC20(deployed.wstETH).balanceOf(sender.addr);
        uint256 receiverPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(receiver.addr);

        // just within
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(collateral, receiver.addr, expectedPeggedTokenOut);
        //--------------------------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), receiverPeggedBefore + expectedPeggedTokenOut);
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), senderCollateralBefore - collateral);

        senderCollateralBefore = IERC20(deployed.wstETH).balanceOf(sender.addr);
        receiverPeggedBefore = IERC20(deployed.BaoUSD).balanceOf(receiver.addr);

        // just over
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.MintInsufficientAmount.selector,
                deployed.BaoUSD,
                expectedPeggedTokenOut + 1,
                expectedPeggedTokenOut
            )
        );
        vm.prank(sender.addr);
        IMinter(minter).mintPeggedToken(collateral, receiver.addr, expectedPeggedTokenOut + 1);
        //------------------------------------------------------------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), receiverPeggedBefore);
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), senderCollateralBefore);

        // mint from all of balance
        mintPeggedFee = (int256(senderCollateralBefore) * mintPeggedNormalFeeRatio) / 1 ether;
        expectedPeggedTokenOut = uint256((int256(senderCollateralBefore) - mintPeggedFee) * int256(price)) / 1 ether;
        _mintPeggedToken(type(uint256).max);
        //---------------------------------
        assertEq(IERC20(deployed.BaoUSD).balanceOf(receiver.addr), receiverPeggedBefore + expectedPeggedTokenOut);
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), 0, "transferred it all");
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

    function _mintLeveragedToken(uint256 collateralIn) private {
        //(, uint256 price, , ) = priceOracle.getPrice();

        uint256 senderCollateralDecrease;
        if (collateralIn == type(uint256).max) {
            senderCollateralDecrease = IERC20(deployed.wstETH).balanceOf(sender.addr);
        } else {
            senderCollateralDecrease = collateralIn;
        }

        deal(address(deployed.wstETH), sender.addr, senderCollateralDecrease);
        vm.prank(sender.addr);
        IERC20(deployed.wstETH).approve(minter, type(uint256).max);

        int256 mintLeveragedFee = (int256(senderCollateralDecrease) * mintLeveragedNormalFeeRatio) / 1 ether;
        uint256 receiverLeveragedIncrease = IMinter(minter).leverageTokensForCollateral(
            uint256(int256(senderCollateralDecrease) - mintLeveragedFee)
        );

        uint256 feeReceiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(feeReceiver.addr);
        uint256 senderCollateralBefore = IERC20(deployed.wstETH).balanceOf(sender.addr);
        uint256 receiverCollateralBefore = IERC20(deployed.wstETH).balanceOf(receiver.addr);
        uint256 receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver.addr);
        uint256 minterCollateralBalanceBefore = IMinter(minter).collateralTokenBalance();
        //uint256 minterPeggedBalanceBefore = IMinter(minter).peggedTokenBalance();
        uint256 minterLeveragedBalanceBefore = IMinter(minter).leveragedTokenBalance();
        uint256 minterCollateralBefore = IERC20(deployed.wstETH).balanceOf(minter);
        uint256 collateralRatioBefore = IMinter(minter).collateralRatio();

        vm.expectEmit(true, true, false, true, minter);
        emit IMinter.MintLeveragedToken(
            sender.addr,
            receiver.addr,
            senderCollateralDecrease,
            receiverLeveragedIncrease,
            uint256(mintLeveragedFee),
            0 // TODO: check for non-zero bonus
        );
        vm.prank(sender.addr);
        (uint256 minted, uint256 bonus) = IMinter(minter).mintLeveragedToken(
            senderCollateralDecrease,
            receiver.addr,
            0
        );
        //                                ------------------------------------------------------------------
        assertEq(minted, receiverLeveragedIncrease, "unexpected amount minted compared to price");
        assertEq(bonus, 0, "expect zero bonus");
        assertEq(
            IERC20(deployed.wstETH).balanceOf(feeReceiver.addr),
            uint256(int256(feeReceiverCollateralBefore) + mintLeveragedFee),
            "fee transferred"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(sender.addr),
            senderCollateralBefore - senderCollateralDecrease,
            "collateral sent"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(receiver.addr),
            receiverCollateralBefore,
            "no change in receiver collateral"
        );
        assertEq(
            IERC20(leveragedToken).balanceOf(receiver.addr),
            receiverLeveragedBefore + receiverLeveragedIncrease,
            "receiver received leveraged"
        );
        assertEq(
            IMinter(minter).collateralTokenBalance(),
            uint256(int256(minterCollateralBalanceBefore + senderCollateralDecrease) - mintLeveragedFee),
            "minter is tracking the new collateral"
        );
        //assertEq(IMinter(minter).peggedTokenBalance(), minterPeggedBalanceBefore, "no new pegged");
        assertEq(
            IMinter(minter).leveragedTokenBalance(),
            minterLeveragedBalanceBefore + receiverLeveragedIncrease,
            "minter is tracking new leveraged tokens"
        );
        assertEq(
            IERC20(deployed.wstETH).balanceOf(minter),
            uint256(int256(minterCollateralBefore + senderCollateralDecrease) - mintLeveragedFee),
            "wstETH has minter owning it"
        );
        assertGt(IMinter(minter).collateralRatio(), collateralRatioBefore, "collateral ratio <= before");
    }

    function test_mintLeveragedBasic() public {
        assertEq(IMinter(minter).collateralRatio(), type(uint256).max);
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // zero input, when none
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), 0);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintLeveragedToken(0, receiver.addr, 0);
        //----------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintLeveragedToken(type(uint256).max, receiver.addr, 0);
        //----------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // some input, when infinite collateral ratio
        vm.expectRevert(abi.encodeWithSelector(IMinter.ActionPaused.selector));
        vm.prank(sender.addr);
        IMinter(minter).mintLeveragedToken(1 ether, receiver.addr, 0);
        //-------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // some input, when none
        setUp_collateral(1 ether, 0); // make collateral ratio 1.0
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        vm.prank(sender.addr);
        IMinter(minter).mintLeveragedToken(1 ether, receiver.addr, 0);
        //-------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // all input, when none
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintLeveragedToken(type(uint256).max, receiver.addr, 0);
        //------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // get collateral
        deal(address(deployed.wstETH), sender.addr, 10 ether);

        // mint no allowance
        assertEq(IERC20(deployed.wstETH).allowance(sender.addr, minter), 0);
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        vm.prank(sender.addr);
        IMinter(minter).mintLeveragedToken(1 ether, receiver.addr, 0);
        //----------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);

        // get allowance
        vm.prank(sender.addr);
        IERC20(deployed.wstETH).approve(minter, 10 ether);

        // zero input, when some
        vm.expectRevert(abi.encodeWithSelector(IMinter.ZeroInputBalance.selector, deployed.wstETH));
        vm.prank(sender.addr);
        IMinter(minter).mintLeveragedToken(0, receiver.addr, 0);
        //----------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), 0);
    }

    // TODO: check bonus function
    function test_mintLeveraged() public {
        setUp_collateral(10 ether, 0);
        priceOracle.setPrice(4000 ether); // put the collateral ratio to 2, so no excess fees
        assertEq(IMinter(minter).collateralRatio(), 2 ether);

        // first mint
        _mintLeveragedToken(1 ether);
        //--------------------------

        // second mint
        _mintLeveragedToken(2 ether);
        //--------------------------

        // check token out check
        uint256 collateral = 3 ether;
        deal(address(deployed.wstETH), sender.addr, collateral * 10);

        int256 mintLeveragedFee = (int256(collateral) * mintLeveragedNormalFeeRatio) / 1 ether;
        uint256 expectedLeveragedTokenOut = IMinter(minter).leverageTokensForCollateral(
            uint256(int256(collateral) - mintLeveragedFee)
        );

        uint256 senderCollateralBefore = IERC20(deployed.wstETH).balanceOf(sender.addr);
        uint256 receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver.addr);

        // just within
        vm.prank(sender.addr);
        IMinter(minter).mintLeveragedToken(collateral, receiver.addr, expectedLeveragedTokenOut);
        //--------------------------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), receiverLeveragedBefore + expectedLeveragedTokenOut);
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), senderCollateralBefore - collateral);

        senderCollateralBefore = IERC20(deployed.wstETH).balanceOf(sender.addr);
        receiverLeveragedBefore = IERC20(leveragedToken).balanceOf(receiver.addr);

        // just over
        vm.expectRevert(
            abi.encodeWithSelector(
                IMinter.MintInsufficientAmount.selector,
                leveragedToken,
                expectedLeveragedTokenOut + 1,
                expectedLeveragedTokenOut
            )
        );
        vm.prank(sender.addr);
        IMinter(minter).mintLeveragedToken(collateral, receiver.addr, expectedLeveragedTokenOut + 1);
        //------------------------------------------------------------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), receiverLeveragedBefore);
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), senderCollateralBefore);

        // mint from all of balance
        mintLeveragedFee = (int256(senderCollateralBefore) * mintLeveragedNormalFeeRatio) / 1 ether;
        expectedLeveragedTokenOut = IMinter(minter).leverageTokensForCollateral(
            uint256(int256(senderCollateralBefore) - mintLeveragedFee)
        );
        _mintLeveragedToken(type(uint256).max);
        //------------------------------------
        assertEq(IERC20(leveragedToken).balanceOf(receiver.addr), receiverLeveragedBefore + expectedLeveragedTokenOut);
        assertEq(IERC20(deployed.wstETH).balanceOf(sender.addr), 0, "transferred it all");
    }

    // checks that two free mint leverage tokens does not produce more leverage tokens than 1
    function test_leveragedToCollateralCalculation() public {
        setUp_collateral(1 ether, 1 ether);
        uint256 startCollateralRatio = 2 ether;
        assertEq(IMinter(minter).collateralRatio(), startCollateralRatio, "CR=2");

        uint256 collateral = 100 ether;

        deal(address(deployed.wstETH), owner.addr, collateral);
        vm.prank(owner.addr);
        IERC20(deployed.wstETH).approve(minter, collateral);
        // for a range of collateral ratios,

        // mint one
        uint256 oneMint = IMinter(minter).leverageTokensForCollateral(collateral);

        // mint multiple
        uint multiples = 100;
        uint256 collateral2 = collateral / multiples;
        uint256 prevCollateralRatio = startCollateralRatio;
        uint256 sum = 0;
        for (uint i = 0; i < multiples; i++) {
            uint256 oneOfMint = IMinter(minter).leverageTokensForCollateral(collateral2);
            assertEq(oneOfMint, oneMint / multiples, "first mint not exactly linear");
            sum += oneOfMint;

            vm.prank(owner.addr);
            uint256 oneOfMintActual = IMinterTreasury(minter).freeMintLeveragedToken(collateral2, receiver.addr);
            assertEq(oneOfMintActual, oneOfMint, "calc meets reality");
            uint256 collateralRatio = IMinter(minter).collateralRatio();
            assertGt(collateralRatio, prevCollateralRatio, "CR not increasing");
            prevCollateralRatio = collateralRatio;
        }
        assertEq(sum, oneMint, "one is the sum of it's constituents");
    }

    // TODO: mint a pegged token and check the fee was the one for the new collateral ratio

    function testMinterRedeemPegged() public {}
}
