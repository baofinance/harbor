// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigChain_mainnet} from "@harbor-script/config/chains/ConfigChain_mainnet.sol";
import {ConfigPeg_ETH} from "@harbor-script/config/pegs/ConfigPeg_ETH.sol";
import {ConfigCollateral_fxUSD_mainnet} from "@harbor-script/config/collaterals/ConfigCollateral_fxUSD_mainnet.sol";
import {ConfigPriceVolatility_130_stable} from "@harbor-script/config/volatility/ConfigPriceVolatility_130_stable.sol";
import {ConfigStabilityPool} from "@harbor-script/config/stabilitypool/ConfigStabilityPool.sol";
import {ConfigStabilityPoolManager} from "@harbor-script/config/stabilitypool/ConfigStabilityPoolManager.sol";
import {ConfigTokenNames} from "@harbor-script/config/ConfigTokenNames.sol";
import {Config_MinterMarket} from "@harbor-script/config/ConfigBase.sol";

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
