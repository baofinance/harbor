// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_mainnet} from "../chains/ConfigChain_mainnet.sol";
import {ConfigPeg_EUR} from "../pegs/ConfigPeg_EUR.sol";
import {ConfigCollateral_fxUSD_mainnet} from "../collaterals/ConfigCollateral_fxUSD_mainnet.sol";
import {ConfigPriceVolatility_105} from "../volatility/ConfigPriceVolatility_105.sol";
import {ConfigStabilityPool} from "../stabilitypool/ConfigStabilityPool.sol";
import {ConfigStabilityPoolManager} from "../stabilitypool/ConfigStabilityPoolManager.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";
import {ConfigTokenNames} from "../ConfigTokenNames.sol";

/// @notice Market configuration for EUR::fxUSD.
contract ConfigMarket_EUR_fxUSD_mainnet is
    Config_MinterMarket,
    ConfigChain_mainnet,
    ConfigPeg_EUR,
    ConfigCollateral_fxUSD_mainnet,
    ConfigPriceVolatility_105,
    ConfigStabilityPool,
    ConfigStabilityPoolManager,
    ConfigTokenNames
{}
