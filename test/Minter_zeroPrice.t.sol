// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice A zero collateral price is legitimate - the oracle gives one only when it is - and the minter handles it:
/// every entry point that reads the oracle answers or reverts by name, and a pegged token, redeemed below the peg,
/// pays its share of the backing in kind whatever the price, zero included.
contract TestMinterZeroPrice is TestMinterSetUp {
    address user;

    /// @dev One ratio either side of the peg for each action; redeeming pegged below it charges 0.5%.
    function setUpConfig() internal virtual override {
        setUp_config(
            ic(ua(100), ia(10, 10)), // mint pegged
            ic(ua(100), ia(50, 20)), // redeem pegged
            ic(ua(100), ia(30, 30)), // mint leveraged
            ic(ua(100), ia(40, 40)) // redeem leveraged
        );
    }

    /// @dev A market holding 13 collateral against 10 pegged, at a rate of one, then priced at zero: each pegged token
    ///      is a claim on 1.3 collateral. Both the user and the zero-fee holder hold pegged and leveraged tokens.
    function setUp() public virtual override {
        super.setUp();
        user = makeAddr("user");
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1 ether, 1 ether);
        setUp_collateral(5 ether, 1.5 ether, user);
        setUp_collateral(5 ether, 1.5 ether, zeroFee);
        deal(wrappedCollateralToken, user, 10 ether);
        deal(wrappedCollateralToken, reservePool, 10 ether);
        address[2] memory actors = [user, zeroFee];
        for (uint256 i = 0; i < actors.length; i++) {
            vm.startPrank(actors[i]);
            IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
            IERC20(peggedToken).approve(minter, type(uint256).max);
            IERC20(leveragedToken).approve(minter, type(uint256).max);
            vm.stopPrank();
        }
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, 1 ether);
    }

    /// @dev A pegged token's share of the backing, in collateral: the backing over the pegged supply.
    function _shareOf(uint256 pegged) private view returns (uint256) {
        return Math.mulDiv(pegged, IMinter(minter).collateralTokenBalance(), IMinter(minter).peggedTokenBalance());
    }

    /// At a zero price a pegged redemption pays the redeemer its share of the backing, less the fee of the band below
    /// the peg, and the record gives up that share.
    function test_redeemPegged_atAZeroPrice_paysItsShareOfTheBacking() public {
        uint256 share = _shareOf(1 ether);
        assertEq(share, 1.3 ether, "a pegged token's share of the backing");
        uint256 fee = (share * uint256(config.redeemPeggedIncentiveConfig.incentiveRatios[0])) / 1 ether;
        uint256 recordBefore = IMinter(minter).collateralTokenBalance();
        uint256 feeBefore = IERC20(wrappedCollateralToken).balanceOf(feeReceiver);

        vm.startPrank(user);
        uint256 paid = IMinter(minter).redeemPeggedToken(1 ether, user, 0);
        vm.stopPrank();

        assertEq(paid, share - fee, "the share, less the fee");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(feeReceiver) - feeBefore, fee, "the fee to the fee receiver");
        assertEq(recordBefore - IMinter(minter).collateralTokenBalance(), share, "the record gives up the share");
    }

    /// The dry run of a redemption at a zero price says what the call does.
    function test_redeemPeggedDryRun_atAZeroPrice_saysWhatTheCallDoes() public {
        (int256 ratio, uint256 fee, uint256 subsidy, uint256 redeemed, uint256 returned, , ) = IMinter(minter)
            .redeemPeggedTokenDryRun(1 ether);

        vm.startPrank(user);
        uint256 paid = IMinter(minter).redeemPeggedToken(1 ether, user, 0);
        vm.stopPrank();

        assertEq(returned, paid, "the collateral the call pays");
        assertEq(redeemed, 1 ether, "the pegged it redeems");
        assertEq(fee, _shareOf(1 ether) / 200, "a 0.5% fee on the share");
        assertEq(subsidy, 0, "no subsidy");
        assertEq(ratio, config.redeemPeggedIncentiveConfig.incentiveRatios[0], "the ratio of the band below the peg");
    }

    /// The rebalance's redemption, at a zero price, pays the stability pool its share of the backing in kind, and its
    /// dry run says so.
    function test_freeRedeemPegged_atAZeroPrice_paysItsShareOfTheBacking() public {
        uint256 share = _shareOf(1 ether);
        (uint256 previewed, ) = IMinter_v3(minter).freeRedeemDryRun(1 ether, 0);

        vm.startPrank(zeroFee);
        (uint256 paid, ) = IMinter(minter).freeRedeemPeggedToken(1 ether, 0, zeroFee);
        vm.stopPrank();

        assertEq(paid, share, "the share, without a fee");
        assertEq(previewed, paid, "the dry run says what the call does");
    }

    /// @dev Calls the minter as `actor` and requires it to answer, or to revert with a named error - a custom error,
    ///      not an arithmetic panic, a bare revert or a string.
    function _answersOrRevertsByName(string memory name, address actor, bytes memory call) private {
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(actor);
        (bool answered, bytes memory reason) = minter.call(call);
        vm.stopPrank();
        vm.revertToState(snapshot);
        if (answered) {
            return;
        }
        assertGe(reason.length, 4, string.concat(name, ": reverted without a reason"));
        bytes4 selector = bytes4(reason);
        assertTrue(selector != bytes4(keccak256("Panic(uint256)")), string.concat(name, ": panicked"));
        assertTrue(selector != bytes4(keccak256("Error(string)")), string.concat(name, ": reverted with a string"));
    }

    /// Every entry point that reads the oracle - for the price, or only for the rate - given a zero price, answers or
    /// reverts by name.
    function test_everyOracleReadingEntryPoint_atAZeroPrice_answersOrRevertsByName() public {
        EntryPoint[] memory points = _oracleReadingEntryPoints(user, 1 ether, 1 ether);
        for (uint256 i = 0; i < points.length; ++i) {
            _answersOrRevertsByName(points[i].name, points[i].caller, points[i].call);
        }
    }
}

/// @notice In a market of leveraged tokens alone, priced at zero, the leveraged has no residual to claim, so a leveraged
/// mint buys nothing: it reverts by name and takes nothing, and its dry run says so. With no pegged claim the collateral
/// ratio reads as unbounded whatever the price, so the min CR does not turn the mint away first.
contract TestMinterZeroPriceLeveragedAlone is TestMinterSetUp {
    address user;

    /// @dev Minting leveraged charges 0.5% below the peg and 0.3% above it.
    function setUpConfig() internal virtual override {
        setUp_config(ic(ua(100), ia(0, 0)), ic(ua(100), ia(0, 0)), ic(ua(100), ia(50, 30)), ic(ua(100), ia(0, 0)));
    }

    /// @dev Ten collateral behind leveraged tokens alone, at a rate of one, then priced at zero; the user holds one
    ///      collateral token, approved to the minter.
    function setUp() public virtual override {
        super.setUp();
        user = makeAddr("user");
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(1 ether, 1 ether);
        setUp_collateral(0, 10 ether, user);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(0, 1 ether);
        deal(wrappedCollateralToken, user, 1 ether);
        vm.startPrank(user);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        vm.stopPrank();
    }

    /// A leveraged mint reverts by name and takes nothing; its dry run reports nothing used, charged, subsidised or
    /// minted, at the ratio of the band an unbounded collateral ratio is in.
    function test_mintLeveraged_inAMarketOfLeveragedAloneAtAZeroPrice_revertsAndItsDryRunReportsNothing() public {
        assertEq(IMinter(minter).peggedTokenBalance(), 0, "precondition: no pegged supply");
        assertGt(IMinter(minter).leveragedTokenBalance(), 0, "precondition: leveraged outstanding");
        assertTrue(IMinter_v3(minter).leveragedMintable(), "precondition: the min CR lets the mint through");

        (int256 ratio, uint256 fee, uint256 subsidy, uint256 used, uint256 minted, , ) = IMinter(minter)
            .mintLeveragedTokenDryRun(1 ether);
        assertEq(used, 0, "the dry run uses nothing");
        assertEq(fee, 0, "charges nothing");
        assertEq(subsidy, 0, "draws no subsidy");
        assertEq(minted, 0, "mints nothing");
        assertEq(ratio, config.mintLeveragedIncentiveConfig.incentiveRatios[1], "and reports the band's ratio");

        uint256 heldBefore = IERC20(wrappedCollateralToken).balanceOf(user);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, leveragedToken));
        IMinter(minter).mintLeveragedToken(1 ether, user, 0);
        vm.stopPrank();
        assertEq(IERC20(wrappedCollateralToken).balanceOf(user), heldBefore, "nothing is taken");
    }
}
