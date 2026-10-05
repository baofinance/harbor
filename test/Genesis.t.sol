// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";
import {IGenesis} from "@harbor/interfaces/IGenesis.sol";
import {IMinter} from "@harbor/interfaces/IMinter.sol";

import {Genesis_v2} from "@harbor/minter/Genesis_v2.sol";

import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";
import {TestMinterMarketConfig} from "@harbor-test/config/TestMinterMarketConfig.sol";
import {MarketDeployRun} from "@harbor-test/harness/MarketDeployRun.sol";
import {Token} from "@bao/Token.sol";

contract Test_GenesisBase is TestMinterSetUp {
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

    /// @dev The minter and its genesis, which the deploy grants the minter's zero-fee role - ending a genesis mints
    ///      through the minter fee-free - and hands to the run's owner.
    function newDeployRun() internal virtual override returns (MarketDeployRun) {
        return
            new MarketDeployRun(
                owner(),
                treasury(),
                HarborDeployRun.Cut.MinterAndGenesis,
                new TestMinterMarketConfig()
            );
    }

    /// @dev A one-percent incentive in every band, which the deploy applies as the minter's config.
    function setUpConfig() internal virtual override {
        IMinter.IncentiveConfig memory percent1 = IMinter.IncentiveConfig(
            ua(1 ether),
            ia(1 ether / 100, 1 ether / 100)
        );
        setUp_config(IMinter.Config(percent1, percent1, percent1, percent1));
    }

    function setUp() public virtual override {
        super.setUp();

        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");

        // substitute the wct for better errors
        // wrappedCollateralToken = address(new MockERC20("Collateral", "COLL", 18));

        genesis = deployRun.genesisAddress(marketConfig);
        IERC20(wrappedCollateralToken).approve(genesis, type(uint256).max);
    }

    /// A genesis comes up announcing itself: its implementation locks its own initialiser, and initialising the proxy
    /// records the implementation, makes the deployer its owner and begins the genesis.
    function test_initEvents() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        address implementation = address(new Genesis_v2(minter));

        vm.expectEmit();
        emit IERC1967.Upgraded(implementation);
        vm.expectEmit();
        emit IBaoOwnable.OwnershipTransferred(address(0), address(this));
        vm.expectEmit();
        emit IGenesis.GenesisBegins();
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call
        UnsafeUpgrades.deployUUPSProxy(implementation, abi.encodeCall(Genesis_v2.initialize, (address(this), owner())));
    }

    function test_init() public {
        // expect a revert if initialize called twice
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        Genesis_v2(genesis).initialize(address(this), address(this));

        // check the data has been set up correctly
        assertEq(IBaoOwnable(genesis).owner(), owner(), "wrong owner");
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
        vm.startPrank(user3);
        IGenesis(genesis).withdraw(1 ether, user3);
        vm.stopPrank();

        // can't withdraw none
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, genesis));
        vm.startPrank(user2);
        IGenesis(genesis).withdraw(0, user2);
        vm.stopPrank();

        // can't withdraw to zero address
        vm.expectRevert(Token.ZeroAddress.selector);
        vm.startPrank(user2);
        IGenesis(genesis).withdraw(1 ether, address(0));
        vm.stopPrank();

        // can withdraw some
        vm.startPrank(user2);
        vm.expectEmit();
        emit IGenesis.Withdraw(user2, user3, 1 ether);
        IGenesis(genesis).withdraw(1 ether, user3);
        vm.stopPrank();
        assertEq(IGenesis(genesis).balanceOf(user1), 1 ether);
        assertEq(IGenesis(genesis).balanceOf(user2), 8 ether);
        assertEq(IGenesis(genesis).balanceOf(user3), 0 ether);

        // can't withdraw more
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user2, 8 ether, 9 ether)
        );
        vm.startPrank(user2);
        IGenesis(genesis).withdraw(9 ether, user2);
        vm.stopPrank();

        // can withdraw all
        vm.startPrank(user2);
        IGenesis(genesis).withdraw(type(uint256).max, user2);
        vm.stopPrank();
        assertEq(IGenesis(genesis).balanceOf(user1), 1 ether);
        assertEq(IGenesis(genesis).balanceOf(user2), 0 ether);
        assertEq(IGenesis(genesis).balanceOf(user3), 0 ether);

        // can't add it unless approved
        vm.expectRevert("ERC20: transfer amount exceeds allowance");
        vm.startPrank(user2);
        IGenesis(genesis).deposit(8 ether, user1);
        vm.stopPrank();

        // approve it, and add it back
        vm.startPrank(user2);
        IERC20(wrappedCollateralToken).approve(genesis, type(uint256).max);
        IGenesis(genesis).deposit(8 ether, user2);
        vm.stopPrank();
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

        // the deploy grants genesis the minter's zero-fee role, without which the ending reverts in the minter - see
        // test_endGenesis_revertsInTheMinterWithoutItsZeroFeeRole
        assertTrue(
            IHarborRoles(minter).hasAllRoles(genesis, zeroFeeRole),
            "the deploy grants genesis the minter's zero-fee role"
        );

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
        vm.startPrank(owner());
        vm.expectEmit();
        emit IGenesis.GenesisEnds();
        IGenesis(genesis).endGenesis();
        vm.stopPrank();
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
        vm.startPrank(owner());
        IGenesis(genesis).endGenesis();
        vm.stopPrank();

        // cannot deposit once ended
        vm.expectRevert(IGenesis.GenesisIsEnded.selector);
        IGenesis(genesis).deposit(100 ether, user1);

        // cannot withdraw after ended
        vm.startPrank(user2);
        vm.expectRevert(IGenesis.GenesisIsEnded.selector);
        IGenesis(genesis).withdraw(1 ether, user2);
        vm.stopPrank();

        // not anyone can claim - only those holding shares
        assertEq(IERC20(peggedToken).balanceOf(user1), 0, "user1 has no pegged");
        assertEq(IERC20(leveragedToken).balanceOf(user1), 0, "user1 has no leveraged");
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, wrappedCollateralToken));
        IGenesis(genesis).claim(user1);
        assertEq(IERC20(peggedToken).balanceOf(user1), 0, "user1 has no pegged");
        assertEq(IERC20(leveragedToken).balanceOf(user1), 0, "user1 has no leveraged");

        // user2 claims
        assertEq(IGenesis(genesis).balanceOf(user2), 8 ether, "user2 still has 9 ether genesis tokens");
        vm.startPrank(user2);
        vm.expectEmit();
        emit IGenesis.Claim(user2, user1, 8000 ether, 8000 ether);
        IGenesis(genesis).claim(user1);
        vm.stopPrank();
        assertEq(IGenesis(genesis).balanceOf(user2), 0 ether, "user2 has no genesis tokens");
        assertEq(IERC20(peggedToken).balanceOf(user1), 8000 ether, "user1 has got pegged");
        assertEq(IERC20(leveragedToken).balanceOf(user1), 8000 ether, "user1 has got leveraged");

        // user2 cannot claim again
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, wrappedCollateralToken));
        vm.startPrank(user2);
        IGenesis(genesis).claim(user2);
        vm.stopPrank();
    }

    /// Ending a genesis mints its collateral through the minter fee-free, so a genesis the minter has not granted the
    /// zero-fee role cannot end: the revert is the minter's, and the genesis stays open.
    function test_endGenesis_revertsInTheMinterWithoutItsZeroFeeRole() public {
        deal(wrappedCollateralToken, address(this), 1 ether);
        IGenesis(genesis).deposit(1 ether, user1);

        vm.startPrank(owner());
        IHarborRoles(minter).revokeRoles(genesis, zeroFeeRole);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        IGenesis(genesis).endGenesis();
        vm.stopPrank();
        assertFalse(IGenesis(genesis).genesisIsEnded(), "the genesis stays open");
    }

    function test_nullGenesis() public {
        vm.startPrank(owner());
        IGenesis(genesis).endGenesis();
        vm.stopPrank();
        uint256 p;
        uint256 l;
        (p, l) = IGenesis(genesis).claimable(user1);
        assertEq(p, 0 ether);
        assertEq(l, 0 ether);
    }
}
