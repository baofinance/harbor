// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "forge-std/Test.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardDistributor} from "src/interfaces/IMultipleRewardDistributor.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StabilityPool_v2} from "src/minter/StabilityPool_v2.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";

/// @title Mainnet Upgrade Test
/// @notice Comprehensive test that:
/// 1. Replicates all three user-visible issues on mainnet (deposit, depositReward, withdrawal)
/// 2. Deploys fixed implementation
/// 3. Upgrades the proxy
/// 4. Verifies all issues are resolved
contract MainnetUpgradeTest is Test {
    uint constant PASS = 0;
    uint constant FAIL = 1;

    address constant STABILITY_POOL = 0x9e56F1E1E80EBf165A1dAa99F9787B41cD5bFE40;
    address constant MINTER = 0x33e32ff4d0677862fa31582CC654a25b9b1e4888; // Real mainnet minter
    address constant REWARD_COLLATERAL = 0x7743e50F534a7f9F1791DdE7dCD89F7783Eefc39; // fxSAVE
    address constant REWARD_SAIL = 0x9567c243F647f9Ac37efb7Fc26BD9551Dce0BE1B; // hsBTC-fxUSD
    address constant ANCHORED = 0x25bA4A826E1A1346dcA2Ab530831dbFF9C08bEA7; // haBTC
    uint256 constant FORK_BLOCK = 24404265;
    uint256 constant LATER_BLOCK = 24433566;

    string mainnet = vm.rpcUrl("mainnet");

    // Known addresses that might have the pegged token for testing
    address userWithTokens;
    address rewardDepositor;
    address userWithBalance; // Existing user with balance for withdrawal test

    function parseError(bytes memory lowLevelData) internal pure {
        // Check if it's an arithmetic underflow (panic code 0x11)
        if (lowLevelData.length >= 36) {
            bytes4 selector = bytes4(lowLevelData);
            if (selector == 0x4e487b71) {
                // Panic selector
                uint256 panicCode;
                assembly {
                    panicCode := mload(add(lowLevelData, 36))
                }
                if (panicCode == 0x11) {
                    console.log("*** User deposit fails with Panic 0x11 (Arithmetic Underflow) ***");
                } else {
                    console.log("Unexpected panic code:", panicCode);
                }
            } else {
                console.log("Unexpected error type");
            }
        }
    }

    function _doFailingTransactions(uint expect) internal {
        // Try to deposit - this should fail with arithmetic underflow
        // Deal some tokens to our test user
        console.log("Attempting user deposit...");
        deal(ANCHORED, userWithTokens, 1000 ether);

        vm.startPrank(userWithTokens);
        IERC20(ANCHORED).approve(STABILITY_POOL, type(uint256).max);

        try IStabilityPool(STABILITY_POOL).deposit(100 ether, userWithTokens, 0) {
            console.log("ERROR: deposit succeeded when it should have failed!");
            assertEq(expect, PASS, "Deposit should have failed");
        } catch (bytes memory lowLevelData) {
            parseError(lowLevelData);
            assertEq(expect, FAIL, "expected deposit to succeed");
        }
        vm.stopPrank();

        vm.startPrank(rewardDepositor);

        address[] memory activeTokens = IMultipleRewardDistributor(STABILITY_POOL).activeRewardTokens();
        for (uint256 i = 0; i < activeTokens.length; i++) {
            address tokenToDeposit = activeTokens[i];

            console.log("Attempting depositReward for token:", tokenToDeposit);

            // Deal some reward tokens to our depositor
            deal(tokenToDeposit, rewardDepositor, 1000 ether);

            IERC20(tokenToDeposit).approve(STABILITY_POOL, type(uint256).max);

            // Try to deposit rewards - this should fail with arithmetic underflow
            try IMultipleRewardDistributor(STABILITY_POOL).depositReward(tokenToDeposit, 100 ether) {
                assertEq(expect, PASS, "depositReward should have failed");
            } catch (bytes memory lowLevelData) {
                parseError(lowLevelData);
                assertEq(expect, FAIL, "expected depositReward to succeed");
            }
        }
        vm.stopPrank();

        // Try to withdraw - this should also fail with arithmetic underflow before upgrade
        // Testing with real mainnet user who had failed withdrawal tx:
        // 0xacbb222f01fa442075187334a42eaefc6ebd03411b18635bbbf8e93cde54c205
        if (userWithBalance != address(0)) {
            console.log("Attempting user withdrawal...");
            console.log("User address:", userWithBalance);
            uint256 balance = IStabilityPool(STABILITY_POOL).assetBalanceOf(userWithBalance);
            console.log("User balance:", balance);

            if (balance > 0) {
                uint256 withdrawAmount = balance / 2; // Withdraw half
                vm.startPrank(userWithBalance);

                try IStabilityPool(STABILITY_POOL).withdraw(withdrawAmount, userWithBalance, 0) {
                    console.log("Withdrawal succeeded");
                    assertEq(expect, PASS, "Withdrawal should have failed");
                } catch (bytes memory lowLevelData) {
                    parseError(lowLevelData);
                    assertEq(expect, FAIL, "expected withdrawal to succeed");
                }
                vm.stopPrank();
            } else {
                console.log("User has no balance to withdraw");
            }
        }
    }

    function setUp() public {
        // Fork mainnet at the problematic block
        vm.createSelectFork(mainnet, FORK_BLOCK);

        // Find the reward depositor by checking who has the REWARD_DEPOSITOR_ROLE
        // For now, we'll use a test address and deal tokens to it
        userWithTokens = makeAddr("user");
        rewardDepositor = makeAddr("rewardDepositor");

        // Find a user with existing balance for withdrawal test
        // We need to find an actual depositor from mainnet state
        userWithBalance = _findUserWithBalance();
    }

    /// @notice Helper to find a user with existing balance in the stability pool
    /// @dev Returns a known depositor who had a failed withdrawal transaction
    /// @dev Transaction: 0xacbb222f01fa442075187334a42eaefc6ebd03411b18635bbbf8e93cde54c205
    function _findUserWithBalance() internal pure returns (address) {
        // Known depositor with failed withdrawal
        return 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F;
    }

    /// @notice Test 1: Demonstrate that deposit, depositReward, and withdrawal all fail on mainnet
    function test_1_AllOperationsFail_OnMainnet() public {
        console.log("=== TEST 1: All Operations Fail on Mainnet ===");
        console.log("Block:", FORK_BLOCK);
        console.log("StabilityPool:", STABILITY_POOL);
        console.log("");

        // Show the problematic token state
        address[] memory activeTokens = IMultipleRewardDistributor(STABILITY_POOL).activeRewardTokens();
        console.log("Active reward tokens:", activeTokens.length);

        for (uint256 i = 0; i < activeTokens.length; i++) {
            address token = activeTokens[i];
            console.log("activeToken[%s]", i, token);

            (uint256 lastUpdate, uint256 finishAt, uint256 rate, ) = IMultipleRewardDistributor(STABILITY_POOL)
                .rewardData(token);
            if (finishAt == 0 && lastUpdate > 0) {
                console.log("");
                console.log("Found problematic token at index:", i);
                console.log("Token address:", token);
                console.log("  lastUpdate:", lastUpdate);
                console.log("  finishAt:", finishAt);
                console.log("  rate:", rate);
                console.log("*** This token will cause underflow! ***");
            }
        }

        _doFailingTransactions(FAIL);
    }

    /// @notice Test 2: Verify issues persist at latest block
    function test_2_IssuesPersist_AtLatestBlock() public {
        console.log("=== TEST 2: Issues Persist at Latest Block ===");
        console.log("");

        // Fork to the latest block
        vm.createSelectFork(mainnet, LATER_BLOCK);
        console.log("Forked to latest block:", block.number);
        _doFailingTransactions(FAIL);
    }

    /// @notice Test 5: Verify all operations work after upgrade
    function test_3_AllOperationsWork_AfterUpgrade() public {
        console.log("=== TEST 3: All Operations Work After Upgrade ===");
        console.log("");

        // First do the upgrade (reusing logic from test 4)
        vm.createSelectFork(mainnet, FORK_BLOCK);

        StabilityPool_v2 currentProxy = StabilityPool_v2(STABILITY_POOL);

        // Read immutable variables from the current contract (these are in the implementation bytecode)
        address liquidationToken = currentProxy.LIQUIDATION_TOKEN();
        (uint64 startDelay, uint64 endWindow) = currentProxy.getWithdrawalWindow();
        uint256 minTotalAssetSupply = currentProxy.MIN_TOTAL_ASSET_SUPPLY();
        console2.log("minTotalAssetSupply = %s", minTotalAssetSupply);

        // Deploy new implementation with the same parameters
        StabilityPool_v2 newImplementation = new StabilityPool_v2(
            MINTER,
            liquidationToken,
            startDelay,
            endWindow,
            minTotalAssetSupply
        );

        address proxyOwner = IBaoOwnable(STABILITY_POOL).owner();
        vm.startPrank(proxyOwner);
        StabilityPool_v2(STABILITY_POOL).upgradeToAndCall(address(newImplementation), "");

        // Grant REWARD_DEPOSITOR_ROLE to our test depositor so depositReward can succeed
        uint256 depositorRole = IMultipleRewardDistributor(STABILITY_POOL).REWARD_DEPOSITOR_ROLE();
        IBaoRoles(STABILITY_POOL).grantRoles(rewardDepositor, depositorRole);
        vm.stopPrank();

        console.log("Upgrade completed. Testing user deposit...");
        console.log("");

        _doFailingTransactions(PASS);
    }
}
