// SPDX-License-Identifier: MIT

pragma solidity ^0.8.25;

import { IPriceOracle } from "src/price/IPriceOracle.sol";

contract MockPriceOracle is IPriceOracle {
    uint256 public price;
    uint256 public spread;
    bool public isValid;

    constructor() {
        price = 0;
        spread = 0;
        isValid = true;
    }

    function setSpread(uint256 spread_) external {
        spread = spread_;
    }

    function setIsValid(bool newValue) external {
        isValid = newValue;
    }

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function getPrice()
        external
        view
        override
        returns (bool isValid_, uint256 safePrice, uint256 minUnsafePrice, uint256 maxUnsafePrice)
    {
        isValid_ = isValid;
        safePrice = price;
        minUnsafePrice = price - spread;
        maxUnsafePrice = price + spread;
    }
}
