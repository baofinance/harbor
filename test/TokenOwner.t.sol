// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
//import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

import { Token } from "src/common/Token.sol";
import { TokenOwner } from "src/common/TokenOwner.sol";

import { deployed } from "test/deployed.sol";

contract DerivedTokenOwner is Initializable, TokenOwner {
    function initialize(address owner) public initializer {
        __BaoAccessControl_init(owner);
    }
}

contract Test_TokenOwner is Test {
    using SafeERC20 for IERC20;
    address token1 = deployed.BaoUSD;
    address token2 = deployed.wstETH;
    address tokenNotERC20 = vm.createWallet("tokenNotERC20").addr; // not an ERC20 token

    address bonusReceiver;
    address owner;

    DerivedTokenOwner tokenOwner;
    bytes32 ownerRole = 0;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 19210000);
        tokenNotERC20 = vm.createWallet("tokenNotERC20").addr; // not an ERC20 token
        bonusReceiver = vm.createWallet("bonusReceiver").addr;
        owner = vm.createWallet("owner").addr;

        tokenOwner = new DerivedTokenOwner();
        tokenOwner.initialize(owner);
    }

    function _balanceOf(address token, address who) private view returns (uint256) {
        if (token == address(0)) {
            return who.balance;
        } else {
            return IERC20(token).balanceOf(who);
        }
    }

    function _deal(address token, address to, uint256 amount) internal {
        if (token == address(0)) {
            vm.deal(to, amount);
        } else {
            deal(token, to, amount);
        }
    }

    function test_access() public {
        // not anyone can withdraw funds
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ownerRole)
        );
        tokenOwner.transferToken(token1, bonusReceiver, 1 ether);
    }

    function test_transfer() public {
        // we assume all tokens are ERC20
        address[2] memory tokens = [token2, token1];
        for (uint i = 0; i < tokens.length; i++) {
            // make sure nothing has a balance of any bonus tokens
            assertEq(_balanceOf(tokens[i], bonusReceiver), 0);
            assertEq(_balanceOf(tokens[i], address(tokenOwner)), 0);

            // when none
            // BaoUSD is one minimalist token!
            if (tokens[i] == deployed.BaoUSD) vm.expectRevert("SafeMath: subtraction underflow");
            else vm.expectRevert("ERC20: transfer amount exceeds balance");
            vm.prank(owner);
            tokenOwner.transferToken(tokens[i], bonusReceiver, 1 ether);
            //----------------------------------------------------------------------------
            assertEq(_balanceOf(tokens[i], bonusReceiver), 0 ether);
            assertEq(_balanceOf(tokens[i], address(tokenOwner)), 0 ether);

            // add some funds - anyone can do this
            deal(tokens[i], address(tokenOwner), 3 ether);
            assertEq(_balanceOf(tokens[i], address(tokenOwner)), 3 ether);

            // request less than some
            vm.expectEmit(true, true, true, true);
            emit IERC20.Transfer(address(tokenOwner), bonusReceiver, 1 ether);
            vm.prank(owner);
            tokenOwner.transferToken(tokens[i], bonusReceiver, 1 ether);
            //----------------------------------------------------------------------------
            assertEq(_balanceOf(tokens[i], bonusReceiver), 1 ether);
            assertEq(_balanceOf(tokens[i], address(tokenOwner)), 2 ether);

            // request more than some
            if (tokens[i] == deployed.BaoUSD) vm.expectRevert("SafeMath: subtraction underflow");
            else vm.expectRevert("ERC20: transfer amount exceeds balance");
            vm.prank(owner);
            tokenOwner.transferToken(tokens[i], bonusReceiver, 3 ether);
            //----------------------------------------------------------------------------
            assertEq(_balanceOf(tokens[i], bonusReceiver), 1 ether);
            assertEq(_balanceOf(tokens[i], address(tokenOwner)), 2 ether);

            // withdraw it all
            // withdraw
            vm.expectEmit(true, true, true, true);
            emit IERC20.Transfer(address(tokenOwner), bonusReceiver, 2 ether);
            vm.prank(owner);
            tokenOwner.transferToken(tokens[i], bonusReceiver, type(uint256).max);
            //----------------------------------------------------------------------------
            assertEq(_balanceOf(tokens[i], bonusReceiver), 3 ether);
            assertEq(_balanceOf(tokens[i], address(tokenOwner)), 0 ether);
        }
    }

    // TODO: create a test file for Token and TokenOwner and test it (below and above0 there, once for all derived classes
    function test_badInputs() public {
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, token1));
        vm.prank(owner);
        tokenOwner.transferToken(token1, address(this), 0 ether);

        vm.expectRevert(Token.ZeroAddress.selector);
        vm.prank(owner);
        tokenOwner.transferToken(token1, address(0), 1 ether);
    }
}
