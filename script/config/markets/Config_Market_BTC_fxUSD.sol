// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_Chain_Mainnet} from "../chains/Config_Chain_Mainnet.sol";
import {Config_Peg_BTC} from "../pegs/Config_Peg_BTC.sol";
import {Config_Collateral_fxUSD} from "../collaterals/Config_Collateral_fxUSD.sol";
import {Config_PriceVolatility_130} from "../volatility/Config_PriceVolatility_130.sol";
import {Config_MinterMarket} from "../ConfigBase.sol";

/// @notice Market configuration for BTC::fxUSD.
contract Config_Market_BTC_fxUSD is
    Config_MinterMarket,
    Config_Chain_Mainnet,
    Config_Peg_BTC,
    Config_Collateral_fxUSD,
    Config_PriceVolatility_130
{
}
