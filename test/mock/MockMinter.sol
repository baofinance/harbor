// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TokenHolder} from "@bao/TokenHolder.sol";

contract MockToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000 ether);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockMinter is TokenHolder {
    address public immutable WRAPPED_COLLATERAL_TOKEN;
    address public immutable PEGGED_TOKEN;
    address public immutable LEVERAGED_TOKEN;

    uint256 public constant ZERO_FEE_ROLE = 1;
    uint256 public constant HARVESTER_ROLE = 2;

    uint256 private _harvestable;
    uint256 private _collateralRatio;
    uint256 private _peggedTokenBalance;

    constructor() {
        WRAPPED_COLLATERAL_TOKEN = address(new MockToken("Mock Wrapped", "MWRAP"));
        PEGGED_TOKEN = address(new MockToken("Mock Pegged", "MPEG"));
        LEVERAGED_TOKEN = address(new MockToken("Mock Leveraged", "MLEV"));

        _collateralRatio = 150 ether / 100; // 150%
        _peggedTokenBalance = 100 ether;
    }

    function setHarvestable(uint256 amount) external {
        _harvestable = amount;
    }

    function setCollateralRatio(uint256 ratio) external {
        _collateralRatio = ratio;
    }

    function setPeggedTokenBalance(uint256 balance) external {
        _peggedTokenBalance = balance;
    }

    function harvestable() external view returns (uint256) {
        return _harvestable;
    }

    function collateralRatio() external view returns (uint256) {
        return _collateralRatio;
    }

    function stabilityCollateralRatio() external pure returns (uint256) {
        return 130 ether / 100; // 130%
    }

    function redeemPeggedForCollateralRatio(uint256) external pure returns (uint256) {
        return 2 ether;
    }

    function swapPeggedForLeveragedForCollateralRatio(uint256) external pure returns (uint256) {
        return 1.5 ether;
    }

    function freeRedeemPeggedToken(uint256, address) external pure returns (uint256) {
        // Simulate successful redemption
        return 1 ether;
    }

    function freeSwapPeggedForLeveraged(uint256, address) external pure returns (uint256) {
        // Simulate successful swap
        return 1 ether;
    }

    function peggedTokenBalance() external view returns (uint256) {
        return _peggedTokenBalance;
    }

    // TokenHolder override
    function _checkSweeper() internal view override {
        // Allow anyone to sweep for testing
    }
}
