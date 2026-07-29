// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;
import {SaltString} from "@bao-script/deployment/SaltString.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";
import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";
import {StabilityPoolManager_v1} from "@harbor/minter/StabilityPoolManager_v1.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "@harbor/interfaces/IStabilityPoolManager.sol";
import {IMultipleRewardAccumulator} from "@harbor/interfaces/IMultipleRewardAccumulator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {Minter_v2} from "@harbor/minter/Minter_v2.sol";

abstract contract RebalanceCheckBase is BaoTest, HarborDeployer {
    uint256 constant FORK_BLOCK = 24687073;
    address constant USER = 0xb9ab9578a34a05c86124c399735fdE44dEc80E7F;

    // Predicted addresses for harbor_v1::ETH::fxUSD market
    address stabilityPoolManager;
    address stabilityPoolCollateral;
    address stabilityPoolLeveraged;
    address minter;
    address pegged;
    address leveraged;

    string mainnet = vm.rpcUrl("mainnet");

    function _forkAndPredict() internal {
        vm.createSelectFork(mainnet, FORK_BLOCK);

        _setSaltPrefix("harbor_v1");
        string memory marketKey = SaltString.key("ETH", "fxUSD");
        stabilityPoolManager = stabilityPoolManagerAddress(marketKey);
        stabilityPoolCollateral = stabilityPoolAddress(marketKey, StabilityPoolType.Collateral);
        stabilityPoolLeveraged = stabilityPoolAddress(marketKey, StabilityPoolType.Leveraged);
        minter = minterAddress(marketKey);
        pegged = peggedTokenAddress("ETH");
        leveraged = leveragedTokenAddress(marketKey);
    }

    function _upgradeSpm() internal {
        address proxyOwner = IBaoOwnable(stabilityPoolManager).owner();
        StabilityPoolManager_v1 manager = StabilityPoolManager_v1(stabilityPoolManager);
        StabilityPoolManager_v1 newSpmImpl = new StabilityPoolManager_v1(
            minter,
            manager.TREASURY(),
            stabilityPoolCollateral,
            stabilityPoolLeveraged
        );
        vm.prank(proxyOwner);
        manager.upgradeToAndCall(address(newSpmImpl), "");
    }

    function _upgradeMinterV2() internal {
        address proxyOwner = IBaoOwnable(minter).owner();
        IMinter m = IMinter(minter);
        address newMinterImpl = address(
            new Minter_v2(m.WRAPPED_COLLATERAL_TOKEN(), m.PEGGED_TOKEN(), m.LEVERAGED_TOKEN(), "burn(uint256)")
        );
        vm.prank(proxyOwner);
        UUPSUpgradeable(minter).upgradeToAndCall(newMinterImpl, "");
    }

    // ---- assertions ----

    function _assert_leveragedTokenPrice_doesNotDecrease() internal {
        uint256 priceBefore = IMinter(minter).leveragedTokenPrice();
        StabilityPoolManager_v1(stabilityPoolManager).rebalance(makeAddr("bounty"), 0);
        uint256 priceAfter = IMinter(minter).leveragedTokenPrice();
        assertGe(priceAfter, priceBefore, "leveragedTokenPrice must not decrease during rebalance");
    }

    function _assert_collateralRatio_hitsThreshold() internal {
        uint256 threshold = IStabilityPoolManager(stabilityPoolManager).rebalanceThreshold();
        uint256 crBefore = IMinter(minter).collateralRatio();
        assertTrue(crBefore < threshold, "precondition: CR must be below threshold to rebalance");

        StabilityPoolManager_v1(stabilityPoolManager).rebalance(makeAddr("bounty"), 0);

        uint256 crAfter = IMinter(minter).collateralRatio();
        assertApprox(crAfter, threshold, 0, 0.0001 ether, "CR should hit rebalance threshold");
    }

    function _assert_userClaimable_proportionalToDeposit() internal {
        StabilityPoolManager_v1(stabilityPoolManager).rebalance(makeAddr("bounty"), 0);

        address[2] memory pools = [stabilityPoolCollateral, stabilityPoolLeveraged];
        for (uint256 i = 0; i < pools.length; i++) {
            IStabilityPool sp = IStabilityPool(pools[i]);
            address liqToken = sp.LIQUIDATION_TOKEN();
            uint256 poolAsset = IERC20(sp.ASSET_TOKEN()).balanceOf(pools[i]);
            if (poolAsset == 0) continue;

            uint256 userAsset = sp.assetBalanceOf(USER);
            uint256 userShareBps = (userAsset * 1e18) / poolAsset;

            uint256 poolLiq = IERC20(liqToken).balanceOf(pools[i]);
            if (poolLiq == 0) continue;

            uint256 userClaimable = IMultipleRewardAccumulator(pools[i]).claimable(USER, liqToken);
            uint256 userLiqShareBps = (userClaimable * 1e18) / poolLiq;

            assertApprox(userLiqShareBps, userShareBps, 0.01 ether, "user liq share should match asset share");
        }
    }

    function _assert_leveragedMint_doesNotExceedPeggedBurned() internal {
        uint256 priceBefore = IMinter(minter).leveragedTokenPrice();
        uint256 supplyBefore = IERC20(leveraged).totalSupply();
        uint256 peggedBefore = IMinter(minter).peggedTokenBalance();

        StabilityPoolManager_v1(stabilityPoolManager).rebalance(makeAddr("bounty"), 0);

        uint256 supplyAfter = IERC20(leveraged).totalSupply();
        uint256 peggedAfter = IMinter(minter).peggedTokenBalance();

        uint256 leveragedMinted = supplyAfter - supplyBefore;
        uint256 peggedBurned = peggedBefore - peggedAfter;

        uint256 mintedValue = (leveragedMinted * priceBefore) / 1 ether;
        assertLe(mintedValue, peggedBurned, "minted leveraged value must not exceed pegged burned");
    }

    /// @notice Verify that known leveraged token holders' total position value
    /// (balance * price) does not decrease during rebalance.
    /// Uses fixed addresses for CI stability.
    function _assert_holderValues_preserved() internal {
        // Known holders at FORK_BLOCK — SPL holds deposited tokens, USER holds directly
        address[2] memory holders = [stabilityPoolLeveraged, USER];

        uint256 priceBefore = IMinter(minter).leveragedTokenPrice();
        uint256[2] memory valuesBefore;
        for (uint256 i = 0; i < holders.length; i++) {
            valuesBefore[i] = (IERC20(leveraged).balanceOf(holders[i]) * priceBefore) / 1 ether;
        }

        StabilityPoolManager_v1(stabilityPoolManager).rebalance(makeAddr("bounty"), 0);

        uint256 priceAfter = IMinter(minter).leveragedTokenPrice();
        for (uint256 i = 0; i < holders.length; i++) {
            uint256 valueAfter = (IERC20(leveraged).balanceOf(holders[i]) * priceAfter) / 1 ether;
            assertGe(valueAfter, valuesBefore[i], "holder value must not decrease during rebalance");
        }
    }
}

/// @notice Tests against the deployed Minter_v1 (no minter upgrade)
contract RebalanceCheck_v1 is RebalanceCheckBase {
    function setUp() public {
        _forkAndPredict();
        _upgradeSpm();
    }

    function test_v1_leveragedTokenPrice_doesNotDecrease() public {
        vm.skip(true);
        _assert_leveragedTokenPrice_doesNotDecrease();
    }

    function test_v1_collateralRatio_hitsThreshold() public {
        _assert_collateralRatio_hitsThreshold();
    }

    function test_v1_userClaimable_proportionalToDeposit() public {
        _assert_userClaimable_proportionalToDeposit();
    }

    function test_v1_leveragedMint_doesNotExceedPeggedBurned() public {
        vm.skip(true);
        _assert_leveragedMint_doesNotExceedPeggedBurned();
    }

    function test_v1_holderValues_preserved() public {
        vm.skip(true);
        _assert_holderValues_preserved();
    }
}

/// @notice Tests after upgrading to Minter_v2
contract RebalanceCheck_v2 is RebalanceCheckBase {
    function setUp() public {
        _forkAndPredict();
        _upgradeMinterV2();
        _upgradeSpm();
    }

    function test_v2_leveragedTokenPrice_doesNotDecrease() public {
        _assert_leveragedTokenPrice_doesNotDecrease();
    }

    function test_v2_collateralRatio_hitsThreshold() public {
        _assert_collateralRatio_hitsThreshold();
    }

    function test_v2_userClaimable_proportionalToDeposit() public {
        _assert_userClaimable_proportionalToDeposit();
    }

    function test_v2_leveragedMint_doesNotExceedPeggedBurned() public {
        _assert_leveragedMint_doesNotExceedPeggedBurned();
    }

    function test_v2_holderValues_preserved() public {
        _assert_holderValues_preserved();
    }
}

/// @notice Quantifies the over-minting from the v1 bug and tests the underlyingCollateral
/// adjustment as a remediation strategy.
contract RebalanceCheck_remediation is RebalanceCheckBase {
    function setUp() public {
        _forkAndPredict();
        _upgradeSpm();
    }

    /// @notice Runs rebalance under v1 and v2, logs the delta in leveraged supply
    /// and underlyingCollateral, showing the exact over-minting.
    function test_log_overminting_delta() public {
        // --- snapshot v1 rebalance ---
        uint256 snap = vm.snapshotState();

        uint256 v1_collateralBefore = IMinter(minter).collateralTokenBalance();
        uint256 v1_levSupplyBefore = IERC20(leveraged).totalSupply();
        uint256 v1_priceBefore = IMinter(minter).leveragedTokenPrice();

        StabilityPoolManager_v1(stabilityPoolManager).rebalance(makeAddr("bounty"), 0);

        uint256 v1_collateralAfter = IMinter(minter).collateralTokenBalance();
        uint256 v1_levSupplyAfter = IERC20(leveraged).totalSupply();
        uint256 v1_priceAfter = IMinter(minter).leveragedTokenPrice();

        vm.revertToState(snap);

        // --- upgrade to v2 and rebalance ---
        _upgradeMinterV2();

        uint256 v2_priceBefore = IMinter(minter).leveragedTokenPrice();

        StabilityPoolManager_v1(stabilityPoolManager).rebalance(makeAddr("bounty"), 0);

        uint256 v2_collateralAfter = IMinter(minter).collateralTokenBalance();
        uint256 v2_levSupplyAfter = IERC20(leveraged).totalSupply();
        uint256 v2_priceAfter = IMinter(minter).leveragedTokenPrice();

        // --- log results ---
        uint256 excessLeveraged = v1_levSupplyAfter - v2_levSupplyAfter;
        uint256 collateralDelta = v1_collateralAfter - v2_collateralAfter;

        emit log_named_uint("v1 leveraged price BEFORE rebalance", v1_priceBefore);
        emit log_named_uint("v1 leveraged price AFTER  rebalance", v1_priceAfter);
        emit log_named_uint("v3 leveraged price BEFORE rebalance", v2_priceBefore);
        emit log_named_uint("v3 leveraged price AFTER  rebalance", v2_priceAfter);
        emit log_named_uint("v1 leveraged minted", v1_levSupplyAfter - v1_levSupplyBefore);
        emit log_named_uint("v3 leveraged minted", v2_levSupplyAfter - v1_levSupplyBefore);
        emit log_named_uint("EXCESS leveraged tokens minted by v1", excessLeveraged);
        emit log_named_uint("v1 underlyingCollateral after", v1_collateralAfter);
        emit log_named_uint("v3 underlyingCollateral after", v2_collateralAfter);
        emit log_named_uint("underlyingCollateral DELTA (v1 too high by)", collateralDelta);
        emit log_named_uint("v1 collateral removed", v1_collateralBefore - v1_collateralAfter);
        emit log_named_uint("v3 collateral removed", v1_collateralBefore - v2_collateralAfter);
    }

    /// @notice Confirms that the v1 bug is purely excess leveraged token supply,
    /// NOT a collateral accounting error. underlyingCollateral is identical.
    function test_confirm_collateralDelta_isZero() public {
        uint256 snapInit = vm.snapshotState();

        // --- Run v2 (correct) rebalance ---
        _upgradeMinterV2();
        StabilityPoolManager_v1(stabilityPoolManager).rebalance(makeAddr("bounty"), 0);
        uint256 v2_collateralAfter = IMinter(minter).collateralTokenBalance();
        uint256 v2_levSupply = IERC20(leveraged).totalSupply();

        // --- Revert and run v1 (buggy) rebalance ---
        vm.revertToState(snapInit);
        StabilityPoolManager_v1(stabilityPoolManager).rebalance(makeAddr("bounty"), 0);
        uint256 v1_collateralAfter = IMinter(minter).collateralTokenBalance();
        uint256 v1_levSupply = IERC20(leveraged).totalSupply();

        // underlyingCollateral is identical — the bug doesn't affect collateral accounting
        assertEq(v1_collateralAfter, v2_collateralAfter, "collateral must be identical");

        // The ONLY difference is excess leveraged tokens minted
        uint256 excess = v1_levSupply - v2_levSupply;
        assertGt(excess, 0, "v1 must over-mint leveraged tokens");

        emit log_named_uint("excess leveraged tokens", excess);
        emit log_named_uint("v1 leveraged price", IMinter(minter).leveragedTokenPrice());
    }
}
