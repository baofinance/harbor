// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_mainnet} from "../chains/ConfigChain_mainnet.sol";
import {ConfigPeg_ETH} from "../pegs/ConfigPeg_ETH.sol";
import {ConfigCollateral_fxUSD_mainnet} from "../collaterals/ConfigCollateral_fxUSD_mainnet.sol";
import {ConfigPriceVolatility_130_stable} from "../volatility/ConfigPriceVolatility_130_stable.sol";
import {ConfigStabilityPool} from "../stabilitypool/ConfigStabilityPool.sol";
import {ConfigStabilityPoolManager} from "../stabilitypool/ConfigStabilityPoolManager.sol";
import {ConfigTokenNames} from "../ConfigTokenNames.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";

/// @notice Market configuration for ETH::fxUSD.
contract ConfigMarket_ETH_fxUSD_mainnet is
    Config_MinterMarket,
    ConfigChain_mainnet,
    ConfigPeg_ETH,
    ConfigCollateral_fxUSD_mainnet,
    ConfigPriceVolatility_130_stable,
    ConfigStabilityPool,
    ConfigStabilityPoolManager,
    ConfigTokenNames
{}
