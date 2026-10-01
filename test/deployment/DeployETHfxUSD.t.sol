// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {ethMintersConfig} from "@harbor-script/src/Deploy_ETH_Minter.sol";
import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IStabilityPool} from "@harbor/interfaces/IStabilityPool.sol";
import {IMultipleRewardDistributor} from "@harbor/interfaces/IMultipleRewardDistributor.sol";
import {MarketAddresses} from "@harbor-test/harness/MarketAddresses.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/// @title Common deployment setup for ETH::fxUSD market tests.
/// @dev Deploys a full ETH::fxUSD market via production deployment scripts.
///      Inherit this instead of rolling your own deployment setup.
abstract contract DeployETHfxUSDSetUp is BaoTest {
    /// @dev The deploy run that stands the market up, held rather than inherited (see `HarborDeployRun`).
    HarborDeployRun internal deployRun;

    address minter;
    address stabilityPoolCollateral;
    address stabilityPoolLeveraged;
    address stabilityPoolManager;
    address pegged;
    address leveraged;
    address wrappedCollateral;

    MockWrappedPriceOracle mockOracle;

    function setUp() public virtual {
        forkMainnet();
        deployRun = new HarborDeployRun(
            HARBOR_MULTISIG,
            HARBOR_MULTISIG,
            "test_eth",
            "mainnet",
            HarborDeployRun.Cut.Whole
        );
        deployRun.ensureFactory();

        (ConfigPeg peg, Config_MinterMarket[] memory mktConfigs) = ethMintersConfig();
        Config_MinterMarket[] memory toDeploy = new Config_MinterMarket[](1);
        toDeploy[0] = mktConfigs[0];
        deployRun.deploy(peg, mktConfigs, true, toDeploy);

        MarketAddresses memory addresses = deployRun.marketAddresses(mktConfigs[0]);
        minter = addresses.minter;
        stabilityPoolCollateral = addresses.collateralPool;
        stabilityPoolLeveraged = addresses.leveragedPool;
        stabilityPoolManager = addresses.manager;
        pegged = addresses.pegged;
        leveraged = addresses.leveraged;
        wrappedCollateral = addresses.wrappedCollateral;

        mockOracle = MockWrappedPriceOracle(deployRun.installMockPriceOracle(mktConfigs[0]));
        mockOracle.setLatestAnswer(1 ether, 1 ether);

        vm.startPrank(HARBOR_MULTISIG);
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
