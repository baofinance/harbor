// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";

/// @notice A genesis - the zero-fee pegged and leveraged mints a Genesis contract makes when it ends - from the states
///         a minter can be in before it. It opens an empty market, in either order of its two mints. Where leveraged
///         tokens already exist its leveraged mint is judged as every leveraged mint is, on the market it starts from:
///         at or above the min CR it is served and worth what it paid, and below the min CR it waits until the market
///         stands there - even for a single wei of leveraged outstanding.
contract TestMinterReGenesis is TestMinterSetUp {
    /// @dev Half of a genesis's pool: Genesis_v2 splits the pool evenly between its two mints.
    uint256 internal constant HALF = 500 ether;
    address internal stranger;
    uint256 internal price;
    uint256 internal rate;

    /// @dev A flat incentive config that allows every retail action down to the peg, so what a stranger can do before
    ///      a genesis is limited only by the code's rules.
    function setUpConfig() internal virtual override {
        setUp_config_flatWide();
    }

    function setUp() public virtual override {
        super.setUp();
        (price, , rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        stranger = makeAddr("stranger");
        deal(wrappedCollateralToken, stranger, 100 ether);
        vm.startPrank(stranger);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        vm.stopPrank();
        deal(wrappedCollateralToken, zeroFee, 2 * HALF);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, type(uint256).max);
        vm.stopPrank();
    }

    /// @dev A wei of backing, as the owner: the one way to move an empty minter's ratio, from one to infinity.
    function _donateAWei() internal {
        deal(wrappedCollateralToken, owner(), 1);
        vm.startPrank(owner());
        IERC20(wrappedCollateralToken).approve(minter, 1);
        IMinter_v3(minter).donateWrappedCollateral(1);
        vm.stopPrank();
    }

    /// @dev A stranger's retail mints before a genesis: leveraged, then pegged. Before a genesis the minter is closed
    ///      to retail, so the stranger needs a donation first: here the owner's wei.
    function _strangerMintsBeforeTheGenesis() internal {
        _donateAWei();
        vm.startPrank(stranger);
        uint256 strangersLeveraged = IMinter(minter).mintLeveragedToken(5 ether, stranger, 0);
        uint256 strangersPegged = IMinter(minter).mintPeggedToken(3 ether, stranger, 0);
        vm.stopPrank();
        assertGt(strangersLeveraged, 0, "precondition: the stranger holds leveraged");
        assertGt(strangersPegged, 0, "precondition: and pegged");
    }

    /// An empty minter reads a collateral ratio of exactly one - under the min CR - so retail mints of pegged and of
    /// leveraged both revert, whatever the incentive config allows, and nothing is taken.
    function test_anEmptyMinter_revertsEveryRetailMint() public {
        assertEq(IMinter(minter).collateralRatio(), 1 ether, "an empty minter reads exactly one");
        bytes memory belowMinimum = abi.encodeWithSelector(
            IMinter_v3.BelowMinimumCollateralRatio.selector,
            1 ether,
            IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO()
        );

        vm.startPrank(stranger);
        vm.expectRevert(belowMinimum);
        IMinter(minter).mintPeggedToken(1 ether, stranger, 0);
        vm.expectRevert(belowMinimum);
        IMinter(minter).mintLeveragedToken(1 ether, stranger, 0);
        vm.stopPrank();
        assertEq(IERC20(wrappedCollateralToken).balanceOf(stranger), 100 ether, "nothing is taken");
    }

    /// On an empty minter a genesis in Genesis_v2's order - the pegged half, which leaves the market exactly at the
    /// peg, then the leveraged half - is served: no leveraged token exists, so the leveraged half is the market's
    /// first and is judged on the market it leaves, at a ratio of two. It holds the whole residual after it, a token
    /// per unit of value; the leveraged price opens at one.
    function test_genesisOnAnEmptyMinter_endsAtTwo() public {
        vm.startPrank(zeroFee);
        uint256 peggedMinted = IMinter(minter).freeMintPeggedToken(HALF, zeroFee);
        uint256 leveragedMinted = IMinter(minter).freeMintLeveragedToken(HALF, zeroFee);
        vm.stopPrank();

        uint256 credit = Math.mulDiv(HALF, rate, 1 ether);
        assertEq(peggedMinted, Math.mulDiv(credit, price, 1 ether), "the pegged half, at the peg");
        assertEq(
            leveragedMinted,
            Math.mulDiv(credit, price, 1 ether),
            "the leveraged half: a token per unit of residual"
        );
        assertEq(IMinter(minter).collateralRatio(), 2 ether, "the market opens at two");
        assertEq(IMinter(minter).leveragedTokenPrice(), 1 ether, "and at a leveraged price of one");
    }

    /// Where a stranger's retail mints have left leveraged tokens outstanding, a genesis that mints its leveraged half
    /// first is served: the market stands above the min CR, and the half receives tokens worth exactly what it paid -
    /// the same count as on an empty minter - leaving the leveraged price at exactly one.
    function test_genesisAfterPreGenesisMints_leveragedFirst_isWorthWhatItPaid() public {
        _strangerMintsBeforeTheGenesis();

        vm.startPrank(zeroFee);
        uint256 leveragedMinted = IMinter(minter).freeMintLeveragedToken(HALF, zeroFee);
        IMinter(minter).freeMintPeggedToken(HALF, zeroFee);
        vm.stopPrank();

        uint256 credit = Math.mulDiv(HALF, rate, 1 ether);
        assertEq(leveragedMinted, Math.mulDiv(credit, price, 1 ether), "the genesis receives a token per unit paid");
        assertEq(IMinter(minter).leveragedTokenPrice(), 1 ether, "and the leveraged price is left at one");
    }

    /// The same market in Genesis_v2's order: the pegged half goes first and leaves the market below the min CR, and
    /// with the stranger's leveraged tokens outstanding the leveraged half is judged there, and reverts.
    function test_genesisAfterPreGenesisMints_peggedFirst_revertsBelowTheMinimum() public {
        _strangerMintsBeforeTheGenesis();
        uint256 minimum = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();

        vm.startPrank(zeroFee);
        IMinter(minter).freeMintPeggedToken(HALF, zeroFee);
        uint256 ratio = IMinter(minter).collateralRatio();
        assertLt(ratio, minimum, "precondition: the pegged half leaves the market below the min CR");
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, minimum));
        IMinter(minter).freeMintLeveragedToken(HALF, zeroFee);
        vm.stopPrank();
    }

    /// The rule holds for a single wei: with a wei of leveraged outstanding and the market at the peg, a genesis's
    /// leveraged half reverts as below the min CR, and a wei donated does not change that. It is served once the
    /// market stands at the min CR - here by the price - at the price before the trade.
    function test_reGenesis_withAWeiOfLeveragedBelowTheMinimum_waitsForTheMinimum() public {
        deal(leveragedToken, stranger, 1, true); // the state, not the path: a wei of leveraged, nothing behind it
        assertEq(IERC20(leveragedToken).totalSupply(), 1, "precondition: a wei of leveraged outstanding");
        assertEq(IMinter(minter).collateralTokenBalance(), 0, "precondition: nothing behind it");
        uint256 minimum = IMinter_v3(minter).MINIMUM_COLLATERAL_RATIO();

        vm.startPrank(zeroFee);
        IMinter(minter).freeMintPeggedToken(HALF, zeroFee);
        uint256 ratio = IMinter(minter).collateralRatio();
        assertLe(ratio, 1 ether, "precondition: the pegged half leaves the market at the peg");
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, minimum));
        IMinter(minter).freeMintLeveragedToken(HALF, zeroFee);
        vm.stopPrank();

        _donateAWei();
        ratio = IMinter(minter).collateralRatio();
        assertLt(ratio, minimum, "precondition: a wei does not bring the market to the min CR");
        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.BelowMinimumCollateralRatio.selector, ratio, minimum));
        IMinter(minter).freeMintLeveragedToken(HALF, zeroFee);
        vm.stopPrank();

        // the least price that reaches the min CR: `minimum x pegged / backing`, rounded up
        uint256 backing = IMinter(minter).collateralTokenBalance();
        uint256 pegged = IMinter(minter).peggedTokenBalance();
        uint256 priceAtTheMinimum = Math.mulDiv(minimum, pegged, backing, Math.Rounding.Ceil);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(priceAtTheMinimum);
        assertEq(IMinter(minter).collateralRatio(), minimum, "precondition: exactly at the min CR");

        vm.startPrank(zeroFee);
        uint256 leveragedMinted = IMinter(minter).freeMintLeveragedToken(HALF, zeroFee);
        vm.stopPrank();
        // the credit's value over the residual before it, times the one wei of leveraged outstanding, floored
        assertEq(
            leveragedMinted,
            (Math.mulDiv(HALF, rate, 1 ether) * priceAtTheMinimum) / (backing * priceAtTheMinimum - pegged * 1 ether),
            "served at the price before the trade"
        );
        assertGt(leveragedMinted, 0, "and receives leveraged");
    }
}
