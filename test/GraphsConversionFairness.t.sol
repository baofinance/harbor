// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMinter_v3} from "@harbor/interfaces/IMinter_v3.sol";

import {BaoTestLib} from "@bao-test/BaoTestLib.sol";
import {GraphTestBase} from "@bao-test/GraphTestBase.t.sol";
import {TestCollateralRatioRangeSetUp} from "@harbor-test/CollateralRatio.t.sol";

/// @notice Graphs what a pegged-to-leveraged conversion returns per unit of pegged given up, against the
/// collateral ratio and against the size of the conversion.
///
/// The bound fixes the CONVERSION RATE a conversion is given - leveraged minted per unit of pegged value -
/// but what that conversion rate is worth is settled by the leveraged price the conversion itself leaves
/// behind: minting leveraged dilutes the leveraged already outstanding, so a large enough conversion dilutes
/// itself. The same bound that hands a small conversion five percent more value than it gave up hands a
/// large one almost exactly what it gave up. Conversion size is therefore a dimension of the bound's
/// unfairness rather than a detail of it, which is why it is swept.
///
/// Size is measured against the residual - the collateral value left once every pegged token is covered
/// - because that is what the leveraged is a claim on, and so what a conversion dilutes. The largest possible
/// conversion gives up every pegged token in existence, which is 1/(collateral ratio - 1) of the
/// residual, so the larger sizes become impossible as the collateral ratio rises and their lines stop:
/// that is the market having no more pegged to convert, and is left as a gap rather than drawn as a
/// number.
///
/// Every point is MEASURED: pegged is put through the conversion and the leveraged received is valued at the
/// price the market reports afterwards. Recomputing it from the same inputs the contract uses would
/// agree by construction and show nothing.
contract TestGraphsConversionFairness is GraphTestBase, TestCollateralRatioRangeSetUp {
    /// @dev Sizes as a fraction of the residual, four orders of magnitude of them because the effect
    ///      is a function of size across orders of magnitude: the smallest stands in for a conversion
    ///      too small to move the price, the largest for one giving up several times the residual.
    uint256[5] private conversionSizes = [0.001 ether, 0.01 ether, 0.1 ether, 1 ether, 10 ether];

    string private file;

    function setUpConfig() internal virtual override {
        setUp_config_likely();
    }

    /// @dev The leveraged holds the residual, and at or below a collateral ratio of 1 there is none - so there
    ///      is nothing for a conversion size to be a fraction of and nothing to measure. The sweep starts
    ///      one step above it rather than spending five hundred points that would every one be a gap.
    function setUpRange() internal override {
        super.setUpRange();
        start = 1 ether + increment;
    }

    function setUp() public virtual override {
        super.setUp();

        // Each column is named from the size that produced it, so the two cannot drift apart.
        string[] memory header = new string[](conversionSizes.length + 1);
        header[0] = "collateral ratio";
        for (uint256 i = 0; i < conversionSizes.length; i++) {
            header[i + 1] = string.concat(
                BaoTestLib.toStringScaled((conversionSizes[i] * 1000) / 1 ether, 1),
                "% of the residual converted"
            );
        }
        file = openFile("rebalance_conversion_fairness", header);
    }

    function setDown() internal override {
        vm.closeFile(file);
    }

    /// @dev One percent of a line's own magnitude, as for the trigger graph: these lines share its
    ///      discontinuity at the collateral ratio where the bound lets go, and that moves them by far
    ///      more.
    function refinementTolerance() internal pure override returns (uint256) {
        return 0.01 ether;
    }

    /// @dev Every line this graph draws at the market's current collateral ratio, in the order the header
    ///      names them. Shared by the recording and by refinement, so what is judged is exactly what is
    ///      drawn.
    function _lines() private returns (int256[] memory lines) {
        lines = new int256[](conversionSizes.length);
        for (uint256 i = 0; i < conversionSizes.length; i++) {
            lines[i] = _valuePerPeggedConverted(conversionSizes[i]);
        }
    }

    function doOneCollateralRatio(uint256 collateralRatio) internal override {
        int256[] memory lines = _lines();
        int256[] memory row = new int256[](lines.length + 1);
        row[0] = int256(collateralRatio);
        for (uint256 i = 0; i < lines.length; i++) {
            row[i + 1] = lines[i];
        }
        writeLine(file, row);
    }

    /// @inheritdoc TestCollateralRatioRangeSetUp
    function refinementSignals() internal override returns (int256[] memory) {
        return _lines();
    }

    /// @dev Convert `sizeOfResidual` of the residual from pegged into leveraged, and report what came back
    ///      per unit of pegged given up - the leveraged valued at the price the conversion itself left
    ///      behind, which is the price its holder now owns. One means the conversion was fair; above
    ///      one it took value from the leveraged already outstanding, below one it gave value to it.
    function _valuePerPeggedConverted(uint256 sizeOfResidual) private returns (int256 valuePerPegged) {
        uint256 peggedPrice = IMinter_v3(minter).peggedTokenPrice();
        uint256 residual = (IMinter_v3(minter).leveragedTokenBalance() * IMinter_v3(minter).leveragedTokenPrice()) /
            1 ether;
        if (residual == 0 || peggedPrice == 0) {
            return NaN;
        }

        uint256 peggedIn = (((residual * sizeOfResidual) / 1 ether) * 1 ether) / peggedPrice;
        // More pegged than exists cannot be converted, and a size that rounds away to nothing measures
        // nothing. Both are gaps rather than numbers.
        if (peggedIn == 0 || IERC20(peggedToken).balanceOf(address(this)) < peggedIn) {
            return NaN;
        }

        uint256 snapshot = vm.snapshotState();
        valuePerPegged = NaN;
        try IMinter_v3(minter).freeRedeemPeggedToken(0, peggedIn, address(this)) returns (
            uint256,
            uint256 leveragedOut
        ) {
            uint256 valueOut = (leveragedOut * IMinter_v3(minter).leveragedTokenPrice()) / 1 ether;
            uint256 valueIn = (peggedIn * peggedPrice) / 1 ether;
            valuePerPegged = int256((valueOut * 1 ether) / valueIn);
        } catch (bytes memory reason) {
            // the conversion is refused here by the leverage cap; a gap says so
            _requireLeverageCapRefusal(reason);
        }
        vm.revertToState(snapshot);
    }
}
