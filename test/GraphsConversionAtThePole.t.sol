// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMinter} from "@harbor/interfaces/IMinter.sol";
import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {MockWrappedPriceOracle} from "@harbor-test/mocks/MockWrappedPriceOracle.sol";
import {TestConversionBoundReleaseSetUp} from "@harbor-test/TestConversionBoundReleaseSetUp.sol";

/// @notice What the anchor-to-sail conversion does in the last few wei of collateral price above the peg,
/// where the residual the sail is a claim on is about to vanish.
///
/// The conversion mints `anchor x sailSupply / residual`, so as the residual falls the quantity minted
/// rises without limit. What actually stops it is not a rule but a granularity: the residual is
/// `collateral x price - anchorClaim`, and the price is an integer, so one wei of price moves the
/// residual by the whole collateral balance. The smallest residual a market can be in is therefore one
/// collateral balance, not one wei, and THAT is what sets the largest conversion rate the market can
/// ever offer. The sweep is over the price's last digits for exactly that reason - any coarser axis
/// steps straight over the interesting part.
///
/// The second question is where the REPORTED sail price goes to zero. Operations divide by the residual
/// at its full precision, while `leveragedTokenPrice()` reports it scaled to eighteen decimals, so there
/// is a band where the protocol mints sail against a price that every external reader sees as zero. The
/// anchor has a rule for exactly this - `MIN_REPORTABLE_ANCHOR_PRICE_E36`, which refuses to mint below
/// the smallest price it can report - and the sail has no counterpart. This measures how wide the band
/// that rule would cover is.
contract TestGraphsConversionAtThePole is GraphTestBase, TestConversionBoundReleaseSetUp {
    /// @dev How many doublings of the price offset above parity to walk. 2^60 wei of price is far past
    ///      the point where the market is ordinary again, so the walk covers the whole approach.
    uint256 private constant OFFSETS = 61;

    string private file;

    function setUp() public virtual override {
        super.setUp();
        file = openFile(
            "conversion_at_the_pole",
            sa(
                "collateral price above parity (wei)",
                "collateral ratio",
                "residual backing the sail (e36)",
                "reported sail price",
                "sail minted for one anchor token",
                "sail supply multiple after the conversion"
            )
        );
    }

    /// @dev The collateral price at which the anchor claim exactly exhausts the collateral value, so the
    ///      residual is zero and the sail is worth nothing. Rounded up, so the market sits AT parity
    ///      rather than below it, and every offset added to it is a residual the market really has.
    function _parityPrice() private view returns (uint256) {
        return
            Math.mulDiv(
                IMinter(minter).peggedTokenBalance(),
                1 ether,
                IMinter(minter).collateralTokenBalance(),
                Math.Rounding.Ceil
            );
    }

    /// @notice The rate, the reported price and the supply growth through the last wei of price above the
    /// peg - the region every bound in this design exists to cover, measured with none in place.
    function test_theApproachToThePole() public {
        uint256 parity = _parityPrice();

        for (uint256 i = 0; i < OFFSETS; i++) {
            uint256 offset = i == 0 ? 0 : uint256(1) << (i - 1);
            uint256 snapshot = vm.snapshotState();
            MockWrappedPriceOracle(priceOracle).setLatestAnswer(parity + offset);

            uint256 sailSupplyBefore = IMinter(minter).leveragedTokenBalance();
            uint256 collateralValueE36 = IMinter(minter).collateralTokenBalance() * (parity + offset);
            uint256 anchorClaimE36 = IMinter(minter).peggedTokenBalance() * 1 ether;

            int256 sailOut = NaN;
            int256 supplyMultiple = NaN;
            try IMinter_v3(minter).freeRedeemPeggedToken(0, ANCHOR_IN, address(this)) returns (uint256, uint256 out) {
                sailOut = int256(out);
                supplyMultiple = int256(
                    Math.mulDiv(IMinter(minter).leveragedTokenBalance(), 1 ether, sailSupplyBefore)
                );
            } catch (bytes memory reason) {
                // refused here by the leverage cap, and a gap says so
                _requireLeverageCapRefusal(reason);
            }
            writeLine(
                file,
                ia(
                    int256(offset),
                    int256(IMinter(minter).collateralRatio()),
                    int256(collateralValueE36 > anchorClaimE36 ? collateralValueE36 - anchorClaimE36 : 0),
                    int256(IMinter_v3(minter).leveragedTokenPrice()),
                    sailOut,
                    supplyMultiple
                ),
                _decimals()
            );

            vm.revertToStateAndDelete(snapshot);
        }
        vm.closeFile(file);
    }

    /// @dev The price offset and the residual are counts, not ratios, and span far too many orders of
    ///      magnitude to be read as fixed point; everything else is an ordinary 18-decimal quantity.
    function _decimals() private pure returns (uint8[] memory decimals) {
        decimals = new uint8[](6);
        decimals[0] = 0;
        decimals[1] = 18;
        decimals[2] = 0;
        decimals[3] = 18;
        decimals[4] = 18;
        decimals[5] = 18;
    }
}
