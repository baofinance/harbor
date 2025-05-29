// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";
import {IBurnable2Arg} from "@bao/interfaces/IBurnable2Arg.sol";
import {IBurnableFrom} from "@bao/interfaces/IBurnableFrom.sol";

contract MockERC20 is ERC20, IMintable, IBurnable2Arg {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }
}

// TODO: make mocks for the other interfaces and test them with the minter mint pegged
