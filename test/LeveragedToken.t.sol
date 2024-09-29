// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";

import { Ownable } from "@solady/auth/Ownable.sol";
import { OwnableRoles } from "@solady/auth/OwnableRoles.sol";

import { LeveragedToken_v1 } from "src/minter/LeveragedToken_v1.sol";
import { IMintable, IBurnable, IBurnableFrom } from "src/minter/IMintable.sol";
import { deployedSepolia } from "test/deployed.sol";

contract TestLeveragedTokensSetUp is Test {
    using ECDSA for bytes32;
    string name = "Leveraged wstETH against BaoUSD";
    string symbol = "BaoUSDLwstETH";

    bytes4 Unauthorized_selector = bytes4(keccak256("Unauthorized()"));

    address leveragedImpl;
    LeveragedToken_v1 leveragedToken;
    address minter;
    address owner;
    address user;
    Vm.Wallet userWallet;
    address user2;

    uint256 minterRole;

    function setUpFork() public virtual {}

    function setUp_impl() internal {
        leveragedImpl = address(new LeveragedToken_v1());
    }

    function setUp_owner() internal {
        owner = vm.createWallet("owner").addr;
    }

    function setUp_proxy() internal {
        name = "Leveraged wstETH against BaoUSD";
        symbol = "BaoUSDLwstETH";
        leveragedToken = LeveragedToken_v1(
            UnsafeUpgrades.deployUUPSProxy(
                leveragedImpl, //"LeveragedToken_v1.sol",
                abi.encodeCall(LeveragedToken_v1.initialize, (owner, name, symbol))
            )
        );
    }

    function setUpContract() public virtual {
        setUp_owner();
        setUp_impl();
        setUp_proxy();
    }

    function setUp() public virtual {
        setUpFork();

        minter = vm.createWallet("minter").addr;
        userWallet = vm.createWallet("user");
        user = userWallet.addr;
        user2 = vm.createWallet("user2").addr;

        setUpContract();

        minterRole = leveragedToken.MINTER_ROLE();
    }

    function setUpMinterAccess() internal {
        vm.expectEmit();
        emit OwnableRoles.RolesUpdated(minter, minterRole);
        vm.prank(owner);
        leveragedToken.grantRoles(minter, minterRole);
    }
}

contract TestLeveragedToken0 is TestLeveragedTokensSetUp {
    function setUp() public override {}

    function test_setUp() public {
        super.setUp();
    }
}

contract TestLeveragedToken is TestLeveragedTokensSetUp {
    function test_initEventsImpl() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        setUp_impl();
    }

    function test_initEventsProxy() public {
        setUp_impl();
        vm.expectEmit();
        emit IERC1967.Upgraded(leveragedImpl);
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call
        setUp_proxy();
    }

    function test_init() public {
        // expect a revert if initialize called twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        leveragedToken.initialize(address(this), name, symbol);

        // check the data has been set up correctly
        assertEq(leveragedToken.name(), name, "wrong name");
        assertEq(leveragedToken.symbol(), symbol, "wrong symbol");
        assertEq(leveragedToken.decimals(), 18, "wrong decimals");
        assertEq(leveragedToken.totalSupply(), 0, "nothing minted yet");

        // admin role
        assertNotEq(leveragedToken.owner(), address(this), "this should not be admin");
        assertEq(leveragedToken.owner(), owner, "owner should be admin");

        // minter role
        assertFalse(leveragedToken.hasAnyRole(address(this), minterRole), "this should not be minter");
        assertFalse(leveragedToken.hasAnyRole(owner, minterRole), "owner should not be minter");
        assertFalse(leveragedToken.hasAnyRole(minter, minterRole), "minter should not be minter (yet)");
    }

    function test_mintburn() public {
        // non-minter mint - minter
        vm.expectRevert(Unauthorized_selector);
        vm.prank(minter);
        leveragedToken.mint(address(this), 1 ether);
        assertEq(leveragedToken.totalSupply(), 0, "nothing minted yet");
        vm.expectRevert(Unauthorized_selector);
        vm.prank(minter);
        leveragedToken.burnFrom(address(this), 1 ether);

        // non-minter mint - owner
        vm.expectRevert(Unauthorized_selector);
        vm.prank(owner);
        leveragedToken.mint(address(this), 1 ether);
        assertEq(leveragedToken.totalSupply(), 0, "nothing minted yet");

        vm.expectRevert(Unauthorized_selector);
        vm.prank(owner);
        leveragedToken.burnFrom(address(this), 1 ether);

        // minter now is minter
        assertEq(leveragedToken.balanceOf(address(this)), 0, "should have none");
        vm.expectRevert(Unauthorized_selector);
        leveragedToken.grantRoles(minter, minterRole);

        setUpMinterAccess();

        // burn when none
        vm.startPrank(minter);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 2 ether)
        );
        leveragedToken.burnFrom(address(this), 2 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, minter, 0, 2 ether));
        leveragedToken.burn(2 ether);

        // mint
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(0), address(this), 2 ether);
        leveragedToken.mint(address(this), 2 ether);
        assertEq(leveragedToken.totalSupply(), 2 ether, "2 ether minted");
        assertEq(leveragedToken.balanceOf(address(this)), 2 ether, "should have 2 ether");
        leveragedToken.mint(minter, 2 ether);
        assertEq(leveragedToken.totalSupply(), 4 ether, "4 ether minted");
        assertEq(leveragedToken.balanceOf(minter), 2 ether, "should have 2 ether");

        // burn too much
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 2 ether, 3 ether)
        );
        leveragedToken.burnFrom(address(this), 3 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, minter, 2 ether, 3 ether)
        );
        leveragedToken.burn(3 ether);

        // burn when some.
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(this), address(0), 1 ether);
        leveragedToken.burnFrom(address(this), 1 ether);
        assertEq(leveragedToken.totalSupply(), 3 ether, "3 ether left now");
        assertEq(leveragedToken.balanceOf(address(this)), 1 ether, "should now have 1");
        leveragedToken.burn(1 ether);
        assertEq(leveragedToken.totalSupply(), 2 ether, "2 ether left now");
        assertEq(leveragedToken.balanceOf(minter), 1 ether, "should now have 1");

        vm.stopPrank();
    }

    function test_transfer() public {
        setUpMinterAccess();

        // transfer when none
        assertEq(leveragedToken.balanceOf(address(this)), 0, "start with none");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1 ether)
        );
        leveragedToken.transfer(user, 1 ether);

        // mint some to this
        vm.prank(minter);
        leveragedToken.mint(address(this), 10 ether);
        assertEq(leveragedToken.balanceOf(address(this)), 10 ether, "start with none");

        // transfer to user
        assertEq(leveragedToken.balanceOf(user), 0, "user starts with none");
        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(address(this), user, 1 ether);
        leveragedToken.transfer(user, 1 ether);
        assertEq(leveragedToken.balanceOf(address(this)), 9 ether, "moved 1");
        assertEq(leveragedToken.balanceOf(user), 1 ether, "received 1");
    }

    function test_allowance() public {
        setUpMinterAccess();
        assertEq(leveragedToken.balanceOf(user), 0, "user starts with none");
        assertEq(leveragedToken.balanceOf(user2), 0, "user starts with none");
        assertEq(leveragedToken.balanceOf(address(this)), 0, "user starts with none");

        // try when no no allowance
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1 ether)
        );
        leveragedToken.transferFrom(user, user2, 1 ether);

        vm.prank(user);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(user, address(this), 1 ether);
        leveragedToken.approve(address(this), 1 ether);
        assertEq(leveragedToken.allowance(user, address(this)), 1 ether, "should have allowance");

        // try when no no balance
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, 0, 1 ether));
        leveragedToken.transferFrom(user, user2, 1 ether);

        // mint some to user
        vm.prank(minter);
        leveragedToken.mint(user, 10 ether);
        assertEq(leveragedToken.balanceOf(user), 10 ether, "start with none");

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(user, user2, 1 ether);
        leveragedToken.transferFrom(user, user2, 1 ether);
        assertEq(leveragedToken.balanceOf(user), 9 ether, "moved 1");
        assertEq(leveragedToken.balanceOf(user2), 1 ether, "received 1");

        // transfer with no allowance again
        assertEq(leveragedToken.allowance(user, address(this)), 0, "should have no allowance");
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1 ether)
        );
        leveragedToken.transferFrom(user, user2, 1 ether);

        vm.startPrank(user);
        uint256 deadline = block.timestamp + 1000;
        bytes32 digest = keccak256(
            abi.encodePacked(
                hex"1901",
                leveragedToken.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        user,
                        address(this),
                        1 ether,
                        leveragedToken.nonces(user),
                        deadline
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userWallet.privateKey, digest);
        vm.expectEmit(true, true, false, true);
        emit IERC20.Approval(user, address(this), 1 ether);
        leveragedToken.permit(user, address(this), 1 ether, deadline, v, r, s);
        vm.stopPrank();
        assertEq(leveragedToken.allowance(user, address(this)), 1 ether, "should have allowance");

        vm.expectEmit(true, true, false, true);
        emit IERC20.Transfer(user, user2, 1 ether);
        leveragedToken.transferFrom(user, user2, 1 ether);
        assertEq(leveragedToken.balanceOf(user), 8 ether, "moved another 1");
        assertEq(leveragedToken.balanceOf(user2), 2 ether, "received another 1");
    }

    function test_introspection() public view {
        assertTrue(leveragedToken.supportsInterface(type(IERC20).interfaceId), "should support IERC20");
        assertTrue(leveragedToken.supportsInterface(type(IERC20Metadata).interfaceId), "should support IERC20Metadata");
        assertTrue(leveragedToken.supportsInterface(type(IMintable).interfaceId), "should support IMinter");
        assertTrue(leveragedToken.supportsInterface(type(IBurnable).interfaceId), "should support IBurnable");
        assertTrue(leveragedToken.supportsInterface(type(IBurnableFrom).interfaceId), "should support IBurnableFrom");
        assertFalse(leveragedToken.supportsInterface(bytes4(0)), "doesn't support 0");
    }
}

contract Test_LeveragedToken_badDeploy is Test {
    function test_zeroOwner() public {
        string memory name = "leveraged";
        string memory symbol = "BaoUSDLwstETH";

        address owner = vm.createWallet("owner").addr;

        UnsafeUpgrades.deployUUPSProxy(
            address(new LeveragedToken_v1()), //"LeveragedToken_v1.sol",
            abi.encodeCall(LeveragedToken_v1.initialize, (owner, name, symbol))
        );

        address lt = address(new LeveragedToken_v1());
        vm.expectRevert(Ownable.NewOwnerIsZeroAddress.selector);
        UnsafeUpgrades.deployUUPSProxy(
            lt, //"LeveragedToken_v1.sol",
            abi.encodeCall(LeveragedToken_v1.initialize, (address(0), name, symbol))
        );
    }
}
/*
contract TestLeveragedToken_sepolia is TestLeveragedToken {
    function setUpFork() public override {
        vm.createSelectFork(vm.rpcUrl("sepolia"), deployedSepolia.blockNumber); // pin to a block for speed (1-July-2024, proxy update block)
    }

    function setUpContract() public override {
        // vm.rpcUrl("sepolia");
        name = "BaoMinter BaoUSD-wstETH";
        symbol = "BaoUSD-wstETH";
        owner = deployedSepolia.owner;
        leveragedToken = LeveragedToken_v1(deployedSepolia.BaoUSDxwstETH);
    }
}
*/
