// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {ITokenHolder} from "@bao/interfaces/ITokenHolder.sol";
import {BaoTest} from "@bao-test/BaoTest.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

import {IRepayment_v1} from "@harbor/interfaces/IRepayment_v1.sol";
import {Repayment_v1} from "@harbor/minter/Repayment_v1.sol";

/// @notice Repayment_v1 repays a fixed list of debts in one token from whatever is paid in: at every moment every account
///         can claim the same fraction of its debt, and the whole of it once the total has been paid in. The owner can
///         sweep other tokens at any time, and the debt token only beyond the debts.
contract RepaymentTest is BaoTest {
    address internal token;
    address internal other;
    address internal owner;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal nobody;
    address internal implementation;
    address internal repayment;

    uint256 internal constant ALICE_DEBT = 10 ether;
    uint256 internal constant BOB_DEBT = 3 ether;
    uint256 internal constant CAROL_DEBT = 1 ether;
    uint256 internal constant TOTAL_DEBT = ALICE_DEBT + BOB_DEBT + CAROL_DEBT;
    string internal constant NAME = "Harbor Repayment wstETH";
    string internal constant SYMBOL = "hrwstETH";

    function setUp() public {
        token = address(new MockERC20("wrapped staked ether", "wstETH", 18));
        other = address(new MockERC20("another token", "OTHER", 18));
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        nobody = makeAddr("nobody");
        implementation = address(new Repayment_v1(token));
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = carol;
        uint256[] memory debts = new uint256[](3);
        debts[0] = ALICE_DEBT;
        debts[1] = BOB_DEBT;
        debts[2] = CAROL_DEBT;
        repayment = _deploy(accounts, debts);
    }

    /// @dev A proxy on the implementation, initialised with `accounts` and `debts`, its ownership handed to `owner`.
    function _deploy(address[] memory accounts, uint256[] memory debts) internal returns (address proxy) {
        proxy = _deployProxy(accounts, debts);
        IHarborOwnable(proxy).transferOwnership(owner);
    }

    /// @dev The proxy alone, still owned by this contract. Its creation is the first external action, so a cheatcode set
    ///      before this call binds to it; a creation that reverts returns nothing, so nothing is called on the result.
    function _deployProxy(address[] memory accounts, uint256[] memory debts) internal returns (address proxy) {
        proxy = UnsafeUpgrades.deployUUPSProxy(
            implementation,
            abi.encodeCall(Repayment_v1.initialize, (address(this), owner, NAME, SYMBOL, accounts, debts))
        );
    }

    /// @notice The debt shows as a token in its owner's wallet: minted at deployment, each balance is what its account is
    ///         still owed and the supply what is outstanding, and a claim burns what it pays.
    function test_token_balanceIsWhatIsStillOwed() public {
        assertEq(IRepayment_v1(repayment).name(), NAME, "name");
        assertEq(IRepayment_v1(repayment).symbol(), SYMBOL, "symbol");
        assertEq(IRepayment_v1(repayment).decimals(), 18, "one token is one wstETH owed");
        assertEq(IRepayment_v1(repayment).totalSupply(), TOTAL_DEBT, "the supply is the whole debt at first");
        assertEq(IRepayment_v1(repayment).balanceOf(alice), ALICE_DEBT, "alice's balance is her debt");
        assertEq(IRepayment_v1(repayment).balanceOf(nobody), 0, "nobody holds nothing");

        address[] memory one = new address[](1);
        one[0] = alice;
        uint256[] memory debts = new uint256[](1);
        debts[0] = 7;
        vm.expectEmit();
        emit IERC20.Transfer(address(0), alice, 7);
        _deploy(one, debts);

        _payIn(7 ether);
        uint256 expected = (ALICE_DEBT * 7 ether) / TOTAL_DEBT;
        vm.startPrank(alice);
        vm.expectEmit(repayment);
        emit IERC20.Transfer(alice, address(0), expected);
        IRepayment_v1(repayment).claim();
        vm.stopPrank();
        assertEq(IRepayment_v1(repayment).balanceOf(alice), ALICE_DEBT - expected, "the claim burnt what it paid");
        assertEq(IRepayment_v1(repayment).totalSupply(), TOTAL_DEBT - expected, "the supply fell by as much");

        _payIn(TOTAL_DEBT - 7 ether);
        vm.startPrank(alice);
        IRepayment_v1(repayment).claim();
        vm.stopPrank();
        assertEq(IRepayment_v1(repayment).balanceOf(alice), 0, "repaid in full, nothing left in her wallet");
        assertEq(IRepayment_v1(repayment).totalSupply(), BOB_DEBT + CAROL_DEBT, "the others' debts remain");
    }

    /// @notice The debt stays with the account that is owed: transfers and approvals are refused, and no allowance exists.
    function test_token_isNotTransferable() public {
        vm.startPrank(alice);
        vm.expectRevert(IRepayment_v1.NotTransferable.selector);
        IRepayment_v1(repayment).transfer(bob, 1);
        vm.expectRevert(IRepayment_v1.NotTransferable.selector);
        IRepayment_v1(repayment).approve(bob, 1);
        vm.expectRevert(IRepayment_v1.NotTransferable.selector);
        IRepayment_v1(repayment).transferFrom(alice, bob, 1);
        vm.stopPrank();
        assertEq(IRepayment_v1(repayment).allowance(alice, bob), 0, "no allowance");
        assertEq(IRepayment_v1(repayment).balanceOf(alice), ALICE_DEBT, "alice's balance is untouched");
    }

    /// @dev Pays `amount` of the debt token in, as a fee receiver is paid: a plain transfer.
    function _payIn(uint256 amount) internal {
        MockERC20(token).mint(repayment, amount);
    }

    /// @notice Each account's debt and the total are recorded for one account and for several, and announced; no account
    ///         is owed nothing, and none is recorded twice.
    function test_constructor_recordsEveryDebt() public {
        assertEq(IRepayment_v1(repayment).TOKEN(), token, "the debt token");
        assertEq(IRepayment_v1(repayment).debt(alice), ALICE_DEBT, "alice's debt");
        assertEq(IRepayment_v1(repayment).debt(bob), BOB_DEBT, "bob's debt");
        assertEq(IRepayment_v1(repayment).debt(carol), CAROL_DEBT, "carol's debt");
        assertEq(IRepayment_v1(repayment).debt(nobody), 0, "nobody is owed nothing");
        assertEq(IRepayment_v1(repayment).totalDebt(), TOTAL_DEBT, "the total");
        assertEq(IRepayment_v1(repayment).totalClaimed(), 0, "nothing claimed yet");
        assertEq(IRepayment_v1(repayment).received(), 0, "nothing received yet");
        assertEq(IBaoOwnable(repayment).owner(), owner, "owned by the owner");

        address[] memory one = new address[](1);
        one[0] = alice;
        uint256[] memory debts = new uint256[](1);
        debts[0] = 7;
        vm.expectEmit();
        emit IRepayment_v1.DebtRecorded(alice, 7);
        address single = _deploy(one, debts);
        assertEq(IRepayment_v1(single).totalDebt(), 7, "one account's total is its debt");

        uint256[] memory two = new uint256[](2);
        vm.expectRevert(abi.encodeWithSelector(IRepayment_v1.AccountsAndDebtsDifferentSizes.selector, 1, 2));
        _deployProxy(one, two);

        debts[0] = 0;
        vm.expectRevert(abi.encodeWithSelector(IRepayment_v1.ZeroDebt.selector, alice));
        _deployProxy(one, debts);

        address[] memory twice = new address[](2);
        twice[0] = alice;
        twice[1] = alice;
        two[0] = 1;
        two[1] = 2;
        vm.expectRevert(abi.encodeWithSelector(IRepayment_v1.DuplicateAccount.selector, alice));
        _deployProxy(twice, two);
    }

    /// @notice After a partial receipt, every account can claim the same fraction of its debt: its debt times what has
    ///         been received over the total debt, floored.
    function test_claimable_isTheSameFractionForEveryone() public {
        // 2 ether of 14: one seventh.
        _payIn(2 ether);
        assertEq(IRepayment_v1(repayment).received(), 2 ether, "received");
        assertEq(IRepayment_v1(repayment).claimable(alice), (ALICE_DEBT * 2 ether) / TOTAL_DEBT, "alice: a seventh");
        assertEq(IRepayment_v1(repayment).claimable(bob), (BOB_DEBT * 2 ether) / TOTAL_DEBT, "bob: a seventh");
        assertEq(IRepayment_v1(repayment).claimable(carol), (CAROL_DEBT * 2 ether) / TOTAL_DEBT, "carol: a seventh");
        assertEq(IRepayment_v1(repayment).claimable(nobody), 0, "nobody can claim nothing");
        // The same fraction for everyone, up to the flooring.
        assertApproxEqAbs(
            (IRepayment_v1(repayment).claimable(alice) * 1 ether) / ALICE_DEBT,
            (IRepayment_v1(repayment).claimable(carol) * 1 ether) / CAROL_DEBT,
            1,
            "the fraction is the same, to the floor"
        );
    }

    /// @notice Once more than the total debt has been received, each account can claim its whole debt and no more.
    function test_claimable_isCappedAtTheDebt() public {
        _payIn(TOTAL_DEBT + 5 ether);
        assertEq(IRepayment_v1(repayment).claimable(alice), ALICE_DEBT, "alice: her whole debt");
        assertEq(IRepayment_v1(repayment).claimable(bob), BOB_DEBT, "bob: his whole debt");
        assertEq(IRepayment_v1(repayment).claimable(carol), CAROL_DEBT, "carol: her whole debt");
    }

    /// @notice A claim pays the claimable amount to the caller, records it, and announces it; a second claim with nothing
    ///         new received is refused.
    function test_claim_paysAndRecords() public {
        _payIn(7 ether);
        uint256 expected = (ALICE_DEBT * 7 ether) / TOTAL_DEBT;
        vm.startPrank(alice);
        vm.expectEmit(repayment);
        emit IRepayment_v1.Claimed(alice, alice, expected);
        uint256 paid = IRepayment_v1(repayment).claim();
        vm.stopPrank();
        assertEq(paid, expected, "returns what it paid");
        assertEq(IERC20(token).balanceOf(alice), expected, "alice holds it");
        assertEq(IRepayment_v1(repayment).claimed(alice), expected, "recorded against alice");
        assertEq(IRepayment_v1(repayment).totalClaimed(), expected, "the total claimed");
        assertEq(IRepayment_v1(repayment).claimable(alice), 0, "nothing more to claim");
        assertEq(IRepayment_v1(repayment).received(), 7 ether, "a claim does not change what was received");

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IRepayment_v1.NothingToClaim.selector, alice));
        IRepayment_v1(repayment).claim();
        vm.stopPrank();
    }

    /// @notice A claim between two receipts: the second claim pays only the second receipt's share, and an account that
    ///         waited claims both shares at once.
    function test_claim_afterMoreArrives() public {
        _payIn(7 ether);
        vm.startPrank(alice);
        IRepayment_v1(repayment).claim();
        vm.stopPrank();
        _payIn(7 ether);
        // 14 of 14 received: every debt is claimable in full.
        assertEq(
            IRepayment_v1(repayment).claimable(alice),
            ALICE_DEBT - (ALICE_DEBT * 7 ether) / TOTAL_DEBT,
            "the rest"
        );
        vm.startPrank(alice);
        IRepayment_v1(repayment).claim();
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(alice), ALICE_DEBT, "alice is repaid in full over two claims");

        vm.startPrank(bob);
        uint256 paid = IRepayment_v1(repayment).claim();
        vm.stopPrank();
        assertEq(paid, BOB_DEBT, "bob is repaid in full in one claim");
        assertEq(IERC20(token).balanceOf(bob), BOB_DEBT, "bob holds it");
    }

    /// @notice A claim to a receiver pays the receiver and is recorded against the caller.
    function test_claim_toAReceiver() public {
        _payIn(7 ether);
        uint256 expected = (BOB_DEBT * 7 ether) / TOTAL_DEBT;
        vm.startPrank(bob);
        vm.expectEmit(repayment);
        emit IRepayment_v1.Claimed(bob, nobody, expected);
        IRepayment_v1(repayment).claim(nobody);
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(nobody), expected, "the receiver holds it");
        assertEq(IERC20(token).balanceOf(bob), 0, "bob does not");
        assertEq(IRepayment_v1(repayment).claimed(bob), expected, "recorded against bob");
        assertEq(IRepayment_v1(repayment).claimed(nobody), 0, "not against the receiver");
    }

    /// @notice An account that is owed nothing is refused by name, whether or not anything has been received.
    function test_claim_byAnAccountWithNoDebt() public {
        _payIn(7 ether);
        vm.startPrank(nobody);
        vm.expectRevert(abi.encodeWithSelector(IRepayment_v1.NoDebt.selector, nobody));
        IRepayment_v1(repayment).claim();
        vm.stopPrank();
    }

    /// @notice The debt token is swept only once the total debt has been received, and only its surplus: every unclaimed
    ///         amount stays claimable. Any other token is swept freely.
    function test_sweep_onlyTheSurplus() public {
        _payIn(7 ether);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IRepayment_v1.DebtsNotCovered.selector, 7 ether, TOTAL_DEBT));
        ITokenHolder(repayment).sweep(token, type(uint256).max, owner);
        vm.stopPrank();

        _payIn(TOTAL_DEBT - 7 ether + 5 ether);
        vm.startPrank(bob);
        IRepayment_v1(repayment).claim();
        vm.stopPrank();
        // The surplus is 5 ether whether or not anyone has claimed.
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IRepayment_v1.SweepExceedsSurplus.selector, 5 ether + 1, 5 ether));
        ITokenHolder(repayment).sweep(token, 5 ether + 1, owner);
        vm.expectEmit(repayment);
        emit ITokenHolder.Swept(token, 5 ether, owner);
        ITokenHolder(repayment).sweep(token, type(uint256).max, owner);
        vm.stopPrank();
        assertEq(IERC20(token).balanceOf(owner), 5 ether, "the owner has the surplus");
        assertEq(IRepayment_v1(repayment).claimable(alice), ALICE_DEBT, "alice can still claim her whole debt");
        assertEq(IRepayment_v1(repayment).claimable(carol), CAROL_DEBT, "carol too");
        assertEq(
            IRepayment_v1(repayment).received(),
            TOTAL_DEBT,
            "a sweep takes what was received down to the debts, never below"
        );

        MockERC20(other).mint(repayment, 3 ether);
        vm.startPrank(owner);
        ITokenHolder(repayment).sweep(other, type(uint256).max, owner);
        vm.stopPrank();
        assertEq(IERC20(other).balanceOf(owner), 3 ether, "another token is swept freely, debts covered or not");
    }

    /// @notice Only the owner sweeps.
    function test_sweep_onlyOwner() public {
        MockERC20(other).mint(repayment, 3 ether);
        vm.startPrank(alice);
        vm.expectRevert(IBaoOwnable.Unauthorized.selector);
        ITokenHolder(repayment).sweep(other, type(uint256).max, alice);
        vm.stopPrank();
    }

    /// @notice For any debts and any receipts, the claimables never sum to more than the balance, and each is within a wei
    ///         of its exact share.
    function test_rounding_neverOverpays(uint96 debtA, uint96 debtB, uint96 debtC, uint96 paidIn) public {
        debtA = uint96(bound(debtA, 1, type(uint96).max));
        debtB = uint96(bound(debtB, 1, type(uint96).max));
        debtC = uint96(bound(debtC, 1, type(uint96).max));
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = carol;
        uint256[] memory debts = new uint256[](3);
        debts[0] = debtA;
        debts[1] = debtB;
        debts[2] = debtC;
        repayment = _deploy(accounts, debts);
        _payIn(paidIn);

        uint256 total = uint256(debtA) + debtB + debtC;
        uint256 paid = paidIn < total ? paidIn : total;
        uint256 sum;
        for (uint256 i = 0; i < 3; ++i) {
            uint256 claimable = IRepayment_v1(repayment).claimable(accounts[i]);
            // The exact share, rounded down: the claimable is that, so the deviation from the unrounded share is < 1.
            assertEq(claimable, (debts[i] * paid) / total, "each claimable is its floored share");
            sum += claimable;
        }
        assertLe(sum, paid, "the claimables never exceed what was received");
        assertLe(paid - sum, 2, "the flooring leaves at most a wei per account but one unclaimed");
    }
}
