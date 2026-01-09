// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Config_Chain_Mainnet} from "../../chains/Config_Chain_Mainnet.sol";
import {Config_Protocol} from "../../chains/Config_Protocol.sol";
import {Config_Collateral_fxUSD} from "../../collateral/Config_Collateral_fxUSD.sol";
import {Config_Minter_Common} from "../Config_Minter_Common.sol";
import {Config_MinterMarket_EUR_fxUSD} from "./Config_MinterMarket_EUR_fxUSD.sol";
import {MinterMarketConfigLib} from "../../ConfigBase.sol";

/// @notice Mainnet wiring for EUR::fxUSD minter market config.
contract Config_MinterMarket_EUR_fxUSD_mainnet is Config_Chain_Mainnet, Config_MinterMarket_EUR_fxUSD {
    constructor(string memory systemSaltString) Config_Chain_Mainnet(systemSaltString) {}

    function fxUSD() public pure override(Config_Chain_Mainnet, Config_Collateral_fxUSD) returns (address) {
        return Config_Chain_Mainnet.fxUSD();
    }

    function fxSAVE() public pure override(Config_Chain_Mainnet, Config_Collateral_fxUSD) returns (address) {
        return Config_Chain_Mainnet.fxSAVE();
    }

    function treasury() public pure override(Config_Minter_Common, Config_Protocol) returns (address) {
        return Config_Protocol.treasury();
    }

    function priceOracle() public view returns (address) {
        return MinterMarketConfigLib.priceOracle(this);
    }
}
