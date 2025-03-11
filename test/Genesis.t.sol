// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

//import { Upgrades } from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

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
import {LeveragedToken_v1} from "src/minter/LeveragedToken_v1.sol";
import {ReservePool_v1} from "src/minter/ReservePool_v1.sol";
import {IGenesis} from "@interfaces/IGenesis.sol";
import {IMinter} from "@interfaces/IMinter.sol";

import {Genesis_v1, Token} from "src/minter/Genesis_v1.sol";

import {MockPriceOracle} from "test/MockPriceOracle.sol";
import {Array} from "test/Array.sol";

contract Test_GenesisBase is Test, Array {
    address collateral;
    address peggedToken;

    address genesisImpl;
    address genesis;
    address owner;

    address leveragedToken;
    address reservePool;
    MockPriceOracle priceOracle;
    address minter;
    uint256 zeroFeeRole;

    address feeReceiver;
    address user1;
    address user2;

    /*
    function recipientAddresses() private returns (address[] memory result) {
        result = new address[](recipients.length);
        for (uint i = 0; i < recipients.length; i++) {
            result[i] = recipients[i].addr;
        }
    }
    */

    function setUpFork() internal virtual {
        // vm.createSelectFork(vm.rpcUrl("mainnet"), 19210000);
        owner = vm.createWallet("owner").addr;
        feeReceiver = vm.createWallet("feeReceiver").addr;

        // collateral = address(deployMockERC20("mock wstETH", "wstETH", 18));
        collateral = address(new ERC20Mock());
        // peggedToken = address(deployMockERC20("mock BaoUSD", "BaoUSD", 18));
        peggedToken = address(new ERC20Mock());

        leveragedToken = UnsafeUpgrades.deployUUPSProxy(
            address(new LeveragedToken_v1()), // "LeveragedToken_v1.sol",
            abi.encodeCall(LeveragedToken_v1.initialize, (owner, "Leveraged Token", "BaoUSDLwstETH"))
        );

        reservePool = UnsafeUpgrades.deployUUPSProxy(
            address(new ReservePool_v1()), //"ReservePool_v1.sol",
            abi.encodeCall(ReservePool_v1.initialize, (owner))
        );

        IMinter.IncentiveConfig memory percent1 = IMinter.IncentiveConfig(ua(), ia(1 ether / 100));
        IMinter.Config memory config = IMinter.Config(
            130 ether / 100,
            200 ether / 100,
            percent1,
            percent1,
            percent1,
            percent1
        );

        priceOracle = new MockPriceOracle();

        minter = UnsafeUpgrades.deployUUPSProxy(
            address(new Minter_v1()), // "Minter_v1.sol",
            abi.encodeCall(
                Minter_v1.initialize,
                (
                    owner,
                    IMinter.BalanceTokens(peggedToken, leveragedToken, collateral),
                    type(IBurnable2Arg).interfaceId,
                    address(priceOracle),
                    feeReceiver,
                    reservePool,
                    config
                )
            )
        );
        IBaoOwnable(minter).transferOwnership(owner);

        uint256 minterRole = LeveragedToken_v1(leveragedToken).MINTER_ROLE();
        IBaoRoles(leveragedToken).grantRoles(minter, minterRole);

        zeroFeeRole = IMinter(minter).ZERO_FEE_ROLE();
        user1 = vm.createWallet("user1").addr;
        user2 = vm.createWallet("user2").addr;
    }

    function setUpContractImplementation() internal {
        genesisImpl = address(new Genesis_v1());
    }

    function setUpContract() internal {
        genesis = address(
            Genesis_v1(
                UnsafeUpgrades.deployUUPSProxy(
                    genesisImpl, //"Genesis_v1.sol",
                    abi.encodeCall(Genesis_v1.initialize, (owner, minter))
                )
            )
        );
        IBaoOwnable(genesis).transferOwnership(owner);

        // approve genesis to use my collateral
        IERC20(collateral).approve(genesis, type(uint256).max);
    }

    function setUp() public virtual {
        setUpFork();
        setUpContractImplementation();
        setUpContract();
    }

    function test_initEvents() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        setUpContractImplementation();

        vm.expectEmit();
        emit IERC1967.Upgraded(genesisImpl);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call
        setUpContract();
    }

    function test_init() public {
        // expect a revert if initialize called twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Genesis_v1(genesis).initialize(address(this), minter);

        // check the data has been set up correctly
        assertEq(IBaoOwnable(genesis).owner(), owner, "wrong owner");
        assertEq(IGenesis(genesis).collateralToken(), collateral, "wrong collateral");
        assertEq(IGenesis(genesis).peggedToken(), peggedToken, "wrong pegged");
        assertEq(IGenesis(genesis).leveragedToken(), leveragedToken, "wrong leveraged");
        assertEq(IGenesis(genesis).balanceOf(address(this)), 0, "wrong balance");
        assertFalse(IGenesis(genesis).genesisIsEnded());
        vm.expectRevert(IGenesis.GenesisIsNotEnded.selector);
        IGenesis(genesis).claimable(address(this));
    }

    function test_depositWithdraw() public {
        // ERC20Mock(collateral).mint(address(this), 1 ether);
        deal(collateral, address(this), 10 ether);

        assertEq(IGenesis(genesis).balanceOf(user1), 0, "user1 has no genesis tokens");
        assertEq(IGenesis(genesis).balanceOf(user2), 0, "user2 has no genesis tokens");
        assertEq(IERC20(collateral).balanceOf(user1), 0, "user1 has no collateral tokens");
        assertEq(IERC20(collateral).balanceOf(user2), 0, "user2 has no collateral tokens");
        assertEq(IERC20(collateral).balanceOf(genesis), 0, "genesis has no collateral tokens");

        // deposit for 0
        vm.expectRevert(Token.ZeroAddress.selector);
        IGenesis(genesis).deposit(1 ether, address(0));

        // deposit too much
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 10 ether, 100 ether)
        );
        IGenesis(genesis).deposit(100 ether, user1);
        assertEq(IGenesis(genesis).balanceOf(user1), 0, "user1 still has no genesis tokens");
        assertEq(IERC20(collateral).balanceOf(genesis), 0, "genesis still has no collateral tokens");

        IGenesis(genesis).deposit(1 ether, user1);
        assertEq(IGenesis(genesis).balanceOf(user1), 1 ether, "user1 now has 1 ether genesis tokens");
        assertEq(IGenesis(genesis).balanceOf(user2), 0, "user2 still has no genesis tokens");
        assertEq(IERC20(collateral).balanceOf(genesis), 1 ether, "genesis now has 1 ether collateral tokens");

        IGenesis(genesis).deposit(type(uint256).max, user2);
        assertEq(IGenesis(genesis).balanceOf(user1), 1 ether, "user1 still has 1 ether genesis tokens");
        assertEq(IGenesis(genesis).balanceOf(user2), 9 ether, "user2 now has 2 ether genesis tokens");
        assertEq(IERC20(collateral).balanceOf(genesis), 10 ether, "genesis now has 10 ether collateral tokens");

        // try to withdraw/claim - need to end the genesis & start the claiming first
        vm.expectRevert(IGenesis.GenesisIsNotEnded.selector);
        IGenesis(genesis).withdraw(user1, 0);
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
        assertEq(IGenesis(genesis).balanceOf(user2), 9 ether, "user2 now has 2 ether genesis tokens");
        assertEq(IERC20(collateral).balanceOf(genesis), 10 ether, "genesis now has 10 ether collateral tokens");
        assertEq(IERC20(peggedToken).balanceOf(genesis), 0 ether, "genesis now has 10 ether collateral tokens");
        assertEq(IERC20(leveragedToken).balanceOf(genesis), 0 ether, "genesis now has 10 ether collateral tokens");
        assertFalse(IGenesis(genesis).genesisIsEnded());
        vm.prank(owner);
        IGenesis(genesis).endGenesis();
        assertEq(IGenesis(genesis).balanceOf(user1), 1 ether, "user1 still has 1 ether genesis tokens");
        assertEq(IGenesis(genesis).balanceOf(user2), 9 ether, "user2 now has 9 ether genesis tokens");
        assertEq(IERC20(collateral).balanceOf(genesis), 0 ether, "genesis converted it's 10 ether collateral tokens");
        assertEq(IERC20(peggedToken).balanceOf(genesis), 10000 ether, "genesis 5 ether -> pegged tokens");
        assertEq(IERC20(leveragedToken).balanceOf(genesis), 10000 ether, "genesis 5 ether -> leveraged tokens");
        uint256 p;
        uint256 l;
        (p, l) = IGenesis(genesis).claimable(user1);
        assertEq(p, 1000 ether);
        assertEq(l, 1000 ether);
        (p, l) = IGenesis(genesis).claimable(user2);
        assertEq(p, 9000 ether);
        assertEq(l, 9000 ether);
        assertTrue(IGenesis(genesis).genesisIsEnded());

        // cannot end it again
        vm.expectRevert(IGenesis.GenesisIsEnded.selector);
        vm.prank(owner);
        IGenesis(genesis).endGenesis();

        // cannot deposit once ended
        vm.expectRevert(IGenesis.GenesisIsEnded.selector);
        IGenesis(genesis).deposit(100 ether, user1);

        // not anyone can withdraw, only those who have shares deposited
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, collateral));
        IGenesis(genesis).withdraw(user1, 0);

        // but not more than they have
        vm.expectRevert(abi.encodeWithSelector(IGenesis.InsufficientCollateral.selector, collateral));
        vm.prank(user1);
        IGenesis(genesis).withdraw(user1, 3 ether);
        assertEq(IGenesis(genesis).balanceOf(user1), 1 ether, "user1 still has 1 ether genesis tokens");

        // or even the same amount as they have because of the fees
        vm.expectRevert(abi.encodeWithSelector(IGenesis.InsufficientCollateral.selector, collateral));
        vm.prank(user1);
        IGenesis(genesis).withdraw(user1, 1 ether);
        assertEq(IGenesis(genesis).balanceOf(user1), 1 ether, "user1 still has 1 ether genesis tokens");

        // user1 can withdraw
        assertEq(IERC20(collateral).balanceOf(user1), 0, "user1 has no collateral");
        vm.prank(user1);
        IGenesis(genesis).withdraw(user1, 9 ether / 10);
        assertEq(IGenesis(genesis).balanceOf(user1), 0, "user1 now has zero genesis tokens");
        uint256 user1Collateral = IERC20(collateral).balanceOf(user1);
        // get the collateral back minus the fees
        assertGe(user1Collateral, 9 ether / 10, "user1 now has no collateral");
        assertLt(user1Collateral, 1 ether, "user1 now has no collateral");

        // user1 cannot withdraw again
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, collateral));
        vm.prank(user1);
        IGenesis(genesis).withdraw(user1, 0);

        // not anyone can claim - only those holding shares
        assertEq(IERC20(peggedToken).balanceOf(user1), 0, "user1 has no pegged");
        assertEq(IERC20(leveragedToken).balanceOf(user1), 0, "user1 has no leveraged");
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, collateral));
        IGenesis(genesis).claim(user1);
        assertEq(IERC20(peggedToken).balanceOf(user1), 0, "user1 has no pegged");
        assertEq(IERC20(leveragedToken).balanceOf(user1), 0, "user1 has no leveraged");

        // user2 claims
        assertEq(IGenesis(genesis).balanceOf(user2), 9 ether, "user2 still has 9 ether genesis tokens");
        vm.prank(user2);
        IGenesis(genesis).claim(user1);
        assertEq(IGenesis(genesis).balanceOf(user2), 0 ether, "user2 has no genesis tokens");
        assertEq(IERC20(peggedToken).balanceOf(user1), 9000 ether, "user1 has got pegged");
        assertEq(IERC20(leveragedToken).balanceOf(user1), 9000 ether, "user1 has got leveraged");

        // user2 cannot claim or withdraw again
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, collateral));
        vm.prank(user2);
        IGenesis(genesis).claim(user1);
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, collateral));
        vm.prank(user2);
        IGenesis(genesis).withdraw(user1, 0);
    }
}
