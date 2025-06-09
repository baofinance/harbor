// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

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
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
    }

    function burnSignature() external pure returns (string memory) {
        return "burn(address,uint256)";
    }
}

contract MockERC20Burn1Arg is ERC20, IMintable, IBurnable {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(uint256 amount) external {
        _burn(_msgSender(), amount);
    }

    function burnSignature() external pure returns (string memory) {
        return "burn(uint256)";
    }
}

contract MockERC20BurnFrom is ERC20, IMintable, IBurnableFrom {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
    }

    function burnSignature() external pure returns (string memory) {
        return "burnFrom(address,uint256)";
    }
}
