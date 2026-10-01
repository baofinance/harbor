// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";
import {IHarborRoles} from "@bao/interfaces/IHarborRoles.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// @notice The four `free*` mint/redeem functions are `onlyOwnerOrRoles(ZERO_FEE_ROLE)`: the owner is authorised
/// without holding the role, and a caller that is neither the owner nor a ZERO_FEE_ROLE holder is rejected - a
/// harvester included, whose role reaches the sweep and nothing else. setUp mints the starting pool as the
/// ZERO_FEE_ROLE holder, so the role path stays exercised too.
contract TestMinterFreeOwnerAuth is TestMinterSetUp {
    address harvester;

    function setUpConfig() internal virtual override {
        setUp_config_flatWide();
    }

    function setUp() public virtual override {
        super.setUp();
        setUp_collateral(3 ether, 1 ether); // populated pool, minted as the ZERO_FEE_ROLE holder
        assertFalse(
            IHarborRoles(minter).hasAnyRole(owner(), IMinter(minter).ZERO_FEE_ROLE()),
            "owner must not hold ZERO_FEE_ROLE, else these tests would not exercise the owner path"
        );
        harvester = makeAddr("harvester");
        uint256 harvesterRole = IMinter(minter).HARVESTER_ROLE();
        vm.startPrank(owner());
        IHarborRoles(minter).grantRoles(harvester, harvesterRole);
        vm.stopPrank();
    }

    /// A harvester cannot free-mint pegged.
    function test_freeMintPeggedToken_isRefusedToAHarvester() public {
        vm.startPrank(harvester);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        IMinter(minter).freeMintPeggedToken(1 ether, harvester);
        vm.stopPrank();
    }

    /// A harvester cannot free-mint leveraged.
    function test_freeMintLeveragedToken_isRefusedToAHarvester() public {
        vm.startPrank(harvester);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        IMinter(minter).freeMintLeveragedToken(1 ether, harvester);
        vm.stopPrank();
    }

    /// A harvester cannot free-redeem pegged.
    function test_freeRedeemPeggedToken_isRefusedToAHarvester() public {
        vm.startPrank(harvester);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        IMinter(minter).freeRedeemPeggedToken(1 ether, 0, harvester);
        vm.stopPrank();
    }

    /// A harvester cannot free-redeem leveraged.
    function test_freeRedeemLeveragedToken_isRefusedToAHarvester() public {
        vm.startPrank(harvester);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        IMinter(minter).freeRedeemLeveragedToken(1 ether, harvester);
        vm.stopPrank();
    }

    function test_freeMintPeggedToken_ownerAuthorisedWithoutRole() public {
        deal(wrappedCollateralToken, owner(), 1 ether);
        vm.startPrank(owner());
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        uint256 minted = IMinter(minter).freeMintPeggedToken(1 ether, owner());
        vm.stopPrank();
        assertGt(minted, 0, "owner free-minted pegged");
        assertEq(IERC20(peggedToken).balanceOf(owner()), minted, "owner received the pegged");
    }

    function test_freeMintLeveragedToken_ownerAuthorisedWithoutRole() public {
        deal(wrappedCollateralToken, owner(), 1 ether);
        vm.startPrank(owner());
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        uint256 minted = IMinter(minter).freeMintLeveragedToken(1 ether, owner());
        vm.stopPrank();
        assertGt(minted, 0, "owner free-minted leveraged");
        assertEq(IERC20(leveragedToken).balanceOf(owner()), minted, "owner received the leveraged");
    }

    function test_freeRedeemPeggedToken_ownerAuthorisedWithoutRole() public {
        deal(wrappedCollateralToken, owner(), 1 ether);
        vm.startPrank(owner());
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        uint256 minted = IMinter(minter).freeMintPeggedToken(1 ether, owner());
        IERC20(peggedToken).approve(minter, minted);
        (uint256 collateralOut, ) = IMinter(minter).freeRedeemPeggedToken(minted, 0, owner());
        vm.stopPrank();
        assertGt(collateralOut, 0, "owner free-redeemed pegged for collateral");
    }

    function test_freeRedeemLeveragedToken_ownerAuthorisedWithoutRole() public {
        deal(wrappedCollateralToken, owner(), 1 ether);
        vm.startPrank(owner());
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        uint256 minted = IMinter(minter).freeMintLeveragedToken(1 ether, owner());
        IERC20(leveragedToken).approve(minter, minted);
        uint256 collateralOut = IMinter(minter).freeRedeemLeveragedToken(minted, owner());
        vm.stopPrank();
        assertGt(collateralOut, 0, "owner free-redeemed leveraged");
    }

    function test_freeMintPeggedToken_nonOwnerNonRoleReverts() public {
        address stranger = makeAddr("stranger");
        deal(wrappedCollateralToken, stranger, 1 ether);
        vm.startPrank(stranger);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        IMinter(minter).freeMintPeggedToken(1 ether, stranger);
        vm.stopPrank();
    }
}
