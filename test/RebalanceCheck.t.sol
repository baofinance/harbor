// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {HarborFactoryDeployer} from "@harbor/../script/src/HarborFactoryDeployer.sol";
import {StabilityPoolManager_v1} from "src/minter/StabilityPoolManager_v1.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {Minter_v2} from "src/minter/Minter_v2.sol";

abstract contract RebalanceCheckBase is BaoTest, HarborFactoryDeployer {
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

    function _predictAndLabel(string memory a, string memory b) private returns (address addr) {
        string memory salt = _saltString(a, b);
        addr = _predictAddressFromFullSalt(salt);
        vm.label(addr, salt);
    }

    function _predictAndLabel(string memory a, string memory b, string memory c) private returns (address addr) {
        string memory salt = _saltString(a, b, c);
        addr = _predictAddressFromFullSalt(salt);
        vm.label(addr, salt);
    }

    function _forkAndPredict() internal {
        vm.createSelectFork(mainnet, FORK_BLOCK);

        _setSaltPrefix("harbor_v1");
        stabilityPoolManager = _predictAndLabel("ETH", "fxUSD", "stabilityPoolManager");
        stabilityPoolCollateral = _predictAndLabel("ETH", "fxUSD", "stabilityPoolCollateral");
        stabilityPoolLeveraged = _predictAndLabel("ETH", "fxUSD", "stabilityPoolLeveraged");
        minter = _predictAndLabel("ETH", "fxUSD", "minter");
        pegged = _predictAndLabel("ETH", "pegged");
        leveraged = _predictAndLabel("ETH", "fxUSD", "leveraged");
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
        Minter_v2 newMinterImpl = new Minter_v2(
            m.WRAPPED_COLLATERAL_TOKEN(),
            m.PEGGED_TOKEN(),
            m.LEVERAGED_TOKEN(),
            "burn(uint256)"
        );
        vm.prank(proxyOwner);
        Minter_v2(minter).upgradeToAndCall(address(newMinterImpl), "");
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
}
