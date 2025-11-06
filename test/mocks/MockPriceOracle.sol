// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";

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
}
