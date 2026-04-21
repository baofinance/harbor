// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_mainnet} from "../chains/ConfigChain_mainnet.sol";
import {ConfigPeg_MCAP} from "../pegs/ConfigPeg_MCAP.sol";
import {ConfigCollateral_fxUSD_mainnet} from "../collaterals/ConfigCollateral_fxUSD_mainnet.sol";
import {ConfigPriceVolatility_130} from "../volatility/ConfigPriceVolatility_130.sol";
import {ConfigStabilityPool} from "../stabilitypool/ConfigStabilityPool.sol";
import {ConfigStabilityPoolManager} from "../stabilitypool/ConfigStabilityPoolManager.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";
import {ConfigTokenNames} from "../ConfigTokenNames.sol";

/// @notice Market configuration for MCAP::fxUSD.
contract ConfigMarket_MCAP_fxUSD_mainnet is
    Config_MinterMarket,
    ConfigChain_mainnet,
    ConfigPeg_MCAP,
    ConfigCollateral_fxUSD_mainnet,
    ConfigPriceVolatility_130,
    ConfigStabilityPool,
    ConfigStabilityPoolManager,
    ConfigTokenNames
{}
