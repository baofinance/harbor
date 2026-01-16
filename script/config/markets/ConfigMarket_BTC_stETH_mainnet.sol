// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_mainnet} from "../chains/ConfigChain_mainnet.sol";
import {ConfigPeg_BTC} from "../pegs/ConfigPeg_BTC.sol";
import {ConfigCollateral_stETH_mainnet} from "../collaterals/ConfigCollateral_stETH_mainnet.sol";
import {ConfigPriceVolatility_125_stable} from "../volatility/ConfigPriceVolatility_125_stable.sol";
import {ConfigStabilityPool} from "../stabilitypool/ConfigStabilityPool.sol";
import {ConfigStabilityPoolManager} from "../stabilitypool/ConfigStabilityPoolManager.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";

/// @notice Market configuration for BTC::stETH.
contract ConfigMarket_BTC_stETH_mainnet is
    Config_MinterMarket,
    ConfigChain_mainnet,
    ConfigPeg_BTC,
    ConfigCollateral_stETH_mainnet,
    ConfigPriceVolatility_125_stable,
    ConfigStabilityPool,
    ConfigStabilityPoolManager
{}
