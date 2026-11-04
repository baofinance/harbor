// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ConfigPeg} from "@harbor-script/config/pegs/ConfigPeg.sol";

/// @notice Configuration for USD peg.
/// @dev Deployed pegged token: haUSD ("Harbor anchored USD")
/// @dev Used by markets: USD::PAXG, USD::tBTC, USD::wBTC, USD::stETH (mainnet); USD::BTC, USD::stETH (megaeth); USD::wstETH (monad); etc.
contract ConfigPeg_USD is ConfigPeg {
    function peg() public pure virtual override returns (string memory) {
        return "USD";
    }

    function aboutADollarInPegged() public pure virtual override returns (uint256) {
        return 1e18;
    }
}
