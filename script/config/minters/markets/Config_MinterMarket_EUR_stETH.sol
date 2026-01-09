// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_Peg_EUR} from "../../pegs/Config_Peg_EUR.sol";
import {Config_Collateral_stETH} from "../../collateral/Config_Collateral_stETH.sol";
import {Config_PriceVolatility_130} from "../../volatility/Config_PriceVolatility_130.sol";
import {Config_StabilityPoolParams_Common} from "../../stabilitypool/Config_StabilityPoolParams_Common.sol";
import {Config_Minter_Common} from "../Config_Minter_Common.sol";
import {Config_MinterMarket, IMarketConfig} from "../../ConfigBase.sol";

/// @notice Minter market config for EUR::stETH.
abstract contract Config_MinterMarket_EUR_stETH is
    Config_MinterMarket,
    IMarketConfig,
    Config_Peg_EUR,
    Config_Collateral_stETH,
    Config_PriceVolatility_130,
    Config_StabilityPoolParams_Common,
    Config_Minter_Common
{
    // Market identity provided by peg and collateral configs

    // Resolve peg/collateral interface diamond
    function peg() public pure override(Config_Peg_EUR, IMarketConfig) returns (string memory) {
        return Config_Peg_EUR.peg();
    }

    function collateral() public pure override(Config_Collateral_stETH, IMarketConfig) returns (string memory) {
        return Config_Collateral_stETH.collateral();
    }

    function wrappedCollateral() public pure override(Config_Collateral_stETH, Config_Minter_Common) returns (address) {
        return Config_Collateral_stETH.wrappedCollateral();
    }

    // Stability pool parameter override
    function stabilityPoolMinTotalAssetSupply() public pure override returns (uint256) {
        return 1e18;
    }
}
