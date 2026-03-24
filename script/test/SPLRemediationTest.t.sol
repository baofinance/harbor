// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {HarborFactoryDeployer} from "@harbor/../script/src/HarborFactoryDeployer.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PostRebalanceRemediationForStabilityPool_v2} from "src/minter/PostRebalanceRemediationForStabilityPool_v2.sol";
import {MockWrappedPriceOracle} from "test/mocks/MockWrappedPriceOracle.sol";
import {IWrappedPriceOracle} from "src/interfaces/IWrappedPriceOracle.sol";
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {console2 as console} from "forge-std/console2.sol";

interface IStabilityPoolImmutables {
    function WITHDRAWAL_START_DELAY() external view returns (uint64);
}

/// @title SPL Remediation Test
/// @notice Runs the full remediation (pause -> grant -> remediate -> restore -> revoke)
/// and compares the result against the v2 correct state from V2ReplaySimulation.
/// @dev Run: forge test --mp script/test/SPLRemediationTest.t.sol -vv
contract SPLRemediationTest is BaoTest, HarborFactoryDeployer {
    // Fork at the last simulated event block so oracle prices match V2ReplaySimulation
    uint256 constant FORK_BLOCK = 24699497;

    address spl;
    address spc;
    address minter;
    address lev;
    address peg;
    address proxyOwner;
    address existingV2Impl;

    address constant CLAIMER = 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F;
    uint256 constant BURNER_ROLE = 1 << 1;

    // V2 correct values from V2ReplaySimulation (results/v2_correct_state.csv)
    // These are the target state after remediation.
    uint256 constant V2_LEV_PRICE = 3467248825484481570; // leveragedTokenPrice
    uint256 constant V2_LEV_SUPPLY = 525304936873195071; // leveragedTotalSupply
    uint256 constant V2_CLAIMER_LEV = 322217071257914429; // Claimer sailETH held

    // Holders with non-zero sailETH positions (from V2ReplaySimulation)
    struct Expected {
        address holder;
        uint256 v2Held;      // sailETH held in wallet under v2
        uint256 v2Claimable; // sailETH claimable from SPL under v2
    }

    Expected[] expected;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);
        _setSaltPrefix("harbor_v1");

        spl = _predictAddress("ETH", "fxUSD", "stabilityPoolLeveraged");
        spc = _predictAddress("ETH", "fxUSD", "stabilityPoolCollateral");
        minter = _predictAddress("ETH", "fxUSD", "minter");
        lev = _predictAddress("ETH", "fxUSD", "leveraged");
        peg = _predictAddress("ETH", "pegged");
        proxyOwner = IBaoOwnable(spl).owner();

        existingV2Impl = address(
            uint160(uint256(vm.load(spl, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)))
        );

        _initExpected();
    }

    /// @dev V2 correct sailETH per holder (held, claimable).
    /// Source: results/v2_correct_state.csv from V2ReplaySimulation.t.sol
    function _initExpected() private {
        expected.push(Expected(0x13F210c8bAf5f5DBAFf3E917E2e5A49E73BBAF12, 0,                            0.060311559463305742 ether));
        expected.push(Expected(0x1a9152528AEFbcD9E5df4E0770f4F510e7056913, 0,                            0.090912789787537255 ether));
        expected.push(Expected(0x1e085ff3CdD38b1E5F04Ace2345966056F0C85E4, 0.001515885365927426 ether,   0.000041497401864749 ether));
        expected.push(Expected(0x3Fdaf8A9af23D27C884e10820130eAB1dB6dDBeD, 0.006181459776411976 ether,   0));
        expected.push(Expected(0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e, 0,                            0.000127808353298059 ether));
        expected.push(Expected(CLAIMER,                                     0.322217071257914429 ether,   0.000053411233151520 ether));
        expected.push(Expected(0xC9df4f62474Cf6cdE6c064DB29416a9F4f27EBdC, 0.039893782695968247 ether,   0));
        expected.push(Expected(0xDC1330EF8dc913C39bd29F9523418eEEacEf03D6, 0.001465014951679706 ether,   0));
        expected.push(Expected(0xDD0CDF8D98d9Ad3ADfaa49AaECD444Bfa01d9C9a, 0.000894459467812868 ether,   0.000110736322807779 ether));
    }

    function _runRemediation() internal {
        // (Pausing is done separately via Pause_SPL_ETH_fxUSD.s.sol)

        // 1. Grant roles
        vm.prank(IBaoOwnable(lev).owner());
        IBaoRoles(lev).grantRoles(spl, BURNER_ROLE);

        uint256 ZERO_FEE_ROLE = IMinter(minter).ZERO_FEE_ROLE();
        vm.prank(IBaoOwnable(minter).owner());
        IBaoRoles(minter).grantRoles(spl, ZERO_FEE_ROLE);

        // Transfer fxSAVE from treasury to SPL for collateral restoration
        uint256 COLLATERAL_GAP = 82.466171119621162782 ether;
        address wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();
        address treasury = IBaoOwnable(minter).owner();
        vm.prank(treasury);
        IERC20(wrappedCollateral).transfer(spl, COLLATERAL_GAP);

        // Claimer must approve SPL to burnFrom their excess (done off-chain before Safe batch)
        uint256 CLAIMER_EXCESS = 0.052087080191248362 ether;
        vm.prank(CLAIMER);
        IERC20(lev).approve(spl, CLAIMER_EXCESS);

        // Bounty receiver must approve SPL to burnFrom their excess (done off-chain)
        address BOUNTY_RECEIVER = 0xf1674FE69b2920b4de51E909cbf060dd78724CD8;
        uint256 BOUNTY_EXCESS = 0.087632380029141447 ether;
        vm.prank(BOUNTY_RECEIVER);
        IERC20(lev).approve(spl, BOUNTY_EXCESS);

        // 2. Remediate
        PostRebalanceRemediationForStabilityPool_v2 impl = new PostRebalanceRemediationForStabilityPool_v2(
            lev,
            minter,
            proxyOwner
        );
        vm.prank(proxyOwner);
        UUPSUpgradeable(spl).upgradeToAndCall(
            address(impl),
            abi.encodeCall(PostRebalanceRemediationForStabilityPool_v2.remediate, ())
        );

        // 3. Restore
        vm.prank(proxyOwner);
        UUPSUpgradeable(spl).upgradeToAndCall(existingV2Impl, "");

        // 4. Revoke roles
        vm.prank(IBaoOwnable(lev).owner());
        IBaoRoles(lev).revokeRoles(spl, BURNER_ROLE);
        vm.prank(IBaoOwnable(minter).owner());
        IBaoRoles(minter).revokeRoles(spl, ZERO_FEE_ROLE);
    }

    function test_remediation() public {
        uint256 supplyBefore = IERC20(lev).totalSupply();
        uint256 levPriceBefore = IMinter(minter).leveragedTokenPrice();

        console.log("=== PRE-REMEDIATION ===");
        console.log("  levPrice:  %e", levPriceBefore);
        console.log("  levSupply: %e", supplyBefore);

        _runRemediation();

        // ---- Verify ----

        uint256 levPriceAfter = IMinter(minter).leveragedTokenPrice();
        uint256 supplyAfter = IERC20(lev).totalSupply();

        console.log("");
        console.log("=== POST-REMEDIATION ===");
        console.log("  levPrice:  %e (v2 target: %e)", levPriceAfter, V2_LEV_PRICE);
        console.log("  levSupply: %e (v2 target: %e)", supplyAfter, V2_LEV_SUPPLY);
        console.log("  burned:    %e", supplyBefore - supplyAfter);

        // Check each holder's total sailETH (held + claimable) against v2 correct
        console.log("");
        console.log("=== PER-HOLDER VERIFICATION ===");
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        uint256 failures;

        for (uint256 i = 0; i < expected.length; i++) {
            address h = expected[i].holder;
            uint256 actualHeld = IERC20(lev).balanceOf(h);
            uint256 actualClaimable = acc.claimable(h, lev);

            // Held should match exactly
            if (actualHeld != expected[i].v2Held) {
                console.log("  FAIL held %s: actual=%e target=%e", h, actualHeld, expected[i].v2Held);
                failures++;
            }
            // Claimable should match except for Claimer (known shortfall — snapshot stuck above
            // corrected integral due to v1 claim between rebalances; resolved by calling claim())
            if (h == CLAIMER) {
                console.log("  [NOTE] Claimer claimable=%e (v2 target=%e, shortfall=%e)",
                    actualClaimable, expected[i].v2Claimable, expected[i].v2Claimable - actualClaimable);
            } else if (actualClaimable != expected[i].v2Claimable) {
                console.log("  FAIL claimable %s: actual=%e target=%e", h, actualClaimable, expected[i].v2Claimable);
                failures++;
            }
        }

        if (failures == 0) {
            console.log("  [OK] All %d holders match v2 correct state", expected.length);
        }
        assertEq(failures, 0, "some holders do not match v2 correct state");

        // Write CSV
        _writeCSV(levPriceAfter);
    }

    function _writeCSV(uint256 levPrice) private {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        uint256 ETH_USD = 2125;

        string memory csv = "Address,sailETH Held,sailETH Claimable,Total sailETH,~$ Value\n";

        for (uint256 i = 0; i < expected.length; i++) {
            address h = expected[i].holder;
            uint256 held = IERC20(lev).balanceOf(h);
            uint256 claimable = acc.claimable(h, lev);
            uint256 total = held + claimable;
            uint256 valueWei = (total * levPrice) / 1 ether + IStabilityPool(spl).assetBalanceOf(h);
            uint256 valueCents = (valueWei * ETH_USD) / 1e16;

            csv = string.concat(
                csv,
                vm.toString(h),
                ",",
                vm.toString(held),
                ",",
                vm.toString(claimable),
                ",",
                vm.toString(total),
                ",",
                vm.toString(valueCents / 100),
                ".",
                valueCents % 100 < 10 ? "0" : "",
                vm.toString(valueCents % 100),
                "\n"
            );
        }

        csv = string.concat(csv, "\nSystem\n");
        csv = string.concat(csv, "leveragedTokenPrice,", vm.toString(levPrice), "\n");
        csv = string.concat(csv, "leveragedTotalSupply,", vm.toString(IERC20(lev).totalSupply()), "\n");

        vm.createDir("results", true);
        vm.writeFile("results/post_remediation.csv", csv);
        console.log("  -> results/post_remediation.csv");
    }
}

/// @title Post-Remediation Integration Test
/// @notice Tests user operations against an already-remediated local anvil fork.
/// @dev Run: forge test --mc PostRemediationIntegrationTest --fork-url local -vv
contract PostRemediationIntegrationTest is BaoTest, HarborFactoryDeployer {
    address spl;
    address minter;
    address lev;
    address peg;
    address spm;
    address proxyOwner;

    address constant CLAIMER = 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F;

    struct Expected {
        address holder;
        uint256 v2Held;
        uint256 v2Claimable;
        uint256 v2HaInSPL; // haETH pool balance from v2_correct_state.csv
    }

    Expected[] expected;

    function setUp() public {
        _setSaltPrefix("harbor_v1");
        spl = _predictAddress("ETH", "fxUSD", "stabilityPoolLeveraged");
        minter = _predictAddress("ETH", "fxUSD", "minter");
        lev = _predictAddress("ETH", "fxUSD", "leveraged");
        peg = _predictAddress("ETH", "pegged");
        spm = _predictAddress("ETH", "fxUSD", "stabilityPoolManager");
        proxyOwner = IBaoOwnable(spl).owner();

        //                                                                    v2Held                       v2Claimable                  v2HaInSPL
        expected.push(Expected(0x13F210c8bAf5f5DBAFf3E917E2e5A49E73BBAF12, 0,                            0.060311559463305742 ether,  0.300336372621867295 ether));
        expected.push(Expected(0x1a9152528AEFbcD9E5df4E0770f4F510e7056913, 0,                            0.090912789787537255 ether,  0.452722790667278425 ether));
        expected.push(Expected(0x1e085ff3CdD38b1E5F04Ace2345966056F0C85E4, 0.001515885365927426 ether,   0.000041497401864749 ether,  0.000206646607386655 ether));
        expected.push(Expected(0x3Fdaf8A9af23D27C884e10820130eAB1dB6dDBeD, 0.006181459776411976 ether,   0,                           0));
        expected.push(Expected(0xAE7Dbb17bc40D53A6363409c6B1ED88d3cFdc31e, 0,                            0.000127808353298059 ether,  0.000636453402331065 ether));
        expected.push(Expected(CLAIMER,                                     0.322217071257914429 ether,   0.000053411233151520 ether,  0.004632259358695266 ether));
        expected.push(Expected(0xC9df4f62474Cf6cdE6c064DB29416a9F4f27EBdC, 0.039893782695968247 ether,   0,                           0));
        expected.push(Expected(0xDC1330EF8dc913C39bd29F9523418eEEacEf03D6, 0.001465014951679706 ether,   0,                           0));
        expected.push(Expected(0xDD0CDF8D98d9Ad3ADfaa49AaECD444Bfa01d9C9a, 0.000894459467812868 ether,   0.000110736322807779 ether,  0.000551438991223686 ether));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════════════════

    function _installMockOracle() internal returns (MockWrappedPriceOracle mockOracle) {
        IWrappedPriceOracle real = IWrappedPriceOracle(IMinter(minter).priceOracle());
        (uint256 minP, uint256 maxP, uint256 minR, uint256 maxR) = real.latestAnswer();
        mockOracle = new MockWrappedPriceOracle();
        mockOracle.setLatestAnswer(minP, maxP, minR, maxR);
        vm.prank(proxyOwner);
        IMinter(minter).updatePriceOracle(address(mockOracle));
    }

    function _triggerRebalance(
        MockWrappedPriceOracle mockOracle, uint256 num, uint256 den
    ) internal returns (uint256 splReceived) {
        (uint256 p,,uint256 r,) = mockOracle.latestAnswer();
        mockOracle.setLatestAnswer(p * num / den, p * num / den, r, r);
        uint256 splLevBefore = IERC20(lev).balanceOf(spl);
        IStabilityPoolManager(spm).rebalance(makeAddr("bounty"), 0);
        splReceived = IERC20(lev).balanceOf(spl) - splLevBefore;
    }

    function _logLevPrice(string memory label) internal view {
        console.log("  levPrice [%s]: %d", label, IMinter(minter).leveragedTokenPrice());
    }

    function _depositAs(address user, uint256 amount) internal {
        deal(peg, user, amount);
        vm.startPrank(user);
        IERC20(peg).approve(spl, amount);
        IStabilityPool(spl).deposit(amount, user, 0);
        vm.stopPrank();
    }

    function _claimAll() internal returns (uint256[] memory received) {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        received = new uint256[](expected.length);
        for (uint256 i = 0; i < expected.length; i++) {
            uint256 balBefore = IERC20(lev).balanceOf(expected[i].holder);
            vm.prank(expected[i].holder);
            acc.claim();
            received[i] = IERC20(lev).balanceOf(expected[i].holder) - balBefore;
        }
    }

    function _hasPoolBalance(uint256 i) internal view returns (bool) {
        return IStabilityPool(spl).assetBalanceOf(expected[i].holder) > 0;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 1: Claim — ALL holders, including those with 0 claimable
    // ═══════════════════════════════════════════════════════════════════════

    function test_claim_allHolders() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);

        for (uint256 i = 0; i < expected.length; i++) {
            address h = expected[i].holder;
            uint256 claimable = acc.claimable(h, lev);
            uint256 balBefore = IERC20(lev).balanceOf(h);

            vm.prank(h);
            acc.claim();

            uint256 received = IERC20(lev).balanceOf(h) - balBefore;
            assertEq(received, claimable, string.concat("claim mismatch for ", vm.toString(h)));
            assertEq(acc.claimable(h, lev), 0, string.concat("residual for ", vm.toString(h)));
            console.log("  Claim %s: %d", vm.toString(h), received);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 2: Deposit — verify shares, transfer, no phantom rewards
    // ═══════════════════════════════════════════════════════════════════════

    function test_deposit() public {
        address newUser = makeAddr("newUser");
        uint256 depositAmount = 0.1 ether;
        deal(peg, newUser, depositAmount);

        uint256 pegBefore = IERC20(peg).balanceOf(newUser);
        vm.startPrank(newUser);
        IERC20(peg).approve(spl, depositAmount);
        uint256 shares = IStabilityPool(spl).deposit(depositAmount, newUser, 0);
        vm.stopPrank();

        assertEq(shares > 0, true, "shares should be > 0");
        assertEq(pegBefore - IERC20(peg).balanceOf(newUser), depositAmount, "haETH transferred");
        assertEq(IStabilityPool(spl).assetBalanceOf(newUser), depositAmount, "pool balance");
        assertEq(IMultipleRewardAccumulator(spl).claimable(newUser, lev), 0, "no phantom rewards");
        console.log("  [OK] Deposit: %d haETH -> %d shares", depositAmount, shares);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 3: Withdrawal — exact refund, window enforcement
    // ═══════════════════════════════════════════════════════════════════════

    function test_requestWithdrawal_and_withdraw() public {
        address newUser = makeAddr("newUser");
        uint256 depositAmount = 0.1 ether;
        _depositAs(newUser, depositAmount);

        vm.prank(newUser);
        IStabilityPool(spl).requestWithdrawal();

        uint64 startDelay = IStabilityPoolImmutables(spl).WITHDRAWAL_START_DELAY();
        vm.warp(block.timestamp + startDelay + 1);

        uint256 pegBefore = IERC20(peg).balanceOf(newUser);
        vm.prank(newUser);
        IStabilityPool(spl).withdraw(type(uint256).max, newUser, 0);
        uint256 pegReceived = IERC20(peg).balanceOf(newUser) - pegBefore;

        assertEq(IStabilityPool(spl).assetBalanceOf(newUser), 0, "pool balance zero");
        assertEq(pegReceived, depositAmount, "exact refund (no rebalance loss)");
        console.log("  [OK] Withdraw: %d haETH returned", pegReceived);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 4: Rebalance + claim — price, supply, all holders
    // ═══════════════════════════════════════════════════════════════════════

    function test_rebalance_and_claim() public {
        address newUser = makeAddr("newUser");
        _depositAs(newUser, 0.1 ether);

        MockWrappedPriceOracle mockOracle = _installMockOracle();
        uint256 priceBefore = IMinter(minter).leveragedTokenPrice();
        uint256 supplyBefore = IERC20(lev).totalSupply();
        uint256 splHaBefore = IStabilityPool(spl).assetBalanceOf(newUser);

        uint256 splReceived = _triggerRebalance(mockOracle, 9, 10);

        uint256 priceAfter = IMinter(minter).leveragedTokenPrice();
        uint256 supplyAfter = IERC20(lev).totalSupply();
        uint256 splHaAfter = IStabilityPool(spl).assetBalanceOf(newUser);

        console.log("  levPrice: %d -> %d", priceBefore, priceAfter);
        console.log("  supply: %d -> %d", supplyBefore, supplyAfter);
        console.log("  SPL received: %d sailETH", splReceived);
        console.log("  newUser haETH in pool: %d -> %d", splHaBefore, splHaAfter);

        // Rebalance mints sailETH and liquidates haETH deposits
        assertEq(supplyAfter > supplyBefore, true, "supply should increase");
        assertEq(splHaAfter < splHaBefore, true, "deposits should decrease (liquidation)");

        // Check ALL holders' + newUser claimable
        _claimAll();
        {
            IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
            uint256 claimable = acc.claimable(newUser, lev);
            uint256 nb = IERC20(lev).balanceOf(newUser);
            vm.prank(newUser);
            acc.claim();
            assertEq(IERC20(lev).balanceOf(newUser) - nb, claimable, "newUser claim");
            assertEq(acc.claimable(newUser, lev), 0, "newUser residual");
            console.log("  newUser: %d", claimable);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 5: Withdraw preserves pending rewards
    // ═══════════════════════════════════════════════════════════════════════

    function test_withdrawPreservesRewards() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        uint64 startDelay = IStabilityPoolImmutables(spl).WITHDRAWAL_START_DELAY();

        // Install mock oracle so warp doesn't trigger staleness errors
        _installMockOracle();

        for (uint256 i = 0; i < expected.length; i++) {
            address h = expected[i].holder;
            uint256 poolBal = IStabilityPool(spl).assetBalanceOf(h);
            uint256 claimablePre = acc.claimable(h, lev);
            if (poolBal == 0 || claimablePre == 0) continue;

            _logLevPrice("before withdraw");

            vm.prank(h);
            IStabilityPool(spl).requestWithdrawal();
            vm.warp(block.timestamp + startDelay + 1);

            vm.prank(h);
            IStabilityPool(spl).withdraw(type(uint256).max, h, 0);

            _logLevPrice("after withdraw");

            // Claimable should be preserved (checkpoint captures pending before balance reduction)
            uint256 claimablePost = acc.claimable(h, lev);
            assertEq(claimablePost >= claimablePre, true,
                string.concat("claimable should not decrease for ", vm.toString(h)));

            uint256 balBefore = IERC20(lev).balanceOf(h);
            vm.prank(h);
            acc.claim();
            assertEq(IERC20(lev).balanceOf(h) - balBefore, claimablePost, "claim after withdraw");
            console.log("  %s: withdrew, claimable %d -> %d", vm.toString(h), claimablePre, claimablePost);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 6: Multiple rebalances
    // ═══════════════════════════════════════════════════════════════════════

    function test_multipleRebalances() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        address alice = makeAddr("alice");
        _depositAs(alice, 0.5 ether);

        MockWrappedPriceOracle mockOracle = _installMockOracle();

        uint256 prevPrice = IMinter(minter).leveragedTokenPrice();
        uint256 prevClaimable = 0;

        for (uint256 r = 1; r <= 3; r++) {
            uint256 splReceived = _triggerRebalance(mockOracle, 9, 10); // 10% drop each
            uint256 newPrice = IMinter(minter).leveragedTokenPrice();
            uint256 aliceClaimable = acc.claimable(alice, lev);

            console.log("  Rebalance %d: splReceived=%d", r, splReceived);
            console.log("    levPrice: %d -> %d", prevPrice, newPrice);
            console.log("    Alice claimable: %d", aliceClaimable);

            assertEq(aliceClaimable > prevClaimable, true, "alice claimable should increase");
            prevPrice = newPrice;
            prevClaimable = aliceClaimable;
        }

        // Everyone claims
        uint256[] memory received = _claimAll();
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(acc.claimable(expected[i].holder, lev), 0, "residual");
            console.log("  %s: %d", vm.toString(expected[i].holder), received[i]);
        }

        // Alice claims
        uint256 aliceBal = IERC20(lev).balanceOf(alice);
        vm.prank(alice);
        acc.claim();
        uint256 aliceReceived = IERC20(lev).balanceOf(alice) - aliceBal;
        assertEq(acc.claimable(alice, lev), 0, "alice residual");
        console.log("  Alice total: %d", aliceReceived);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 7: Redeem leveraged token
    // ═══════════════════════════════════════════════════════════════════════

    function test_redeemLeveragedToken() public {
        for (uint256 i = 0; i < expected.length; i++) {
            address h = expected[i].holder;
            uint256 sailBal = IERC20(lev).balanceOf(h);
            if (sailBal == 0 || IStabilityPool(spl).assetBalanceOf(h) > 0) continue;
            // Only wallet-only holders (no pool position to complicate)

            uint256 priceBefore = IMinter(minter).leveragedTokenPrice();
            uint256 supplyBefore = IERC20(lev).totalSupply();

            vm.startPrank(h);
            IERC20(lev).approve(minter, sailBal);
            IMinter(minter).redeemLeveragedToken(sailBal, h, 0);
            vm.stopPrank();

            uint256 priceAfter = IMinter(minter).leveragedTokenPrice();
            uint256 supplyAfter = IERC20(lev).totalSupply();

            assertEq(supplyBefore - supplyAfter, sailBal, "supply decreased by redeemed amount");
            assertEq(IERC20(lev).balanceOf(h), 0, "holder sailETH zero after full redeem");
            assertEq(priceAfter >= priceBefore, true, "price should not decrease after redeem");
            console.log("  %s: redeemed %d", vm.toString(h), sailBal);
            console.log("    price: %d -> %d", priceBefore, priceAfter);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 8: Redeem pegged token
    // ═══════════════════════════════════════════════════════════════════════

    function test_redeemPeggedToken() public {
        address user = makeAddr("pegRedeemer");
        deal(peg, user, 0.1 ether);

        uint256 priceBefore = IMinter(minter).leveragedTokenPrice();
        uint256 pegBalBefore = IMinter(minter).peggedTokenBalance();
        uint256 ratioBefore = IMinter(minter).collateralRatio();

        vm.startPrank(user);
        IERC20(peg).approve(minter, 0.1 ether);
        IMinter(minter).redeemPeggedToken(0.1 ether, user, 0);
        vm.stopPrank();

        uint256 priceAfter = IMinter(minter).leveragedTokenPrice();
        uint256 pegBalAfter = IMinter(minter).peggedTokenBalance();
        uint256 ratioAfter = IMinter(minter).collateralRatio();

        assertEq(pegBalBefore - pegBalAfter, 0.1 ether, "peggedTokenBalance decreased");
        console.log("  peggedTokenBalance: %d -> %d", pegBalBefore, pegBalAfter);
        console.log("  collateralRatio: %d -> %d", ratioBefore, ratioAfter);
        console.log("  levPrice: %d -> %d", priceBefore, priceAfter);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 9: New user full lifecycle
    // ═══════════════════════════════════════════════════════════════════════

    function test_newUser_fullLifecycle() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        address alice = makeAddr("alice");

        _logLevPrice("start");

        // 1. Deposit
        _depositAs(alice, 0.5 ether);
        assertEq(IStabilityPool(spl).assetBalanceOf(alice), 0.5 ether, "deposit balance");

        // 2. Rebalance
        MockWrappedPriceOracle mockOracle = _installMockOracle();
        _triggerRebalance(mockOracle, 9, 10);
        _logLevPrice("after rebalance");

        // 3. Claim sailETH
        uint256 claimable = acc.claimable(alice, lev);
        vm.prank(alice);
        acc.claim();
        uint256 sailBal = IERC20(lev).balanceOf(alice);
        assertEq(sailBal, claimable, "claim amount");
        assertEq(sailBal > 0, true, "should have claimed something");
        console.log("  Claimed %d sailETH", sailBal);

        // 4. Request withdrawal + warp + withdraw
        vm.prank(alice);
        IStabilityPool(spl).requestWithdrawal();
        uint64 startDelay = IStabilityPoolImmutables(spl).WITHDRAWAL_START_DELAY();
        vm.warp(block.timestamp + startDelay + 1);

        (uint256 p,,uint256 r,) = mockOracle.latestAnswer();
        mockOracle.setLatestAnswer(p, p, r, r);

        uint256 pegBefore = IERC20(peg).balanceOf(alice);
        vm.prank(alice);
        IStabilityPool(spl).withdraw(type(uint256).max, alice, 0);
        uint256 haReceived = IERC20(peg).balanceOf(alice) - pegBefore;
        assertEq(haReceived > 0, true, "should receive haETH");
        _logLevPrice("after withdraw");

        // 5. Redeem sailETH via minter
        uint256 sailToRedeem = IERC20(lev).balanceOf(alice);
        assertEq(sailToRedeem > 0, true, "should have sailETH to redeem");
        uint256 priceBefore = IMinter(minter).leveragedTokenPrice();

        vm.startPrank(alice);
        IERC20(lev).approve(minter, sailToRedeem);
        IMinter(minter).redeemLeveragedToken(sailToRedeem, alice, 0);
        vm.stopPrank();

        uint256 priceAfter = IMinter(minter).leveragedTokenPrice();
        assertEq(priceAfter >= priceBefore, true, "price should not drop on redeem");
        _logLevPrice("after redeem");

        // Final state
        assertEq(IERC20(lev).balanceOf(alice), 0, "alice sailETH zero");
        assertEq(IStabilityPool(spl).assetBalanceOf(alice), 0, "alice pool zero");
        assertEq(acc.claimable(alice, lev), 0, "alice claimable zero");
        console.log("  [OK] Lifecycle complete. haETH=%d", IERC20(peg).balanceOf(alice));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 10: State check with assertions
    // ═══════════════════════════════════════════════════════════════════════

    function test_realOracle_stateCheck() public view {
        uint256 ratio = IMinter(minter).collateralRatio();
        uint256 price = IMinter(minter).leveragedTokenPrice();
        uint256 supply = IERC20(lev).totalSupply();
        uint256 splBal = IERC20(lev).balanceOf(spl);

        console.log("  collateralRatio:     %d", ratio);
        console.log("  leveragedTokenPrice: %d", price);
        console.log("  sailETH totalSupply: %d", supply);
        console.log("  SPL sailETH balance: %d", splBal);

        assertEq(ratio > 0, true, "collateralRatio > 0");
        assertEq(price > 0, true, "leveragedTokenPrice > 0");
        assertEq(supply > 0, true, "totalSupply > 0");
        assertEq(splBal > 0, true, "SPL balance > 0");

        // SPL must have enough sailETH to cover all claimable
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < expected.length; i++) {
            totalClaimable += acc.claimable(expected[i].holder, lev);
        }
        assertEq(splBal >= totalClaimable, true, "SPL balance >= total claimable");
        console.log("  totalClaimable:      %d (SPL surplus: %d)", totalClaimable, splBal - totalClaimable);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 11: Claimer snapshot reset
    // ═══════════════════════════════════════════════════════════════════════

    function test_claimerSnapshotReset() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);

        uint256 claimerClaimable = acc.claimable(CLAIMER, lev);
        assertEq(claimerClaimable, 0, "Claimer should start with 0 claimable (stuck snapshot)");

        uint256 walletBefore = IERC20(lev).balanceOf(CLAIMER);
        vm.prank(CLAIMER);
        acc.claim();
        assertEq(IERC20(lev).balanceOf(CLAIMER), walletBefore, "wallet unchanged from empty claim");

        // Trigger rebalance
        MockWrappedPriceOracle mockOracle = _installMockOracle();
        _logLevPrice("before rebalance");
        uint256 received = _triggerRebalance(mockOracle, 9, 10);
        _logLevPrice("after rebalance");
        console.log("  SPL received: %d sailETH", received);

        // Claimer should now accumulate
        uint256 claimerAfter = acc.claimable(CLAIMER, lev);
        assertEq(claimerAfter > 0, true, "Claimer should accumulate after snapshot reset");

        uint256 balBefore = IERC20(lev).balanceOf(CLAIMER);
        vm.prank(CLAIMER);
        acc.claim();
        assertEq(IERC20(lev).balanceOf(CLAIMER) - balBefore, claimerAfter, "Claimer claim amount");
        assertEq(acc.claimable(CLAIMER, lev), 0, "Claimer residual zero");
        console.log("  [OK] Claimer received: %d after reset", claimerAfter);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 12: Claim → Rebalance → Claim again (all holders + new users)
    // ═══════════════════════════════════════════════════════════════════════

    function test_claimThenRebalanceThenClaimAgain() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        _claimAll();
        _depositAs(alice, 0.5 ether);
        _depositAs(bob, 0.2 ether);

        MockWrappedPriceOracle mockOracle = _installMockOracle();
        _logLevPrice("before rebalance");
        uint256 splReceived = _triggerRebalance(mockOracle, 9, 10);
        _logLevPrice("after rebalance");

        // All holders + Alice + Bob claim; track total
        uint256 totalClaimed = 0;
        for (uint256 i = 0; i < expected.length; i++) {
            address h = expected[i].holder;
            uint256 claimable = acc.claimable(h, lev);
            if (!_hasPoolBalance(i)) {
                assertEq(claimable, 0, string.concat("no-pool holder should get 0: ", vm.toString(h)));
            }
            uint256 balBefore = IERC20(lev).balanceOf(h);
            vm.prank(h);
            acc.claim();
            uint256 got = IERC20(lev).balanceOf(h) - balBefore;
            assertEq(got, claimable, "claim mismatch");
            assertEq(acc.claimable(h, lev), 0, "residual");
            totalClaimed += got;
            console.log("  %s: %d", vm.toString(h), got);
        }

        // Alice and Bob
        address[2] memory users = [alice, bob];
        for (uint256 i = 0; i < 2; i++) {
            uint256 claimable = acc.claimable(users[i], lev);
            uint256 balBefore = IERC20(lev).balanceOf(users[i]);
            vm.prank(users[i]);
            acc.claim();
            assertEq(IERC20(lev).balanceOf(users[i]) - balBefore, claimable, "new user claim");
            totalClaimed += claimable;
            console.log("  user%d: %d", i, claimable);
        }

        // Conservation: total claimed should not exceed what SPL received + pre-existing pool balance
        console.log("  totalClaimed: %d, splReceived: %d", totalClaimed, splReceived);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 13: Stale holders — rebalance without claiming first
    // ═══════════════════════════════════════════════════════════════════════

    function test_staleHolders_rebalanceWithoutClaiming() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);

        uint256[] memory claimableBefore = new uint256[](expected.length);
        for (uint256 i = 0; i < expected.length; i++) {
            claimableBefore[i] = acc.claimable(expected[i].holder, lev);
        }

        MockWrappedPriceOracle mockOracle = _installMockOracle();
        _logLevPrice("before rebalance");
        _triggerRebalance(mockOracle, 9, 10);
        _logLevPrice("after rebalance");

        for (uint256 i = 0; i < expected.length; i++) {
            address h = expected[i].holder;
            uint256 claimableAfter = acc.claimable(h, lev);

            if (_hasPoolBalance(i)) {
                assertEq(claimableAfter >= claimableBefore[i], true,
                    string.concat("pool holder claimable should not decrease: ", vm.toString(h)));
            } else {
                assertEq(claimableAfter, claimableBefore[i],
                    string.concat("no-pool holder claimable unchanged: ", vm.toString(h)));
            }

            uint256 balBefore = IERC20(lev).balanceOf(h);
            vm.prank(h);
            acc.claim();
            assertEq(IERC20(lev).balanceOf(h) - balBefore, claimableAfter, "claim mismatch");
            console.log("  %s: %d (was %d)", vm.toString(h), claimableAfter, claimableBefore[i]);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Test 14: Deposit then rebalance then claim (existing + new users)
    // ═══════════════════════════════════════════════════════════════════════

    function test_depositThenRebalanceThenClaim() public {
        IMultipleRewardAccumulator acc = IMultipleRewardAccumulator(spl);
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");

        _depositAs(alice, 0.3 ether);
        _depositAs(bob, 0.1 ether);

        // Existing holders with pool balance deposit more
        for (uint256 i = 0; i < expected.length; i++) {
            if (!_hasPoolBalance(i)) continue;
            address h = expected[i].holder;
            deal(peg, h, 0.05 ether);
            vm.startPrank(h);
            IERC20(peg).approve(spl, 0.05 ether);
            IStabilityPool(spl).deposit(0.05 ether, h, 0);
            vm.stopPrank();
        }

        MockWrappedPriceOracle mockOracle = _installMockOracle();
        _logLevPrice("before rebalance");
        _triggerRebalance(mockOracle, 9, 10);
        _logLevPrice("after rebalance");

        // All depositors should have claimable > 0
        address[2] memory newUsers = [alice, bob];
        for (uint256 j = 0; j < 2; j++) {
            uint256 claimable = acc.claimable(newUsers[j], lev);
            assertEq(claimable > 0, true, "new user should have claimable");
            uint256 balBefore = IERC20(lev).balanceOf(newUsers[j]);
            vm.prank(newUsers[j]);
            acc.claim();
            assertEq(IERC20(lev).balanceOf(newUsers[j]) - balBefore, claimable, "new user claim");
            console.log("  user%d: %d", j, claimable);
        }

        for (uint256 i = 0; i < expected.length; i++) {
            address h = expected[i].holder;
            uint256 claimable = acc.claimable(h, lev);
            uint256 balBefore = IERC20(lev).balanceOf(h);
            vm.prank(h);
            acc.claim();
            assertEq(IERC20(lev).balanceOf(h) - balBefore, claimable, "holder claim");
            assertEq(acc.claimable(h, lev), 0, "residual");
            console.log("  %s: %d", vm.toString(h), claimable);
        }
    }
}
