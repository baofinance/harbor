// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoFactory} from "@bao-factory/IBaoFactory.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {Deploy_ETH_Minter} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket, MinterMarketConfigLib} from "@harbor-script/config/ConfigBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/// @title Common deployment setup for ETH::fxUSD market tests.
/// @dev Deploys a full ETH::fxUSD market via production deployment scripts.
///      Inherit this instead of rolling your own deployment setup.
abstract contract DeployETHfxUSDSetUp is BaoTest, Deploy_ETH_Minter {
    address minter;
    address stabilityPoolCollateral;
    address stabilityPoolLeveraged;
    address stabilityPoolManager;
    address pegged;
    address leveraged;
    address wrappedCollateral;

    MockWrappedPriceOracle mockOracle;

    function setUp() public virtual {
        address factory = _ensureBaoFactory();
        // Pinned after latest Harbor deployment (SPL remediation, 2026-03-25) for caching
        vm.createSelectFork(vm.rpcUrl("mainnet"), 24699497);

        vm.prank(IBaoFactory(factory).owner());
        IBaoFactory(factory).setOperator(address(this), 365 days);

        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = createETHMintersConfig();
        Config_MinterMarket[] memory toDeploy = new Config_MinterMarket[](1);
        toDeploy[0] = mktConfigs[0];
        deployHarborForPeg("test_eth", peg, mktConfigs, "mainnet", true, toDeploy);

        string memory mk = MinterMarketConfigLib.salt(mktConfigs[0]); // "ETH::fxUSD"
        minter = minterAddress(mk);
        stabilityPoolCollateral = stabilityPoolAddress(mk, StabilityPoolType.Collateral);
        stabilityPoolLeveraged = stabilityPoolAddress(mk, StabilityPoolType.Leveraged);
        stabilityPoolManager = stabilityPoolManagerAddress(mk);
        pegged = peggedTokenAddress(peg.key());
        leveraged = leveragedTokenAddress(mk);
        wrappedCollateral = IMinter(minter).WRAPPED_COLLATERAL_TOKEN();

        mockOracle = new MockWrappedPriceOracle();
        mockOracle.setLatestAnswer(1 ether, 1 ether);

        vm.startPrank(HARBOR_MULTISIG);
        IMinter(minter).updatePriceOracle(address(mockOracle));
        IBaoRoles(minter).grantRoles(address(this), IMinter(minter).ZERO_FEE_ROLE());
        IBaoRoles(stabilityPoolCollateral).grantRoles(
            address(this),
            IMultipleRewardDistributor(stabilityPoolCollateral).REWARD_DEPOSITOR_ROLE()
        );
        vm.stopPrank();
    }

    function _mintPegged(address to, uint256 collateralAmount) internal returns (uint256 peggedMinted) {
        deal(wrappedCollateral, address(this), collateralAmount);
        IERC20(wrappedCollateral).approve(minter, collateralAmount);
        peggedMinted = IMinter(minter).freeMintPeggedToken(collateralAmount, to);
    }

    function _mintAndDeposit(address user, uint256 amount) internal {
        uint256 peggedMinted = _mintPegged(user, amount);
        vm.startPrank(user);
        IERC20(pegged).approve(stabilityPoolCollateral, peggedMinted);
        IStabilityPool(stabilityPoolCollateral).deposit(peggedMinted, user, 0);
        vm.stopPrank();
    }

    function _depositReward(address token, uint256 amount) internal {
        deal(wrappedCollateral, address(this), amount);
        IERC20(wrappedCollateral).approve(stabilityPoolCollateral, amount);
        IMultipleRewardDistributor(stabilityPoolCollateral).depositReward(token, amount);
    }
}
