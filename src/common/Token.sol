// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/*
function totalSupply() external view returns (uint256);
function balanceOf(address account) external view returns (uint256);
function transfer(address to, uint256 value) external returns (bool);
function allowance(address owner, address spender) external view returns (uint256);
function approve(address spender, uint256 value) external returns (bool);
function transferFrom(address from, address to, uint256 value) external returns (bool);
*/

// import {DateUtils} from "DateUtils/DateUtils.sol";
import { console2 as console } from "forge-std/console2.sol";

// Attribution: string basics stolen from OpenZeppelin

library Token {
    function isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    error NotERC20Token(address token);

    function isERC20(address addr) internal returns (bool) {
        if (!isContract(addr)) {
            return false;
        }
        try IERC20(addr).totalSupply() returns (uint256) {
            try IERC20(addr).balanceOf(address(0)) returns (uint256) {
                // If both the calls succeed, check for a transfer
                try IERC20(addr).transfer(address(0), 0) returns (bool) {
                    return true;
                } catch Error(string memory revertMessage) {
                    if (
                        bytes(revertMessage).length > 0 &&
                        keccak256(bytes(revertMessage)) == keccak256("ERC20: transfer to the zero address")
                    ) {
                        return true; // Reverted with ERC20 error message, indicating compliance
                    } else {
                        return false;
                    }
                }
            } catch {
                return false;
            }
        } catch {
            return false;
        }
    }
}
