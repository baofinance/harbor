// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_Chain_Mainnet} from "../chains/Config_Chain_Mainnet.sol";
import {Config_Peg_MCAP} from "../pegs/Config_Peg_MCAP.sol";
import {Config_Collateral_stETH} from "../collaterals/Config_Collateral_stETH.sol";
import {Config_PriceVolatility_130} from "../volatility/Config_PriceVolatility_130.sol";
import {Config_StabilityPool} from "../stabilitypool/Config_StabilityPool.sol";
import {Config_StabilityPoolManager} from "../stabilitypool/Config_StabilityPoolManager.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";

/// @notice Market configuration for MCAP::stETH.
contract Config_Market_MCAP_stETH is
    Config_MinterMarket,
    Config_Chain_Mainnet,
    Config_Peg_MCAP,
    Config_Collateral_stETH,
    Config_PriceVolatility_130,
    Config_StabilityPool,
    Config_StabilityPoolManager
{}
