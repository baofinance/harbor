// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_megaeth} from "../chains/ConfigChain_megaeth.sol";
import {ConfigPeg_USD} from "../pegs/ConfigPeg_USD.sol";
import {ConfigCollateral_wstETH_megaeth} from "../collaterals/ConfigCollateral_wstETH_megaeth.sol";
import {ConfigPriceVolatility_125_stable} from "../volatility/ConfigPriceVolatility_125_stable.sol";
import {ConfigStabilityPool} from "../stabilitypool/ConfigStabilityPool.sol";
import {ConfigStabilityPoolManager} from "../stabilitypool/ConfigStabilityPoolManager.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";

/// @notice Market configuration for USD::wstETH (megaeth).
contract ConfigMarket_USD_wstETH_megaeth is
    Config_MinterMarket,
    ConfigChain_megaeth,
    ConfigPeg_USD,
    ConfigCollateral_wstETH_megaeth,
    ConfigPriceVolatility_125_stable,
    ConfigStabilityPool,
    ConfigStabilityPoolManager
{}
