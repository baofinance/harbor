// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_mainnet} from "@harbor-script/config/chains/ConfigChain_mainnet.sol";
import {ConfigPeg_SILVER} from "@harbor-script/config/pegs/ConfigPeg_SILVER.sol";
import {ConfigCollateral_fxUSD_mainnet} from "@harbor-script/config/collaterals/ConfigCollateral_fxUSD_mainnet.sol";
import {ConfigPriceVolatility_125} from "@harbor-script/config/volatility/ConfigPriceVolatility_125.sol";
import {ConfigStabilityPool} from "@harbor-script/config/stabilitypool/ConfigStabilityPool.sol";
import {ConfigStabilityPoolManager} from "@harbor-script/config/stabilitypool/ConfigStabilityPoolManager.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";

/// @notice Market configuration for SILVER::fxUSD.
contract ConfigMarket_SILVER_fxUSD_mainnet is
    Config_MinterMarket,
    ConfigChain_mainnet,
    ConfigPeg_SILVER,
    ConfigCollateral_fxUSD_mainnet,
    ConfigPriceVolatility_125,
    ConfigStabilityPool,
    ConfigStabilityPoolManager,
    ConfigTokenNames
{}
