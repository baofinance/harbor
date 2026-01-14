// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_mainnet} from "../chains/ConfigChain_mainnet.sol";
import {ConfigPeg_SILVER} from "../pegs/ConfigPeg_SILVER.sol";
import {ConfigCollateral_fxUSD_mainnet} from "../collaterals/ConfigCollateral_fxUSD_mainnet.sol";
import {ConfigPriceVolatility_125} from "../volatility/ConfigPriceVolatility_125.sol";
import {ConfigStabilityPool} from "../stabilitypool/ConfigStabilityPool.sol";
import {ConfigStabilityPoolManager} from "../stabilitypool/ConfigStabilityPoolManager.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";

/// @notice Market configuration for SILVER::fxUSD.
contract ConfigMarket_SILVER_fxUSD_mainnet is
    Config_MinterMarket,
    ConfigChain_mainnet,
    ConfigPeg_SILVER,
    ConfigCollateral_fxUSD_mainnet,
    ConfigPriceVolatility_125,
    ConfigStabilityPool,
    ConfigStabilityPoolManager
{}
