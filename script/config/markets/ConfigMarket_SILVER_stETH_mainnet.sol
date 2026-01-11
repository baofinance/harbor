// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_mainnet} from "../chains/ConfigChain_mainnet.sol";
import {ConfigPeg_SILVER} from "../pegs/ConfigPeg_SILVER.sol";
import {ConfigCollateral_stETH_mainnet} from "../collaterals/ConfigCollateral_stETH_mainnet.sol";
import {ConfigPriceVolatility_130} from "../volatility/ConfigPriceVolatility_130.sol";
import {ConfigStabilityPool} from "../stabilitypool/ConfigStabilityPool.sol";
import {ConfigStabilityPoolManager} from "../stabilitypool/ConfigStabilityPoolManager.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";

/// @notice Market configuration for SILVER::stETH.
contract ConfigMarket_SILVER_stETH_mainnet is
    Config_MinterMarket,
    ConfigChain_mainnet,
    ConfigPeg_SILVER,
    ConfigCollateral_stETH_mainnet,
    ConfigPriceVolatility_130,
    ConfigStabilityPool,
    ConfigStabilityPoolManager
{}
