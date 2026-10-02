// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice A zero collateral price is legitimate - the oracle gives one only when it is - and the minter handles it:
/// every entry point that reads the price answers or refuses by name, and a pegged token, redeemed below the peg,
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

    /// @dev Calls the minter as `actor` and requires it to answer, or to refuse with a named error - a custom error,
    ///      not an arithmetic panic, a bare revert or a string.
    function _answersOrRefusesByName(string memory name, address actor, bytes memory call) private {
        uint256 snapshot = vm.snapshotState();
        vm.startPrank(actor);
        (bool answered, bytes memory reason) = minter.call(call);
        vm.stopPrank();
        vm.revertToState(snapshot);
        if (answered) {
            return;
        }
        assertGe(reason.length, 4, string.concat(name, ": refused without a reason"));
        bytes4 selector = bytes4(reason);
        assertTrue(selector != bytes4(keccak256("Panic(uint256)")), string.concat(name, ": panicked"));
        assertTrue(selector != bytes4(keccak256("Error(string)")), string.concat(name, ": refused with a string"));
    }

    /// Every entry point that reads the price, given a zero price, answers or refuses by name.
    function test_everyPriceReadingEntryPoint_atAZeroPrice_answersOrRefusesByName() public {
        _answersOrRefusesByName("collateralRatio", user, abi.encodeCall(IMinter_v3.collateralRatio, ()));
        _answersOrRefusesByName("leverageRatio", user, abi.encodeCall(IMinter_v3.leverageRatio, ()));
        _answersOrRefusesByName("leveragedMintable", user, abi.encodeCall(IMinter_v3.leveragedMintable, ()));
        _answersOrRefusesByName("peggedTokenPrice", user, abi.encodeCall(IMinter_v3.peggedTokenPrice, ()));
        _answersOrRefusesByName("leveragedTokenPrice", user, abi.encodeCall(IMinter_v3.leveragedTokenPrice, ()));
        _answersOrRefusesByName(
            "mintPeggedTokenIncentiveRatio",
            user,
            abi.encodeCall(IMinter_v3.mintPeggedTokenIncentiveRatio, ())
        );
        _answersOrRefusesByName(
            "redeemPeggedTokenIncentiveRatio",
            user,
            abi.encodeCall(IMinter_v3.redeemPeggedTokenIncentiveRatio, ())
        );
        _answersOrRefusesByName(
            "mintLeveragedTokenIncentiveRatio",
            user,
            abi.encodeCall(IMinter_v3.mintLeveragedTokenIncentiveRatio, ())
        );
        _answersOrRefusesByName(
            "redeemLeveragedTokenIncentiveRatio",
            user,
            abi.encodeCall(IMinter_v3.redeemLeveragedTokenIncentiveRatio, ())
        );
        _answersOrRefusesByName(
            "mintPeggedToken",
            user,
            abi.encodeWithSignature("mintPeggedToken(uint256,address,uint256)", 1 ether, user, 0)
        );
        _answersOrRefusesByName(
            "mintPeggedToken capped",
            user,
            abi.encodeWithSignature(
                "mintPeggedToken(uint256,address,uint256,uint256)",
                1 ether,
                user,
                0,
                type(uint256).max
            )
        );
        _answersOrRefusesByName(
            "redeemPeggedToken",
            user,
            abi.encodeCall(IMinter_v3.redeemPeggedToken, (1 ether, user, 0))
        );
        _answersOrRefusesByName(
            "mintLeveragedToken",
            user,
            abi.encodeCall(IMinter_v3.mintLeveragedToken, (1 ether, user, 0))
        );
        _answersOrRefusesByName(
            "redeemLeveragedToken",
            user,
            abi.encodeCall(IMinter_v3.redeemLeveragedToken, (1 ether, user, 0))
        );
        _answersOrRefusesByName(
            "mintPeggedTokenDryRun",
            user,
            abi.encodeWithSignature("mintPeggedTokenDryRun(uint256)", 1 ether)
        );
        _answersOrRefusesByName(
            "mintPeggedTokenDryRun capped",
            user,
            abi.encodeWithSignature("mintPeggedTokenDryRun(uint256,uint256)", 1 ether, type(uint256).max)
        );
        _answersOrRefusesByName(
            "redeemPeggedTokenDryRun",
            user,
            abi.encodeCall(IMinter_v3.redeemPeggedTokenDryRun, (1 ether))
        );
        _answersOrRefusesByName(
            "mintLeveragedTokenDryRun",
            user,
            abi.encodeCall(IMinter_v3.mintLeveragedTokenDryRun, (1 ether))
        );
        _answersOrRefusesByName(
            "redeemLeveragedTokenDryRun",
            user,
            abi.encodeCall(IMinter_v3.redeemLeveragedTokenDryRun, (1 ether))
        );
        _answersOrRefusesByName(
            "freeMintPeggedToken",
            zeroFee,
            abi.encodeCall(IMinter_v3.freeMintPeggedToken, (1 ether, zeroFee))
        );
        _answersOrRefusesByName(
            "freeMintLeveragedToken",
            zeroFee,
            abi.encodeCall(IMinter_v3.freeMintLeveragedToken, (1 ether, zeroFee))
        );
        _answersOrRefusesByName(
            "freeRedeemPeggedToken for collateral",
            zeroFee,
            abi.encodeCall(IMinter_v3.freeRedeemPeggedToken, (1 ether, 0, zeroFee))
        );
        _answersOrRefusesByName(
            "freeRedeemPeggedToken for leveraged",
            zeroFee,
            abi.encodeCall(IMinter_v3.freeRedeemPeggedToken, (0, 1 ether, zeroFee))
        );
        _answersOrRefusesByName(
            "freeRedeemLeveragedToken",
            zeroFee,
            abi.encodeCall(IMinter_v3.freeRedeemLeveragedToken, (1 ether, zeroFee))
        );
        _answersOrRefusesByName(
            "freeRedeemDryRun for collateral",
            zeroFee,
            abi.encodeCall(IMinter_v3.freeRedeemDryRun, (1 ether, 0))
        );
        _answersOrRefusesByName(
            "freeRedeemDryRun for leveraged",
            zeroFee,
            abi.encodeCall(IMinter_v3.freeRedeemDryRun, (0, 1 ether))
        );
        _answersOrRefusesByName(
            "redeemPeggedForCollateralRatio",
            user,
            abi.encodeCall(IMinter_v3.redeemPeggedForCollateralRatio, (1.5 ether, 5 ether, 5 ether, 5 ether, 5 ether))
        );
    }
}
