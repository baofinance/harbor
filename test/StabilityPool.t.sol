// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IMintableRole} from "@bao/interfaces/IMintableRole.sol";
import {IBurnableRole} from "@bao/interfaces/IBurnableRole.sol";
import {IMintable} from "@bao/interfaces/IMintable.sol";

import {Token} from "@bao/Token.sol";

import {IVotingEscrow} from "src/interfaces/IVotingEscrow.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {StabilityPool_v1} from "src/minter/StabilityPool_v1.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";

import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";

import {VotingEscrow_v1} from "src/reward/voting-escrow/VotingEscrow_v1.sol";
import {Steam_v1} from "src/reward/steam/Steam_v1.sol";

import {Deployed} from "@bao/Deployed.sol";
import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {IBaoUSD} from "test/IBaoUSD.sol";
import {TestMinterFeeSetUp} from "test/Minter_fees.t.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

import {console2} from "forge-std/console2.sol";

// New version for testing upgrades
contract StabilityPool_v2 is StabilityPool_v1 {
    // Keep the same constructor signature
    constructor(
        address minter_,
        address liquidationToken_,
        address stabilityPoolToken_,
        address steam_,
        address veSteam_
    )
        StabilityPool_v1(
            minter_,
            liquidationToken_,
            stabilityPoolToken_,
            steam_,
            0.025 ether,
            0x3dFc49e5112005179Da613BdE5973229082dAc35,
            3600,
            90000
        )
    {}

    // Add a new function to verify the upgrade worked
    function version() external pure returns (string memory) {
        return "v2";
    }
}

// used to expose internal functions
contract MockStabilityPool is StabilityPool_v1 {
    constructor(
        address minter_,
        address liquidationToken_,
        address stabilityPoolToken_,
        address steam_,
        address veSteam_
    )
        StabilityPool_v1(
            minter_,
            liquidationToken_,
            stabilityPoolToken_,
            steam_,
            0.025 ether,
            0x3dFc49e5112005179Da613BdE5973229082dAc35,
            3600,
            90000
        )
    {}

    /// @notice Exposes the product value for testing purposes
    function __totalSupply() external view returns (TokenBalance memory) {
        return _getStabilityPoolStorage().totalAssetSupply;
    }
}

// serves no other purpose than making the foundry traces more informative
contract MockSTEAM is MintableBurnableERC20_v1 {}

contract TestStabilityPoolSetUp is TestMinterFeeSetUp {
    uint256 internal constant EARLY_WITHDRAWAL_FEE = 0.025 ether;
    address internal constant FEE_ADDRESS = 0x3dFc49e5112005179Da613BdE5973229082dAc35;
    uint256 internal constant WITHDRAWAL_START_DELAY = 3600;
    uint256 internal constant WITHDRAWAL_END_WINDOW = 90000;
    address stabilityPoolCollateral;
    address steam;
    address veSteam;
    address user1;
    address user2;

    function _setupStabilityPool(address liquidationToken) internal virtual returns (address stabilityPool) {
        string memory liquidation = IERC20Metadata(liquidationToken).symbol();

        address stabilityPoolToken = address(
            UnsafeUpgrades.deployUUPSProxy(
                address(new MintableBurnableERC20_v1()), // "MintableBurnableERC20_v1.sol",
                abi.encodeCall(
                    MintableBurnableERC20_v1.initialize,
                    (owner, "StabilityPool Token", string.concat("lpBaoUSDLwstETHx", liquidation))
                )
            )
        );

        // use mock stability pool to expose internals for testing, otherwise it's identical to StabilityPool_v1
        stabilityPool = UnsafeUpgrades.deployUUPSProxy(
            address(new MockStabilityPool(minter, liquidationToken, stabilityPoolToken, steam, veSteam)), // "StabilityPool_v1.sol",
            abi.encodeCall(StabilityPool_v1.initialize, (owner))
        );
        IBaoRoles(stabilityPoolToken).grantRoles(address(this), IMintableRole(stabilityPoolToken).MINTER_ROLE());
        IMintable(stabilityPoolToken).mint(stabilityPool, 1 ether);

        IBaoRoles(stabilityPool).grantRoles(owner, IMultipleRewardDistributor(stabilityPool).REWARD_MANAGER_ROLE());
        vm.prank(owner);
        IMultipleRewardDistributor(stabilityPool).registerRewardToken(liquidationToken, stabilityPool);

        IBaoOwnable(stabilityPoolToken).transferOwnership(owner);
        IBaoOwnable(stabilityPool).transferOwnership(owner);
    }

    function setUp() public virtual override(TestMinterFeeSetUp) {
        super.setUp();

        uint256 _init_supply = 200_000 ether;
        uint256 _init_rate = uint256(1000 ether) / 356 days; // emissions per second
        uint256 _rate_reduction_coefficient = 2 ether; // rate halves every year

        steam = UnsafeUpgrades.deployUUPSProxy(
            address(new Steam_v1(_init_rate, _rate_reduction_coefficient)),
            abi.encodeCall(Steam_v1.initialize, (owner, _init_supply, "Zhenglong Steam", "STEAM"))
        );
        IBaoOwnable(steam).transferOwnership(owner);

        veSteam = UnsafeUpgrades.deployUUPSProxy(
            address(new VotingEscrow_v1(address(steam))),
            abi.encodeCall(VotingEscrow_v1.initialize, (owner, "Zhenglong Voting Escrow", "veSTEAM", "1"))
        );
        IBaoOwnable(veSteam).transferOwnership(owner);

        stabilityPoolCollateral = _setupStabilityPool(wrappedCollateralToken);
        // configure withdrawal settings on the proxy (constructor values are on implementation only)
        vm.startPrank(owner);
        IStabilityPool(stabilityPoolCollateral).setEarlyWithdrawalFee(EARLY_WITHDRAWAL_FEE);
        IStabilityPool(stabilityPoolCollateral).setFeeAddress(FEE_ADDRESS);
        IStabilityPool(stabilityPoolCollateral).setWithdrawalWindow(WITHDRAWAL_START_DELAY, WITHDRAWAL_END_WINDOW);
        vm.stopPrank();

        user1 = vm.createWallet("user1").addr;
        vm.prank(user1);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);

        user2 = vm.createWallet("user2").addr;
        vm.prank(user2);
        IERC20(peggedToken).approve(stabilityPoolCollateral, type(uint256).max);
    }

    function test_initOnly(address sp, address liquidateTo) internal view {
        assertEq(StabilityPool_v1(sp).owner(), owner);
        assertEq(IStabilityPool(sp).ASSET_TOKEN(), peggedToken);
        assertEq(IStabilityPool(sp).LIQUIDATION_TOKEN(), liquidateTo);
        assertNotEq(IStabilityPool(sp).GAUGE_STAKE_TOKEN(), address(0)); // make sure it has something
        assertEq(IStabilityPool(sp).GAUGE_REWARD_TOKEN(), steam); // make sure it has something
        assertEq(IStabilityPool(sp).gauge(), address(0));
        assertEq(IStabilityPool(sp).totalAssetSupply(), 0);
    }
}

contract TestStabilityPoolInit is TestStabilityPoolSetUp {
    using SafeERC20 for IERC20;

    function test_initOnly() public view {
        test_initOnly(stabilityPoolCollateral, wrappedCollateralToken);
    }

    // Test for _authorizeUpgrade function (coverage for function 192)
    function testUpgrade() public {
        // Only owner can upgrade
        vm.prank(user1);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        UUPSUpgradeable(stabilityPoolCollateral).upgradeToAndCall(address(0), "");

        address stabilityPoolToken = address(
            UnsafeUpgrades.deployUUPSProxy(
                address(new MintableBurnableERC20_v1()), // "MintableBurnableERC20_v1.sol",
                abi.encodeCall(MintableBurnableERC20_v1.initialize, (owner, "StabilityPool Token name", "lpToken"))
            )
        );

        // Create the V2 implementation
        StabilityPool_v2 implementationV2 = new StabilityPool_v2(
            minter,
            wrappedCollateralToken,
            stabilityPoolToken,
            steam,
            veSteam
        );

        // Perform the upgrade as the owner
        vm.prank(owner);
        UUPSUpgradeable(stabilityPoolCollateral).upgradeToAndCall(address(implementationV2), "");

        // Verify the upgrade was successful by calling the new version function
        assertEq(
            StabilityPool_v2(stabilityPoolCollateral).version(),
            "v2",
            "Upgrade should succeed and new function should be available"
        );
    }
}

contract TestStabilityPoolInitEvents is TestStabilityPoolSetUp {
    address stabilityPoolToken;

    function setUp() public virtual override(TestStabilityPoolSetUp) {
        super.setUp();
        stabilityPoolToken = address(
            UnsafeUpgrades.deployUUPSProxy(
                address(new MintableBurnableERC20_v1()), // "MintableBurnableERC20_v1.sol",
                abi.encodeCall(MintableBurnableERC20_v1.initialize, (owner, "StabilityPool Token name", "lpToken"))
            )
        );
    }

    function test_initEventsImplementation() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        address(
            new StabilityPool_v1(
                minter,
                wrappedCollateralToken,
                stabilityPoolToken,
                steam,
                EARLY_WITHDRAWAL_FEE,
                FEE_ADDRESS,
                WITHDRAWAL_START_DELAY,
                WITHDRAWAL_END_WINDOW
            )
        );
    }

    function test_initEvents(address liquidateTo) internal {
        address sp = address(
            new StabilityPool_v1(
                minter,
                liquidateTo,
                stabilityPoolToken,
                steam,
                EARLY_WITHDRAWAL_FEE,
                FEE_ADDRESS,
                WITHDRAWAL_START_DELAY,
                WITHDRAWAL_END_WINDOW
            )
        );
        vm.expectEmit();
        emit IERC1967.Upgraded(address(sp));
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call

        address spProxy = UnsafeUpgrades.deployUUPSProxy(
            sp, // "StabilityPool_v1.sol",
            abi.encodeCall(StabilityPool_v1.initialize, owner)
        );
        IBaoOwnable(spProxy).transferOwnership(owner);

        test_initOnly(spProxy, liquidateTo);
    }

    function test_initEventsCollateral() public {
        test_initEvents(wrappedCollateralToken);
    }

    function test_initEventsLeveraged() public {
        test_initEvents(leveragedToken);
    }

    // function test_initEventsBad() public {
    //     vm.expectRevert(abi.encodeWithSelector(IStabilityPool.InvalidLiquidationToken.selector, peggedToken));
    //     new StabilityPool_v1(minter, peggedToken, stabilityPoolToken, steam);

    //     vm.expectRevert(abi.encodeWithSelector(IMultipleRewardDistributor.InvalidPeriodLength.selector));
    //     new StabilityPool_v1(minter, peggedToken, stabilityPoolToken, steam);
    // }
}

contract TestStabilityPoolDepositWithdraw is TestStabilityPoolSetUp {
    function test_access() public {
        uint256 rebalancerRole = IStabilityPool(stabilityPoolCollateral).REBALANCER_ROLE();
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoRoles(stabilityPoolCollateral).grantRoles(address(this), rebalancerRole);

        vm.prank(owner);
        IBaoRoles(stabilityPoolCollateral).grantRoles(address(this), rebalancerRole);
    }

    function _depositWithdraw(address receiver) private {
        (uint256 price, , , ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        // more than holding
        setUp_collateral(20 ether, 0 ether);
        deal(peggedToken, user1, 10 * price);
        assertEq(IERC20(peggedToken).balanceOf(user1), 10 * price, "user1 has");
        vm.expectRevert(); // should be amount exceeds balance, but hey-ho BaoUSD
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(20 * price, receiver, 0);
        // 1 deposit -----------------------------------------------------------

        // $2 deposit
        assertEq(IERC20(peggedToken).balanceOf(user1), 10 * price);
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 0);
        vm.prank(user1);
        uint256 deposited = IStabilityPool(stabilityPoolCollateral).deposit(2 * price, receiver, 0);
        // 2 deposit ------------------------------------------------------------------------------
        assertEq(deposited, 2 * price, "returned value");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 2 * price);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(receiver), 2 * price);
        assertEq(IERC20(peggedToken).balanceOf(user1), 8 * price);

        // $3 withdrawal
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPool.WithdrawAmountExceedsBalance.selector, 3 * price, 2 * price)
        );
        IStabilityPool(stabilityPoolCollateral).withdraw(3 * price, receiver, 0);
        // 1 withdraw ---------------------------------------------
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(receiver), 2 * price);

        // $5 second deposit
        vm.prank(user1);
        deposited = IStabilityPool(stabilityPoolCollateral).deposit(5 * price, receiver, 0);
        // 3 deposit ------------------------------------------------------------
        assertEq(deposited, 5 * price, "returned value 5");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 7 * price);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(receiver), 7 * price);

        // withdraw some
        vm.prank(user1);
        uint256 withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(4 * price, receiver, 0);
        // 2 withdraw ---------------------------------------------------------------------------
        assertEq(withdrawn, 4 * price, "withdraw 4");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 3 * price);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(receiver), 3 * price);

        // withdraw rest
        vm.prank(user1);
        withdrawn = IStabilityPool(stabilityPoolCollateral).withdraw(type(uint256).max, receiver, 0);
        // 3 withdraw ---------------------------------------------------------------------------
        assertEq(withdrawn, 3 * price, "withdraw 3 (-1)");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 0);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(receiver), 0);

        // deposit -1
        vm.prank(user1);
        deposited = IStabilityPool(stabilityPoolCollateral).deposit(type(uint256).max, receiver, 0);
        // 4 deposit ------------------------------------------------------------------------------
        assertEq(deposited, 10 * price, "returned value 10");
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 10 * price);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(receiver), 10 * price);
        assertEq(IERC20(peggedToken).balanceOf(user1), 0);

        // check min deposit amount
        setUp_collateral(1 ether, 0 ether); // add more minter
        deal(address(peggedToken), user1, 3 * price);
        vm.expectRevert(
            abi.encodeWithSelector(IStabilityPool.DepositAmountLessThanMinimum.selector, 1 * price, 2 * price)
        );
        vm.prank(user1);
        IStabilityPool(stabilityPoolCollateral).deposit(1 * price, receiver, 2 * price);
        // 5 deposit ------------------------------------------------------------------
    }

    function test_depositWithdraw1() public {
        _depositWithdraw(user1);
    }

    function test_depositWithdraw2() private {
        _depositWithdraw(user2);
    }
}
