// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_mainnet} from "../chains/ConfigChain_mainnet.sol";
import {ConfigPeg_USD} from "../pegs/ConfigPeg_USD.sol";
import {ConfigCollateral_PAXG_mainnet} from "../collaterals/ConfigCollateral_PAXG_mainnet.sol";
import {ConfigPriceVolatility_125_stable} from "../volatility/ConfigPriceVolatility_125_stable.sol";
import {ConfigStabilityPool} from "../stabilitypool/ConfigStabilityPool.sol";
import {ConfigStabilityPoolManager} from "../stabilitypool/ConfigStabilityPoolManager.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";

/// @notice Market configuration for USD::PAXG (mainnet).
contract ConfigMarket_USD_PAXG_mainnet is
    Config_MinterMarket,
    ConfigChain_mainnet,
    ConfigPeg_USD,
    ConfigCollateral_PAXG_mainnet,
    ConfigPriceVolatility_125_stable,
    ConfigStabilityPool,
    ConfigStabilityPoolManager
{}
