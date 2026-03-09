// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_monad} from "../chains/ConfigChain_monad.sol";
import {ConfigPeg_BTC} from "../pegs/ConfigPeg_BTC.sol";
import {ConfigCollateral_wstETH_monad} from "../collaterals/ConfigCollateral_wstETH_monad.sol";
import {ConfigPriceVolatility_125_stable} from "../volatility/ConfigPriceVolatility_125_stable.sol";
import {ConfigStabilityPool} from "../stabilitypool/ConfigStabilityPool.sol";
import {ConfigStabilityPoolManager} from "../stabilitypool/ConfigStabilityPoolManager.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";

/// @notice Market configuration for BTC::wstETH (monad).
contract ConfigMarket_BTC_wstETH_monad is
    Config_MinterMarket,
    ConfigChain_monad,
    ConfigPeg_BTC,
    ConfigCollateral_wstETH_monad,
    ConfigPriceVolatility_125_stable,
    ConfigStabilityPool,
    ConfigStabilityPoolManager
{}
