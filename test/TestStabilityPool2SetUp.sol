// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HarborDeployer} from "@harbor-script/src/HarborDeployer.sol";

import {TestMinterMarketConfig} from "@harbor-test/config/TestMinterMarketConfig.sol";
import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {MarketDeployRun} from "@harbor-test/harness/MarketDeployRun.sol";
import {MockStabilityPoolMarketDeployRun} from "@harbor-test/harness/MockStabilityPoolMarketDeployRun.sol";
import {TestStabilityPoolRebalanceSetUp} from "@harbor-test/StabilityPoolRebalance.t.sol";

contract TestStabilityPool2SetUp is TestStabilityPoolRebalanceSetUp {
    address stabilityPoolLeveraged;

    /// @dev Both of the market's pools: the collateral pool below and the one that absorbs leveraged tokens.
    ///      Together that is every pool a market has.
    function newDeployRun() internal virtual override returns (MarketDeployRun) {
        return
            new MockStabilityPoolMarketDeployRun(
                owner(),
                treasury(),
                HarborDeployRun.Cut.BothPools,
                new TestMinterMarketConfig()
            );
    }

    function setUp() public virtual override {
        super.setUp();

        stabilityPoolLeveraged = deployRun.stabilityPoolAddress(
            marketConfig,
            HarborDeployer.StabilityPoolType.Leveraged
        );
        vm.label(stabilityPoolLeveraged, "stabilityPoolLeveraged");
        _grantPoolTestRoles(stabilityPoolLeveraged);

        vm.startPrank(user1);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        vm.stopPrank();
    }
}
