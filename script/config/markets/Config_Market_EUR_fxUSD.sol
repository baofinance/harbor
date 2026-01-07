// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_Chain_Mainnet} from "../chains/Config_Chain_Mainnet.sol";
import {Config_Peg_EUR} from "../pegs/Config_Peg_EUR.sol";
import {Config_Collateral_fxUSD} from "../collaterals/Config_Collateral_fxUSD.sol";
import {Config_PriceVolatility_130} from "../volatility/Config_PriceVolatility_130.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";

/// @notice Market configuration for EUR::fxUSD.
contract Config_Market_EUR_fxUSD is
    Config_MinterMarket,
    Config_Chain_Mainnet,
    Config_Peg_EUR,
    Config_Collateral_fxUSD,
    Config_PriceVolatility_130
{}
