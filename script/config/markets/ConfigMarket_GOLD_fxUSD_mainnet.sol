// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_mainnet} from "@harbor-script/config/chains/ConfigChain_mainnet.sol";
import {ConfigPeg_GOLD} from "@harbor-script/config/pegs/ConfigPeg_GOLD.sol";
import {ConfigCollateral_fxUSD_mainnet} from "@harbor-script/config/collaterals/ConfigCollateral_fxUSD_mainnet.sol";
import {ConfigPriceVolatility_115} from "@harbor-script/config/volatility/ConfigPriceVolatility_115.sol";
import {ConfigStabilityPool} from "@harbor-script/config/stabilitypool/ConfigStabilityPool.sol";
import {ConfigStabilityPoolManager} from "@harbor-script/config/stabilitypool/ConfigStabilityPoolManager.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";
import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";

/// @notice Market configuration for GOLD::fxUSD.
contract ConfigMarket_GOLD_fxUSD_mainnet is
    Config_MinterMarket,
    ConfigChain_mainnet,
    ConfigPeg_GOLD,
    ConfigCollateral_fxUSD_mainnet,
    ConfigPriceVolatility_115,
    ConfigStabilityPool,
    ConfigStabilityPoolManager,
    ConfigTokenNames
{}
