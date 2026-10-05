// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {Token} from "@bao/Token.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";
import {IWrappedPriceOracle} from "@bao/interfaces/IWrappedPriceOracle.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {IBaoRoles} from "@bao/interfaces/IBaoRoles.sol";
import {IHarborOwnable} from "@bao/interfaces/IHarborOwnable.sol";

import {TestMinterSetUp} from "@harbor-test/Minter_base.t.sol";

/// How the protocol responds to the collateral it holds losing value, and how collateral given to it
/// as backing restores that.
contract MinterSlashTest is TestMinterSetUp {
    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    /// An address holding the donor role, and no other.
    function _donor() private returns (address donor) {
        donor = makeAddr("donor");
        vm.startPrank(owner());
        IBaoRoles(minter).grantRoles(donor, IMinter_v3(minter).DONOR_ROLE());
        vm.stopPrank();
    }

    /// `donor` donates `wrappedAmount`, funded and approved for exactly that.
    function _donate(address donor, uint256 wrappedAmount) private {
        deal(wrappedCollateralToken, donor, wrappedAmount);
        vm.startPrank(donor);
        IERC20(wrappedCollateralToken).approve(minter, wrappedAmount);
        IMinter_v3(minter).donateWrappedCollateral(wrappedAmount);
        vm.stopPrank();
    }

    /// A rate rise is yield: it becomes harvestable, and moves neither the backing nor any price.
    /// A rate fall past that surplus takes effect at once, without anyone acting: the market halts. The views
    /// go on reporting the record, because deciding the fall is a real loss is the owner's call, and every
    /// update refuses until that call is made - which is when the ratio falls to what is held.
    function test_slash_haltsTheMarketWithoutIntervention() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();

        setUp_collateral(100 ether, 40 ether); // CR = 140%

        assertEq(IMinter(minter).collateralRatio(), 1.4 ether, "start CR");
        assertEq(IMinter(minter).leverageRatio(), 3.5 ether, "start leverage ratio");
        assertEq(IMinter(minter).harvestable(), 0, "start harvestable");

        // 1% of yield: the surplus grows, the backing does not
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 101) / 100);

        assertEq(IMinter(minter).collateralRatio(), 1.4 ether, "yield does not move the ratio");
        assertEq(IMinter(minter).leverageRatio(), 3.5 ether, "yield does not move leverage");
        // The 140 wrapped held, less what the record of 140 collateral needs at the risen rate - that need rounded up,
        // so a harvest of all of it leaves the record covered.
        assertEq(
            IMinter(minter).harvestable(),
            140 ether - Math.ceilDiv(140 ether * 1 ether, (rate * 101) / 100),
            "yield is harvestable"
        );

        // a 10% fall, far past the 1% surplus
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, (rate * 9) / 10);

        assertEq(IMinter(minter).collateralRatio(), 1.4 ether, "the ratio reports the record");
        assertEq(IMinter(minter).harvestable(), 0, "a shortfall is not a surplus");
        (uint256 recorded, uint256 held) = IMinter_v3(minter).impairment();
        assertEq(held, 126 ether, "the holding is worth 126 at the fallen rate");
        assertEq(recorded, 140 ether, "against a record of 140");

        deal(wrappedCollateralToken, zeroFee, 1 ether);
        vm.startPrank(zeroFee);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(IMinter_v3.UnrecognisedImpairment.selector, recorded, held));
        IMinter(minter).mintPeggedToken(1 ether, zeroFee, 0);
        vm.stopPrank();

        // the owner judges it a real loss
        vm.startPrank(owner());
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();

        assertEq(IMinter(minter).collateralRatio(), 1.26 ether, "recognised, the ratio falls to what is held");
        assertEq(IMinter(minter).leverageRatio(), 4846153846153846153, "leverage rises as cover falls");
    }

    /// Collateral given as backing raises the ratio, and is credited at exactly what it is worth. Given after a
    /// loss has been recognised, it makes the ratio whole again, but for the wei its two conversions floor away.
    function test_donateWrappedCollateral_restoresTheRatio() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(100 ether, 40 ether);

        uint256 fallenRate = (rate * 9) / 10;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, fallenRate);
        vm.startPrank(owner());
        IMinter_v3(minter).recogniseImpairment();
        vm.stopPrank();
        assertEq(IMinter_v3(minter).collateralRatio(), 1.26 ether, "loss recognised");

        // the shortfall is 14 collateral tokens; at the reduced rate that is 14/0.9 wrapped
        uint256 makeGood = (14 ether * 1 ether) / fallenRate;
        _donate(_donor(), makeGood);

        // 14/0.9 wrapped is floored, to 15.555...555, and its value at 0.9 floored again, to 14 less a wei: the record
        // ends a wei short of 140, which puts the ratio, 1.4 at a record of 140, a wei short of 1.4.
        assertEq(IMinter_v3(minter).collateralRatio(), 1.4 ether - 1, "the ratio is made whole, less the wei floored");
        // The holding is now 140 and 15.555...555 wrapped, which is exactly what a record a wei short of 140 needs at
        // 0.9, rounded up: none of the donation is left over as yield.
        assertEq(IMinter_v3(minter).harvestable(), 0, "a donation is backing, not yield");
    }

    /// A donation is credited at the low edge of the rate band, as every credit to the record is, so it never stands
    /// for more backing than the holding gains. The ratio rises with the record, and so does the leveraged price:
    /// the pegged claim is unchanged, so the whole credit is residual, shared across the leveraged supply.
    function test_donation_creditsItsValueAtTheMinRateAndRaisesTheLeveragedPrice() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(100 ether, 40 ether);
        uint256 minRate = (rate * 105) / 100;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, price, minRate, (rate * 115) / 100);

        address donor = _donor();
        // at 1.05 the 7 wei are worth 7.35 collateral wei, so a credit rounded up would be a wei more
        uint256 donation = 10 ether + 7;
        deal(wrappedCollateralToken, donor, donation);
        uint256 recordBefore = IMinter_v3(minter).collateralTokenBalance();
        uint256 minterWrappedBefore = IERC20(wrappedCollateralToken).balanceOf(minter);
        uint256 leveragedPriceBefore = IMinter_v3(minter).leveragedTokenPrice();
        uint256 credit = Math.mulDiv(donation, minRate, 1 ether);

        vm.startPrank(donor);
        IERC20(wrappedCollateralToken).approve(minter, donation);
        vm.expectEmit(minter);
        emit IMinter_v3.DonateWrappedCollateral(donor, donation, credit, recordBefore + credit);
        IMinter_v3(minter).donateWrappedCollateral(donation);
        vm.stopPrank();

        assertEq(IMinter_v3(minter).collateralTokenBalance(), recordBefore + credit, "credited at the min rate");
        assertEq(IERC20(wrappedCollateralToken).balanceOf(donor), 0, "the donor gives up the whole donation");
        assertEq(
            IERC20(wrappedCollateralToken).balanceOf(minter),
            minterWrappedBefore + donation,
            "the minter holds it"
        );
        assertEq(
            IMinter_v3(minter).collateralRatio(),
            Math.mulDiv(recordBefore + credit, price, IMinter_v3(minter).peggedTokenBalance()),
            "the ratio rises with the record"
        );
        // A residual of 80,000 across 80,000 leveraged tokens prices each at exactly one, with nothing floored, so the
        // price after the donation is one plus the credit's value per leveraged token, floored once.
        assertEq(leveragedPriceBefore, 1 ether, "the leveraged price starts with no remainder");
        assertEq(
            IMinter_v3(minter).leveragedTokenPrice(),
            leveragedPriceBefore + Math.mulDiv(credit, price, IERC20(leveragedToken).totalSupply()),
            "the leveraged price rises by the credit's value per leveraged token"
        );
    }

    /// Wrapped collateral simply transferred in is yield for the stability pools, and moves neither
    /// the backing nor any price. The two routes are distinct and must stay so.
    function test_plainTransfer_becomesYieldNotBacking() public {
        setUp_collateral(100 ether, 40 ether);
        uint256 ratioBefore = IMinter(minter).collateralRatio();
        uint256 leveragedPriceBefore = IMinter(minter).leveragedTokenPrice();

        deal(wrappedCollateralToken, address(this), 10 ether);
        IERC20(wrappedCollateralToken).transfer(minter, 10 ether);

        assertEq(IMinter(minter).collateralRatio(), ratioBefore, "a transfer is not backing");
        assertEq(IMinter(minter).leveragedTokenPrice(), leveragedPriceBefore, "and moves no price");
        assertEq(IMinter(minter).harvestable(), 10 ether, "it is yield for the pools");
    }

    /// A donation may only ever add what it supplies. The surplus already held belongs to the stability pools, and
    /// no caller may absorb it into backing: harvestable after a donation is at least what it was. It gains no more
    /// than rounding either - the credit and the holding are each floored at the min rate, apart, and the holding's
    /// floor can gain at most ceil(1e18 / min rate) wrapped wei of harvestable over the credit's. Under a band, so a
    /// credit at the high edge, which would absorb the surplus, is not mistaken for one at the low.
    function test_donateWrappedCollateral_cannotAbsorbTheExistingSurplus() public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(100 ether, 40 ether);

        uint256 minRate = (rate * 105) / 100;
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, price, minRate, (rate * 115) / 100);
        uint256 surplus = IMinter_v3(minter).harvestable();
        assertGt(surplus, 0, "a surplus must exist for this to test anything");

        _donate(_donor(), 1 ether);

        uint256 harvestableAfter = IMinter_v3(minter).harvestable();
        assertGe(harvestableAfter, surplus, "the pools' surplus survives a donation untouched");
        assertLe(harvestableAfter, surplus + Math.ceilDiv(1 ether, minRate), "and gains no more than the rounding");
    }

    /// A donation to a halted market credits the record with its value at the min rate, floored, while the holding
    /// gains that value floored as part of the whole - the credit, or a wei more. So a donation never widens a
    /// shortfall and narrows it by at most a wei: a halted market stays halted, unless its whole shortfall was that wei.
    function testFuzz_donation_neverWidensAShortfallAndNarrowsItByAtMostOneWei(
        uint256 donation,
        uint256 minRate,
        uint256 maxRate
    ) public {
        (uint256 price, , uint256 rate, ) = IWrappedPriceOracle(priceOracle).latestAnswer();
        setUp_collateral(100 ether, 40 ether);
        // any low edge below the rate of the market's genesis leaves the record above what the holding converts to
        minRate = bound(minRate, rate / 1e6, rate - 1);
        maxRate = bound(maxRate, minRate, 2 * rate);
        MockWrappedPriceOracle(priceOracle).setLatestAnswer(price, price, minRate, maxRate);
        (uint256 recordedBefore, uint256 heldBefore) = IMinter_v3(minter).impairment();
        uint256 shortfall = recordedBefore - heldBefore;
        assertGt(shortfall, 0, "the market must be halted for this to test anything");

        _donate(_donor(), bound(donation, 1, 1e9 ether));

        (uint256 recordedAfter, uint256 heldAfter) = IMinter_v3(minter).impairment();
        assertLe(recordedAfter, heldAfter + shortfall, "a donation never widens the shortfall");
        assertGe(recordedAfter + 1, heldAfter + shortfall, "and narrows it by at most a wei");
    }

    /// Donating is for the owner, the zero-fee role and the donor role. Anyone else reverts, so no stranger can move a
    /// market's collateral ratio - or lift an empty minter's from one, where it is closed to retail, to infinity.
    function test_donateWrappedCollateral_withoutARole_reverts() public {
        setUp_collateral(100 ether, 40 ether);

        address anyone = makeAddr("anyone");
        deal(wrappedCollateralToken, anyone, 1 ether);
        vm.startPrank(anyone);
        IERC20(wrappedCollateralToken).approve(minter, 1 ether);
        vm.expectRevert(IHarborOwnable.Unauthorized.selector);
        IMinter_v3(minter).donateWrappedCollateral(1 ether);
        vm.stopPrank();
    }

    /// The owner, the zero-fee role and the donor role each donate, and each donation is taken as backing.
    function test_donateWrappedCollateral_asOwnerZeroFeeOrDonor_isServed() public {
        setUp_collateral(100 ether, 40 ether);

        address[3] memory donors = [owner(), zeroFee, _donor()];
        for (uint256 i = 0; i < donors.length; i++) {
            uint256 backingBefore = IMinter(minter).collateralTokenBalance();
            _donate(donors[i], 1 ether);
            assertGt(IMinter(minter).collateralTokenBalance(), backingBefore, "the donation is taken as backing");
        }
    }

    /// A donation of nothing reverts by name, for a caller allowed to donate.
    function test_donateWrappedCollateral_refusesZero() public {
        setUp_collateral(100 ether, 40 ether);

        vm.startPrank(zeroFee);
        vm.expectRevert(abi.encodeWithSelector(Token.ZeroInputBalance.selector, wrappedCollateralToken));
        IMinter_v3(minter).donateWrappedCollateral(0);
        vm.stopPrank();
    }
}
