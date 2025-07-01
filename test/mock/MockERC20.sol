// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IMintable} from "@bao/interfaces/IMintable.sol";
import {IBurnable} from "@bao/interfaces/IBurnable.sol";
import {IBurnable2Arg} from "@bao/interfaces/IBurnable2Arg.sol";
import {IBurnableFrom} from "@bao/interfaces/IBurnableFrom.sol";

// MockERC20Base is a base contract for creating mock ERC20 tokens with a specified number of decimals.
abstract contract MockERC20Base is ERC20 {
    uint8 private _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
}

contract MockERC20 is MockERC20Base, IMintable, IBurnable, IBurnableFrom {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20Base(name_, symbol_, decimals_) {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function burn(uint256 amount) external {
        _burn(_msgSender(), amount);
    }

    function burnFrom(address account, uint256 amount) external {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
    }
}

contract MockERC20Burn2Arg is MockERC20Base, IMintable, IBurnable2Arg {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20Base(name_, symbol_, decimals_) {}

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

contract MockERC20Burn1Arg is MockERC20Base, IMintable, IBurnable {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20Base(name_, symbol_, decimals_) {}

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

contract MockERC20BurnFrom is MockERC20Base, IMintable, IBurnableFrom {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20Base(name_, symbol_, decimals_) {}

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
