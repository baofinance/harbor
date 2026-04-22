// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigStabilityPoolManager} from "./ConfigStabilityPoolManager.sol";
import {HarborFactoryDeployer} from "@harbor-script/src/HarborFactoryDeployer.sol";

/// @notice Shared stability pool manager fee receiver and parameter defaults.
/// @dev Keeps stability pool manager concerns separate from minter config.
abstract contract ConfigStabilityPoolManagerCommon is ConfigStabilityPoolManager, HarborFactoryDeployer {
    function feeReceiverName() public pure returns (string memory) {
        return "StabilityPoolManager Cut Receiver";
    }

    function feeReceiverTokens() public view returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = wrappedCollateral();
    }

    function feeReceiverRecipients() public view returns (address[] memory arr) {
        arr = new address[](3);
        arr[0] = treasury();
        arr[1] = stabilityPoolCollateral();
        arr[2] = stabilityPoolLeveraged();
    }

    function feeReceiverShares() public pure returns (uint256[] memory arr) {
        arr = new uint256[](3);
        arr[0] = 4e16;
        arr[1] = 48e16; // 4.8e17
        arr[2] = 48e16;
    }

    // Default rebalance/harvest params retained from base; override if needed per market.
    function rebalanceBountyRatio() public pure virtual override returns (uint256) {
        return super.rebalanceBountyRatio();
    }

    function harvestBountyRatio() public pure virtual override returns (uint256) {
        return super.harvestBountyRatio();
    }

    function harvestCutRatio() public pure virtual override returns (uint256) {
        return super.harvestCutRatio();
    }

    // To be supplied by concrete market configs
    function wrappedCollateral() public view virtual returns (address);
    function stabilityPoolCollateral() public view virtual returns (address);
    function stabilityPoolLeveraged() public view virtual returns (address);
}
