// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_megaeth} from "../chains/ConfigChain_megaeth.sol";
import {ConfigPeg_HYPE} from "../pegs/ConfigPeg_HYPE.sol";
import {ConfigCollateral_USDMY_megaeth} from "../collaterals/ConfigCollateral_USDMY_megaeth.sol";
import {ConfigPriceVolatility_125_stable} from "../volatility/ConfigPriceVolatility_125_stable.sol";
import {ConfigStabilityPool} from "../stabilitypool/ConfigStabilityPool.sol";
import {ConfigStabilityPoolManager} from "../stabilitypool/ConfigStabilityPoolManager.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";

/// @notice Market configuration for HYPE::USDMY (megaeth).
contract ConfigMarket_HYPE_USDMY_megaeth is
    Config_MinterMarket,
    ConfigChain_megaeth,
    ConfigPeg_HYPE,
    ConfigCollateral_USDMY_megaeth,
    ConfigPriceVolatility_125_stable,
    ConfigStabilityPool,
    ConfigStabilityPoolManager
{}
