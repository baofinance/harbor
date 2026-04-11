// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_mainnet} from "../chains/ConfigChain_mainnet.sol";
import {ConfigPeg_GOLD} from "../pegs/ConfigPeg_GOLD.sol";
import {ConfigCollateral_fxUSD_mainnet} from "../collaterals/ConfigCollateral_fxUSD_mainnet.sol";
import {ConfigPriceVolatility_115} from "../volatility/ConfigPriceVolatility_115.sol";
import {ConfigStabilityPool} from "../stabilitypool/ConfigStabilityPool.sol";
import {ConfigStabilityPoolManager} from "../stabilitypool/ConfigStabilityPoolManager.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";
import {ConfigTokenNames} from "../ConfigTokenNames.sol";
import {ConfigAutoCompounder} from "../autocompounder/ConfigAutoCompounder.sol";

/// @notice Market configuration for GOLD::fxUSD.
contract ConfigMarket_GOLD_fxUSD_mainnet is
    Config_MinterMarket,
    ConfigChain_mainnet,
    ConfigPeg_GOLD,
    ConfigCollateral_fxUSD_mainnet,
    ConfigPriceVolatility_115,
    ConfigStabilityPool,
    ConfigStabilityPoolManager,
    ConfigTokenNames,
    ConfigAutoCompounder
{}
