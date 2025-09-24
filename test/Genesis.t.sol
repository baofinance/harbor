// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

//import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
// import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockERC20} from "test/mock/MockERC20.sol";

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";
import {Vm} from "forge-std/Vm.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IBurnable2Arg} from "@bao/interfaces/IBurnable2Arg.sol";
import {Minter_v1} from "src/minter/Minter_v1.sol";
import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";
import {ReservePool_v1} from "src/minter/ReservePool_v1.sol";
import {IGenesis} from "src/interfaces/IGenesis.sol";
import {IMinter} from "src/interfaces/IMinter.sol";

import {Genesis_v1} from "src/minter/Genesis_v1.sol";

import {TestMinterSetUp} from "test/Minter_base.t.sol";
import {Token} from "@bao/Token.sol";

import {MockWrappedPriceOracle} from "test/mock/MockWrappedPriceOracle.sol";
import {Array} from "test/Array.sol";

contract Test_GenesisBase is TestMinterSetUp {
    address genesisImpl;
    address genesis;

    address user1;
    address user2;
    address user3;

    /*
    function recipientAddresses() private returns (address[] memory result) {
        result = new address[](recipients.length);
        for (uint i = 0; i < recipients.length; i++) {
            result[i] = recipients[i].addr;
        }
    }
    */

    function setUp() public virtual override {
        super.setUp();

        IMinter.IncentiveConfig memory percent1 = IMinter.IncentiveConfig(
            ua(1 ether),
            ia(1 ether / 100, 1 ether / 100)
        );
        config = IMinter.Config(percent1, percent1, percent1, percent1);

        vm.prank(owner);
        IMinter(minter).updateConfig(config);

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // substitute the wct for better errors
        // wrappedCollateralToken = address(new MockERC20("Collateral", "COLL", 18));

        setUp_genesisImplementation();
        setUp_genesisProxy();
    }

    function setUp_genesisImplementation() internal {
        genesisImpl = address(new Genesis_v1(minter));
    }

    function setUp_genesisProxy() internal {
        // vm.expectEmit();
        // emit IERC1967.Upgraded(genesisImpl);
        // vm.expectEmit();
        // emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        // vm.expectEmit();
        // emit IGenesis.GenesisBegins();
        // vm.expectEmit();
        // emit Initializable.Initialized(1);
        genesis = UnsafeUpgrades.deployUUPSProxy(
            genesisImpl, //"Genesis_v1.sol",
            abi.encodeCall(Genesis_v1.initialize, owner)
        );
        // vm.expectEmit();
        // emit IBaoOwnable.OwnershipTransferred(address(this), owner);
        IBaoOwnable(genesis).transferOwnership(owner);

        // approve genesis to use my collateral
        IERC20(wrappedCollateralToken).approve(genesis, type(uint256).max);
    }

    function test_initEvents() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        setUp_genesisImplementation();

        vm.expectEmit();
        emit IERC1967.Upgraded(genesisImpl);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        vm.expectEmit();
        emit IGenesis.GenesisBegins();
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call
        setUp_genesisProxy();
    }

    function test_init() public {
        // expect a revert if initialize called twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Genesis_v1(genesis).initialize(address(this));

        // check the data has been set up correctly
        assertEq(IBaoOwnable(genesis).owner(), owner, "wrong owner");
        assertEq(IGenesis(genesis).MINTER(), minter, "wrong minter");
        assertEq(IGenesis(genesis).WRAPPED_COLLATERAL_TOKEN(), wrappedCollateralToken, "wrong collateral");
        assertEq(IGenesis(genesis).PEGGED_TOKEN(), peggedToken, "wrong pegged");
        assertEq(IGenesis(genesis).LEVERAGED_TOKEN(), leveragedToken, "wrong leveraged");
        assertEq(IGenesis(genesis).balanceOf(address(this)), 0, "wrong balance");
        assertFalse(IGenesis(genesis).genesisIsEnded());
        vm.expectRevert(IGenesis.GenesisIsNotEnded.selector);
        IGenesis(genesis).claimable(address(this));
    }

    function test_depositWithdraw() public {
        deal(wrappedCollateralToken, address(this), 10 ether);

        assertEq(IGenesis(genesis).balanceOf(user1), 0, "user1 has no genesis tokens");
        assertEq(IGenesis(genesis).balanceOf(user2), 0, "user2 has no genesis tokens");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(user1), 0, "user1 has no collateral tokens");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(user2), 0, "user2 has no collateral tokens");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(genesis), 0, "genesis has no collateral tokens");

        // deposit for 0
        vm.expectRevert(Token.ZeroAddress.selector);
        IGenesis(genesis).deposit(1 ether, address(0));

        // deposit too much
        vm.expectRevert(
            "ERC20: transfer amount exceeds balance"
            // abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 10 ether, 100 ether)
        );
        IGenesis(genesis).deposit(100 ether, user1);
        assertEq(IGenesis(genesis).balanceOf(user1), 0, "user1 still has no genesis tokens");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(genesis), 0, "genesis still has no collateral tokens");

        // first actual deposit
        uint256 thisBalance = IERC20(wrappedCollateralToken).balanceOf(address(this));
        vm.expectEmit();
        emit IGenesis.Deposit(address(this), user1, 1 ether);
        IGenesis(genesis).deposit(1 ether, user1);
        assertEq(IGenesis(genesis).balanceOf(user1), 1 ether, "user1 now has 1 ether genesis tokens");
        assertEq(IGenesis(genesis).balanceOf(user2), 0, "user2 still has no genesis tokens");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(genesis),
            1 ether,
            "genesis now has 1 ether collateral tokens"
        );
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(address(this)),
            thisBalance - 1 ether,
            "this has 1 less collateral"
        );

        IGenesis(genesis).deposit(type(uint256).max, user2);
        assertEq(IGenesis(genesis).balanceOf(user1), 1 ether, "user1 still has 1 ether genesis tokens");
        assertEq(IGenesis(genesis).balanceOf(user2), 9 ether, "user2 now has 2 ether genesis tokens");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(genesis),
            10 ether,
            "genesis now has 10 ether collateral tokens"
        );

        // can't withdraw if none
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user3, 0, 1 ether));
        vm.prank(user3);
        IGenesis(genesis).withdraw(1 ether, user3);

        // can't withdraw none
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, genesis));
        vm.prank(user2);
        IGenesis(genesis).withdraw(0, user2);

        // can't withdraw to zero address
        vm.expectRevert(Token.ZeroAddress.selector);
        vm.prank(user2);
        IGenesis(genesis).withdraw(1 ether, address(0));

        // can withdraw some
        vm.prank(user2);
        vm.expectEmit();
        emit IGenesis.Withdraw(user2, user3, 1 ether);
        IGenesis(genesis).withdraw(1 ether, user3);
        assertEq(IGenesis(genesis).balanceOf(user1), 1 ether);
        assertEq(IGenesis(genesis).balanceOf(user2), 8 ether);
        assertEq(IGenesis(genesis).balanceOf(user3), 0 ether);

        // can't withdraw more
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user2, 8 ether, 9 ether)
        );
        vm.prank(user2);
        IGenesis(genesis).withdraw(9 ether, user2);

        // can withdraw all
        vm.prank(user2);
        IGenesis(genesis).withdraw(type(uint256).max, user2);
        assertEq(IGenesis(genesis).balanceOf(user1), 1 ether);
        assertEq(IGenesis(genesis).balanceOf(user2), 0 ether);
        assertEq(IGenesis(genesis).balanceOf(user3), 0 ether);

        // can't add it unless approved
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        vm.prank(user2);
        IGenesis(genesis).deposit(8 ether, user1);

        // approve it
        vm.prank(user2);
        IERC20(wrappedCollateralToken).approve(genesis, type(uint256).max);
        // and add it back
        vm.prank(user2);
        IGenesis(genesis).deposit(8 ether, user2);
        assertEq(IGenesis(genesis).balanceOf(user1), 1 ether);
        assertEq(IGenesis(genesis).balanceOf(user2), 8 ether);
        assertEq(IGenesis(genesis).balanceOf(user3), 0 ether);

        // try to claim - need to end the genesis & start the claiming first
        vm.expectRevert(IGenesis.GenesisIsNotEnded.selector);
        IGenesis(genesis).claim(user1);

        // end it
        assertFalse(IGenesis(genesis).genesisIsEnded());

        // only owner can call it
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IGenesis(genesis).endGenesis();
        assertFalse(IGenesis(genesis).genesisIsEnded());

        // only minter zero fee access can complete it
        assertFalse(IBaoRoles(minter).hasAnyRole(genesis, zeroFeeRole));
        vm.prank(owner);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IGenesis(genesis).endGenesis();
        assertFalse(IGenesis(genesis).genesisIsEnded());

        // grant zero fee access
        vm.prank(owner);
        IBaoRoles(minter).grantRoles(genesis, zeroFeeRole);
        assertTrue(IBaoRoles(minter).hasAllRoles(genesis, zeroFeeRole));

        // actually end it
        // ------------------------------------------------------------------------------------
        assertEq(IGenesis(genesis).balanceOf(user1), 1 ether, "user1 still has 1 ether genesis tokens");
        assertEq(IGenesis(genesis).balanceOf(user2), 8 ether, "user2 now has 8 ether genesis tokens");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(genesis),
            9 ether,
            "genesis now has 9 ether collateral tokens"
        );
        assertEq(IERC20(peggedToken).balanceOf(genesis), 0 ether, "genesis now has 0 ether pegged tokens");
        assertEq(IERC20(leveragedToken).balanceOf(genesis), 0 ether, "genesis now has 0 ether leveraged tokens");
        assertFalse(IGenesis(genesis).genesisIsEnded());
        vm.prank(owner);
        vm.expectEmit();
        emit IGenesis.GenesisEnds();
        IGenesis(genesis).endGenesis();
        assertEq(IGenesis(genesis).balanceOf(user1), 1 ether, "user1 still has 1 ether genesis tokens");
        assertEq(IGenesis(genesis).balanceOf(user2), 8 ether, "user2 now has 8 ether genesis tokens");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(genesis),
            0 ether,
            "genesis converted it's 9 ether collateral tokens"
        );
        assertEq(IERC20(peggedToken).balanceOf(genesis), 9000 ether, "genesis 5 ether -> pegged tokens");
        assertEq(IERC20(leveragedToken).balanceOf(genesis), 9000 ether, "genesis 5 ether -> leveraged tokens");
        uint256 p;
        uint256 l;
        (p, l) = IGenesis(genesis).claimable(user1);
        assertEq(p, 1000 ether);
        assertEq(l, 1000 ether);
        (p, l) = IGenesis(genesis).claimable(user2);
        assertEq(p, 8000 ether);
        assertEq(l, 8000 ether);
        (p, l) = IGenesis(genesis).claimable(user3);
        assertEq(p, 0 ether);
        assertEq(l, 0 ether);
        assertTrue(IGenesis(genesis).genesisIsEnded());

        // cannot end it again
        vm.expectRevert(IGenesis.GenesisIsEnded.selector);
        vm.prank(owner);
        IGenesis(genesis).endGenesis();

        // cannot deposit once ended
        vm.expectRevert(IGenesis.GenesisIsEnded.selector);
        IGenesis(genesis).deposit(100 ether, user1);

        // cannot withdraw after ended
        vm.prank(user2);
        vm.expectRevert(IGenesis.GenesisIsEnded.selector);
        IGenesis(genesis).withdraw(1 ether, user2);

        // not anyone can claim - only those holding shares
        assertEq(IERC20(peggedToken).balanceOf(user1), 0, "user1 has no pegged");
        assertEq(IERC20(leveragedToken).balanceOf(user1), 0, "user1 has no leveraged");
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, wrappedCollateralToken));
        IGenesis(genesis).claim(user1);
        assertEq(IERC20(peggedToken).balanceOf(user1), 0, "user1 has no pegged");
        assertEq(IERC20(leveragedToken).balanceOf(user1), 0, "user1 has no leveraged");

        // user2 claims
        assertEq(IGenesis(genesis).balanceOf(user2), 8 ether, "user2 still has 9 ether genesis tokens");
        vm.prank(user2);
        vm.expectEmit();
        emit IGenesis.Claim(user2, user1, 8000 ether, 8000 ether);
        IGenesis(genesis).claim(user1);
        assertEq(IGenesis(genesis).balanceOf(user2), 0 ether, "user2 has no genesis tokens");
        assertEq(IERC20(peggedToken).balanceOf(user1), 8000 ether, "user1 has got pegged");
        assertEq(IERC20(leveragedToken).balanceOf(user1), 8000 ether, "user1 has got leveraged");

        // user2 cannot claim again
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, wrappedCollateralToken));
        vm.prank(user2);
        IGenesis(genesis).claim(user2);
    }

    function test_nullGenesis() public {
        vm.prank(owner);
        IGenesis(genesis).endGenesis();
        uint256 p;
        uint256 l;
        (p, l) = IGenesis(genesis).claimable(user1);
        assertEq(p, 0 ether);
        assertEq(l, 0 ether);
    }
}
