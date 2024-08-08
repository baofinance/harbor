// SPDX-License-Identifier: MIT

pragma solidity ^0.8.25;

import { IPriceOracle } from "src/price/IPriceOracle.sol";

contract MockPriceOracle is IPriceOracle {
    uint256 public price;
    uint256 public spread;
    bool public isValid;

    constructor() {
        price = 2000 ether;
        spread = 1 ether;
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
        if (spread >= price) {
            minUnsafePrice = 1; // lowest non-zero price
        } else {
            minUnsafePrice = price - spread;
        }
        maxUnsafePrice = price + spread;
    }
}
