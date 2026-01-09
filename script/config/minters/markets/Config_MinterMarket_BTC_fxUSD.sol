// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_Peg_BTC} from "../../pegs/Config_Peg_BTC.sol";
import {Config_Collateral_fxUSD} from "../../collateral/Config_Collateral_fxUSD.sol";
import {Config_PriceVolatility_130} from "../../volatility/Config_PriceVolatility_130.sol";
import {Config_StabilityPoolParams_Common} from "../../stabilitypool/Config_StabilityPoolParams_Common.sol";
import {Config_Minter_Common} from "../Config_Minter_Common.sol";
import {Config_MinterMarket, IMarketConfig} from "../../ConfigBase.sol";

/// @notice Minter market config for BTC::fxUSD.
abstract contract Config_MinterMarket_BTC_fxUSD is
    Config_MinterMarket,
    IMarketConfig,
    Config_Peg_BTC,
    Config_Collateral_fxUSD,
    Config_PriceVolatility_130,
    Config_StabilityPoolParams_Common,
    Config_Minter_Common
{
    // Market identity provided by peg (from Config_Peg_BTC) and collateral (from Config_Collateral_fxUSD)

    // Resolve peg/collateral interface diamond
    function peg() public pure override(Config_Peg_BTC, IMarketConfig) returns (string memory) {
        return Config_Peg_BTC.peg();
    }

    function collateral() public pure override(Config_Collateral_fxUSD, IMarketConfig) returns (string memory) {
        return Config_Collateral_fxUSD.collateral();
    }

    function wrappedCollateral() public pure override(Config_Collateral_fxUSD, Config_Minter_Common) returns (address) {
        return Config_Collateral_fxUSD.wrappedCollateral();
    }

    // Stability pool parameter override
    function stabilityPoolMinTotalAssetSupply() public pure override returns (uint256) {
        return 1e13;
    }
}
