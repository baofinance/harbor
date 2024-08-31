// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import { UnsafeUpgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";
import { Vm } from "forge-std/Vm.sol";

import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Errors } from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IAccessControl } from "@openzeppelin/contracts/access/IAccessControl.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";

import { Token } from "src/common/Token.sol";
import { TokenDistributor_v1 } from "src/minter/TokenDistributor_v1.sol";
import { ITokenDistributor } from "src/minter/ITokenDistributor.sol";

import { Array } from "test/Array.sol";
import { deployed, deployedSepolia } from "test/deployed.sol";

//import "test/clog.sol";

contract Test_TokenDistributorBase is Test, Array {
    using ECDSA for bytes32;
    using SafeERC20 for IERC20;

    TokenDistributor_v1 tokenDistributor;

    address owner;
    string name;
    address token1 = deployed.wstETH;
    address token2 = deployed.BaoUSD;
    address token3 = deployed.BaoETH;

    bytes32 ownerRole;
    bytes32 claimerRole;
    address claimer;

    address recipient1;
    address recipient2;
    address recipient3;

    /*
    function recipientAddresses() private returns (address[] memory result) {
        result = new address[](recipients.length);
        for (uint i = 0; i < recipients.length; i++) {
            result[i] = recipients[i].addr;
        }
    }
    */

    function setUpFork() public virtual {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 19210000);

        token1 = deployed.wstETH;
        token2 = deployed.BaoUSD;
        token3 = deployed.BaoETH;

        owner = vm.createWallet("owner").addr;
    }

    function setUpContract() public virtual {
        name = "test distributor";
        tokenDistributor = TokenDistributor_v1(
            UnsafeUpgrades.deployUUPSProxy(
                address(new TokenDistributor_v1()), //"TokenDistributor_v1.sol",
                abi.encodeCall(TokenDistributor_v1.initialize, (owner, name))
            )
        );
    }

    function setUp() public virtual {
        setUpFork();

        claimer = vm.createWallet("claimer").addr;

        recipient1 = vm.createWallet("recipient1").addr;
        recipient2 = vm.createWallet("recipient2").addr;
        recipient3 = vm.createWallet("recipient3").addr;

        setUpContract();

        ownerRole = tokenDistributor.DEFAULT_ADMIN_ROLE();
        claimerRole = tokenDistributor.CLAIMER_ROLE();
    }

    function test_initEvents() public {
        vm.expectEmit(true, true, true, true);
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        vm.expectEmit(false, false, false, false);
        emit IERC1967.Upgraded(address(0)); // TODO: we don't know the address right now
        vm.expectEmit(true, true, true, false);
        emit IAccessControl.RoleGranted(ownerRole, owner, address(this));
        vm.expectEmit(false, false, false, true);
        emit Initializable.Initialized(1); // from the proxy delegate call
        UnsafeUpgrades.deployUUPSProxy(
            address(new TokenDistributor_v1()), //"TokenDistributor_v1.sol",
            abi.encodeCall(TokenDistributor_v1.initialize, (owner, "test init"))
        );
    }

    function test_init() public {
        // expect a revert if initialize called twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        tokenDistributor.initialize(address(this), "second init");

        // IERC165
        tokenDistributor.supportsInterface(type(ITokenDistributor).interfaceId);
        tokenDistributor.supportsInterface(type(IAccessControl).interfaceId);

        // name
        assertEq(tokenDistributor.name(), name);

        // check the data has been set up correctly
        assertEq(tokenDistributor.owner(), owner, "wrong owner");

        // admin role
        assertFalse(tokenDistributor.hasRole(ownerRole, address(this)), "this should not be admin");
        assertTrue(tokenDistributor.hasRole(ownerRole, owner), "owner should be admin");
        assertFalse(tokenDistributor.hasRole(claimerRole, claimer), "claimer should not be admin");

        // claimer role
        assertFalse(tokenDistributor.hasRole(claimerRole, address(this)), "this should not be a claimer");
        assertFalse(tokenDistributor.hasRole(claimerRole, owner), "owner should not be a claimer");
        assertFalse(tokenDistributor.hasRole(claimerRole, claimer), "claimer should not be a claimer");

        // tokens
        assertEq(tokenDistributor.tokens().length, 0, "some tokens");

        // recipients
        (address[] memory recipients_, uint256[] memory shares_, uint256 totalShares) = tokenDistributor.distribution();
        assertEq(recipients_.length, 0);
        assertEq(shares_.length, 0);
        assertEq(totalShares, 0);

        // access to protected functions
        // admin role
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ownerRole)
        );
        tokenDistributor.addToken(address(0));

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ownerRole)
        );
        tokenDistributor.removeToken(address(0));

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ownerRole)
        );
        tokenDistributor.setDistribution(aa(), ua());

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ownerRole)
        );
        tokenDistributor.addRecipient(address(0), 0);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ownerRole)
        );
        tokenDistributor.removeRecipient(address(0));

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ownerRole)
        );
        tokenDistributor.transferToken(address(0), address(0), 0);

        // claimer roles
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), claimerRole)
        );
        tokenDistributor.distribute();
    }

    function test_config() public {
        // tokens
        assertEq(tokenDistributor.tokens().length, 0, "some tokens");

        // recipients
        (address[] memory recipients, uint256[] memory shares, uint256 totalShares) = tokenDistributor.distribution();
        assertEq(recipients.length, 0);
        assertEq(shares.length, 0);
        assertEq(totalShares, 0);

        vm.startPrank(owner);
        // bad inputs
        vm.expectRevert(abi.encodeWithSelector(TokenDistributor_v1.RecipientsAndSharesDifferentSizes.selector, 2, 1));
        tokenDistributor.setDistribution(aa(address(0), address(0)), ua(0));

        vm.expectRevert(abi.encodeWithSelector(TokenDistributor_v1.RecipientsAndSharesDifferentSizes.selector, 1, 2));
        tokenDistributor.setDistribution(aa(address(0)), ua(0, 0));

        vm.expectRevert(Token.ZeroAddress.selector);
        tokenDistributor.setDistribution(aa(recipient1, address(0)), ua(10, 20));

        vm.expectRevert(abi.encodeWithSelector(TokenDistributor_v1.ShareAmountIsZero.selector, recipient1));
        tokenDistributor.setDistribution(aa(recipient1), ua(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                TokenDistributor_v1.ShareAmountIsTooHigh.selector,
                recipient1,
                uint256(type(uint64).max) + 1
            )
        );
        tokenDistributor.setDistribution(aa(recipient1), ua(uint256(type(uint64).max) + 1));
        vm.expectRevert(abi.encodeWithSelector(TokenDistributor_v1.DuplicateRecipient.selector, recipient1));
        tokenDistributor.setDistribution(aa(recipient1, recipient1), ua(1, 2));
        vm.expectRevert(abi.encodeWithSelector(TokenDistributor_v1.DuplicateRecipient.selector, recipient2));
        tokenDistributor.setDistribution(aa(recipient1, recipient2, recipient2), ua(1, 2, 3));
        vm.expectRevert(abi.encodeWithSelector(TokenDistributor_v1.DuplicateRecipient.selector, recipient1));
        tokenDistributor.setDistribution(aa(recipient1, recipient2, recipient3, recipient1), ua(1, 2, 3, 1));
        vm.expectRevert(abi.encodeWithSelector(TokenDistributor_v1.DuplicateRecipient.selector, recipient3));
        tokenDistributor.setDistribution(aa(recipient1, recipient2, recipient3, recipient3), ua(1, 2, 2, 3));

        // addresses
        tokenDistributor.setDistribution(aa(recipient1), ua(10));
        (recipients, shares, totalShares) = tokenDistributor.distribution();
        assertEq(recipients.length, 1);
        assertEq(shares.length, recipients.length);
        assertEq(recipients[0], recipient1);
        assertEq(shares[0], 10);
        assertEq(totalShares, 10);

        // add three to one
        tokenDistributor.setDistribution(aa(recipient1, recipient2, recipient3), ua(100, 200, 300));
        (recipients, shares, totalShares) = tokenDistributor.distribution();
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
        tokenDistributor.setDistribution(aa(recipient1, recipient2), ua(1, 2));
        (recipients, shares, totalShares) = tokenDistributor.distribution();
        assertEq(recipients.length, 2);
        assertEq(shares.length, recipients.length);
        assertEq(recipients[0], recipient1);
        assertEq(recipients[1], recipient2);
        assertEq(shares[0], 1);
        assertEq(shares[1], 2);
        assertEq(totalShares, 3);

        // take all away
        tokenDistributor.setDistribution(aa(), ua());
        (recipients, shares, totalShares) = tokenDistributor.distribution();
        assertEq(recipients.length, 0);
        assertEq(shares.length, recipients.length);
        assertEq(totalShares, 0);

        // now test the individual adding and removing
        tokenDistributor.removeRecipient(recipient1);
        (recipients, shares, totalShares) = tokenDistributor.distribution();
        assertEq(recipients.length, 0);
        assertEq(shares.length, recipients.length);
        assertEq(totalShares, 0);

        tokenDistributor.addRecipient(recipient1, 10);
        (recipients, shares, totalShares) = tokenDistributor.distribution();
        assertEq(recipients.length, 1);
        assertEq(shares.length, recipients.length);
        assertEq(recipients[0], recipient1);
        assertEq(shares[0], 10);
        assertEq(totalShares, 10);

        tokenDistributor.removeRecipient(recipient1);
        (recipients, shares, totalShares) = tokenDistributor.distribution();
        assertEq(recipients.length, 0);
        assertEq(shares.length, recipients.length);
        assertEq(totalShares, 0);

        tokenDistributor.addRecipient(recipient1, 10);
        (recipients, shares, totalShares) = tokenDistributor.distribution();
        assertEq(recipients.length, 1);
        assertEq(shares.length, recipients.length);
        assertEq(recipients[0], recipient1);
        assertEq(shares[0], 10);
        assertEq(totalShares, 10);

        tokenDistributor.addRecipient(recipient2, 20);
        (recipients, shares, totalShares) = tokenDistributor.distribution();
        assertEq(recipients.length, 2);
        assertEq(shares.length, recipients.length);
        assertEq(recipients[0], recipient1);
        assertEq(recipients[1], recipient2);
        assertEq(shares[0], 10);
        assertEq(shares[1], 20);
        assertEq(totalShares, 30);

        tokenDistributor.addRecipient(recipient2, 200);
        (recipients, shares, totalShares) = tokenDistributor.distribution();
        assertEq(recipients.length, 2);
        assertEq(shares.length, recipients.length);
        assertEq(recipients[0], recipient1);
        assertEq(recipients[1], recipient2);
        assertEq(shares[0], 10);
        assertEq(shares[1], 200);
        assertEq(totalShares, 210);

        tokenDistributor.removeRecipient(recipient1);
        (recipients, shares, totalShares) = tokenDistributor.distribution();
        assertEq(recipients.length, 1);
        assertEq(shares.length, recipients.length);
        assertEq(recipients[0], recipient2);
        assertEq(shares[0], 200);
        assertEq(totalShares, 200);

        tokenDistributor.setDistribution(aa(recipient1), ua(10));

        // tokens
        vm.expectRevert(Token.ZeroAddress.selector);
        tokenDistributor.addToken(address(0));

        vm.expectRevert(abi.encodeWithSelector(Token.NotContractAddress.selector, recipient1));
        tokenDistributor.addToken(recipient1);

        vm.expectRevert(abi.encodeWithSelector(Token.NotERC20Token.selector, address(this)));
        tokenDistributor.addToken(address(this));

        assertEq(tokenDistributor.tokens().length, 0);
        tokenDistributor.addToken(token1);
        assertEq(tokenDistributor.tokens().length, 1);
        assertEq(tokenDistributor.tokens()[0], token1);

        // adding the same token tiwce has no effect
        tokenDistributor.addToken(token1);
        assertEq(tokenDistributor.tokens().length, 1);
        assertEq(tokenDistributor.tokens()[0], token1);

        tokenDistributor.removeToken(token1);
        assertEq(tokenDistributor.tokens().length, 0);

        tokenDistributor.addToken(token1);
        assertEq(tokenDistributor.tokens().length, 1);
        assertEq(tokenDistributor.tokens()[0], token1);

        tokenDistributor.addToken(token2);
        assertEq(tokenDistributor.tokens().length, 2);
        assertEq(tokenDistributor.tokens()[0], token1);
        assertEq(tokenDistributor.tokens()[1], token2);

        tokenDistributor.removeToken(token2);
        assertEq(tokenDistributor.tokens().length, 1);
        assertEq(tokenDistributor.tokens()[0], token1);

        vm.stopPrank();
    }

    function test_distribute() public {
        // no permission to distribute
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), claimerRole)
        );
        tokenDistributor.distribute();
        vm.prank(owner);
        tokenDistributor.grantRole(claimerRole, address(this));

        assertEq(IERC20(token1).balanceOf(recipient1), 0);
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 0);
        // no tokens or distribution config
        tokenDistributor.distribute();
        assertEq(IERC20(token1).balanceOf(recipient1), 0);
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 0);

        // single token
        vm.prank(owner);
        tokenDistributor.addToken(token1);
        tokenDistributor.distribute();
        assertEq(IERC20(token1).balanceOf(recipient1), 0);
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 0);

        vm.prank(owner);
        tokenDistributor.setDistribution(aa(recipient1), ua(1));
        tokenDistributor.distribute();
        assertEq(IERC20(token1).balanceOf(recipient1), 0);
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 0);

        deal(token1, address(this), 10 ether);
        assertEq(IERC20(token1).balanceOf(address(this)), 10 ether);

        IERC20(token1).safeTransfer(address(tokenDistributor), 1 ether);
        assertEq(IERC20(token1).balanceOf(address(this)), 9 ether);

        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 1 ether);
        tokenDistributor.distribute();
        assertEq(IERC20(token1).balanceOf(recipient1), 1 ether);
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 0);

        // multiple tokens, multiple recipients
        deal(token2, address(this), 12 ether);
        IERC20(token1).safeTransfer(address(tokenDistributor), 6 ether);
        IERC20(token2).safeTransfer(address(tokenDistributor), 12 ether);
        vm.startPrank(owner);
        tokenDistributor.addToken(token2);
        tokenDistributor.addRecipient(recipient2, 2);
        tokenDistributor.addRecipient(recipient3, 3);
        vm.stopPrank();
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 6 ether);
        assertEq(IERC20(token2).balanceOf(address(tokenDistributor)), 12 ether);
        tokenDistributor.distribute();
        assertEq(IERC20(token1).balanceOf(recipient1), 2 ether);
        assertEq(IERC20(token1).balanceOf(recipient2), 2 ether);
        assertEq(IERC20(token1).balanceOf(recipient3), 3 ether);
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 0);
        assertEq(IERC20(token2).balanceOf(recipient1), 2 ether);
        assertEq(IERC20(token2).balanceOf(recipient2), 4 ether);
        assertEq(IERC20(token2).balanceOf(recipient3), 6 ether);
        assertEq(IERC20(token2).balanceOf(address(tokenDistributor)), 0);
    }

    function test_transferToken() public {
        deal(token1, address(tokenDistributor), 11 ether);
        deal(token2, address(tokenDistributor), 12 ether);

        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 11 ether);
        assertEq(IERC20(token1).balanceOf(recipient1), 0 ether);
        assertEq(IERC20(token1).balanceOf(recipient2), 0 ether);
        assertEq(IERC20(token2).balanceOf(address(tokenDistributor)), 12 ether);
        assertEq(IERC20(token2).balanceOf(recipient1), 0 ether);
        assertEq(IERC20(token2).balanceOf(recipient2), 0 ether);

        // not owner
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, address(this), ownerRole)
        );
        tokenDistributor.transferToken(token1, recipient1, 1 ether);

        vm.startPrank(owner);

        vm.expectRevert(Token.ZeroAddress.selector);
        tokenDistributor.transferToken(token1, address(0), 1 ether);

        // a token that is in use
        tokenDistributor.addToken(token1);
        vm.expectRevert(abi.encodeWithSelector(TokenDistributor_v1.TokenStillInUse.selector, token1));
        tokenDistributor.transferToken(token1, recipient1, 1 ether);
        tokenDistributor.removeToken(token1);

        //console.log("about to try 1 ether");
        tokenDistributor.transferToken(token1, recipient1, 1 ether);
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 10 ether);
        assertEq(IERC20(token1).balanceOf(recipient1), 1 ether);
        assertEq(IERC20(token1).balanceOf(recipient2), 0 ether);
        assertEq(IERC20(token2).balanceOf(address(tokenDistributor)), 12 ether);
        assertEq(IERC20(token2).balanceOf(recipient1), 0 ether);
        assertEq(IERC20(token2).balanceOf(recipient2), 0 ether);

        //console.log("about to try -1");
        tokenDistributor.transferToken(token2, recipient2, type(uint256).max); // 12
        assertEq(IERC20(token1).balanceOf(address(tokenDistributor)), 10 ether);
        assertEq(IERC20(token1).balanceOf(recipient1), 1 ether);
        assertEq(IERC20(token1).balanceOf(recipient2), 0 ether);
        assertEq(IERC20(token2).balanceOf(address(tokenDistributor)), 0 ether);
        assertEq(IERC20(token2).balanceOf(recipient1), 0 ether);
        assertEq(IERC20(token2).balanceOf(recipient2), 12 ether);

        vm.expectRevert("ERC20: transfer amount exceeds balance");
        tokenDistributor.transferToken(token1, recipient2, 100 ether);

        vm.stopPrank();
    }
}

contract Test_TokenDistributor_sepolia is Test_TokenDistributorBase {
    function setUpFork() public override {
        vm.createSelectFork(vm.rpcUrl("sepolia"), deployedSepolia.blockNumber);
        token1 = deployedSepolia.USDT;
        token2 = deployedSepolia.MAGIC;
        token3 = deployedSepolia.USDC;
    }

    function setUpContract() public override {
        // vm.rpcUrl("sepolia");
        owner = deployedSepolia.owner;
        name = "FeeDistributor";
        tokenDistributor = TokenDistributor_v1(deployedSepolia.FeeDistributor);
    }
}
