// SPDX-License-Identifier: MIT

pragma solidity ^0.8.26;

import {IPriceOracle} from "src/price/IPriceOracle.sol";

contract MockPriceOracle is IPriceOracle {
    uint256 public latestAnswer;
    uint8 public decimals;

    constructor() {
        latestAnswer = 2000 ether;
        decimals = 18;
    }

    function setLatestAnswer(uint256 price_) public {
        latestAnswer = price_;
    }

    function setDecimals(uint8 decimals_) public {
        decimals = decimals_;
    }
}
