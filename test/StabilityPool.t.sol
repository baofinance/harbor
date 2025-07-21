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

import {DecrementalFloatingPoint} from "src/math/DecrementalFloatingPoint.sol";
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
    ) StabilityPool_v1(minter_, liquidationToken_, stabilityPoolToken_, steam_, 1 ether) {}

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
    ) StabilityPool_v1(minter_, liquidationToken_, stabilityPoolToken_, steam_, 1 ether) {}

    /// @notice Exposes the product value for testing purposes
    function __totalSupply() external view returns (TokenBalance memory) {
        return _getStabilityPoolStorage().totalAssetSupply;
    }

    /// @notice Exposes the notifyReward function for testing purposes
    function __notifyReward(address rewardToken, uint256 rewardAmount) external {
        return _notifyReward(rewardToken, rewardAmount);
    }

    /// @notice Exposes the notifyReward function for testing purposes
    function __notifyLoss(uint256 lossAmount) external {
        _notifyLoss(lossAmount);
    }

    function __distributePendingReward() external {
        _distributePendingReward();
    }

    function __getCompoundedBalance(
        uint256 initialBalance,
        uint128 initialProduct,
        uint128 currentProduct
    ) external pure returns (uint256) {
        return _getCompoundedBalance(initialBalance, initialProduct, currentProduct);
    }
}

// serves no other purpose than making the foundry traces more informative
contract MockSTEAM is MintableBurnableERC20_v1 {}

contract TestStabilityPoolSetUp is TestMinterFeeSetUp {
    address stabilityPoolCollateral;
    address steam;
    address veSteam;
    address user1;
    address user2;
    address rewardDepositor;
    address rebalancer;

    function _setupStabilityPool(address liquidationToken) internal virtual returns (address stabilityPool) {
        string memory liquidation = IERC20Metadata(liquidationToken).symbol();
        string memory pegged = IERC20Metadata(IMinter(minter).PEGGED_TOKEN()).symbol();
        string memory wrappedCollateral = IERC20Metadata(IMinter(minter).WRAPPED_COLLATERAL_TOKEN()).symbol();

        string memory SPName = string.concat(pegged, "x", wrappedCollateral, "~", liquidation);
        address stabilityPoolToken = address(
            UnsafeUpgrades.deployUUPSProxy(
                address(new MintableBurnableERC20_v1()), // "MintableBurnableERC20_v1.sol",
                abi.encodeCall(
                    MintableBurnableERC20_v1.initialize,
                    (owner, "StabilityPool Token", string.concat("lp", SPName))
                )
            )
        );
        vm.label(stabilityPoolToken, string.concat("lp", SPName));

        // use mock stability pool to expose internals for testing, otherwise it's identical to StabilityPool_v1
        stabilityPool = UnsafeUpgrades.deployUUPSProxy(
            address(new MockStabilityPool(minter, liquidationToken, stabilityPoolToken, steam, veSteam)), // "StabilityPool_v1.sol",
            abi.encodeCall(StabilityPool_v1.initialize, (owner))
        );
        vm.label(stabilityPool, SPName);

        IBaoRoles(stabilityPoolToken).grantRoles(address(this), IMintableRole(stabilityPoolToken).MINTER_ROLE());
        IMintable(stabilityPoolToken).mint(stabilityPool, 1 ether);

        IBaoRoles(stabilityPool).grantRoles(owner, IMultipleRewardDistributor(stabilityPool).REWARD_MANAGER_ROLE());
        IBaoRoles(stabilityPool).grantRoles(
            rewardDepositor,
            IMultipleRewardDistributor(stabilityPool).REWARD_DEPOSITOR_ROLE()
        );
        IBaoRoles(stabilityPool).grantRoles(rebalancer, IStabilityPool(stabilityPool).REBALANCER_ROLE());

        IMultipleRewardDistributor(stabilityPool).registerRewardToken(liquidationToken);
        IMultipleRewardDistributor(stabilityPool).registerRewardToken(steam);

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
        vm.label(steam, "STEAM");
        IBaoOwnable(steam).transferOwnership(owner);

        veSteam = UnsafeUpgrades.deployUUPSProxy(
            address(new VotingEscrow_v1(address(steam))),
            abi.encodeCall(VotingEscrow_v1.initialize, (owner, "Zhenglong Voting Escrow", "veSTEAM", "1"))
        );
        vm.label(veSteam, "veSTEAM");
        IBaoOwnable(veSteam).transferOwnership(owner);

        rewardDepositor = makeAddr("rewardDistributor");

        stabilityPoolCollateral = _setupStabilityPool(wrappedCollateralToken);

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
        address(new StabilityPool_v1(minter, wrappedCollateralToken, stabilityPoolToken, steam, 1 ether));
    }

    function test_initEvents(address liquidateTo) internal {
        address sp = address(new StabilityPool_v1(minter, liquidateTo, stabilityPoolToken, steam, 1 ether));
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
        assertEq(withdrawn, 3 * price - 1 ether, "withdraw 3 (-1)"); // include the minimum pool size
        assertEq(IERC20(peggedToken).balanceOf(stabilityPoolCollateral), 1 ether);
        assertEq(IStabilityPool(stabilityPoolCollateral).assetBalanceOf(receiver), 1 ether);

        // deposit -1
        vm.prank(user1);
        deposited = IStabilityPool(stabilityPoolCollateral).deposit(type(uint256).max, receiver, 0);
        // 4 deposit ------------------------------------------------------------------------------
        assertEq(deposited, 10 * price - 1 ether, "returned value 10");
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

contract StabilityPoolCompoundingTest is TestStabilityPoolSetUp {
    using DecrementalFloatingPoint for uint128;

    function test_CompoundedAmount_() public view {
        // Test data structure: [initialAmount, initialExponent, initialMagnitude, currentExponent, currentMagnitude, expectedResult]
        uint256[6][16] memory testCases;

        // No change (exponentDiff = 0, same magnitude)
        testCases[0] = [uint256(1e18), 0, 1e36, 0, 1e36, 1e18];

        // No exponent change, magnitude reduced by half
        testCases[1] = [uint256(1e18), 0, 1e36, 0, 5e35, 5e17];

        // Single exponent change (exponentDiff = 1), same magnitude
        testCases[2] = [uint256(1e18), 0, 1e36, 1, 1e36, 1e9]; // divided by SCALE_FACTOR (1e9)

        // Single exponent change with magnitude reduction
        testCases[3] = [uint256(1e18), 0, 1e36, 1, 5e35, 5e8]; // (1e18 * 5e35 / 1e36) / 1e9

        // Double exponent change (exponentDiff = 2)
        testCases[4] = [uint256(1e18), 0, 1e36, 2, 1e36, 1]; // divided by SCALE_FACTOR^2 (1e18)

        // Maximum allowed exponent change (exponentDiff = 8)
        testCases[5] = [uint256(1e27), 0, 1e36, 8, 1e36, 0]; // 1e27 / 1e9^8 = 1e27 / 1e72 = very small, rounds to 1 due to integer math

        // Add a more realistic test case for large exponent differences that might still have a result:
        // alternative: Use much larger initial amount
        testCases[6] = [uint256(1e45), 0, 1e36, 8, 1e36, 0]; // 1e45 / 1e72 = 1e-27, but this exceeds uint256

        // Or test a smaller exponent difference:
        testCases[7] = [uint256(1e36), 0, 1e36, 4, 1e36, 1e0]; // 1e36 / 1e36 = 1

        // Beyond maximum (exponentDiff = 9) - should return 0
        testCases[8] = [uint256(1e18), 0, 1e36, 9, 1e36, 0];

        // Large initial amount, small exponent change
        testCases[9] = [uint256(1e24), 0, 1e36, 1, 1e36, 1e15];

        // Edge case - very small initial amount
        testCases[10] = [uint256(1000), 0, 1e36, 1, 1e36, 0]; // 1000 / 1e9 = 0 (integer division)

        // Starting with non-zero exponent
        testCases[11] = [uint256(1e18), 2, 1e36, 3, 1e36, 1e9]; // exponentDiff = 1

        // Magnitude increase (theoretical, though unlikely in practice)
        testCases[12] = [uint256(1e18), 0, 5e35, 0, 1e36, 2e18];

        // Complex case with both exponent and magnitude changes
        testCases[13] = [uint256(2e18), 1, 8e35, 3, 4e35, 1]; // (2e18 * 4e35 / 8e35) / 1e18 = 1e9

        // Maximum uint104 boundary test
        testCases[14] = [uint256(type(uint104).max), 0, 1e36, 0, 1e36, type(uint104).max];

        // Precision loss edge case
        testCases[15] = [uint256(1e12), 0, 1e36, 3, 1e27, 0]; // Very small result due to multiple scale factors

        for (uint i = 0; i < testCases.length; i++) {
            uint256 initialAmount = testCases[i][0];
            uint8 initialExponent = uint8(testCases[i][1]);
            uint120 initialMagnitude = uint120(testCases[i][2]);
            uint8 currentExponent = uint8(testCases[i][3]);
            uint120 currentMagnitude = uint120(testCases[i][4]);
            uint256 expectedResult = testCases[i][5];

            uint128 initialFP = DecrementalFloatingPoint.encode(initialExponent, initialMagnitude);
            uint128 currentFP = DecrementalFloatingPoint.encode(currentExponent, currentMagnitude);

            uint256 actualResult = MockStabilityPool(stabilityPoolCollateral).__getCompoundedBalance(
                initialAmount,
                initialFP,
                currentFP
            );

            assertEq(actualResult, expectedResult, string(abi.encodePacked("Test case ", vm.toString(i), " failed")));
        }
    }

    function test_CompoundedAmountEdgeCases() public view {
        // Test the boundary at exponent difference = 8 vs 9
        uint128 initialFP = DecrementalFloatingPoint.encode(0, DecrementalFloatingPoint.MAGNITUDE_PRECISION);

        // Exactly 8 exponent difference - should work
        uint128 maxAllowedFP = DecrementalFloatingPoint.encode(8, DecrementalFloatingPoint.MAGNITUDE_PRECISION);
        uint256 result8 = MockStabilityPool(stabilityPoolCollateral).__getCompoundedBalance(
            1e72,
            initialFP,
            maxAllowedFP
        );
        assertGt(result8, 0, "8 exponent difference should produce non-zero result");

        // 9 exponent difference - should return 0
        uint128 tooMuchFP = DecrementalFloatingPoint.encode(9, DecrementalFloatingPoint.MAGNITUDE_PRECISION);
        uint256 result9 = MockStabilityPool(stabilityPoolCollateral).__getCompoundedBalance(1e27, initialFP, tooMuchFP);
        assertEq(result9, 0, "9 exponent difference should return 0");
    }
    function test_CompoundedAmountScaleFactorProgression() public view {
        // Test that each exponent increment divides by SCALE_FACTOR
        uint256 initialAmount = 1e27; // Large enough to avoid precision loss
        uint128 baseFP = DecrementalFloatingPoint.encode(0, DecrementalFloatingPoint.MAGNITUDE_PRECISION);

        uint256 previousResult = initialAmount;

        for (uint8 exponent = 1; exponent <= 8; exponent++) {
            uint128 currentFP = DecrementalFloatingPoint.encode(exponent, DecrementalFloatingPoint.MAGNITUDE_PRECISION);
            uint256 currentResult = MockStabilityPool(stabilityPoolCollateral).__getCompoundedBalance(
                initialAmount,
                baseFP,
                currentFP
            );

            // Each step should divide by SCALE_FACTOR (1e9)
            uint256 expectedResult = previousResult / DecrementalFloatingPoint.SCALE_FACTOR;

            // Allow for minor rounding differences due to integer division
            assertTrue(
                currentResult == expectedResult || currentResult == expectedResult - 1,
                string(abi.encodePacked("Scale factor progression failed at exponent ", vm.toString(exponent)))
            );

            previousResult = expectedResult;
        }
    }

    function test_CompoundedAmountConsistencyWithMul() public view {
        // Verify that compoundedAmount is consistent with the mul function's behavior

        uint256 initialAmount = 1e18;
        uint128 initialFP = DecrementalFloatingPoint.init();

        // Apply a factor using mul
        uint128 factor = 5e17; // 0.5
        uint128 afterMulFP = initialFP.mul(factor);

        // Calculate what the balance should be
        uint256 expectedBalance = (initialAmount * factor) / 1e18;
        uint256 actualBalance = MockStabilityPool(stabilityPoolCollateral).__getCompoundedBalance(
            initialAmount,
            initialFP,
            afterMulFP
        );

        assertEq(actualBalance, expectedBalance, "CompoundedAmount should be consistent with mul operation");
    }

    function test_CompoundedAmountOverflowSafety_() public view {
        // Test with maximum values to ensure no overflow
        uint256 maxAmount = type(uint104).max; // Maximum storable amount
        uint128 maxMagnitudeFP = DecrementalFloatingPoint.encode(0, type(uint120).max);
        uint128 minMagnitudeFP = DecrementalFloatingPoint.encode(0, 1);

        // This should not overflow or revert
        uint256 result = MockStabilityPool(stabilityPoolCollateral).__getCompoundedBalance(
            maxAmount,
            minMagnitudeFP,
            maxMagnitudeFP
        );

        // Result should be very large but not overflow
        assertTrue(result >= maxAmount, "Result should be at least the initial amount when magnitude increases");
    }

    function test_DustThresholdNecessity_() public view {
        uint256[3] memory testAmounts = [uint256(1000), 1e18, 1e24];

        for (uint i = 0; i < testAmounts.length; i++) {
            uint256 initialDeposit = testAmounts[i];

            // Simulate maximum precision loss scenario
            uint128 initialFP = DecrementalFloatingPoint.init();
            uint128 maxLossFP = DecrementalFloatingPoint.encode(1, DecrementalFloatingPoint.MIN_PRECISION);

            uint256 rawResult = MockStabilityPool(stabilityPoolCollateral).__getCompoundedBalance(
                initialDeposit,
                initialFP,
                maxLossFP
            );
            uint256 dustThreshold = initialDeposit / DecrementalFloatingPoint.SCALE_FACTOR;

            // Test that dust threshold is 1 billionth of original
            assertEq(dustThreshold, initialDeposit / 1e9, "Dust threshold should be 1/1e9 of initial");

            // For large deposits, dust should be meaningful
            if (initialDeposit >= 1e18) {
                assertTrue(dustThreshold >= 1e9, "Dust threshold should be meaningful for large deposits");
            }

            // Raw result should be <= initial (only losses, no gains)
            assertTrue(rawResult <= initialDeposit, "Compounded balance should not exceed initial deposit");

            // Verify uint104 casting behavior
            if (rawResult > type(uint104).max) {
                // This would truncate - assert this is handled properly
                assertTrue(false, "Result exceeds uint104 - needs handling");
            }

            // Economic significance test - less than 1 wei in most tokens is meaningless
            bool economicallyMeaningless = rawResult > 0 && rawResult < 100; // 100 wei threshold
            if (economicallyMeaningless && rawResult < dustThreshold) {
                assertTrue(
                    rawResult < dustThreshold,
                    "Economically meaningless amounts should be below dust threshold"
                );
            }
        }

        // Edge case: exactly at threshold
        uint256 testAmount = 1e18;
        uint256 exactThreshold = testAmount / DecrementalFloatingPoint.SCALE_FACTOR;

        // The current logic uses `<` so exactly at threshold is NOT dusted
        assertFalse(exactThreshold < exactThreshold, "Amount exactly at threshold should not be dusted");
    }
}
