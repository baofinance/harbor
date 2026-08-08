// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeploymentTypes} from "@bao-script/deployment/DeploymentTypes.sol";
import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

import {TestStabilityPoolRebalanceSetUp} from "@harbor-test/StabilityPoolRebalance.t.sol";

contract TestStabilityPool2SetUp is TestStabilityPoolRebalanceSetUp {
    address stabilityPoolLeveraged;

    /// @dev Adds the market's SECOND stability pool, the one that absorbs leveraged tokens. Together with the
    ///      collateral pool below it that is every pool a market has.
    function _deployAndConfigure(
        DeploymentTypes.State memory state,
        ConfigPeg peg,
        Config_MinterMarket[] memory allMarkets,
        bool deployPeg,
        Config_MinterMarket[] memory marketsToDeploy
    ) internal virtual override {
        super._deployAndConfigure(state, peg, allMarkets, deployPeg, marketsToDeploy);

        _grantPoolTestRoles(deployStabilityPool(StabilityPoolType.Leveraged, state, marketsToDeploy[0]));
    }

    function setUp() public virtual override {
        super.setUp();

        stabilityPoolLeveraged = stabilityPoolAddress(marketConfig, StabilityPoolType.Leveraged);
        vm.label(stabilityPoolLeveraged, "stabilityPoolLeveraged");

        vm.startPrank(user1);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(peggedToken).approve(stabilityPoolLeveraged, type(uint256).max);
        vm.stopPrank();
    }
}
