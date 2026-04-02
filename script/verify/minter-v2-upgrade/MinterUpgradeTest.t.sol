// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {HarborFactoryDeployer} from "script/src/HarborFactoryDeployer.sol";
import {IMinter} from "src/interfaces/IMinter.sol";
import {IStabilityPoolManager} from "src/interfaces/IStabilityPoolManager.sol";
import {IStabilityPool} from "src/interfaces/IStabilityPool.sol";
import {IMultipleRewardAccumulator} from "src/interfaces/IMultipleRewardAccumulator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StabilityPoolManager_v1} from "src/minter/StabilityPoolManager_v1.sol";

/// @title Minter v2 Post-Deploy Verification
/// @notice Asserts that the deploy script correctly upgraded all minters and
/// that rebalance works correctly on the ETH::fxUSD market (which has enough
/// liquidity and a CR below threshold at the fork block).
/// @dev Run against a local anvil fork AFTER deploying via Deploy_Minter_v2_mainnet:
///   1. script/anvil --block 24687073
///   2. ./script/run-script Deploy_Minter_v2_mainnet --network mainnet --salt harbor_v1 --broadcast --local
///   3. forge test --match-path script/test/MinterUpgradeTest.t.sol --fork-url local -vv
contract MinterUpgradeTest is BaoTest, HarborFactoryDeployer {
    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("local"));
        _setSaltPrefix("harbor_v1");
    }

    function _predict(string memory marketKey, string memory suffix) internal returns (address) {
        return _predictAddressFromFullSalt(_saltString(_key(marketKey, suffix)));
    }

    // ---- ETH::fxUSD rebalance tests (the market with known sub-threshold CR) ----
    // Role checks are in MainnetRoles.t.sol (shared between upgrade and deploy workflows)

    function _ethFxUSD() internal returns (address minter, address spm, address leveraged) {
        string memory key = "ETH::fxUSD";
        minter = _predict(key, "minter");
        spm = _predict(key, "stabilityPoolManager");
        leveraged = _predict(key, "leveraged");
    }

    function test_rebalance_leveragedTokenPrice_doesNotDecrease() public {
        (address minter, address spm, ) = _ethFxUSD();
        uint256 priceBefore = IMinter(minter).leveragedTokenPrice();
        StabilityPoolManager_v1(spm).rebalance(makeAddr("bounty"), 0);
        uint256 priceAfter = IMinter(minter).leveragedTokenPrice();
        assertGe(priceAfter, priceBefore, "leveragedTokenPrice must not decrease during rebalance");
    }

    function test_rebalance_collateralRatio_hitsThreshold() public {
        (address minter, address spm, ) = _ethFxUSD();
        uint256 threshold = IStabilityPoolManager(spm).rebalanceThreshold();
        uint256 crBefore = IMinter(minter).collateralRatio();
        assertTrue(crBefore < threshold, "precondition: CR must be below threshold");

        StabilityPoolManager_v1(spm).rebalance(makeAddr("bounty"), 0);

        uint256 crAfter = IMinter(minter).collateralRatio();
        assertApprox(crAfter, threshold, 0, 0.0001 ether, "CR should hit rebalance threshold");
    }

    function test_rebalance_leveragedMint_doesNotExceedPeggedBurned() public {
        (address minter, address spm, address leveraged) = _ethFxUSD();
        uint256 priceBefore = IMinter(minter).leveragedTokenPrice();
        uint256 supplyBefore = IERC20(leveraged).totalSupply();
        uint256 peggedBefore = IMinter(minter).peggedTokenBalance();

        StabilityPoolManager_v1(spm).rebalance(makeAddr("bounty"), 0);

        uint256 leveragedMinted = IERC20(leveraged).totalSupply() - supplyBefore;
        uint256 peggedBurned = peggedBefore - IMinter(minter).peggedTokenBalance();
        uint256 mintedValue = (leveragedMinted * priceBefore) / 1 ether;
        assertLe(mintedValue, peggedBurned, "minted leveraged value must not exceed pegged burned");
    }
}
