// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_Chain_Mainnet} from "../../chains/Config_Chain_Mainnet.sol";
import {Config_Protocol} from "../../chains/Config_Protocol.sol";
import {Config_Collateral_stETH} from "../../collateral/Config_Collateral_stETH.sol";
import {Config_Minter_Common} from "../Config_Minter_Common.sol";
import {Config_MinterMarket_EUR_stETH} from "./Config_MinterMarket_EUR_stETH.sol";
import {MinterMarketConfigLib} from "../../ConfigBase.sol";

/// @notice Mainnet wiring for EUR::stETH minter market config.
contract Config_MinterMarket_EUR_stETH_mainnet is Config_Chain_Mainnet, Config_MinterMarket_EUR_stETH {

    function stETH() public pure override(Config_Chain_Mainnet, Config_Collateral_stETH) returns (address) {
        return Config_Chain_Mainnet.stETH();
    }

    function wstETH() public pure override(Config_Chain_Mainnet, Config_Collateral_stETH) returns (address) {
        return Config_Chain_Mainnet.wstETH();
    }

    function treasury() public pure override(Config_Minter_Common, Config_Protocol) returns (address) {
        return Config_Protocol.treasury();
    }

    function priceOracle() public view returns (address) {
        return MinterMarketConfigLib.priceOracle(this);
    }
}
