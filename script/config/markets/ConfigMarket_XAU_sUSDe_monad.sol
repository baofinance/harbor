// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_monad} from "../chains/ConfigChain_monad.sol";
import {ConfigPeg_XAU} from "../pegs/ConfigPeg_XAU.sol";
import {ConfigCollateral_sUSDe_monad} from "../collaterals/ConfigCollateral_sUSDe_monad.sol";
import {ConfigPriceVolatility_125_stable} from "../volatility/ConfigPriceVolatility_125_stable.sol";
import {ConfigStabilityPool} from "../stabilitypool/ConfigStabilityPool.sol";
import {ConfigStabilityPoolManager} from "../stabilitypool/ConfigStabilityPoolManager.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";

/// @notice Market configuration for XAU::sUSDe (monad).
contract ConfigMarket_XAU_sUSDe_monad is
    Config_MinterMarket,
    ConfigChain_monad,
    ConfigPeg_XAU,
    ConfigCollateral_sUSDe_monad,
    ConfigPriceVolatility_125_stable,
    ConfigStabilityPool,
    ConfigStabilityPoolManager
{}
