// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

//import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {Token} from "@bao/Token.sol";
import {ITokenHolder} from "@bao/interfaces/ITokenHolder.sol";
import {TokenDistributor_v1} from "src/minter/TokenDistributor_v1.sol";
import {ITokenDistributor} from "src/interfaces/ITokenDistributor.sol";

import {Deployed} from "@bao/Deployed.sol";

import {Array} from "test/Array.sol";

contract TestTokenDistributorSetUp is Test, Array {
    using ECDSA for bytes32;

    address tokenDistributor;

    address owner;
    string name;
    address token1 = Deployed.wstETH;
    address token2 = Deployed.BaoUSD;
    address token3 = Deployed.BaoETH;

    address claimer;

    address recipient1;
    address recipient2;
    address recipient3;

    function setUpFork() internal virtual {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 19210000);

        owner = vm.createWallet("owner").addr;
        claimer = vm.createWallet("claimer").addr;
    }

    function setUpContract() internal virtual {
        name = "test distributor";
        tokenDistributor = address(
            TokenDistributor_v1(
                UnsafeUpgrades.deployUUPSProxy(
                    address(new TokenDistributor_v1()), //"TokenDistributor_v1.sol",
                    abi.encodeCall(TokenDistributor_v1.initialize, (owner, name))
                )
            )
        );
        IBaoOwnable(tokenDistributor).transferOwnership(owner);
    }

    function setUp() public virtual {
        setUpFork();
        setUpContract();

        recipient1 = vm.createWallet("recipient1").addr;
        recipient2 = vm.createWallet("recipient2").addr;
        recipient3 = vm.createWallet("recipient3").addr;

        token1 = Deployed.wstETH;
        token2 = Deployed.BaoUSD;
        token3 = Deployed.BaoETH;

        uint256 claimerRole = ITokenDistributor(tokenDistributor).CLAIMER_ROLE();
        vm.prank(owner);
        IBaoRoles(tokenDistributor).grantRoles(claimer, claimerRole);
    }
}
contract TestTokenDistributorInitEvents is TestTokenDistributorSetUp {
    function test_initEvents() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        address impl = address(new TokenDistributor_v1());

        vm.expectEmit();
        emit IERC1967.Upgraded(impl);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call
        UnsafeUpgrades.deployUUPSProxy(
            impl, //"TokenDistributor_v1.sol",
            abi.encodeCall(TokenDistributor_v1.initialize, (owner, "test init"))
        );

        // second proxy for the same implementation - this works because the state is in the proxy
        vm.expectEmit();
        emit IERC1967.Upgraded(impl);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        vm.expectEmit();
        emit Initializable.Initialized(1);
        UnsafeUpgrades.deployUUPSProxy(
            impl, //"TokenDistributor_v1.sol",
            abi.encodeCall(TokenDistributor_v1.initialize, (owner, "test init"))
        );
    }
}

contract TestTokenDistributor is TestTokenDistributorSetUp {
    using SafeERC20 for IERC20;

    function test_init() public {
        // expect a revert if initialize called twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        TokenDistributor_v1(tokenDistributor).initialize(address(this), "second init");

        // IERC165
        IERC165(tokenDistributor).supportsInterface(type(ITokenDistributor).interfaceId);
        IERC165(tokenDistributor).supportsInterface(type(IBaoOwnable).interfaceId);
        IERC165(tokenDistributor).supportsInterface(type(IBaoRoles).interfaceId);
        IERC165(tokenDistributor).supportsInterface(type(ITokenHolder).interfaceId);

        // name
        assertEq(ITokenDistributor(tokenDistributor).name(), name);

        // check the data has been set up correctly
        assertEq(IBaoOwnable(tokenDistributor).owner(), owner, "owner should be admin");

        // claimer role
        assertTrue(
            IBaoRoles(tokenDistributor).hasAnyRole(claimer, ITokenDistributor(tokenDistributor).CLAIMER_ROLE()),
            "this should not be a claimer"
        );

        // tokens
        assertEq(ITokenDistributor(tokenDistributor).tokens().length, 0, "no tokens yet");

        // recipients
        (address[] memory recipients_, uint256[] memory shares_, uint256 totalShares) = ITokenDistributor(
            tokenDistributor
        ).distribution();
        assertEq(recipients_.length, 0);
        assertEq(shares_.length, 0);
        assertEq(totalShares, 0);
    }

    function test_access() public {
        // access to protected functions
        // admin role
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        ITokenDistributor(tokenDistributor).addToken(address(0));

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        ITokenDistributor(tokenDistributor).removeToken(address(0));

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        ITokenDistributor(tokenDistributor).setDistribution(aa(), ua());

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        ITokenDistributor(tokenDistributor).addRecipient(address(0), 0);

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        ITokenDistributor(tokenDistributor).removeRecipient(address(0));

        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        ITokenHolder(tokenDistributor).sweep(address(0), 0, address(0));

        // claimer roles
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        ITokenDistributor(tokenDistributor).distribute();
    }

    function test_config() public {
        // tokens
        assertEq(ITokenDistributor(tokenDistributor).tokens().length, 0, "some tokens");

        // recipients
        (address[] memory recipients, uint256[] memory shares, uint256 totalShares) = ITokenDistributor(
            tokenDistributor
        ).distribution();
        assertEq(recipients.length, 0);
        assertEq(shares.length, 0);
        assertEq(totalShares, 0);

        vm.startPrank(owner);
        // bad inputs
        vm.expectRevert(abi.encodeWithSelector(ITokenDistributor.RecipientsAndSharesDifferentSizes.selector, 2, 1));
        ITokenDistributor(tokenDistributor).setDistribution(aa(address(0), address(0)), ua(0));

        vm.expectRevert(abi.encodeWithSelector(ITokenDistributor.RecipientsAndSharesDifferentSizes.selector, 1, 2));
        ITokenDistributor(tokenDistributor).setDistribution(aa(address(0)), ua(0, 0));

        vm.expectRevert(Token.ZeroAddress.selector);
        ITokenDistributor(tokenDistributor).setDistribution(aa(recipient1, address(0)), ua(10, 20));

        vm.expectRevert(abi.encodeWithSelector(ITokenDistributor.ShareAmountIsZero.selector, recipient1));
        ITokenDistributor(tokenDistributor).setDistribution(aa(recipient1), ua(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                ITokenDistributor.ShareAmountIsTooHigh.selector,
                recipient1,
                uint256(type(uint64).max) + 1
            )
        );
        ITokenDistributor(tokenDistributor).setDistribution(aa(recipient1), ua(uint256(type(uint64).max) + 1));
        vm.expectRevert(abi.encodeWithSelector(ITokenDistributor.DuplicateRecipient.selector, recipient1));
        ITokenDistributor(tokenDistributor).setDistribution(aa(recipient1, recipient1), ua(1, 2));
        vm.expectRevert(abi.encodeWithSelector(ITokenDistributor.DuplicateRecipient.selector, recipient2));
        ITokenDistributor(tokenDistributor).setDistribution(aa(recipient1, recipient2, recipient2), ua(1, 2, 3));
        vm.expectRevert(abi.encodeWithSelector(ITokenDistributor.DuplicateRecipient.selector, recipient1));
        ITokenDistributor(tokenDistributor).setDistribution(
            aa(recipient1, recipient2, recipient3, recipient1),
            ua(1, 2, 3, 1)
        );
        vm.expectRevert(abi.encodeWithSelector(ITokenDistributor.DuplicateRecipient.selector, recipient3));
        ITokenDistributor(tokenDistributor).setDistribution(
            aa(recipient1, recipient2, recipient3, recipient3),
            ua(1, 2, 2, 3)
        );

        // addresses
        ITokenDistributor(tokenDistributor).setDistribution(aa(recipient1), ua(10));
        (recipients, shares, totalShares) = ITokenDistributor(tokenDistributor).distribution();
        assertEq(recipients.length, 1);
        assertEq(shares.length, recipients.length);
        assertEq(recipients[0], recipient1);
        assertEq(shares[0], 10);
        assertEq(totalShares, 10);

        // add three to one
        ITokenDistributor(tokenDistributor).setDistribution(aa(recipient1, recipient2, recipient3), ua(100, 200, 300));
        (recipients, shares, totalShares) = ITokenDistributor(tokenDistributor).distribution();
        assertEq(recipients.length, 3);
        assertEq(shares.length, recipients.length);
        assertEq(recipients[0], recipient1);
        assertEq(recipients[1], recipient2);
        assertEq(recipients[2], recipient3);
        assertEq(shares[0], 100);
        assertEq(shares[1], 200);
        assertEq(shares[2], 300);
        assertEq(totalShares, 600);

        // take away one
        ITokenDistributor(tokenDistributor).setDistribution(aa(recipient1, recipient2), ua(1, 2));
        (recipients, shares, totalShares) = ITokenDistributor(tokenDistributor).distribution();
        assertEq(recipients.length, 2);
        assertEq(shares.length, recipients.length);
        assertEq(recipients[0], recipient1);
        assertEq(recipients[1], recipient2);
        assertEq(shares[0], 1);
        assertEq(shares[1], 2);
        assertEq(totalShares, 3);

        // take all away
        ITokenDistributor(tokenDistributor).setDistribution(aa(), ua());
        (recipients, shares, totalShares) = ITokenDistributor(tokenDistributor).distribution();
        assertEq(recipients.length, 0);
        assertEq(shares.length, recipients.length);
        assertEq(totalShares, 0);

        // now test the individual adding and removing
        ITokenDistributor(tokenDistributor).removeRecipient(recipient1);
        (recipients, shares, totalShares) = ITokenDistributor(tokenDistributor).distribution();
        assertEq(recipients.length, 0);
        assertEq(shares.length, recipients.length);
        assertEq(totalShares, 0);

        ITokenDistributor(tokenDistributor).addRecipient(recipient1, 10);
        (recipients, shares, totalShares) = ITokenDistributor(tokenDistributor).distribution();
        assertEq(recipients.length, 1);
        assertEq(shares.length, recipients.length);
        assertEq(recipients[0], recipient1);
        assertEq(shares[0], 10);
        assertEq(totalShares, 10);

        ITokenDistributor(tokenDistributor).removeRecipient(recipient1);
        (recipients, shares, totalShares) = ITokenDistributor(tokenDistributor).distribution();
        assertEq(recipients.length, 0);
        assertEq(shares.length, recipients.length);
        assertEq(totalShares, 0);

        ITokenDistributor(tokenDistributor).addRecipient(recipient1, 10);
        (recipients, shares, totalShares) = ITokenDistributor(tokenDistributor).distribution();
        assertEq(recipients.length, 1);
        assertEq(shares.length, recipients.length);
        assertEq(recipients[0], recipient1);
        assertEq(shares[0], 10);
        assertEq(totalShares, 10);

        ITokenDistributor(tokenDistributor).addRecipient(recipient2, 20);
        (recipients, shares, totalShares) = ITokenDistributor(tokenDistributor).distribution();
        assertEq(recipients.length, 2);
        assertEq(shares.length, recipients.length);
        assertEq(recipients[0], recipient1);
        assertEq(recipients[1], recipient2);
        assertEq(shares[0], 10);
        assertEq(shares[1], 20);
        assertEq(totalShares, 30);

        ITokenDistributor(tokenDistributor).addRecipient(recipient2, 200);
        (recipients, shares, totalShares) = ITokenDistributor(tokenDistributor).distribution();
        assertEq(recipients.length, 2);
        assertEq(shares.length, recipients.length);
        assertEq(recipients[0], recipient1);
        assertEq(recipients[1], recipient2);
        assertEq(shares[0], 10);
        assertEq(shares[1], 200);
        assertEq(totalShares, 210);

        ITokenDistributor(tokenDistributor).removeRecipient(recipient1);
        (recipients, shares, totalShares) = ITokenDistributor(tokenDistributor).distribution();
        assertEq(recipients.length, 1);
        assertEq(shares.length, recipients.length);
        assertEq(recipients[0], recipient2);
        assertEq(shares[0], 200);
        assertEq(totalShares, 200);

        ITokenDistributor(tokenDistributor).setDistribution(aa(recipient1), ua(10));

        // tokens
        vm.expectRevert(Token.ZeroAddress.selector);
        ITokenDistributor(tokenDistributor).addToken(address(0));

        vm.expectRevert(abi.encodeWithSelector(Token.NotContractAddress.selector, recipient1));
        ITokenDistributor(tokenDistributor).addToken(recipient1);

        vm.expectRevert(abi.encodeWithSelector(Token.NotERC20Token.selector, address(this)));
        ITokenDistributor(tokenDistributor).addToken(address(this));

        assertEq(ITokenDistributor(tokenDistributor).tokens().length, 0);
        ITokenDistributor(tokenDistributor).addToken(token1);
        assertEq(ITokenDistributor(tokenDistributor).tokens().length, 1);
        assertEq(ITokenDistributor(tokenDistributor).tokens()[0], token1);

        // adding the same token tiwce has no effect
        ITokenDistributor(tokenDistributor).addToken(token1);
        assertEq(ITokenDistributor(tokenDistributor).tokens().length, 1);
        assertEq(ITokenDistributor(tokenDistributor).tokens()[0], token1);

        ITokenDistributor(tokenDistributor).removeToken(token1);
        assertEq(ITokenDistributor(tokenDistributor).tokens().length, 0);

        ITokenDistributor(tokenDistributor).addToken(token1);
        assertEq(ITokenDistributor(tokenDistributor).tokens().length, 1);
        assertEq(ITokenDistributor(tokenDistributor).tokens()[0], token1);

        ITokenDistributor(tokenDistributor).addToken(token2);
        assertEq(ITokenDistributor(tokenDistributor).tokens().length, 2);
        assertEq(ITokenDistributor(tokenDistributor).tokens()[0], token1);
        assertEq(ITokenDistributor(tokenDistributor).tokens()[1], token2);

        ITokenDistributor(tokenDistributor).removeToken(token2);
        assertEq(ITokenDistributor(tokenDistributor).tokens().length, 1);
        assertEq(ITokenDistributor(tokenDistributor).tokens()[0], token1);

        vm.stopPrank();
    }

    function test_distribute() public {
        assertEq(IERC20(token1).balanceOf(recipient1), 0);
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 0);
        // no tokens or distribution config
        vm.prank(claimer);
        ITokenDistributor(tokenDistributor).distribute();
        assertEq(IERC20(token1).balanceOf(recipient1), 0);
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 0);

        // single token
        vm.prank(owner);
        ITokenDistributor(tokenDistributor).addToken(token1);
        vm.prank(claimer);
        ITokenDistributor(tokenDistributor).distribute();
        assertEq(IERC20(token1).balanceOf(recipient1), 0);
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 0);

        vm.prank(owner);
        ITokenDistributor(tokenDistributor).setDistribution(aa(recipient1), ua(1));
        vm.prank(claimer);
        ITokenDistributor(tokenDistributor).distribute();
        assertEq(IERC20(token1).balanceOf(recipient1), 0);
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 0);

        deal(token1, address(this), 10 ether);
        assertEq(IERC20(token1).balanceOf(address(this)), 10 ether);

        IERC20(token1).safeTransfer(address(tokenDistributor), 1 ether);
        assertEq(IERC20(token1).balanceOf(address(this)), 9 ether);

        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 1 ether);
        vm.prank(claimer);
        ITokenDistributor(tokenDistributor).distribute();
        assertEq(IERC20(token1).balanceOf(recipient1), 1 ether);
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 0);

        // multiple tokens, multiple recipients
        deal(token2, address(this), 12 ether);
        IERC20(token1).safeTransfer(address(tokenDistributor), 6 ether);
        IERC20(token2).safeTransfer(address(tokenDistributor), 12 ether);
        vm.startPrank(owner);
        ITokenDistributor(tokenDistributor).addToken(token2);
        ITokenDistributor(tokenDistributor).addRecipient(recipient2, 2);
        ITokenDistributor(tokenDistributor).addRecipient(recipient3, 3);
        vm.stopPrank();
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 6 ether);
        assertEq(IERC20(token2).balanceOf(address(tokenDistributor)), 12 ether);
        vm.prank(claimer);
        ITokenDistributor(tokenDistributor).distribute();
        assertEq(IERC20(token1).balanceOf(recipient1), 2 ether);
        assertEq(IERC20(token1).balanceOf(recipient2), 2 ether);
        assertEq(IERC20(token1).balanceOf(recipient3), 3 ether);
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 0);
        assertEq(IERC20(token2).balanceOf(recipient1), 2 ether);
        assertEq(IERC20(token2).balanceOf(recipient2), 4 ether);
        assertEq(IERC20(token2).balanceOf(recipient3), 6 ether);
        assertEq(IERC20(token2).balanceOf(address(tokenDistributor)), 0);

        // owner can distribute too
        vm.prank(owner);
        ITokenDistributor(tokenDistributor).distribute();
    }

    function test_sweep() public {
        deal(token1, address(tokenDistributor), 11 ether);
        deal(token2, address(tokenDistributor), 12 ether);

        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 11 ether);
        assertEq(IERC20(token1).balanceOf(recipient1), 0 ether);
        assertEq(IERC20(token1).balanceOf(recipient2), 0 ether);
        assertEq(IERC20(token2).balanceOf(address(tokenDistributor)), 12 ether);
        assertEq(IERC20(token2).balanceOf(recipient1), 0 ether);
        assertEq(IERC20(token2).balanceOf(recipient2), 0 ether);

        // not owner
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        ITokenHolder(tokenDistributor).sweep(token1, 1 ether, recipient1);

        vm.startPrank(owner);

        vm.expectRevert(Token.ZeroAddress.selector);
        ITokenHolder(tokenDistributor).sweep(token1, 1 ether, address(0));

        // a token that is in use
        ITokenDistributor(tokenDistributor).addToken(token1);
        vm.expectRevert(abi.encodeWithSelector(ITokenDistributor.TokenStillInUse.selector, token1));
        ITokenHolder(tokenDistributor).sweep(token1, 1 ether, recipient1);
        ITokenDistributor(tokenDistributor).removeToken(token1);

        //console.log("about to try 1 ether");
        ITokenHolder(tokenDistributor).sweep(token1, 1 ether, recipient1);
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 10 ether);
        assertEq(IERC20(token1).balanceOf(recipient1), 1 ether);
        assertEq(IERC20(token1).balanceOf(recipient2), 0 ether);
        assertEq(IERC20(token2).balanceOf(address(tokenDistributor)), 12 ether);
        assertEq(IERC20(token2).balanceOf(recipient1), 0 ether);
        assertEq(IERC20(token2).balanceOf(recipient2), 0 ether);

        //console.log("about to try -1");
        ITokenHolder(tokenDistributor).sweep(token2, type(uint256).max, recipient2); // 12
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 10 ether);
        assertEq(IERC20(token1).balanceOf(recipient1), 1 ether);
        assertEq(IERC20(token1).balanceOf(recipient2), 0 ether);
        assertEq(IERC20(token2).balanceOf(address(tokenDistributor)), 0 ether);
        assertEq(IERC20(token2).balanceOf(recipient1), 0 ether);
        assertEq(IERC20(token2).balanceOf(recipient2), 12 ether);

        vm.expectRevert("ERC20: transfer amount exceeds balance");
        ITokenHolder(tokenDistributor).sweep(token1, 100 ether, recipient2);

        vm.stopPrank();
    }
}
