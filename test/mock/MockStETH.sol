// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockStETH
/// @notice Mock stETH contract that implements submit function
/// @dev Simulates Lido's stETH submit function
contract MockStETH is ERC20 {
    constructor() ERC20("Mock stETH", "stETH") {}

    /// @notice Submit ETH and receive stETH
    /// @return Amount of stETH received
    function submit(address /* referral */) external payable returns (uint256) {
        uint256 amount = msg.value;
        _mint(msg.sender, amount);
        return amount;
    }

    /// @notice Allow contract to receive ETH
    receive() external payable {}
}
