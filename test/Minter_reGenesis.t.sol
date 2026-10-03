// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice A genesis - the zero-fee pegged and leveraged mints a Genesis contract makes when it ends - from the states
///         a minter can be in before it: empty, holding a stranger's retail mints, or holding a leveraged token that
///         nothing backs. A genesis is never stopped for good: at most it needs more collateral, or a wei donated.
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

    /// @dev Genesis_v2's end: the pegged half, then the leveraged half, both zero-fee, to the genesis itself.
    function _endGenesis() internal returns (uint256 peggedMinted, uint256 leveragedMinted) {
        vm.startPrank(zeroFee);
        peggedMinted = IMinter(minter).freeMintPeggedToken(HALF, zeroFee);
        leveragedMinted = IMinter(minter).freeMintLeveragedToken(HALF, zeroFee);
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
    /// peg, then the leveraged half - is served: the leveraged half is judged on the market it leaves, at a ratio of
    /// two, and holds the whole residual after it, a token per unit of value; the leveraged price opens at one.
    function test_genesisOnAnEmptyMinter_endsAtTwo() public {
        (uint256 peggedMinted, uint256 leveragedMinted) = _endGenesis();

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

    /// A stranger's retail mints before a genesis change nothing for it: whatever leveraged and pegged they leave, the
    /// genesis's leveraged half receives tokens worth exactly what it paid - the same count as on an empty minter - and
    /// the market opens at a leveraged price of exactly one. Before a genesis the minter is closed to retail, so the
    /// stranger needs a donation first: here the owner's wei.
    function test_genesisAfterPreGenesisMints_isWorthWhatItPaid() public {
        _donateAWei();
        vm.startPrank(stranger);
        uint256 strangersLeveraged = IMinter(minter).mintLeveragedToken(5 ether, stranger, 0);
        uint256 strangersPegged = IMinter(minter).mintPeggedToken(3 ether, stranger, 0);
        vm.stopPrank();
        assertGt(strangersLeveraged, 0, "precondition: the stranger holds leveraged");
        assertGt(strangersPegged, 0, "precondition: and pegged");

        (, uint256 leveragedMinted) = _endGenesis();

        uint256 credit = Math.mulDiv(HALF, rate, 1 ether);
        assertEq(leveragedMinted, Math.mulDiv(credit, price, 1 ether), "the genesis receives a token per unit paid");
        assertEq(IMinter(minter).leveragedTokenPrice(), 1 ether, "and the market opens at a leveraged price of one");
    }

    /// A leveraged token outstanding with nothing behind it - the wei a stranger could leave by redeeming all but one
    /// - gives a genesis's leveraged half no residual to share, so it mints nothing and reverts as such. A wei donated
    /// first creates the residual: the half is then served, its tokens worth what it paid and all but one of them its.
    function test_genesisAfterAOneWeiLeveragedResidue_needsAWeiDonated() public {
        deal(leveragedToken, stranger, 1, true); // the state, not the path: a wei of leveraged, nothing behind it
        assertEq(IERC20(leveragedToken).totalSupply(), 1, "precondition: a wei of leveraged outstanding");
        assertEq(IMinter(minter).collateralTokenBalance(), 0, "precondition: nothing behind it");

        vm.startPrank(zeroFee);
        IMinter(minter).freeMintPeggedToken(HALF, zeroFee);
        vm.expectRevert(abi.encodeWithSelector(IMinter.ReturnZeroAmount.selector, leveragedToken));
        IMinter(minter).freeMintLeveragedToken(HALF, zeroFee);
        vm.stopPrank();

        _donateAWei();

        vm.startPrank(zeroFee);
        uint256 leveragedMinted = IMinter(minter).freeMintLeveragedToken(HALF, zeroFee);
        vm.stopPrank();
        // the credit's share of a residual of one wei of collateral, in the one token outstanding: a token a wei
        uint256 credit = Math.mulDiv(HALF, rate, 1 ether);
        assertEq(leveragedMinted, credit, "a token per wei of collateral paid");
        assertEq(IMinter(minter).leveragedTokenPrice(), price, "each worth a collateral token");
    }
}
