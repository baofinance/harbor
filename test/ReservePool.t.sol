// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {BaoTest} from "@bao-test/BaoTest.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
//import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {ReservePool_v2} from "@harbor/minter/ReservePool_v2.sol";
import {IReservePool} from "@harbor/interfaces/IReservePool.sol";

import {Deployed} from "@bao/Deployed.sol";

import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";
import {TestMinterMarketConfig} from "@harbor-test/config/TestMinterMarketConfig.sol";
import {MarketDeployRun} from "@harbor-test/harness/MarketDeployRun.sol";

/// @dev The reserve pool comes from the deploy, cut to the minter: the minter is the one requester the deploy grants,
///      so the requests here are made as it.
contract TestReservePoolSetUp is BaoTest {
    address token1 = Deployed.BaoUSD;
    address token2 = Deployed.wstETH;
    address tokenNotERC20 = makeAddr("tokenNotERC20"); // not an ERC20 token

    address bonusReceiver;
    address owner;
    address minter;
    address treasury;
    address reservePool;

    MarketDeployRun internal deployRun;

    function setUpFork() internal virtual {
        forkMainnet();
        owner = makeAddr("owner");
        bonusReceiver = makeAddr("bonusReceiver");
        treasury = makeAddr("treasury");
    }

    function setUpContract() internal virtual {
        deployRun = new MarketDeployRun(owner, treasury, HarborDeployRun.Cut.Minter, new TestMinterMarketConfig());
        deployRun.deployMinterMarket();
        reservePool = deployRun.reservePoolAddress(deployRun.marketConfig());
        minter = deployRun.minterAddress(deployRun.marketConfig());
    }

    function setUp() public {
        setUpFork();
        setUpContract();
    }
}

contract TestReservePoolInitEvents is TestReservePoolSetUp {
    /// The implementation locks its own initialiser as it is constructed.
    function test_initEventsImpl() public {
        vm.expectEmit();
        emit Initializable.Initialized(type(uint64).max); // from the logic contract constructor
        new ReservePool_v2();
    }

    /// Initialising a proxy records the implementation behind it and initialises it once.
    function test_initEventsProxy() public {
        address implementation = address(new ReservePool_v2());
        vm.expectEmit();
        emit IERC1967.Upgraded(implementation);
        vm.expectEmit();
        emit Initializable.Initialized(1); // from the proxy delegate call
        UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeCall(ReservePool_v2.initialize, (address(this), owner))
        );
    }
}

contract TestReservePool is TestReservePoolSetUp {
    using SafeERC20 for IERC20;

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

    function test_init() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        ReservePool_v2(reservePool).initialize(address(this), owner);

        // admin role
        assertEq(IBaoOwnable(reservePool).owner(), owner, "owner should be admin");

        // minter role
        assertTrue(
            IBaoRoles(reservePool).hasAnyRole(minter, IReservePool(reservePool).REQUESTER_ROLE()),
            "requester should be minter"
        );
    }

    function test_access() public {
        // can anyone request bonus
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IReservePool(reservePool).requestBonus(token1, bonusReceiver, 1 ether);
        // not anyone can withdraw funds
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        ReservePool_v2(reservePool).sweep(token1, 1 ether, bonusReceiver);
        // not anyone can grant roles
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoRoles(reservePool).grantRoles(minter, 23);
        // not anyone can transfer ownership
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        IBaoOwnable(reservePool).transferOwnership(address(this));
    }

    function test_bonus() public {
        // we assume all tokens are ERC20
        address[2] memory tokens = [token2, token1];
        for (uint i = 0; i < tokens.length; i++) {
            // make sure nothing has a balance of any bonus tokens
            assertEq(_balanceOf(tokens[i], bonusReceiver), 0);
            assertEq(_balanceOf(tokens[i], treasury), 0);
            assertEq(_balanceOf(tokens[i], reservePool), 0);

            // when none
            // request
            vm.expectEmit(true, true, true, true);
            emit IReservePool.RequestBonus(minter, tokens[i], bonusReceiver, 1 ether, 0);
            vm.startPrank(minter);
            IReservePool(reservePool).requestBonus(tokens[i], bonusReceiver, 1 ether);
            vm.stopPrank();
            //----------------------------------------------------------------------------
            assertEq(_balanceOf(tokens[i], bonusReceiver), 0);
            assertEq(_balanceOf(tokens[i], reservePool), 0 ether);

            // add some funds - anyone can
            deal(tokens[i], reservePool, 3 ether);
            assertEq(_balanceOf(tokens[i], reservePool), 3 ether);

            // request less than some
            vm.expectEmit(true, true, true, true);
            emit IReservePool.RequestBonus(minter, tokens[i], bonusReceiver, 1 ether, 1 ether);
            vm.startPrank(minter);
            IReservePool(reservePool).requestBonus(tokens[i], bonusReceiver, 1 ether);
            vm.stopPrank();
            //-------------------------------------------------------------------------
            assertEq(_balanceOf(tokens[i], bonusReceiver), 1 ether);
            assertEq(_balanceOf(tokens[i], reservePool), 2 ether);

            // request more than some
            vm.expectEmit(true, true, true, true);
            emit IReservePool.RequestBonus(minter, tokens[i], bonusReceiver, 3 ether, 2 ether);
            vm.startPrank(minter);
            IReservePool(reservePool).requestBonus(tokens[i], bonusReceiver, 3 ether);
            vm.stopPrank();
            //-------------------------------------------------------------------------
            assertEq(_balanceOf(tokens[i], bonusReceiver), 3 ether);
            assertEq(_balanceOf(tokens[i], reservePool), 0 ether);
        }
    }

    function test_notERC20() public {
        // requestBonus reads IERC20(token).balanceOf first; the token has no code, so Solidity's extcodesize guard
        // reverts. The revert data is NOT portable across run modes (verified): `forge test`/coverage see EMPTY data
        // (so `expectRevert(bytes(""))` matches), but `--gas-report` (yarn gas) enables the call inspector which
        // rewrites it into a synthetic "call to non-contract address 0x..." reason that empty-bytes does NOT match.
        // No single expectRevert parameter matches both, and the ONLY thing that can revert here is that extcodesize
        // guard (codeless token, balanceOf is the first call), so this parameterless form is the justified exception.
        vm.expectRevert();
        vm.startPrank(minter);
        IReservePool(reservePool).requestBonus(tokenNotERC20, bonusReceiver, 1 ether);
        vm.stopPrank();
    }

    function test_introspection() public view {
        assertTrue(
            ReservePool_v2(reservePool).supportsInterface(type(IReservePool).interfaceId),
            "should support IReservePool"
        );
        assertFalse(ReservePool_v2(reservePool).supportsInterface(bytes4(0)), "doesn't support 0");
    }
}
