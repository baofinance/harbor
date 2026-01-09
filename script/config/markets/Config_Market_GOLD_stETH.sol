// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_Chain_Mainnet} from "../chains/Config_Chain_Mainnet.sol";
import {Config_Peg_GOLD} from "../pegs/Config_Peg_GOLD.sol";
import {Config_Collateral_stETH} from "../collaterals/Config_Collateral_stETH.sol";
import {Config_PriceVolatility_130} from "../volatility/Config_PriceVolatility_130.sol";
import {Config_StabilityPool} from "../stabilitypool/Config_StabilityPool.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";

/// @notice Market configuration for GOLD::stETH.
contract Config_Market_GOLD_stETH is
    Config_MinterMarket,
    Config_Chain_Mainnet,
    Config_Peg_GOLD,
    Config_Collateral_stETH,
    Config_PriceVolatility_130,
    Config_StabilityPool
{
    function stabilityPoolMinTotalAssetSupply() public pure override returns (uint256) {
        return 2e14;
    }
}
